# 05 — Pipeline Spec (aws-devsecops-pipeline-module)

> This doc covers two things:
> 1. **The pipeline this module creates** — stages, buildspecs, CodeStar setup
> 2. **The module's own release process** — how to develop, validate, and tag a new module version

---

## Pipeline Overview (What the Module Creates)

### Base Mode (`enable_container_scan = false`)

```
┌─────────────────────────────────────────────────────────────────┐
│                    Push to var.branch (default: main)           │
└───────────────────────────┬─────────────────────────────────────┘
                            │ CodeStar Connection webhook
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Stage 1: Source                                                │
│  Pulls source artifact from GitHub → stores in S3              │
│  Output artifact: SourceArtifact                               │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Stage 2: Security Scan                          BLOCKS HERE   │
│  CodeBuild: ${app_name}-security-scan                          │
│  Image: local.scanner_images[var.language]                     │
│  pre-commit run --all-files                                    │
│  Input: SourceArtifact                                         │
└─────────────────────────────────────────────────────────────────┘
```

### Container Scan Mode (`enable_container_scan = true`)

```
┌─────────────────────────────────────────────────────────────────┐
│  Stage 1: Source                                                │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Stage 2: Security Scan                          BLOCKS HERE   │
└───────────────────────────┬─────────────────────────────────────┘
                            │ exit 0 on all hooks
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Stage 3: Build & Scan Image                     BLOCKS HERE   │
│  CodeBuild: ${app_name}-build-scan                             │
│  Image: aws/codebuild/standard:7.0 (privileged)               │
│  docker build → trivy → docker push to ECR                    │
│  Input: SourceArtifact                                         │
│  Output: BuildArtifact (imagedefinitions.json + image_uri.env) │
└─────────────────────────────────────────────────────────────────┘
```

The consuming project's deployment pipeline takes over from ECR after Stage 3 completes.

---

## CodeStar Connection Setup (One-Time Manual Step)

CodeStar Connections require a human GitHub OAuth authorization. Terraform can create the connection resource, but it starts in `PENDING` state. The human click in the console moves it to `AVAILABLE`.

### Step-by-Step

1. Open AWS Console → **CodePipeline** → **Settings** → **Connections**
2. Click **Create connection**
3. Provider: **GitHub**
4. Connection name: `github-connection` (or any name — must match your `codestar_connection_arn` variable)
5. Click **Connect to GitHub** → complete OAuth authorization
6. Click **Connect** — status changes to **Available**
7. Copy the full Connection ARN (format: `arn:aws:codeconnections:us-east-1:<account-id>:connection/<uuid>`)
8. Add to consuming project's `terraform.tfvars` as `codestar_connection_arn`

> This is the only manual AWS console step required. One connection per AWS account can serve all pipelines.

---

## Buildspec Reference

### Stage 2 — `buildspecs/scan.yml`

```yaml
version: 0.2

phases:
  install:
    commands:
      # pre-commit is already installed in the scanner image
      # This install step handles any consuming-project pre-commit hooks
      # that require additional packages not in the scanner image
      - echo "Scanner image: $CODEBUILD_BUILD_IMAGE"
  pre_build:
    commands:
      - echo "Running security scan (language: $LANGUAGE)"
  build:
    commands:
      # --show-diff-on-failure prints which lines triggered the finding
      - pre-commit run --all-files --show-diff-on-failure
  post_build:
    commands:
      - echo "Security scan completed successfully"

cache:
  paths:
    - '/root/.cache/pre-commit/**/*'
    - '/root/.cache/pip/**/*'
```

**Failure behavior:** `pre-commit` exits non-zero on any hook failure. CodeBuild propagates the exit code. CodePipeline marks the stage FAILED. Stage 3 (if configured) does not run.

**Environment variables injected by Terraform:** `LANGUAGE` (for logging only — the scanner image is already selected by Terraform before CodeBuild starts).

---

### Stage 3 — `buildspecs/build.yml` (`enable_container_scan = true` only)

```yaml
version: 0.2

env:
  variables:
    ECR_REPO: ""         # injected by Terraform module (the consuming project's private ECR URL)
    AWS_REGION: "us-east-1"

phases:
  pre_build:
    commands:
      # Authenticate to private ECR for push
      - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO
      # Short commit SHA used as image tag — immutable, traceable to exact commit
      - COMMIT_SHA=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-8)
      - IMAGE_TAG=$COMMIT_SHA
      - IMAGE_URI=$ECR_REPO:$IMAGE_TAG
  build:
    commands:
      # Dockerfile expected at sample-app/Dockerfile in the consuming project
      - docker build -t $IMAGE_URI sample-app/
  post_build:
    commands:
      # Block on CRITICAL unfixed CVEs — image is NOT pushed if this exits 1
      - trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 $IMAGE_URI
      - echo "Trivy scan passed — pushing image"
      - docker push $IMAGE_URI
      # These files are passed as artifacts to the consuming project's deployment stage
      - echo "IMAGE_URI=$IMAGE_URI" > image_uri.env
      - printf '[{"name":"app","imageUri":"%s"}]' $IMAGE_URI > imagedefinitions.json

artifacts:
  files:
    - imagedefinitions.json
    - image_uri.env

cache:
  paths:
    - '/root/.docker/**/*'
```

**Failure behavior:** If trivy exits 1 (CRITICAL CVEs found), the image is not pushed. Stage 3 is FAILED. The base image or dependency with the CVE must be updated and the pipeline re-run.

**Note on `--ignore-unfixed`:** Only CRITICAL CVEs with an available fix are blocked. Known CVEs without a patch do not block the pipeline — they are logged in the build output for visibility.

---

## Pipeline Stage Configuration in Terraform

Artifact passing pattern:

```
Stage 1 Output → SourceArtifact
Stage 2 Input  → SourceArtifact  (no output artifact — passes or blocks)
Stage 3 Input  → SourceArtifact  (enable_container_scan = true only)
Stage 3 Output → BuildArtifact   (imagedefinitions.json + image_uri.env)
```

Stage 3 is added via a Terraform `dynamic` block — it only exists in the pipeline when `var.enable_container_scan = true`.

---

## Pipeline Trigger — What Does and Does Not Trigger

| Event | Triggers Pipeline? |
|-------|--------------------|
| Push to `var.branch` (default: `main`) | Yes |
| Push to any other branch | No |
| Pull request opened/updated | No |
| Manual execution from console | Yes (Terraform does not disable this) |
| CodePipeline stage retry | Yes (from the failed stage forward) |

There is no PR pipeline in v1. All security gates run on merge to `main`. For pre-merge checks, the optional local pre-commit setup (via `scripts/setup-dev.sh`) provides equivalent feedback before pushing.

---

## Module Release Process

This module does not have its own CI/CD pipeline (no self-hosting pipeline for a pipeline module). The release process is manual:

```
1. Make changes to infra/modules/pipeline/ or scanner-images/
2. Test locally:
   - terraform validate   (in infra/modules/pipeline/)
   - terraform fmt -check (in infra/modules/pipeline/)
   - checkov -d infra/    (IaC scan on the module itself)
   - docker build         (scanner images, if changed)
3. Commit and push to main
4. Tag the release:
   git tag v1.0.1
   git push origin v1.0.1
5. Update consuming projects:
   - Change source ref: ?ref=v1.0.1
   - Run: terraform init -upgrade && terraform plan
```

**Never push a breaking change without incrementing the major version.** Consuming projects pin to a tag — they will not see the change until they explicitly update.
