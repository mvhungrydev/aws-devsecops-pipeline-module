# ─────────────────────────────────────────────────────────────────────────────
# Wiring file — shows a consuming project how to call the pipeline module.
#
# Copy this directory to your project under infra/envs/dev/ (or prod/).
# Supply real values in terraform.tfvars (never commit that file).
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Replace with your own S3 backend.
  # Terraform 1.10+ supports use_lockfile = true — no DynamoDB table required.
  backend "s3" {
    bucket       = "your-tfstate-bucket"
    key          = "your-app/dev/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────────────────────────────────────
# Variables — caller supplies these; values come from terraform.tfvars
# ─────────────────────────────────────────────────────────────────────────────

variable "app_name" {
  type        = string
  description = "Application name — used as a prefix for all AWS resource names"
}

variable "language" {
  type        = string
  description = "Scanner image selector — python | java | dotnet | node"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in owner/repo format (e.g. myorg/my-app)"
}

variable "branch" {
  type        = string
  default     = "main"
  description = "Branch that triggers the pipeline on push"
}

variable "codestar_connection_arn" {
  type        = string
  description = "ARN of an Available CodeStar Connection to GitHub"
}

variable "enable_container_scan" {
  type    = bool
  default = false
}

variable "ecr_repo_name" {
  type    = string
  default = ""
}

variable "dockerfile_path" {
  type    = string
  default = "sample-app"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

# ─────────────────────────────────────────────────────────────────────────────
# Module call — every variable maps 1-to-1 to a module input
# ─────────────────────────────────────────────────────────────────────────────

module "pipeline" {
  # Pin to a specific tag — run `terraform init -upgrade` after bumping the version.
  source = "github.com/mvhungrydev/aws-devsecops-pipeline-module//infra/modules/pipeline?ref=v1.0.0"

  # ── Required ──────────────────────────────────────────────────────────────
  app_name                = var.app_name
  language                = var.language   # "python" | "java" | "dotnet" | "node"
  github_repo             = var.github_repo
  codestar_connection_arn = var.codestar_connection_arn

  # ── Optional with defaults ────────────────────────────────────────────────
  branch      = var.branch      # default: "main"
  aws_region  = var.aws_region  # default: "us-east-1"
  environment = var.environment # default: "dev"

  # ── Container scan (Stage 3) ──────────────────────────────────────────────
  # Set enable_container_scan = true to add the Build → Trivy → ECR Push stage.
  # Both ecr_repo_name and dockerfile_path are required when enabled (validated
  # at plan time via preconditions in validations.tf).
  enable_container_scan = var.enable_container_scan
  ecr_repo_name         = var.ecr_repo_name   # e.g. "my-app" — must already exist in ECR
  dockerfile_path       = var.dockerfile_path  # directory containing Dockerfile, relative to repo root
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs — surface module outputs to the caller
# ─────────────────────────────────────────────────────────────────────────────

output "pipeline_name" {
  value       = module.pipeline.pipeline_name
  description = "CodePipeline name — for console navigation and manual retries"
}

output "artifact_bucket_name" {
  value       = module.pipeline.artifact_bucket_name
  description = "S3 artifact bucket name"
}

output "artifact_bucket_arn" {
  value       = module.pipeline.artifact_bucket_arn
  description = "S3 artifact bucket ARN — attach additional IAM policies here if needed"
}