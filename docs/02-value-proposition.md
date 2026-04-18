# 02 — Value Proposition (aws-devsecops-pipeline-module)

## Why Not GitHub Actions?

| Concern | GitHub Actions | CodePipeline (this module) |
|---------|---------------|---------------------------|
| Account boundary | Build logs and secrets leave AWS | Everything runs inside the AWS account |
| Audit trail | GitHub UI only | Native CloudTrail — every execution, approval, and failure |
| AWS credential management | OIDC token exchange required in every workflow | IAM role attached natively to CodeBuild — no token exchange |
| Manual Approval gate | No built-in equivalent | Native CodePipeline approval action with SNS email |
| Regulated environment fit | Third-party SaaS dependency | AWS-managed service, no external dependency |
| CAB process mirror | Must be scripted/workarounded | Manual Approval is a first-class stage |

**When GitHub Actions is the better choice:** Open source projects, small teams heavily invested in the GitHub ecosystem (dependabot, PR checks, Actions marketplace), multi-cloud environments. For AWS-native enterprise DevOps, CodePipeline is the correct tool.

---

## Why Not Manual Pipeline Setup?

Every team that builds pipelines manually makes slightly different choices: different stage names, different scan tools, different severity thresholds, different approval mechanics. When something goes wrong, there is no single reference to audit. When a new project starts, the process begins again from scratch.

This module eliminates that inconsistency. The security gates are wired in by default — they cannot be forgotten because they are the module. A consuming project gets the same pipeline as every other project that uses the module, with the same severity thresholds and the same stage structure.

---

## What This Module Adds Over Manual Setup

| Capability | Manual Setup | This Module |
|-----------|-------------|------------|
| Security scanning | Forgotten, inconsistent | Enforced on every push to `main` |
| Multi-language support | Per-project decision | Single `language` variable selects correct scanner image |
| Scanner image management | Build on every run or manage separately | Pre-built images on GitHub Container Registry (ghcr.io) — zero setup for consumers |
| IaC scanning | Typically skipped | checkov runs on every push to main |
| Container CVE scanning | Often skipped | trivy blocks CRITICAL CVEs before ECR push (`enable_container_scan = true`) |
| Reusability | Copy-paste | `module "pipeline"` call with ≤ 8 inputs |
| Versioning | None | Git tags — pin to `?ref=v1.0.0` |

---

## Tooling Decisions

### Secret Detection: gitleaks

| Alternative | Why Not |
|-------------|---------|
| `detect-secrets` (Yelp) | Lower recall on AWS credential patterns — gitleaks specifically tuned for API keys, JWT tokens, and cloud credentials |
| `git-secrets` (AWS) | AWS-specific only — misses non-AWS secrets; abandoned project |
| Manual review | Not scalable — humans miss patterns in large diffs |
| **gitleaks** | Active project, high recall across credential types, pre-commit integration, blocks at scan stage |

**When detect-secrets is better:** Repositories that need to whitelist known false positives via a `.secrets.baseline` file with team sign-off. For a portfolio/portfolio-demo pipeline, gitleaks recall is more important.

---

### Python SAST: bandit + Semgrep

| Alternative | Why Not |
|-------------|---------|
| bandit alone | Misses cross-file patterns, no rules for non-Python frameworks |
| Semgrep alone | Strong but does not have the Flask/Django-native depth of bandit |
| PyLint security plugin | Limited security rules, primarily a style linter |
| **bandit + Semgrep** | Layered coverage: bandit handles Python-native patterns (subprocess, eval, crypto misuse); Semgrep handles cross-language patterns and framework rules |

**When Semgrep alone is better:** Non-Python projects where bandit is irrelevant. Java/C#/Node scanner images use Semgrep only.

---

### IaC Scanning: checkov

| Alternative | Why Not |
|-------------|---------|
| tfsec | Fewer AWS-specific rules; merged into Trivy as of 2023 |
| Trivy (IaC mode) | Viable — but Trivy is already used for container scanning; using one tool for both reduces specialization |
| Terrascan | Narrower rule set for AWS; less active community |
| **checkov** | Widest AWS Terraform rule coverage, active rule updates, pre-commit integration via `checkov` hook |

**When tfsec is better:** Teams already invested in the Aqua Security toolchain (Trivy, tfsec/Trivy IaC) who want a single vendor.

---

### Container Scanning: trivy

| Alternative | Why Not |
|-------------|---------|
| ECR native scanning (Basic) | Scans only on push — too late in the pipeline; misses the blocking opportunity |
| ECR enhanced scanning (Inspector) | $0.09/image — not free tier |
| Snyk | Paid tier required for CI/CD integration |
| **trivy** | Free, open source, high recall, runs in CodeBuild before ECR push, blocks on CRITICAL unfixed CVEs |

**ECR Basic scanning** is still enabled on the private ECR repo as a second layer (scan-on-push). Trivy in the pipeline is the gate; ECR Basic is the audit trail.

---

### Multi-Language SAST: Semgrep (Community)

| Alternative | Why Not |
|-------------|---------|
| SpotBugs + FindSecBugs (Java) | Requires compilation (JDK in image, separate compile stage) — adds ~3 min and significant complexity |
| Security Code Scan (C#) | Requires dotnet build (SDK in image, separate compile stage) |
| eslint-plugin-security (Node) | Pattern-based like Semgrep — no meaningful advantage over Semgrep's JS ruleset |
| **Semgrep community** | Source-only, no compilation, unified tool across all 4 languages, active rule registry |

**Acknowledged gap:** Semgrep community performs pattern-based analysis only. It does not trace user input flowing through method calls to a dangerous sink (taint analysis). This gap is meaningful for Java and C# in production environments. The gap is documented in the module README — production users of Java/C# should add SpotBugs + FindSecBugs or Security Code Scan to the pipeline.

---

### Scanner Image Registry: GitHub Container Registry (ghcr.io)

| Alternative | Rate Limits | Auth to Pull (public) | Account Dependency | Why Not |
|-------------|-------------|----------------------|-------------------|---------|
| ECR Public Gallery | None | No | AWS account — images lost on account closure | Tied to the AWS account being used for learning; not portable |
| Docker Hub | 100–200 pulls/6h (free tier) | No | Docker Hub account | Rate limits are a real risk for CodeBuild — multiple simultaneous pipeline runs could get throttled |
| Quay.io | None | No | Red Hat account | Less familiar; no meaningful advantage over ghcr.io |
| **GitHub Container Registry (ghcr.io)** | None | No (public images) | GitHub account | — |

**Decision:** ghcr.io — images live at `ghcr.io/mvhungrydev/`, tied to GitHub which is already the source of truth for all code. Survives any AWS account closure. No pull rate limits. Public images require no credentials for CodeBuild to pull — simpler IAM (no `ecr-public:GetAuthorizationToken` needed). Push via a GitHub Personal Access Token (PAT) with `write:packages` scope.

**When ECR Public is better:** Teams that want all artifacts inside AWS and have a stable, long-lived AWS account (e.g., enterprise production). For a portfolio project where the AWS account may be closed and reopened, ghcr.io is the more durable choice.

---

### CI/CD Platform: CodePipeline + CodeBuild

**Decision:** AWS CodePipeline + CodeBuild — AWS-managed, no server to maintain, native IAM, native CloudTrail, Manual Approval built in.

| Alternative | Why Not |
|-------------|---------|
| Jenkins | Self-hosted — requires EC2 instance (not free tier), OS patching, plugin management |
| CircleCI | Third-party SaaS — secrets and logs leave AWS account boundary |
| GitLab CI | Requires GitLab (not GitHub) or self-hosted GitLab runner |

**When Jenkins is better:** Large teams with existing Jenkins infrastructure and plugin ecosystems. For a new AWS-native project with no existing CI/CD investment, CodePipeline is the path of least resistance.
