# 01 — Business Requirements (aws-devsecops-pipeline-module)

## Problem Statement

Every development team eventually needs automated security scanning in their CI/CD pipeline. In practice, security tooling is added manually — inconsistently, often forgotten, and easy to skip under deadline pressure. When it is added, it varies across projects: different tools, different severity thresholds, different enforcement points. When something goes wrong there is no single reference to audit.

This repository solves that by packaging security scanning as a reusable Terraform module. Any project — regardless of language or deployment target — can adopt security gates by calling `module "pipeline"` with a small set of inputs and get:

- Secret scanning (gitleaks) on every commit
- Language-aware SAST (Semgrep + optional bandit for Python)
- IaC scanning (checkov) on every Terraform change
- Optionally: container vulnerability scanning (trivy) before ECR push

The module is deliberately scoped to **security scanning only**. It does not own deployment. The consuming project handles building, deploying, and managing its own infrastructure after the pipeline produces a verified artifact.

The scanner images are pre-built and hosted on GitHub Container Registry (ghcr.io). The Terraform module is consumed via a versioned GitHub source reference.

---

## Goals

| # | Goal | Success Criteria |
|---|------|-----------------|
| G1 | Deliver a reusable security scanning Terraform module | Any project calls `module "pipeline"` with ≤ 8 inputs and gets a working pipeline |
| G2 | Support 4 languages via a single `language` input variable | `python`, `java`, `dotnet`, `node` each select the correct scanner image |
| G3 | Make scanner images publicly pullable with no auth | Images on ghcr.io — CodeBuild pulls without credentials or IAM permissions |
| G4 | Block all HIGH+ security findings automatically | Pipeline stage fails and stops on any finding at or above threshold |
| G5 | Optionally scan container images for CVEs | `enable_container_scan = true` adds a Build + Trivy + ECR Push stage |
| G6 | Operate within AWS Free Tier for infrequent use | ≤ 100 CodeBuild minutes/month with S3 caching enabled |

---

## Stakeholders

| Role | Responsibility |
|------|---------------|
| Module author (builder) | Builds and maintains scanner images and Terraform module |
| Module consumer (developer) | Calls `module "pipeline"` from their own project's `infra/envs/` entrypoint |
| Pipeline operator | Responds to security findings in CodeBuild logs |

---

## Functional Requirements

| ID | Requirement |
|----|-------------|
| FR1 | Module accepts `language` variable: `python`, `java`, `dotnet`, `node` — selects correct ghcr.io scanner image |
| FR2 | Module accepts `app_name`, `github_repo`, `branch`, `codestar_connection_arn` as required inputs |
| FR3 | Pipeline triggers automatically on push to the configured `branch` via CodeStar Connection |
| FR4 | Security Scan stage runs `pre-commit run --all-files` inside the scanner image — blocks on any hook failure |
| FR5 | gitleaks runs on every file in every commit — blocks on any detected credential |
| FR6 | bandit runs on Python source files — blocks on HIGH+ findings (Python language only) |
| FR7 | Semgrep runs on all source files — blocks on HIGH+ findings (all languages) |
| FR8 | checkov runs on `infra/**/*.tf` — blocks on CRITICAL/HIGH misconfigs |
| FR9 | When `enable_container_scan = true`: docker build → trivy scan → ECR push — blocks on CRITICAL unfixed CVEs |
| FR10 | S3 caching is enabled on all CodeBuild projects — pre-commit envs, pip cache, Docker layers |
| FR11 | Module provisions `.pre-commit-config.yaml` as a template that consuming projects copy to their repo root |
| FR12 | `scripts/setup-dev.sh` (macOS) and `scripts/setup-dev.ps1` (Windows) are provided for optional local setup |
| FR13 | Module is tagged with `v<major>.<minor>.<patch>` — consuming projects pin to a tag, not `HEAD` |

---

## Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR1 | Cost | 0 unexpected charges — all resources within AWS Free Tier for low-frequency use |
| NFR2 | Pipeline runtime | < 10 min uncached; < 5 min with S3 caching on repeat runs |
| NFR3 | Reusability | Module callable with ≤ 8 lines of Terraform from any consuming project |
| NFR4 | Scanner images | Publicly pullable from ghcr.io — no auth, no rate limits |
| NFR5 | Credentials | No long-lived credentials — CodeBuild uses IAM roles natively; no AWS keys in code |
| NFR6 | Auditability | Every pipeline execution logged in CloudTrail; all logs in CloudWatch |
| NFR7 | Module versioning | Breaking changes increment major version; all tags are immutable git tags |

---

## Out of Scope

| Item | Reason |
|------|--------|
| Deployment pipeline | Consuming project owns its own deployment — module stops at verified artifact |
| Terraform Plan / Apply | Deployment orchestration is not this module's responsibility |
| Manual Approval gate | No deployment means no gate needed — security blocks are automated |
| PR / feature-branch pipeline | `main` branch trigger only for v1 |
| Multi-account deployment | Single AWS account for free tier |
| GitHub Actions | AWS-native tooling chosen for audit trail and account boundary |
| Taint analysis for Java/C# | Documented gap — Semgrep community (pattern-based) is used |
| Automated module pipeline | Module is released via manual git tag — no self-hosting pipeline |
