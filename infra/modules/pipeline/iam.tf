data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# Role 1 — CodeBuild: Security Scan
# Used by the security scan stage (Stage 2) in every pipeline configuration.
# Needs: read source artifact from S3, write cache to S3, write build logs.
# ghcr.io is a public registry — no IAM permissions required to pull scanner images.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "codebuild_scan" {
  name = "${var.app_name}-codebuild-scan-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codebuild.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "aws_iam_role_policy" "codebuild_scan" {
  name = "${var.app_name}-codebuild-scan-policy"
  role = aws_iam_role.codebuild_scan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read source artifact and read/write pre-commit + pip cache
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      # Required for CodeBuild to verify bucket ownership before accessing objects
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.artifacts.arn
      },
      # Write build logs to CloudWatch — scoped to this app's log group prefix only
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.app_name}-*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Role 2 — CodeBuild: Build & Scan Image
# Used by Stage 3 (enable_container_scan = true only).
# Inherits scan role permissions + adds private ECR push for the app image.
# count = 0 when enable_container_scan = false — role is not created.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "codebuild_build" {
  count = var.enable_container_scan ? 1 : 0
  name  = "${var.app_name}-codebuild-build-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codebuild.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "aws_iam_role_policy" "codebuild_build" {
  count = var.enable_container_scan ? 1 : 0
  name  = "${var.app_name}-codebuild-build-policy"
  role  = aws_iam_role.codebuild_build[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read source artifact and read/write Docker layer cache
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.artifacts.arn
      },
      # Write build logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.app_name}-*"
      },
      # GetAuthorizationToken is account-scoped — Resource: "*" is required by the ECR API.
      # This token authorizes docker login; actual push permissions are scoped to the specific repo below.
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      # Push image layers and manifest to the consuming project's private ECR repo only
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repo_name}"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Role 3 — CodePipeline
# Orchestrates the pipeline: starts CodeBuild projects, reads/writes artifacts
# in S3, and uses the CodeStar Connection to pull from GitHub.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "codepipeline" {
  name = "${var.app_name}-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "codepipeline.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    app_name    = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "${var.app_name}-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Start builds and poll build status — CodePipeline needs batch access for stage polling.
      # Resource: "*" is required here because CodePipeline calls BatchGetBuilds with build IDs
      # that are only known at runtime; scoping by project ARN would cause permission errors.
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds"
        ]
        Resource = "*"
      },
      # Read and write pipeline artifacts — source zip in, scan output (pass/fail) managed here
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:GetBucketVersioning"
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      # Use the CodeStar Connection to pull source from GitHub — scoped to the specific connection ARN
      {
        Effect   = "Allow"
        Action   = "codestar-connections:UseConnection"
        Resource = var.codestar_connection_arn
      }
    ]
  })
}
