locals {
  # Construct the private ECR repo URL from account ID, region, and repo name.
  # Used as an environment variable in the build CodeBuild project.
  # Empty string when enable_container_scan = false — never referenced in that case.
  ecr_repo_url = var.enable_container_scan ? "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repo_name}" : ""
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 — Pipeline Artifact Bucket
# Stores source artifacts (Stage 1 output) and build artifacts (Stage 3 output).
# Also used as the CodeBuild S3 cache location.
# Account ID suffix ensures global uniqueness across all AWS accounts.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "artifacts" {
  # checkov:skip=CKV_AWS_145: SSE-S3 is sufficient; KMS CMK costs $1/key/month with no free tier
  # checkov:skip=CKV_AWS_18: Access logging requires a second bucket; covered by CloudTrail at account level if needed
  # checkov:skip=CKV_AWS_144: Artifacts are ephemeral and regenerated on each run; CRR adds cost with no recovery value
  # checkov:skip=CKV2_AWS_62: Pipeline artifact bucket; CodePipeline manages triggers — S3 event notifications have no consumer
  bucket        = "${var.app_name}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# Versioning is required by CodePipeline — it uses object versions to track artifact lineage
resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Expire artifacts after 30 days — prevents unbounded S3 storage growth
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"

    # Empty prefix = apply to all objects in the bucket.
    # AWS provider v4+ requires an explicit filter — without it the rule is ignored.
    filter {
      prefix = ""
    }

    expiration {
      days = 30
    }

    # Also expire old object versions to reclaim storage
    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    # Abort incomplete multipart uploads after 1 day to prevent
    # abandoned uploads from silently accumulating storage charges.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Block all public access — this bucket contains source code and build artifacts
resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt all objects at rest with S3-managed keys (SSE-S3)
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CloudWatch Log Groups
# Pre-created with a 30-day retention policy.
# CodeBuild would create these automatically, but explicit creation lets Terraform
# control retention — otherwise logs accumulate indefinitely at no cost limit.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "scan" {
  # checkov:skip=CKV_AWS_158: CloudWatch default encryption is sufficient; KMS CMK costs $1/key/month with no free tier
  # checkov:skip=CKV_AWS_338: 30-day retention is intentional — build logs are verbose and CloudWatch storage is $0.03/GB/month
  name              = "/aws/codebuild/${var.app_name}-security-scan"
  retention_in_days = 30

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "aws_cloudwatch_log_group" "build" {
  count             = var.enable_container_scan ? 1 : 0
  name              = "/aws/codebuild/${var.app_name}-build-scan"
  retention_in_days = 30

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CodeBuild — Security Scan (Stage 2)
# Always created. Uses the language-specific ghcr.io scanner image.
# Runs pre-commit run --all-files via buildspecs/scan.yml.
# ghcr.io is a public registry — no registry credentials needed.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_codebuild_project" "scan" {
  # checkov:skip=CKV_AWS_147: Artifacts encrypted at rest via S3 SSE-S3; additional CMK adds $1/key/month with no added value
  name         = "${var.app_name}-security-scan"
  description  = "Security scan stage: gitleaks, Semgrep, checkov, bandit (Python)"
  service_role = aws_iam_role.codebuild_scan.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  # Source is provided by CodePipeline at runtime — type must match artifacts type
  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/scan.yml")
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # language variable selects the pre-built scanner image from ghcr.io
    image = local.scanner_images[var.language]
    type  = "LINUX_CONTAINER"
    # CODEBUILD credential type performs an anonymous pull for public registries.
    # ghcr.io scanner images are public — no registry credentials needed.
    # SERVICE_ROLE would require Secrets Manager credentials to be configured.
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false

    environment_variable {
      name  = "LANGUAGE"
      value = var.language
    }
  }

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.artifacts.bucket}/codebuild-cache/${var.app_name}/scan"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.scan.name
    }
  }

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CodeBuild — Build & Scan Image (Stage 3, enable_container_scan = true only)
# Uses the AWS standard image with privileged mode (required for docker build).
# Builds the consuming project's container, runs trivy, pushes to private ECR.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_codebuild_project" "build" {
  count        = var.enable_container_scan ? 1 : 0
  name         = "${var.app_name}-build-scan"
  description  = "Build, trivy scan, and ECR push stage"
  service_role = aws_iam_role.codebuild_build[0].arn

  artifacts {
    type = "CODEPIPELINE"
  }

  # Source is provided by CodePipeline at runtime — type must match artifacts type
  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/build.yml")
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    # AWS standard image — includes docker CLI, aws CLI, trivy is installed via buildspec
    image = "aws/codebuild/standard:7.0"
    type  = "LINUX_CONTAINER"
    # privileged_mode required for docker build and docker daemon access
    # checkov:skip=CKV_AWS_316: privileged mode is required to run docker build inside CodeBuild
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ECR_REPO"
      value = local.ecr_repo_url
    }

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }

    environment_variable {
      name  = "DOCKERFILE_PATH"
      value = var.dockerfile_path
    }
  }

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.artifacts.bucket}/codebuild-cache/${var.app_name}/build"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.build[0].name
    }
  }

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CodePipeline
# 2 stages base (Source → SecurityScan).
# 3rd stage (BuildAndScanImage) added via dynamic block when enable_container_scan = true.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_codepipeline" "this" {
  # checkov:skip=CKV_AWS_219: Artifact bucket uses SSE-S3 encryption; KMS CMK adds $1/key/month with no added value for transient artifacts
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
        # DetectChanges = true is the default — pipeline triggers automatically on push
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

      configuration = {
        ProjectName = aws_codebuild_project.scan.name
      }
    }
  }

  # Stage 3 is only added when enable_container_scan = true.
  # for_each = [1] adds the stage once; for_each = [] omits it entirely.
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

        configuration = {
          ProjectName = aws_codebuild_project.build[0].name
        }
      }
    }
  }

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}
