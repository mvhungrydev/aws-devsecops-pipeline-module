# 01 — Business Requirements (aws-devsecops-pipeline-module)

## Problem Statement

Every AWS application eventually needs a CI/CD pipeline with security gates. This module is purpose-built for that use case: applications hosted on AWS, containerized with Docker, deployed to ECS, with infrastructure managed by Terraform. It is not a generic CI/CD tool — it assumes AWS as the deployment target throughout.

In practice, most teams wire up their pipelines manually — copy-pasting CodeBuild buildspecs, configuring stages in the console, and forgetting to add security scanning until a secret leaks or a CVE reaches production. When security tooling is added manually, it is inconsistent across projects and easy to skip.

This repository solves that problem by packaging a full, opinionated, security-first CI/CD pipeline as a reusable Terraform module. Any portfolio or production project can adopt the pipeline by calling `module "pipeline"` with 8–9 inputs and get:

- Secret scanning (gitleaks) on every commit
- Language-aware SAST (Semgrep + optional bandit)
- IaC scanning (checkov) on every Terraform change
- Container vulnerability scanning (trivy) before every ECR push
- A human approval gate before `terraform apply` runs
- Full CloudTrail auditability — nothing runs outside the AWS account boundary

The scanner images are pre-built and hosted on ECR Public Gallery. The Terraform module is consumed via a versioned GitHub source reference. There is no vendor lock-in beyond AWS itself.

---

## Goals

| # | Goal | Success Criteria |
|---|------|-----------------|
| G1 | Deliver a reusable pipeline Terraform module | Any project calls `module "pipeline"` with 8 inputs and gets a working 6-stage pipeline |
| G2 | Support 4 languages via a single `language` input variable | `python`, `java`, `dotnet`, `node` each select the correct scanner image |
| G3 | Make scanner images publicly pullable with no auth | Images on ECR Public Gallery — CodeBuild pulls without credentials |
| G4 | Block all HIGH+ security findings automatically | Pipeline stage fails and stops on any finding at or above threshold |
| G5 | Require human approval before infrastructure changes apply | Manual Approval gate with SNS email + S3 plan link |
| G6 | Operate within AWS Free Tier for infrequent deployments | ≤ 100 CodeBuild minutes/month with S3 caching enabled |

---

## Stakeholders

| Role | Responsibility |
|------|---------------|
| Module author (builder) | Builds and maintains scanner images and Terraform module |
| Module consumer (developer) | Calls `module "pipeline"` from their own project's `infra/envs/` entrypoint |
| Pipeline operator | Responds to security findings, reviews approval emails, clicks Approve/Reject |

---

## Functional Requirements

| ID | Requirement |
|----|-------------|
| FR1 | Module accepts `language` variable: `python`, `java`, `dotnet`, `node` — selects correct ECR Public scanner image |
| FR2 | Module accepts `app_name`, `github_repo`, `branch`, `ecr_repo_name`, `ecs_cluster_name`, `ecs_service_name`, `approval_email`, `codestar_connection_arn` as inputs |
| FR3 | Pipeline triggers automatically on push to the configured `branch` via CodeStar Connection |
| FR4 | Stage 2 runs `pre-commit run --all-files` inside the ECR Public scanner image — blocks on any hook failure |
| FR5 | gitleaks runs on every file in every commit — blocks on any detected credential |
| FR6 | bandit runs on Python source files — blocks on HIGH+ findings (Python language only) |
| FR7 | Semgrep runs on all source files — blocks on HIGH+ findings (all languages) |
| FR8 | checkov runs on `infra/**/*.tf` — blocks on CRITICAL/HIGH misconfigs |
| FR9 | Stage 3 builds the Docker image and runs trivy — blocks on CRITICAL unfixed CVEs before ECR push |
| FR10 | Stage 4 runs `terraform plan` and saves output to S3 — plan is accessible to the approver |
| FR11 | Stage 5 sends SNS email with S3 plan link — pipeline waits for human Approve or Reject |
| FR12 | Stage 6 runs `terraform apply` only after human approval — deploys new image to ECS |
| FR13 | All 6 stages are distinct, named, and visible in the CodePipeline console |
| FR14 | S3 caching is enabled on all CodeBuild projects — pre-commit envs, pip, Docker layers, Terraform providers |
| FR15 | Module provisions `.pre-commit-config.yaml` as a template that consuming projects copy to their repo root |
| FR16 | `scripts/setup-dev.sh` (macOS) and `scripts/setup-dev.ps1` (Windows) are provided for optional local setup |
| FR17 | Module is tagged with `v<major>.<minor>.<patch>` — consuming projects pin to a tag, not `HEAD` |

---

## Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR1 | Cost | 0 unexpected charges — all resources within AWS Free Tier for low-frequency deployments |
| NFR2 | Pipeline runtime | < 15 min uncached; < 8 min with S3 caching on repeat runs |
| NFR3 | Reusability | Module callable with ≤ 10 lines of Terraform from any consuming project |
| NFR4 | Scanner images | Publicly pullable from ECR Public Gallery — no auth, no rate limits |
| NFR5 | Credentials | No long-lived credentials — CodeBuild uses IAM roles natively; no AWS keys in code |
| NFR6 | Auditability | Every pipeline execution logged in CloudTrail; all logs in CloudWatch |
| NFR7 | Module versioning | Breaking changes increment major version; all tags are immutable git tags |

---

## Out of Scope

| Item | Reason |
|------|--------|
| PR / feature-branch pipeline | `main` branch trigger only for v1 |
| Multi-account deployment | Single AWS account for free tier |
| GitHub Actions | AWS-native tooling chosen for audit trail and account boundary |
| NAT Gateway | SSM Session Manager covers access needs |
| Application Load Balancer | SSM port forwarding — free tier |
| Taint analysis for Java/C# | Documented gap — Semgrep community (pattern-based) is used |
| Automated module pipeline | Module is released via manual git tag — no self-hosting pipeline |
| ECR Private for scanner images | ECR Public Gallery chosen — zero auth overhead for CodeBuild pull |
