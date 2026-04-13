# setup-dev.ps1 — install pre-commit and wire up the git hook (Windows)
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── helpers ───────────────────────────────────────────────────────────────────
function Info  { param($msg) Write-Host "[setup-dev] $msg" }
function Abort { param($msg) Write-Error "[setup-dev] ERROR: $msg"; exit 1 }
function Has   { param($cmd) $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

# ── git check ─────────────────────────────────────────────────────────────────
if (-not (Has 'git')) { Abort "git is not installed." }

# ── install pre-commit ────────────────────────────────────────────────────────
if (Has 'pre-commit') {
    Info "pre-commit already installed: $(pre-commit --version)"

} elseif (Has 'winget') {
    Info "Installing pre-commit via winget..."
    winget install --id Python.Launcher -e --silent   # ensure 'py' launcher if needed
    winget install --id pre-commit.pre-commit -e --silent

} elseif (Has 'pipx') {
    Info "Installing pre-commit via pipx..."
    pipx install pre-commit

} elseif (Has 'pip') {
    Info "Installing pre-commit via pip..."
    pip install --user pre-commit

} elseif (Has 'pip3') {
    Info "Installing pre-commit via pip3..."
    pip3 install --user pre-commit

} else {
    Abort @"
No package manager found (winget, pipx, pip).
Options:
  - winget is built into Windows 10 (1809+) and Windows 11.
  - Install Python from https://python.org (includes pip), then re-run.
  - Install pipx: https://pipx.pypa.io
"@
}

# Refresh PATH so a freshly installed pre-commit is visible in this session
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# ── install the git hook ──────────────────────────────────────────────────────
if (-not (Test-Path '.git')) {
    Abort "Run this script from the repo root (no .git directory found)."
}

Info "Installing pre-commit git hook..."
pre-commit install

Info "Done. pre-commit will now run automatically on every 'git commit'."
Info "To run all hooks manually: pre-commit run --all-files"
