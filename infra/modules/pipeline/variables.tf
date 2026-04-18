variable "language" {
  type        = string
  description = "Scanner image selector — determines which ghcr.io scanner image CodeBuild uses for the security scan stage"

  validation {
    condition     = contains(["python", "java", "dotnet", "node"], var.language)
    error_message = "language must be one of: python, java, dotnet, node"
  }
}

variable "app_name" {
  type        = string
  description = "Application name — used as a prefix in all resource names and tags"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository in owner/repo format (e.g. mvhungrydev/my-app)"
}

variable "branch" {
  type        = string
  description = "Branch that triggers the pipeline on push"
  default     = "main"
}

variable "codestar_connection_arn" {
  type        = string
  description = "ARN of an Available CodeStar Connection to GitHub — must be in Available state before apply"
}

variable "enable_container_scan" {
  type        = bool
  description = "When true, adds a Build + Trivy + ECR Push stage after the security scan. Requires ecr_repo_name to be set."
  default     = false
}

variable "ecr_repo_name" {
  type        = string
  description = "Name of the consuming project's private ECR repository. Required when enable_container_scan = true."
  default     = ""
}

variable "aws_region" {
  type        = string
  description = "AWS region for all resources provisioned by this module"
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment tag applied to all module resources (e.g. dev, prod)"
  default     = "dev"
}
