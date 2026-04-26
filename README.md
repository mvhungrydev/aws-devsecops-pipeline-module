# aws-devsecops-pipeline-module

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.10-purple)
![AWS CodePipeline](https://img.shields.io/badge/AWS-CodePipeline-orange)
![License](https://img.shields.io/badge/License-MIT-green)

A reusable Terraform module that provisions an AWS-native security scanning pipeline. Drop it into any project to get automated secret scanning, SAST, and IaC scanning on every push — with optional container vulnerability scanning. Supports Python, Java, C#, and Node.js via a single `language` input variable. Does not own deployment — stops at producing a verified artifact.

---

## What This Repo Delivers

**Two artifacts:**

1. **4 scanner Docker images** — hosted on GitHub Container Registry (ghcr.io), pulled by CodeBuild at runtime with no authentication required
2. **Terraform module** (`infra/modules/pipeline/`) — provisions CodePipeline, CodeBuild projects, S3 artifact bucket, CloudWatch log groups, and IAM roles in the consuming project's AWS account

This repo contains no application code. The Flask demo app that consumes this module lives in a separate repository (`sample-python-app`).

---

## How the Gates Work Together

```
Developer pushes / opens PR
        │
        ▼
GitHub Actions (security-scan.yml)        ← PRE-MERGE GATE
  pre-commit run --all-files
  gitleaks + bandit/Semgrep + checkov
  Blocks PR merge on any finding
        │
        │ PR approved + checks pass → merge to main
        ▼
CodePipeline (AWS)                        ← POST-MERGE ENFORCEMENT + AUDIT
  Stage 1: Source     ← pull from GitHub → S3
  Stage 2: Scan       ← same tools, AWS audit trail   [BLOCKS]
  Stage 3: Build+Scan ← docker build + trivy + ECR    [BLOCKS, optional]
```

Both gates run the same tools via the same `.pre-commit-config.yaml`. GitHub Actions catches issues before merge. CodePipeline enforces on main with full CloudTrail auditability. Neither replaces the other.

---

## Security Scanning Tools

| Stage | Tool | Scope | Blocks On |
|-------|------|-------|-----------|
| Security Scan | gitleaks | All files | Any detected credential |
| Security Scan | bandit | Python source only | HIGH+ findings |
| Security Scan | Semgrep | All source files | HIGH+ findings |
| Security Scan | checkov | `infra/**/*.tf` | CRITICAL/HIGH misconfigs |
| Build & Scan | trivy | Built container image | CRITICAL unfixed CVEs |

### SAST Gap — Read Before Using in Production

This pipeline uses **Semgrep community** for multi-language SAST. Semgrep performs **pattern-based analysis** — it identifies dangerous function calls and obvious misuse. It does **not** perform **taint analysis** — it cannot trace user input through multiple method calls to a dangerous sink.

| Language | Gap | Production Recommendation |
|----------|-----|--------------------------|
| Python | Small — bandit covers Flask/stdlib patterns | bandit + Semgrep (already included) |
| Node | Negligible — comparable to eslint-plugin-security | Semgrep is sufficient |
| Java | Meaningful — multi-hop injection paths missed | Add SpotBugs + Find Security Bugs |
| C# | Meaningful — cross-method taint analysis missing | Add Security Code Scan |

---

## Scanner Images (GitHub Container Registry)

Pre-built images, publicly pullable — no authentication required for CodeBuild to pull.

| `language` value | Image URI |
|-----------------|-----------|
| `python` | `ghcr.io/mvhungrydev/security-scanner-python:latest` |
| `java` | `ghcr.io/mvhungrydev/security-scanner-java:latest` |
| `dotnet` | `ghcr.io/mvhungrydev/security-scanner-dotnet:latest` |
| `node` | `ghcr.io/mvhungrydev/security-scanner-node:latest` |

Each image includes: checkov, gitleaks, Semgrep, pre-commit. The Python image also includes bandit.

### First-Time Bootstrap (Module Maintainer Only)

> **If you are consuming this module, skip this section — the images are already live on ghcr.io and publicly pullable. No action needed.**

This section is only relevant if you are maintaining the module and need to rebuild or republish the scanner images. Run from this repo's root:

```bash
# 1. Create a GitHub PAT with write:packages scope
#    GitHub → Settings → Developer settings → Personal access tokens → Generate new token (classic)
#    Scopes: write:packages

# 2. Authenticate
export GITHUB_PAT=<your-token>
echo $GITHUB_PAT | docker login ghcr.io --username mvhungrydev --password-stdin

# 3. Build and push all 4 images
docker build -t security-scanner-python scanner-images/python/
docker tag security-scanner-python ghcr.io/mvhungrydev/security-scanner-python:latest
docker push ghcr.io/mvhungrydev/security-scanner-python:latest

docker build -t security-scanner-java scanner-images/java/
docker tag security-scanner-java ghcr.io/mvhungrydev/security-scanner-java:latest
docker push ghcr.io/mvhungrydev/security-scanner-java:latest

docker build -t security-scanner-dotnet scanner-images/dotnet/
docker tag security-scanner-dotnet ghcr.io/mvhungrydev/security-scanner-dotnet:latest
docker push ghcr.io/mvhungrydev/security-scanner-dotnet:latest

docker build -t security-scanner-node scanner-images/node/
docker tag security-scanner-node ghcr.io/mvhungrydev/security-scanner-node:latest
docker push ghcr.io/mvhungrydev/security-scanner-node:latest

# 4. Set each package to Public visibility
#    GitHub → Packages → [package name] → Package settings → Change visibility → Public
```

To update a scanner image, bump the version in the Dockerfile, rebuild, and push with the same tag.

---

## Prerequisites

Before wiring up a consuming project, make sure you have:

| Requirement | Notes |
|-------------|-------|
| Terraform >= 1.10 | `terraform -version` to check |
| AWS CLI configured | `aws sts get-caller-identity` to verify credentials |
| GitHub account | Repo must be on GitHub — CodeStar Connections only supports GitHub |
| AWS account | Pipelines are created in the consuming project's account |

No Docker required for consuming the module — Docker is only needed if you're rebuilding the scanner images themselves.

---

## Consuming This Module

### Step 1 — CodeStar Connection (One-Time Per AWS Account)

CodePipeline connects to GitHub via AWS CodeStar Connections. The OAuth step cannot be automated — it requires a one-time click in the console.

1. AWS Console → **CodePipeline** → **Settings** → **Connections**
2. **Create connection** → provider: **GitHub** → name: `github-connection`
3. **Connect to GitHub** → authorize AWS Connector for GitHub → **Connect**
4. Wait for status: **Available**
5. Copy the Connection ARN → add to `terraform.tfvars` as `codestar_connection_arn`

One connection per AWS account can serve all pipelines.

### Step 2 — Call the Module

A fully worked example is in [`examples/complete/`](examples/complete/) — copy `main.tf` and `terraform.tfvars.example` to your project's `infra/envs/dev/` and fill in the values.

Pin to a git tag. Never use `HEAD` — a tag guarantees the module version is immutable.

**Security scan only (default):**
```hcl
# your-project/infra/envs/dev/main.tf
module "pipeline" {
  source = "github.com/mvhungrydev/aws-devsecops-pipeline-module//infra/modules/pipeline?ref=v1.0.0"

  language                = "python"   # python | java | dotnet | node
  app_name                = "my-app"
  github_repo             = "your-org/my-app"
  branch                  = "main"     # pipeline triggers on push to this branch
  codestar_connection_arn = var.codestar_connection_arn
}
```

**With container scanning (adds Build + Trivy + ECR Push stage):**

> **Prerequisite:** The ECR private repository must already exist before running `terraform apply`. This module does not create the ECR repo — create it separately and pass the name in.

```hcl
module "pipeline" {
  source = "github.com/mvhungrydev/aws-devsecops-pipeline-module//infra/modules/pipeline?ref=v1.0.0"

  language                = "python"
  app_name                = "my-app"
  github_repo             = "your-org/my-app"
  branch                  = "main"
  codestar_connection_arn = var.codestar_connection_arn
  enable_container_scan   = true
  ecr_repo_name           = "my-app"          # must match your existing ECR repo name
  dockerfile_path         = "."               # directory containing your Dockerfile, relative to repo root
}
```

**`terraform.tfvars` (minimum required values):**
```hcl
app_name                = "my-app"
language                = "python"
github_repo             = "your-org/my-app"
codestar_connection_arn = "arn:aws:codeconnections:us-east-1:123456789012:connection/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

A fully annotated example with all variables is in [`examples/complete/terraform.tfvars.example`](examples/complete/terraform.tfvars.example).

**Deploy:**
```bash
cd your-project/infra/envs/dev/

# First time — fetches the module from GitHub
terraform init

# Preview what will be created
terraform plan -var-file=terraform.tfvars

# Create the pipeline
terraform apply -var-file=terraform.tfvars
```

After `terraform apply`, push a commit to your configured `branch` to trigger the first pipeline run.

### Step 3 — Set Up GitHub Actions

Copy the workflow to your consuming project. You can download it directly from GitHub:

```bash
mkdir -p .github/workflows
curl -sSfL https://raw.githubusercontent.com/mvhungrydev/aws-devsecops-pipeline-module/main/.github/workflows/security-scan.yml \
  -o .github/workflows/security-scan.yml
```

Or copy it manually from [`/.github/workflows/security-scan.yml`](/.github/workflows/security-scan.yml) in this repo.

Then enable branch protection:

1. GitHub → repo → **Settings** → **Branches** → **Add branch protection rule**
2. Pattern: match your `branch` variable value (e.g. `main`, `develop`)
3. Enable: **Require a pull request before merging**
4. Enable: **Require status checks to pass** → search for and add `Security Scan`
5. Enable: **Restrict who can push to matching branches**

Push any commit to trigger the first workflow run and confirm the check appears.

### Step 4 — Done

The pipeline is self-contained — no SNS subscription, no approval email needed. Consuming projects handle their own deployment after the pipeline produces a verified artifact.

> **Note on Terraform state:** Your consuming project needs a backend to store Terraform state. The `examples/complete/main.tf` includes an S3 backend configuration — create an S3 bucket for state and update the `backend "s3"` block before running `terraform init`. See [Terraform state docs](https://developer.hashicorp.com/terraform/language/settings/backends/s3) if unfamiliar.

---

## Using with Java, C#, or Node.js

Changing `language` is the only Terraform change needed. Two additional steps are required in your consuming project:

### 1. Update `.pre-commit-config.yaml`

Copy `.pre-commit-config.yaml` from this repo to your project root, then **remove the bandit hook** — bandit is Python-only and will error on Java/C#/Node source files:

```yaml
# REMOVE this entire block for non-Python projects
- repo: https://github.com/PyCQA/bandit
  rev: 1.7.9
  hooks:
    - id: bandit
      args: ["-c", "pyproject.toml"]
      files: ^sample-app/
```

The remaining hooks (gitleaks, Semgrep, checkov, terraform_fmt) work for all languages.

### 2. Know the SAST gap for Java and C#

This module uses **Semgrep community** for SAST — pattern-based analysis only. For Java and C#, Semgrep cannot trace user input through multiple method calls to a dangerous sink (taint analysis). This is a meaningful gap for production workloads.

| Language | Gap | Recommended addition |
|----------|-----|----------------------|
| Java | Multi-hop injection paths missed | SpotBugs + [Find Security Bugs](https://find-sec-bugs.github.io/) |
| C# | Cross-method taint analysis missing | [Security Code Scan](https://security-code-scan.github.io/) |
| Node.js | Negligible — comparable rule coverage | None required |

Adding these tools requires a dedicated compile-and-scan stage (they need bytecode/compiled output). This is a documented v1 limitation — not a blocker for getting started, but address it before using this pipeline for production Java or C# workloads.

---

## Module Input Variables

| Variable | Type | Default | Required | Description |
|----------|------|---------|----------|-------------|
| `language` | string | — | Yes | Scanner image selector: `python`, `java`, `dotnet`, `node` |
| `app_name` | string | — | Yes | Used in all resource names and tags |
| `github_repo` | string | — | Yes | GitHub repo in `owner/repo` format |
| `branch` | string | `"main"` | No | Pipeline trigger branch |
| `codestar_connection_arn` | string | — | Yes | ARN of the Available CodeStar Connection to GitHub |
| `enable_container_scan` | bool | `false` | No | Adds Build + Trivy + ECR Push stage when `true` |
| `ecr_repo_name` | string | `""` | No | Required when `enable_container_scan = true` — must match existing ECR repo name |
| `dockerfile_path` | string | `"."` | No | Directory containing your Dockerfile, relative to repo root. Required when `enable_container_scan = true` |
| `aws_region` | string | `"us-east-1"` | No | AWS region for all resources |
| `environment` | string | `"dev"` | No | Environment tag applied to all module resources |

## Module Outputs

| Output | Description |
|--------|-------------|
| `pipeline_name` | CodePipeline name — for console navigation |
| `artifact_bucket_name` | S3 artifact bucket name |
| `artifact_bucket_arn` | S3 artifact bucket ARN |

---

## Module Versioning

This module uses semantic versioning via git tags.

```
v1.0.0  — initial release
v1.0.1  — buildspec bugfix, no variable changes
v1.1.0  — new optional variable added (backward compatible)
v2.0.0  — breaking change: variable renamed or removed
```

To release a new version:

```bash
git tag v1.0.1
git push origin v1.0.1
```

Consuming projects update their `source` ref and run:

```bash
terraform init -upgrade
terraform plan
```

---

## Local Developer Setup

Copy `.pre-commit-config.yaml` from this repo to your consuming project's root, then run the setup script.

### macOS / Linux

```bash
./scripts/setup-dev.sh
```

### Windows (PowerShell)

```powershell
.\scripts\setup-dev.ps1
```

Both scripts install `pre-commit` and register hooks in `.git/hooks/`. Hooks then run automatically on every `git commit`.

### Why Local pre-commit Matters

GitHub Actions blocks PR merges and CodePipeline blocks post-merge — but both gates fire **after** the commit reaches GitHub. For most hooks this means local setup is a faster feedback loop. For **gitleaks specifically**, it is a security requirement:

- **Without local gitleaks:** A commit with a secret reaches GitHub before any gate fires. The secret is in git history and must be scrubbed — a painful, often incomplete process even if the PR is blocked.
- **With local gitleaks:** The commit is rejected before it leaves your machine. The secret never touches GitHub.

**Recommendation:** Treat local pre-commit setup as mandatory for any developer on a repo protected by this module. Run `scripts/setup-dev.sh` (macOS) or `scripts/setup-dev.ps1` (Windows) as part of onboarding.

---

## Free Tier Usage (Per Consuming Project)

| Service | Free Tier | Usage |
|---------|-----------|-------|
| CodePipeline | 1 free active pipeline/month | 1 pipeline per project |
| CodeBuild | 100 min/month (`general1.small`) | ~8 min/run with S3 caching |
| S3 | 5 GB storage, 20k GET, 2k PUT | Artifacts + cache + state |
| CloudWatch Logs | 5 GB ingestion/month | Build logs, 30-day retention |

With S3 caching: approximately **12 full pipeline runs per month** within the free tier. Over-budget runs cost ~$0.04–$0.07 each (`$0.005/min × ~8 min`).

---

## Repo Structure

```
aws-devsecops-pipeline-module/
├── .github/
│   └── workflows/
│       └── security-scan.yml  ← GitHub Actions workflow (copy to consuming projects)
├── infra/
│   └── modules/
│       └── pipeline/          ← reusable Terraform module
│           ├── main.tf        ← CodePipeline, CodeBuild, S3, CloudWatch
│           ├── variables.tf
│           ├── outputs.tf
│           ├── iam.tf         ← scan role + build role (optional) + codepipeline role
│           ├── scanner_images.tf  ← locals: language → ghcr.io image map
│           └── buildspecs/    ← YAML templates per stage
│               ├── scan.yml
│               └── build.yml
├── scanner-images/            ← Dockerfiles for ghcr.io
│   ├── python/Dockerfile
│   ├── java/Dockerfile
│   ├── dotnet/Dockerfile
│   └── node/Dockerfile
├── scripts/
│   ├── setup-dev.sh           ← macOS/Linux pre-commit setup
│   └── setup-dev.ps1          ← Windows pre-commit setup
├── docs/                      ← design documentation (Mike Velasco Special)
├── .pre-commit-config.yaml    ← template — copy to consuming project root
├── .gitignore
└── README.md
```
