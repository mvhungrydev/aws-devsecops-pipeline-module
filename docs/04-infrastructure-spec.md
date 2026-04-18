# 04 — Infrastructure Spec (aws-devsecops-pipeline-module)

## Terraform Module Structure

This repo contains a single reusable Terraform module. There are no `envs/` entrypoints in this repo — consuming projects provide their own entrypoints and call the module via a versioned GitHub source reference.

```
infra/
└── modules/
    └── pipeline/                    ← the reusable module — this is the artifact
        ├── main.tf                  ← CodePipeline (2–3 stages), S3 artifact bucket, CloudWatch log groups
        ├── variables.tf             ← all input variables (language, app_name, github_repo, etc.)
        ├── outputs.tf               ← pipeline_name, artifact_bucket_arn, artifact_bucket_name
        ├── iam.tf                   ← scan role + pipeline role (+ optional build role)
        ├── scanner_images.tf        ← locals: language → ghcr.io image URI map
        └── buildspecs/              ← YAML templates embedded in CodeBuild project resources
            ├── scan.yml             ← Stage 2: pre-commit run --all-files
            └── build.yml            ← Stage 3: docker build + trivy + ECR push (optional)
```

**No `envs/` directory.** This repo is infrastructure code, not an environment entrypoint. The `infra/modules/pipeline/` directory is meant to be referenced remotely — it is not intended to be run with `terraform apply` directly from this repo.

---

## How Consuming Projects Reference This Module

```hcl
# In the consuming project: infra/envs/dev/main.tf

# Security scan only (default)
module "pipeline" {
  source = "github.com/mvhungrydev/aws-devsecops-pipeline-module//infra/modules/pipeline?ref=v1.0.0"

  language                = "python"
  app_name                = "sample-python-app"
  github_repo             = "mvhungrydev/sample-python-app"
  branch                  = "main"
  codestar_connection_arn = var.codestar_connection_arn
}

# With container scanning
module "pipeline" {
  source = "github.com/mvhungrydev/aws-devsecops-pipeline-module//infra/modules/pipeline?ref=v1.0.0"

  language                = "python"
  app_name                = "sample-python-app"
  github_repo             = "mvhungrydev/sample-python-app"
  branch                  = "main"
  codestar_connection_arn = var.codestar_connection_arn
  enable_container_scan   = true
  ecr_repo_name           = module.ecr.repository_name
}
```

The `//` before `infra/modules/pipeline` is the Terraform GitHub source syntax for a subdirectory. The `?ref=v1.0.0` pins to a git tag. Always pin to a tag — never use `HEAD` or a branch name.

---

## Resource Inventory (Resources Provisioned by This Module)

When a consuming project calls `module "pipeline"`, the following AWS resources are created in that project's account:

| Resource | Terraform Type | File | Notable Config |
|----------|---------------|------|---------------|
| CodePipeline | `aws_codepipeline` | `main.tf` | 2 stages base; 3 stages with `enable_container_scan = true` |
| S3 Artifact Bucket | `aws_s3_bucket` | `main.tf` | Versioning on; lifecycle 30-day object cleanup |
| S3 Bucket Versioning | `aws_s3_bucket_versioning` | `main.tf` | Enabled |
| S3 Lifecycle Rule | `aws_s3_bucket_lifecycle_configuration` | `main.tf` | Expire objects > 30 days |
| S3 Bucket Policy | `aws_s3_bucket_policy` | `main.tf` | CodePipeline + CodeBuild read/write |
| CodeBuild — Scan | `aws_codebuild_project` | `main.tf` | ghcr.io scanner image; `general1.small`; S3 cache |
| CodeBuild — Build | `aws_codebuild_project` | `main.tf` | `enable_container_scan = true` only; AWS standard image; privileged=true; S3 cache |
| IAM Role — Scan | `aws_iam_role` | `iam.tf` | S3 artifact read/write + CloudWatch (no ECR Public perms needed — ghcr.io is public) |
| IAM Role — Build | `aws_iam_role` | `iam.tf` | `enable_container_scan = true` only; scan role permissions + private ECR push |
| IAM Role — CodePipeline | `aws_iam_role` | `iam.tf` | CodeBuild start + S3 + CodeStar connection use |
| IAM Role Policies | `aws_iam_role_policy` | `iam.tf` | Inline policies on each role |
| CloudWatch Log Group — Scan | `aws_cloudwatch_log_group` | `main.tf` | `/aws/codebuild/${app_name}-security-scan`; 30-day retention |
| CloudWatch Log Group — Build | `aws_cloudwatch_log_group` | `main.tf` | `enable_container_scan = true` only; `/aws/codebuild/${app_name}-build-scan`; 30-day retention |

**Not provisioned by this module (consumer provides):**
- S3 Terraform state bucket
- CodeStar Connection (requires human OAuth click — ARN passed in as `var.codestar_connection_arn`)
- ECR private repo (required when `enable_container_scan = true`)
- VPC and networking
- ECS cluster, service, and all deployment infrastructure

---

## `scanner_images.tf` — Language-to-Image Map

```hcl
# infra/modules/pipeline/scanner_images.tf

locals {
  scanner_images = {
    python = "ghcr.io/mvhungrydev/security-scanner-python:latest"
    java   = "ghcr.io/mvhungrydev/security-scanner-java:latest"
    dotnet = "ghcr.io/mvhungrydev/security-scanner-dotnet:latest"
    node   = "ghcr.io/mvhungrydev/security-scanner-node:latest"
  }
}
```

Referenced in the CodeBuild scan project resource:

```hcl
environment {
  compute_type = "BUILD_GENERAL1_SMALL"
  image        = local.scanner_images[var.language]
  type         = "LINUX_CONTAINER"
}
```

Terraform validates that `var.language` is one of the four allowed values. If an invalid value is passed, `local.scanner_images[var.language]` will produce a Terraform error at plan time.

---

## Key Terraform Variables

| Variable | Type | Default | Required | Description |
|----------|------|---------|----------|-------------|
| `language` | `string` | — | Yes | Scanner image selector: `python`, `java`, `dotnet`, `node` |
| `app_name` | `string` | — | Yes | Used in all resource names and tags |
| `github_repo` | `string` | — | Yes | GitHub repo in `owner/repo` format |
| `branch` | `string` | `"main"` | No | Pipeline trigger branch |
| `codestar_connection_arn` | `string` | — | Yes | ARN of the CodeStar Connection to GitHub |
| `enable_container_scan` | `bool` | `false` | No | Adds Build + Trivy + ECR Push stage when true |
| `ecr_repo_name` | `string` | `""` | No | Required when `enable_container_scan = true` |
| `aws_region` | `string` | `"us-east-1"` | No | AWS region for all resources |
| `environment` | `string` | `"dev"` | No | Environment tag applied to all module resources |

### Variable Validation

```hcl
# variables.tf
variable "language" {
  type        = string
  description = "Scanner image selector"

  validation {
    condition     = contains(["python", "java", "dotnet", "node"], var.language)
    error_message = "language must be one of: python, java, dotnet, node"
  }
}
```

---

## Outputs

| Output | Description |
|--------|-------------|
| `pipeline_name` | Name of the CodePipeline — for console navigation and CloudWatch dashboards |
| `artifact_bucket_name` | S3 artifact bucket name |
| `artifact_bucket_arn` | ARN — for IAM policy references in consuming projects |

---

## S3 Artifact Bucket Configuration

```hcl
resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.app_name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project     = var.app_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    expiration { days = 30 }
  }
}
```

Bucket name includes account ID for global uniqueness. Versioning is required by CodePipeline. 30-day lifecycle prevents unbounded S3 growth.

---

## CodeBuild Cache Configuration

Applied to all CodeBuild projects that benefit from caching:

```hcl
cache {
  type     = "S3"
  location = "${aws_s3_bucket.artifacts.bucket}/codebuild-cache/${var.app_name}"
}
```

Each stage caches different paths (configured in its buildspec YAML):

```yaml
# scan.yml
cache:
  paths:
    - '/root/.cache/pre-commit/**/*'
    - '/root/.cache/pip/**/*'

# build.yml (enable_container_scan = true only)
cache:
  paths:
    - '/root/.docker/**/*'
```

---

## Module Versioning and Release

The module is released via git tags. Consuming projects pin to a tag.

### Tag Convention

```
v<major>.<minor>.<patch>

v1.0.0  — initial release
v1.0.1  — buildspec bugfix, no variable changes
v1.1.0  — new optional variable added (backward compatible)
v2.0.0  — breaking change: variable renamed or removed
```

### Release Process

```bash
# In aws-devsecops-pipeline-module/ after changes are committed and pushed:
git tag v1.0.0
git push origin v1.0.0
```

Consuming projects then update their `source` reference and run `terraform init -upgrade` to pull the new module version.

### Terraform State

This module does **not** manage its own Terraform state — it has no `envs/` entrypoints. The Terraform that gets run is in the consuming project. State strategy for consuming projects:

```hcl
# consuming project: infra/envs/dev/backend.tf
terraform {
  backend "s3" {
    bucket       = "sample-python-app-tfstate-dev-<account-id>"
    key          = "sample-python-app/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true   # Terraform 1.10+ — no DynamoDB required
  }
}
```

The module itself has no backend configuration. `terraform validate` can be run from `infra/modules/pipeline/` for syntax checking, but `terraform plan/apply` is always run from the consuming project's `infra/envs/<env>/` directory.
