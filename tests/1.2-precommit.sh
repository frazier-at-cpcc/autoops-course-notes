#!/usr/bin/env bash
# Verifies the pre-commit framework example in the 1.2 notes.
# Needs: pre-commit (pip install pre-commit) and network access to GitHub.
set -euo pipefail
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name ci && git config --global user.email ci@example.com
git init -q
cat > .pre-commit-config.yaml <<'YAML'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: check-yaml
      - id: detect-private-key
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.6.9
    hooks:
      - id: ruff          # lint
      - id: ruff-format   # format
YAML
printf 'import os\ndef f( x ):\n    return x\n' > tool.py
printf -- '-----BEGIN RSA PRIVATE KEY-----\nabc\n' > id_rsa
git add .
out=$(pre-commit run --all-files 2>&1 || true)
echo "$out" | grep -E "\.\.\.+(Passed|Failed)$"
expect() { grep -Eq "^$1\.+$2$" <<<"$out" || { echo "FAIL: expected '$1 ... $2'"; echo "$out"; exit 1; }; }
expect 'trim trailing whitespace' Passed
expect 'check yaml' Passed
expect 'detect private key' Failed
expect 'ruff' Failed
expect 'ruff-format' Failed   # formatter rewrote tool.py
pre-commit install >/dev/null && [ -x .git/hooks/pre-commit ]
echo "ALL 1.2 PRE-COMMIT CHECKS PASSED"
