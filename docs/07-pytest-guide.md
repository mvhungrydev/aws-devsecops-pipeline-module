# 08 — Testing Guide (aws-devsecops-pipeline-module)

> This repo contains Dockerfiles and Terraform HCL — no Flask app, no boto3, no DynamoDB.
> pytest is not the primary testing tool here. This guide covers the testing approach appropriate for this repo's artifacts.

---

## What Needs Testing

| Artifact | Test Method | Automates? |
|----------|------------|-----------|
| Scanner image Dockerfiles | Docker build + `RUN` verification commands | Yes — fails build if tools broken |
| Terraform module syntax | `terraform validate` + `terraform fmt -check` | Yes — CI/manual |
| Terraform module IaC security | `checkov -d infra/ --framework terraform` | Yes — pre-commit |
| Scanner image behavior | Manual smoke test (run scanner against dirty/clean code) | No — manual |
| Pipeline end-to-end | Integration test via `sample-python-app` | Manual pipeline run |

---

## Dockerfile Testing

### Built-in Verification (Automatic)

Each Dockerfile ends with a `RUN` command that verifies all installed tools:

```dockerfile
# Python image
RUN gitleaks version && bandit --version && semgrep --version && checkov --version

# Java/dotnet/node images
RUN gitleaks version && semgrep --version && checkov --version
```

If any tool fails to install or is broken, `docker build` exits non-zero immediately. This catches:
- Version not found (yanked PyPI release)
- Binary URL changed (gitleaks GitHub release URL drift)
- Incompatible dependency resolution

### Local Build Test

```bash
# Build and verify all 4 images locally
docker build -t security-scanner-python scanner-images/python/
docker build -t security-scanner-java scanner-images/java/
docker build -t security-scanner-dotnet scanner-images/dotnet/
docker build -t security-scanner-node scanner-images/node/
```

All 4 must build without errors before pushing to ECR Public.

### Scanner Smoke Test (Manual)

After building the Python image, verify it catches findings on known-bad code:

```bash
# Create a temp file with a fake secret
echo 'password = "AKIAIOSFODNN7EXAMPLE"' > /tmp/test_secret.py

# Run the scanner image against it
docker run --rm \
  -v /tmp:/scan \
  security-scanner-python \
  bash -c "cd /scan && gitleaks detect --source . --no-git --exit-code 1"

# Expected: gitleaks exits 1 (finding detected)
echo "Exit code: $?"  # Should print: Exit code: 1

# Cleanup
rm /tmp/test_secret.py
```

Run the inverse test with a clean file to confirm no false positives:

```bash
echo 'def hello(): return "world"' > /tmp/test_clean.py

docker run --rm \
  -v /tmp:/scan \
  security-scanner-python \
  bash -c "cd /scan && gitleaks detect --source . --no-git --exit-code 1"

echo "Exit code: $?"  # Should print: Exit code: 0

rm /tmp/test_clean.py
```

---

## Terraform Module Testing

### Syntax Validation

Run from `infra/modules/pipeline/`:

```bash
# Initialize (needed for validate, but no backend required for a module)
terraform init -backend=false

# Validate HCL syntax and references
terraform validate

# Check formatting
terraform fmt -check -recursive
```

`terraform validate` without a backend confirms:
- All variable references exist
- All resource attributes are valid types
- No circular dependencies
- `local.scanner_images[var.language]` key reference is syntactically correct

It does NOT confirm:
- That the AWS resources will actually be created (no plan)
- That the IAM policies are correct
- That the CodePipeline stage artifact names match

### IaC Security Scan

```bash
# Run checkov on the Terraform module
checkov -d infra/ --framework terraform

# Or with pre-commit:
pre-commit run checkov --all-files
```

Expected checkov output: a set of PASSED checks and potentially some FAILED or SKIPPED checks. For acceptable failures (e.g., S3 bucket without public access block — CodePipeline artifact buckets are private by design), add inline suppressions:

```hcl
resource "aws_s3_bucket" "artifacts" {
  bucket = "..."
  #checkov:skip=CKV_AWS_144: Cross-region replication not required for CI/CD artifact storage
  #checkov:skip=CKV2_AWS_62: S3 event notifications not required for artifact bucket
}
```

Document every suppression with a reason. Do not suppress CRITICAL checks without understanding the risk.

### Terraform Format

```bash
# Fix formatting in place
terraform fmt -recursive

# Or check only (used in CI/pre-commit)
terraform fmt -check -recursive
```

All `.tf` files must be formatted before commit. The `terraform fmt` pre-commit hook enforces this.

---

## Pre-Commit Hook Testing

The `.pre-commit-config.yaml` in this repo is a **template for consuming projects**. To verify it works correctly, test it against the `sample-python-app` repo (which copies this file to its root).

To test the template locally in isolation:

```bash
# Create a test directory mimicking a consuming project
mkdir /tmp/test-consumer && cd /tmp/test-consumer
git init
cp /path/to/aws-devsecops-pipeline-module/.pre-commit-config.yaml .
mkdir -p infra sample-app

# Create a clean Terraform file
cat > infra/main.tf <<'EOF'
resource "aws_s3_bucket" "test" {
  bucket = "test-bucket"
}
EOF

# Run the hooks
pre-commit run --all-files

# Cleanup
cd / && rm -rf /tmp/test-consumer
```

---

## No pytest for This Repo

This repo has no Python application code. pytest is not used. If helper Python scripts are added to `scripts/` in the future (e.g., a script to validate scanner image versions are up to date), add a `tests/` directory and a `requirements-dev.txt` at that time.

For now:

```
tests/ — does not exist in this repo
pytest — not installed, not required
```

The equivalent of "all tests pass" for this repo is:
1. All 4 Docker builds succeed
2. `terraform validate` passes on `infra/modules/pipeline/`
3. `terraform fmt -check` passes
4. `checkov` passes with no unexpected failures
5. Manual scanner smoke test produces correct exit codes

---

## Running All Checks Locally

```bash
# From the repo root

# 1. Build scanner images
docker build -t security-scanner-python scanner-images/python/
docker build -t security-scanner-java scanner-images/java/
docker build -t security-scanner-dotnet scanner-images/dotnet/
docker build -t security-scanner-node scanner-images/node/

# 2. Terraform module validation
cd infra/modules/pipeline
terraform init -backend=false
terraform validate
terraform fmt -check -recursive
cd ../../..

# 3. IaC scan
checkov -d infra/ --framework terraform

# 4. Pre-commit (on this repo itself)
pre-commit run --all-files
```

All of the above must pass before tagging a new module version.
