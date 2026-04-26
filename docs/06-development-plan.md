# 06 — Development Plan (aws-devsecops-pipeline-module)

## Overview

This plan covers building the two deliverables in this repo: scanner images and the Terraform pipeline module. Implementation is ordered by dependency — scanner images must exist on ECR Public before the pipeline Terraform can reference them; the Terraform module must be tagged before consuming projects can run `terraform init`.

No code is written until all 7 docs are reviewed and approved (Mike Velasco Special).

---

## Phase 0 — Scaffold

Stories in this phase are procedural. No deep background required.

### Story 0.1 — Directory Scaffold ✓ Done

Create the full directory structure with `.gitkeep` files in empty directories:

```
aws-devsecops-pipeline-module/
├── infra/
│   └── modules/
│       └── pipeline/
│           └── buildspecs/
├── scanner-images/
│   ├── python/
│   ├── java/
│   ├── dotnet/
│   └── node/
└── scripts/
```

Commit: `chore: initial directory scaffold`

### Story 0.4 — GitHub Actions Workflow ✓ Done

Create `.github/workflows/security-scan.yml` at the repo root. This workflow:
- Triggers on every `push` and `pull_request` across all branches
- Runs `pre-commit run --all-files` — same tools and behavior as CodePipeline Stage 2
- Serves as a working template for consuming projects to copy

Consuming projects copy this file to their own `.github/workflows/` directory and set up branch protection rules to require the `Security Scan` check before merging.

Branch protection setup (consuming project, one-time):
1. GitHub → repo → Settings → Branches → Add rule for `main`
2. Enable: Require PR before merging
3. Enable: Require status checks → add `Security Scan`
4. Enable: Restrict direct pushes to main

Commit: `chore: add GitHub Actions security scan workflow`

---

### Story 0.2 — `.pre-commit-config.yaml` Template ✓ Done

Create `.pre-commit-config.yaml` at the repo root. This file is the template that consuming projects copy. It must be functional in the context of a consuming project (not this module repo — this repo has no Python app to scan with bandit).

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.2
    hooks:
      - id: gitleaks

  - repo: https://github.com/PyCQA/bandit
    rev: 1.7.9
    hooks:
      - id: bandit
        args: ["-c", "pyproject.toml"]
        files: ^sample-app/

  - repo: https://github.com/returntocorp/semgrep
    rev: v1.70.0
    hooks:
      - id: semgrep
        args: ["--config=auto", "--error"]

  - repo: https://github.com/bridgecrewio/checkov
    rev: 3.2.0
    hooks:
      - id: checkov
        args: ["-d", "infra/", "--framework", "terraform"]

  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.88.0
    hooks:
      - id: terraform_fmt
```

### Story 0.3 — Setup Scripts ✓ Done

Create `scripts/setup-dev.sh` (macOS/Linux):

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "Installing pre-commit..."
pip install pre-commit

echo "Installing pre-commit hooks..."
pre-commit install

echo "Running hooks on all files (first run installs hook environments)..."
pre-commit run --all-files || true  # first run may fail — tool environments being created

echo "Done. pre-commit will run automatically on git commit."
```

Create `scripts/setup-dev.ps1` (Windows):

```powershell
Write-Host "Installing pre-commit..."
pip install pre-commit

Write-Host "Installing pre-commit hooks..."
pre-commit install

Write-Host "Running hooks on all files..."
pre-commit run --all-files
```

Make `setup-dev.sh` executable: `chmod +x scripts/setup-dev.sh`

---

## Phase 1 — Scanner Images

All work in this phase happens in this repo (`aws-devsecops-pipeline-module/`). Scanner images must be on ECR Public before any consuming project runs a pipeline.

### Background

**ghcr.io is account-independent** — images are tied to the GitHub account (`mvhungrydev`), not an AWS account. Survives AWS account closure. No pull rate limits.

**Push requires a GitHub PAT** with `write:packages` scope. This is a one-time setup. The PAT is only used locally for pushing — CodeBuild pulls public images without any credentials.

**Images must be set to Public after first push** — newly pushed packages default to Private on ghcr.io. Navigate to GitHub → Packages → [package name] → Package settings → Change visibility → Public.

**Image rebuild policy:** Pin all tool versions in each Dockerfile. Never use `latest` or unpinned pip installs — an unpinned install could pull a breaking version and silently change scanner behavior.

**Verification step (`RUN ... && ... version`):** The final `RUN` in each Dockerfile verifies that tools installed correctly. If any tool is missing or broken, the Docker build fails immediately — catching errors before the image reaches ECR.

### Story 1.1 — GitHub Container Registry Setup ✓ Done (one-time machine setup)

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Click **Generate new token (classic)**
3. Name it `ghcr-push`, set expiration as appropriate, check `write:packages` scope
4. Copy the token — save it somewhere safe, you cannot view it again
5. Authenticate Docker locally:

```bash
export GITHUB_PAT=<your-token>
echo $GITHUB_PAT | docker login ghcr.io --username mvhungrydev --password-stdin
```

One-time setup per machine. Repositories are created automatically on first push — no pre-creation needed.

### Story 1.2 — Python Scanner Image ✓ Dockerfile done — push pending

Create `scanner-images/python/Dockerfile`:

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSfL \
    https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz \
    | tar -xz -C /usr/local/bin gitleaks

RUN pip install --no-cache-dir \
    bandit==1.7.9 \
    semgrep==1.70.0 \
    checkov==3.2.0 \
    pre-commit==3.7.0

RUN gitleaks version && bandit --version && semgrep --version && checkov --version
```

Build and push:

```bash
# Authenticate (one-time per machine — see Story 1.1)
echo $GITHUB_PAT | docker login ghcr.io --username mvhungrydev --password-stdin

# Build
docker build -t security-scanner-python scanner-images/python/

# Tag
docker tag security-scanner-python ghcr.io/mvhungrydev/security-scanner-python:latest

# Push
docker push ghcr.io/mvhungrydev/security-scanner-python:latest
```

After push: GitHub → Packages → security-scanner-python → Package settings → Change visibility → **Public**

Verify: `docker pull ghcr.io/mvhungrydev/security-scanner-python:latest` (unauthenticated — confirms public visibility).

### Story 1.3 — Java, dotnet, Node Scanner Images ✓ Dockerfiles done — push pending

Create identical Dockerfiles for the other 3 languages, omitting bandit:

```dockerfile
# scanner-images/java/Dockerfile  (and dotnet/, node/ — identical content)
FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSfL \
    https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz \
    | tar -xz -C /usr/local/bin gitleaks

RUN pip install --no-cache-dir \
    semgrep==1.70.0 \
    checkov==3.2.0 \
    pre-commit==3.7.0

RUN gitleaks version && semgrep --version && checkov --version
```

Build and push each image (same pattern as Story 1.2):
- `security-scanner-java` → `ghcr.io/mvhungrydev/security-scanner-java:latest`
- `security-scanner-dotnet` → `ghcr.io/mvhungrydev/security-scanner-dotnet:latest`
- `security-scanner-node` → `ghcr.io/mvhungrydev/security-scanner-node:latest`

---

## Phase 2 — Terraform Pipeline Module

All work in `infra/modules/pipeline/`. No `envs/` directory in this repo — the module is tested by wiring it into `sample-python-app/` in Phase 3 of that project's development plan.

### Background

**Module scope:** This module provisions a security scanning pipeline only. It does not own deployment, Terraform plan/apply, or ECS updates. The pipeline stops at producing a verified artifact (scan pass, or scanned image in ECR when `enable_container_scan = true`). The consuming project handles everything after.

**Terraform module vs root module:** A module in `infra/modules/pipeline/` cannot be run with `terraform apply` directly — it has no backend, no provider block, no input values. Validation (`terraform validate`) works from the module directory; planning and applying do not.

**CodeBuild buildspecs as inline strings:** Using `file("${path.module}/buildspecs/scan.yml")` keeps the YAML readable and separately diffable. `path.module` resolves to the module directory regardless of where the root module is.

**`dynamic` blocks for optional stages:** The Build + Trivy stage is added via a Terraform `dynamic` block — it only exists in the pipeline when `var.enable_container_scan = true`. The associated CodeBuild project and IAM role are also conditionally created with `count = var.enable_container_scan ? 1 : 0`.

**CodeStar Connection ARN:** The connection must already exist in `AVAILABLE` state when `terraform apply` runs. If the connection is `PENDING`, the pipeline creation will succeed but will fail at Stage 1 until the connection is confirmed.

### Story 2.1 — `variables.tf` ✓ Done

Define all input variables with types, descriptions, and validations:
- `language` — validated against `["python", "java", "dotnet", "node"]`
- `app_name`, `github_repo`, `branch`, `codestar_connection_arn` — required strings
- `enable_container_scan` — bool, default `false`
- `ecr_repo_name` — string, default `""` (required when `enable_container_scan = true`)
- `aws_region` — string, default `"us-east-1"`
- `environment` — string, default `"dev"`

### Story 2.2 — `scanner_images.tf` ✓ Done

Define the language-to-image locals map:

```hcl
locals {
  scanner_images = {
    python = "ghcr.io/mvhungrydev/security-scanner-python:latest"
    java   = "ghcr.io/mvhungrydev/security-scanner-java:latest"
    dotnet = "ghcr.io/mvhungrydev/security-scanner-dotnet:latest"
    node   = "ghcr.io/mvhungrydev/security-scanner-node:latest"
  }
}
```

Validate: `terraform validate` from `infra/modules/pipeline/` — confirms HCL syntax is valid.

### Story 2.3 — `iam.tf` (2–3 IAM Roles) ✓ Done

Create IAM roles with `aws_iam_role_policy` inline policies:

- `${var.app_name}-codebuild-scan-role` — S3 artifact read/write + CloudWatch
- `${var.app_name}-codebuild-build-role` — scan role permissions + private ECR push (`count = var.enable_container_scan ? 1 : 0`)
- `${var.app_name}-codepipeline-role` — CodeBuild start + S3 + CodeStar connection use

IAM permissions reference: see `docs/03-technical-design.md` IAM Role Design section for the full JSON.

No ECR Public permissions needed — ghcr.io scanner images are pulled as public images without IAM.

### Story 2.4 — S3 Artifact Bucket + CodeBuild Projects ✓ Done

In `main.tf`:

**S3 Artifact Bucket:**
- `aws_s3_bucket` — name: `${var.app_name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}`
- `aws_s3_bucket_versioning` — enabled
- `aws_s3_bucket_lifecycle_configuration` — expire objects after 30 days
- `aws_s3_bucket_policy` — CodePipeline and CodeBuild access

**Scan CodeBuild Project (always created):**

```hcl
resource "aws_codebuild_project" "scan" {
  name         = "${var.app_name}-security-scan"
  service_role = aws_iam_role.scan.arn

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = local.scanner_images[var.language]
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    environment_variable {
      name  = "LANGUAGE"
      value = var.language
    }
  }

  buildspec = file("${path.module}/buildspecs/scan.yml")

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.artifacts.bucket}/codebuild-cache/${var.app_name}/scan"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.scan.name
    }
  }
}
```

**Build CodeBuild Project (`enable_container_scan = true` only):**

`count = var.enable_container_scan ? 1 : 0`, `privileged_mode = true`, AWS standard image `aws/codebuild/standard:7.0`, `ECR_REPO` and `AWS_REGION` env vars injected.

### Story 2.5 — CloudWatch Log Groups + `outputs.tf` ✓ Done

**CloudWatch Log Groups:**

```hcl
resource "aws_cloudwatch_log_group" "scan" {
  name              = "/aws/codebuild/${var.app_name}-security-scan"
  retention_in_days = 30
}

# Build log group — only when enable_container_scan = true
resource "aws_cloudwatch_log_group" "build" {
  count             = var.enable_container_scan ? 1 : 0
  name              = "/aws/codebuild/${var.app_name}-build-scan"
  retention_in_days = 30
}
```

**`outputs.tf`:**

```hcl
output "pipeline_name" {
  value       = aws_codepipeline.this.name
  description = "CodePipeline name — for console navigation"
}

output "artifact_bucket_name" {
  value       = aws_s3_bucket.artifacts.bucket
  description = "S3 artifact bucket name"
}

output "artifact_bucket_arn" {
  value       = aws_s3_bucket.artifacts.arn
  description = "S3 artifact bucket ARN"
}
```

### Story 2.6 — `aws_codepipeline` (2–3 Stages) ✓ Done

```hcl
resource "aws_codepipeline" "this" {
  name     = "${var.app_name}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]
      configuration = {
        ConnectionArn    = var.codestar_connection_arn
        FullRepositoryId = var.github_repo
        BranchName       = var.branch
      }
    }
  }

  stage {
    name = "SecurityScan"
    action {
      name            = "SecurityScan"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceArtifact"]
      configuration   = { ProjectName = aws_codebuild_project.scan.name }
    }
  }

  dynamic "stage" {
    for_each = var.enable_container_scan ? [1] : []
    content {
      name = "BuildAndScanImage"
      action {
        name             = "BuildAndScanImage"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        version          = "1"
        input_artifacts  = ["SourceArtifact"]
        output_artifacts = ["BuildArtifact"]
        configuration    = { ProjectName = aws_codebuild_project.build[0].name }
      }
    }
  }
}
```

### Story 2.7 — Terraform Validation ✓ Done (35 passed, 0 failed, 9 skipped with justification)

Run from `infra/modules/pipeline/`:

```bash
terraform validate
terraform fmt -check -recursive
checkov -d infra/ --framework terraform
```

Fix any checkov findings that are not acceptable. Add `#checkov:skip=<rule>` inline comments for intentional exceptions (e.g., the S3 bucket may trigger a public access block warning — add the block resource or suppress with a comment explaining why).

---

## Phase 3 — Integration Test

**OUT OF SCOPE — Decision 2026-04-25**

Wiring the pipeline module into `sample-python-app` is out of scope for this repo. The goal of this project is a reusable, standalone module — not a vertically integrated demo. The `examples/complete/` directory provides a fully documented consumption example covering all variables. End-to-end integration testing is the responsibility of the consuming project.

---

## Phase 4 — Documentation and Release Tag

### Story 4.1 — `README.md` ✓ Done

README covers all required sections:
1. Scanner image bootstrap — step-by-step manual push to ghcr.io
2. SAST gap documentation — Semgrep community vs taint analysis, affected languages, production recommendations
3. Local dev setup — `scripts/setup-dev.sh` and `setup-dev.ps1`
4. How to consume the module — `source` reference with base and container scan examples
5. Module input variables reference table
6. Module versioning — git tag convention, `terraform init -upgrade` process

### Story 4.2 — Checkov Findings Documentation ✓ Done

`docs/10-checkov-findings.md` created 2026-04-25. Documents all 9 findings from the Phase 2 checkov run:
- 1 fix applied: `abort_incomplete_multipart_upload` added to S3 lifecycle rule
- 8 skips: all KMS/cost-driven, each with explanation and `#checkov:skip` annotation applied inline in `main.tf`
- Final result: 35 passed, 0 failed, 9 skipped

### Story 4.3 — First Release Tag ✓ Done — tagged v1.0.0 on 2026-04-26

```bash
git tag v1.0.0
git push origin v1.0.0
```

**Prerequisite:** All 4 scanner images must be pushed to ghcr.io and set to Public before tagging. The `scanner_images.tf` locals map references these image URIs — the tag is only valid once the images exist at those URIs.

```bash
# Build and push all 4 images (run from repo root)
docker build -t ghcr.io/mvhungrydev/security-scanner-python:latest scanner-images/python/
docker push ghcr.io/mvhungrydev/security-scanner-python:latest

docker build -t ghcr.io/mvhungrydev/security-scanner-java:latest scanner-images/java/
docker push ghcr.io/mvhungrydev/security-scanner-java:latest

docker build -t ghcr.io/mvhungrydev/security-scanner-dotnet:latest scanner-images/dotnet/
docker push ghcr.io/mvhungrydev/security-scanner-dotnet:latest

docker build -t ghcr.io/mvhungrydev/security-scanner-node:latest scanner-images/node/
docker push ghcr.io/mvhungrydev/security-scanner-node:latest

# After all 4 are pushed and set to Public on ghcr.io
git tag v1.0.0
git push origin v1.0.0
```
