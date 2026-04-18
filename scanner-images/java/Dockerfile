FROM python:3.12-slim

# git is required by pre-commit for hook installation and by gitleaks for history scan
RUN apt-get update && apt-get install -y \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# gitleaks: installed as a binary (not via pip) — pinned to known-good version
RUN curl -sSfL \
    https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz \
    | tar -xz -C /usr/local/bin gitleaks

# semgrep: Multi-language pattern-based SAST
# checkov: Terraform IaC misconfiguration scanner
# pre-commit: Hook framework — runs all tools via .pre-commit-config.yaml
# bandit omitted — Python-only tool, no benefit for Java projects
RUN pip install --no-cache-dir \
    semgrep==1.70.0 \
    checkov==3.2.0 \
    pre-commit==3.7.0

# Fail the image build if any tool is broken — catches installation errors early
RUN gitleaks version && semgrep --version && checkov --version
