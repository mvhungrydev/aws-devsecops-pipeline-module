#!/usr/bin/env bash
# setup-dev.sh — install pre-commit and wire up the git hook (macOS)
set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────
info()  { echo "[setup-dev] $*"; }
error() { echo "[setup-dev] ERROR: $*" >&2; exit 1; }

# ── git check ────────────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || error "git is not installed."

# ── install pre-commit ───────────────────────────────────────────────────────
if command -v pre-commit >/dev/null 2>&1; then
    info "pre-commit already installed: $(pre-commit --version)"

elif command -v brew >/dev/null 2>&1; then
    info "Installing pre-commit via Homebrew..."
    brew install pre-commit

elif command -v pipx >/dev/null 2>&1; then
    info "Installing pre-commit via pipx..."
    pipx install pre-commit

elif command -v pip3 >/dev/null 2>&1; then
    info "Installing pre-commit via pip3..."
    pip3 install --user pre-commit

elif command -v pip >/dev/null 2>&1; then
    info "Installing pre-commit via pip..."
    pip install --user pre-commit

else
    error "No package manager found (brew, pipx, pip3, pip). \
Install one of them first, then re-run this script. \
Recommended: https://brew.sh"
fi

# ── install the git hook ──────────────────────────────────────────────────────
if [ ! -d ".git" ]; then
    error "Run this script from the repo root (no .git directory found)."
fi

info "Installing pre-commit git hook..."
pre-commit install

info "Done. pre-commit will now run automatically on every 'git commit'."
info "To run all hooks manually: pre-commit run --all-files"
