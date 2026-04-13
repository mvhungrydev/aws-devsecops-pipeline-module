# 06 — Development Plan (aws-devsecops-pipeline-module)

## Overview

This plan covers building the two deliverables in this repo: scanner images and the Terraform pipeline module. Implementation is ordered by dependency — scanner images must exist on ECR Public before the pipeline Terraform can reference them; the Terraform module must be tagged before consuming projects can run `terraform init`.

No code is written until all 7 docs are reviewed and approved (Mike Velasco Special).

---

## Phase 0 — Scaffold

Stories in this phase are procedural. No deep background required.

### Story 0.1 — Directory Scaffold

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

### Story 0.2 — `.pre-commit-config.yaml` Template

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

### Story 0.3 — Setup Scripts

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

**ECR Public authentication always uses `us-east-1`** regardless of your working region. This is an AWS requirement — the ECR Public global registry authentication endpoint is only available in `us-east-1`. The `aws ecr-public get-login-password` command must include `--region us-east-1`.

**ECR Public namespace (alias)** is a globally unique identifier you claim once. After setup, all your public images live under `public.ecr.aws/<your-alias>/`. The alias `mvhungrydev` must be claimed before any push.

**Image rebuild policy:** Pin all tool versions in each Dockerfile. Never use `latest` or unpinned pip installs — an unpinned install could pull a breaking version and silently change scanner behavior.

**Verification step (`RUN ... && ... version`):** The final `RUN` in each Dockerfile verifies that tools installed correctly. If any tool is missing or broken, the Docker build fails immediately — catching errors before the image reaches ECR.

### Story 1.1 — ECR Public Namespace Setup

1. Open AWS Console → **ECR** → **Public** → **Get started** (or **Create repository** if you already have a public namespace)
2. Choose alias: `mvhungrydev`
3. Note the full public gallery URI: `public.ecr.aws/mvhungrydev`

One-time setup — the namespace persists. You do not need to create individual repositories in advance; ECR Public creates them on first push.

### Story 1.2 — Python Scanner Image

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
# Authenticate (always us-east-1 for ECR Public)
aws ecr-public get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin public.ecr.aws

# Build
docker build -t security-scanner-python scanner-images/python/

# Tag
docker tag security-scanner-python public.ecr.aws/mvhungrydev/security-scanner-python:latest

# Push
docker push public.ecr.aws/mvhungrydev/security-scanner-python:latest
```

Verify: navigate to ECR Public gallery → confirm image appears.

### Story 1.3 — Java, dotnet, Node Scanner Images

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
- `security-scanner-java` → `public.ecr.aws/mvhungrydev/security-scanner-java:latest`
- `security-scanner-dotnet` → `public.ecr.aws/mvhungrydev/security-scanner-dotnet:latest`
- `security-scanner-node` → `public.ecr.aws/mvhungrydev/security-scanner-node:latest`

---

## Phase 2 — Terraform Pipeline Module

All work in `infra/modules/pipeline/`. No `envs/` directory in this repo — the module is tested by wiring it into `sample-python-app/` in Phase 3 of that project's development plan.

### Background

**Terraform module vs root module:** A module in `infra/modules/pipeline/` cannot be run with `terraform apply` directly — it has no backend, no provider block, no input values. It must be called from a root module (an `envs/dev/` directory with `main.tf`, `backend.tf`, and `terraform.tfvars`). Validation (`terraform validate`) works from the module directory; planning and applying do not.

**CodeBuild buildspecs as inline strings:** The buildspec YAML can be embedded directly in the `aws_codebuild_project` resource via the `buildspec` argument (as a heredoc string) or stored as files and referenced with `file()`. Using `file("${path.module}/buildspecs/scan.yml")` keeps the YAML readable and separately diffable. `path.module` resolves to the module directory regardless of where the root module is.

**CodePipeline artifact passing:** Each stage declares input and output artifacts by name. The names are arbitrary strings — they just need to match between the producing stage's `output_artifacts` and the consuming stage's `input_artifacts`. Once artifacts are in S3, CodeBuild accesses them via the `$CODEBUILD_SRC_DIR` and `$CODEBUILD_SRC_DIR_<ArtifactName>` environment variables.

**SNS email subscription confirmation:** Terraform creates the SNS subscription, which triggers an AWS confirmation email. The subscription is `PENDING` until the subscriber clicks the confirmation link. The module cannot automate this step.

**CodeStar Connection ARN:** The connection must already exist in `AVAILABLE` state when `terraform apply` runs. Terraform creates the `aws_codepipeline` resource which references the connection ARN — if the connection is `PENDING`, the pipeline creation will succeed but the pipeline will fail at Stage 1 until the connection is confirmed.

### Story 2.1 — `variables.tf`

Define all input variables with types, descriptions, and validations:
- `language` — validated against `["python", "java", "dotnet", "node"]`
- `app_name`, `github_repo`, `branch`, `ecr_repo_name`, `ecs_cluster_name`, `ecs_service_name` — strings
- `approval_email`, `codestar_connection_arn`, `tfstate_bucket` — strings, no defaults
- `aws_region` — string, default `"us-east-1"`
- `environment` — string, default `"dev"`

### Story 2.2 — `scanner_images.tf`

Define the language-to-image locals map:

```hcl
locals {
  scanner_images = {
    python = "public.ecr.aws/mvhungrydev/security-scanner-python:latest"
    java   = "public.ecr.aws/mvhungrydev/security-scanner-java:latest"
    dotnet = "public.ecr.aws/mvhungrydev/security-scanner-dotnet:latest"
    node   = "public.ecr.aws/mvhungrydev/security-scanner-node:latest"
  }
}
```

Validate: `terraform validate` from `infra/modules/pipeline/` — confirms HCL syntax is valid.

### Story 2.3 — `iam.tf` (3 IAM Roles)

Create 3 `aws_iam_role` resources with `aws_iam_role_policy` inline policies:
- `${var.app_name}-codebuild-scan-role` — ECR Public pull + S3 + CloudWatch
- `${var.app_name}-codebuild-build-role` — scan role permissions + private ECR push
- `${var.app_name}-codebuild-tf-role` — scan role permissions + S3 state + full infra

IAM permissions reference: see `docs/03-technical-design.md` IAM Role Design section for the full JSON.

All role ARNs scoped to specific resources where possible. The Terraform role uses `Resource: "*"` for resource provisioning — this is expected and documented.

### Story 2.4 — S3 Artifact Bucket + CodeBuild Projects

In `main.tf`:

**S3 Artifact Bucket:**
- `aws_s3_bucket` — name: `${var.app_name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}`
- `aws_s3_bucket_versioning` — enabled
- `aws_s3_bucket_lifecycle_configuration` — expire objects after 30 days
- `aws_s3_bucket_policy` — CodePipeline and CodeBuild access

**4 CodeBuild Projects:**

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

Build project differs: `privileged_mode = true`, AWS standard image `aws/codebuild/standard:7.0`, `ECR_REPO` env var injected.

Plan and Apply projects: AWS standard image, `TF_VERSION` and `ENV` env vars, `ARTIFACT_BUCKET` env var (plan only).

### Story 2.5 — SNS Topic + CloudWatch Log Groups

```hcl
resource "aws_sns_topic" "approval" {
  name = "${var.app_name}-pipeline-approval"
}

resource "aws_sns_topic_subscription" "approval_email" {
  topic_arn = aws_sns_topic.approval.arn
  protocol  = "email"
  endpoint  = var.approval_email
}

resource "aws_cloudwatch_log_group" "scan" {
  name              = "/aws/codebuild/${var.app_name}-security-scan"
  retention_in_days = 30
}
# Repeat for build, plan, apply log groups
```

### Story 2.6 — `aws_codepipeline` (6 Stages)

```hcl
resource "aws_codepipeline" "this" {
  name     = "${var.app_name}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn  # note: a 4th role needed for CodePipeline itself

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
      name             = "SecurityScan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact"]
      configuration    = { ProjectName = aws_codebuild_project.scan.name }
    }
  }

  stage {
    name = "BuildAndScanImage"
    action {
      name             = "BuildAndScanImage"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["BuildArtifact"]
      configuration    = { ProjectName = aws_codebuild_project.build.name }
    }
  }

  stage {
    name = "TerraformPlan"
    action {
      name             = "TerraformPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact", "BuildArtifact"]
      output_artifacts = ["PlanArtifact"]
      configuration = {
        ProjectName          = aws_codebuild_project.plan.name
        PrimarySource        = "SourceArtifact"
      }
    }
  }

  stage {
    name = "ManualApproval"
    action {
      name     = "ManualApproval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        NotificationArn = aws_sns_topic.approval.arn
        CustomData      = "Review the Terraform plan before approving deployment."
      }
    }
  }

  stage {
    name = "TerraformApply"
    action {
      name            = "TerraformApply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceArtifact", "PlanArtifact"]
      configuration = {
        ProjectName   = aws_codebuild_project.apply.name
        PrimarySource = "SourceArtifact"
      }
    }
  }
}
```

**Note:** CodePipeline itself needs an IAM role (`aws_iam_role.codepipeline`) with permissions to call CodeBuild, CodeStar, S3, and SNS. This is a 4th role not covered in `iam.tf` — add it there or in `main.tf`.

### Story 2.7 — `outputs.tf`

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

### Story 2.8 — Terraform Validation

Run from `infra/modules/pipeline/`:

```bash
terraform validate
terraform fmt -check -recursive
checkov -d infra/ --framework terraform
```

Fix any checkov findings that are not acceptable. Add `#checkov:skip=<rule>` inline comments for intentional exceptions (e.g., the S3 bucket may trigger a public access block warning — add the block resource or suppress with a comment explaining why).

---

## Phase 3 — Integration Test

The pipeline module cannot be tested in isolation — it requires a consuming project with VPC, ECS, ECR, and a CodeStar Connection.

**Integration test target:** `sample-python-app`. After Phase 2 (pipeline module stories) and the corresponding Phase 2 (core infrastructure stories) in `sample-python-app`, wire the pipeline module in and run it end-to-end.

See `sample-python-app/docs/06-development-plan.md` — Story 3.6 "Wire Pipeline into Dev Environment" is the integration test entry point.

---

## Phase 4 — Documentation and Release Tag

### Story 4.1 — `README.md`

Complete the module repo README with these sections (per `CONTEXT.md` in `sample-python-app/`):

1. **Scanner image bootstrap** — step-by-step manual push to ECR Public
2. **SAST gap documentation** — Semgrep community vs taint analysis, affected languages, production recommendations
3. **Local dev setup** — `scripts/setup-dev.sh` and `setup-dev.ps1`, why gitleaks locally matters
4. **How to consume the module** — `source` reference with example
5. **Module input variables reference table** — all variables, types, defaults, descriptions
6. **Module versioning** — git tag convention, `terraform init -upgrade` process

### Story 4.2 — First Release Tag

```bash
git tag v1.0.0
git push origin v1.0.0
```

After tagging, update `sample-python-app/infra/envs/dev/main.tf` to reference `?ref=v1.0.0` and run `terraform init`.
