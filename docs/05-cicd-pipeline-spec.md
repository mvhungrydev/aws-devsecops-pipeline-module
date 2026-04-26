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

## GitHub Actions Workflow

The module includes `.github/workflows/security-scan.yml` — a working workflow that also serves as a template for consuming projects.

### What It Does

Triggers on every `push` and `pull_request` across all branches. Runs `pre-commit run --all-files` using the same `.pre-commit-config.yaml` that CodePipeline Stage 2 uses — same tools, same behavior, same severity thresholds. Both gates are consistent by design.

### Workflow

```yaml
name: security-scan
on:
  push:
    branches: ["**"]
  pull_request:
    branches: ["**"]

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # full history required for gitleaks
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - uses: actions/cache@v4
        with:
          path: ~/.cache/pre-commit
          key: pre-commit-${{ hashFiles('.pre-commit-config.yaml') }}
      - run: pip install pre-commit==3.7.0
      - run: pre-commit run --all-files --show-diff-on-failure
```

### Branch Protection Setup (One-Time Per Repo)

To make the GitHub Actions check a hard gate on PRs:

1. GitHub → repo → **Settings** → **Branches** → **Add branch protection rule**
2. Branch name pattern: `main`
3. Enable: **Require a pull request before merging**
4. Enable: **Require status checks to pass before merging**
5. Search for and add: `Security Scan` (the job name from the workflow)
6. Enable: **Restrict who can push to matching branches** → only allow merges via PR

After this, no PR can merge to `main` until the `security-scan` workflow passes.

### Consuming Projects

Copy `.github/workflows/security-scan.yml` from this repo to your consuming project's `.github/workflows/` directory. Copy `.pre-commit-config.yaml` to the consuming project root and update the `bandit` path if needed (see README).

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

phases:
  pre_build:
    commands:
      # ECR_REPO and DOCKERFILE_PATH are injected by Terraform at CodeBuild project creation time
      - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO
      # Short commit SHA used as image tag — immutable, traceable to exact commit
      - COMMIT_SHA=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-8)
      - IMAGE_URI=$ECR_REPO:$COMMIT_SHA
  build:
    commands:
      # DOCKERFILE_PATH is the directory containing the Dockerfile, relative to repo root
      - docker build -t $IMAGE_URI $DOCKERFILE_PATH/
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

CodePipeline triggers on merge to `main` only — it is the post-merge enforcement gate. Pre-merge gating is handled by the GitHub Actions workflow (`security-scan.yml`) which triggers on every push and pull_request. Both gates run the same tools via the same `.pre-commit-config.yaml`. See the GitHub Actions section above for branch protection setup.

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
