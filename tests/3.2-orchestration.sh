#!/usr/bin/env bash
# Verifies the pipelines and runs shown in the 3.2 Pipeline Orchestration notes.
# Runs a real GitLab pipeline with gitlab-ci-local (shell executor) and a real
# GitHub Actions workflow with act (Docker), then checks job order and results.
# Needs: gitlab-ci-local, rsync (used by gitlab-ci-local), act, actionlint,
#        docker (pulls mirror.gcr.io/library/node:24-bookworm-slim for act).
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name ci && git config --global user.email ci@example.com
# act would try to authenticate to GitHub with any token in the environment
unset GITHUB_TOKEN GH_TOKEN || true
RUNNER_IMAGE=mirror.gcr.io/library/node:24-bookworm-slim
docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 || docker pull -q "$RUNNER_IMAGE" >/dev/null

say() { printf '\n== %s\n' "$*"; }
absent() { if grep -q "$@"; then echo "FAIL: did not expect '$1' in $2"; exit 1; fi; }
# gitlab-ci-local prints git remote warnings for a repo with no real remote
glci() { gitlab-ci-local --no-color "$@" 2>&1 | grep -v -e '^Unable to retrieve' -e 'Command failed' \
  -e '^fatal:' -e '^Using fallback' -e '^error: No such remote' -e '^$' -e 'parsing and downloads' \
  -e 'json schema validated' || true; }
before() { # before FILE A B: first line matching A comes before first line matching B
  local a b; a=$(grep -n -m1 -- "$2" "$1" | cut -d: -f1); b=$(grep -n -m1 -- "$3" "$1" | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "FAIL: '$2' should come before '$3'"; cat "$1"; exit 1; }
}

say "GitLab DAG pipeline"
git init -q -b main netops && cd netops
git remote add origin https://gitlab.example.com/netops/configs.git
# Part 1 of .gitlab-ci.yml as shown in the notes
cat > .gitlab-ci.yml <<'YAML'
stages: [lint, test, build, deploy]

lint-yaml:
  stage: lint
  script: [echo "inventory ok"]

lint-python:
  stage: lint
  script: [echo "ruff ok"]

unit-tests:
  stage: test
  needs: [lint-python]
  script: [sleep 3, echo "14 passed"]

smoke-test:
  stage: test
  needs: [lint-yaml]
  allow_failure: true
  script: [exit 1]

render-configs:
  stage: build
  needs: [lint-yaml]
  script: [echo "rendered 12 configs"]
YAML
# Part 2 of .gitlab-ci.yml as shown in the notes
cat >> .gitlab-ci.yml <<'YAML'

deploy-staging:
  stage: deploy
  needs: [unit-tests, render-configs]
  timeout: 10m
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - echo "pushing configs"
    - test "$BREAK_DEPLOY" != "yes"

rollback:
  stage: deploy
  needs: [deploy-staging]
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: on_failure
  script: [echo "restoring last good configs"]
YAML
yamllint -d '{extends: default, rules: {document-start: disable, line-length: {max: 52}}}' .gitlab-ci.yml
git add . && git commit -qm "ci: add pipeline"

glci > ../run-main.txt
grep -E 'starting|finished|PASS|WARN|FAIL' ../run-main.txt
# DAG: render-configs (build stage) finishes while unit-tests (test stage) is still sleeping
before ../run-main.txt 'render-configs finished' 'unit-tests     finished'
before ../run-main.txt 'unit-tests     finished' 'deploy-staging starting'
grep -q 'smoke-test     finished in .* WARN 1' ../run-main.txt
grep -q '^ PASS  deploy-staging' ../run-main.txt
grep -q '^ WARN  smoke-test' ../run-main.txt
absent 'rollback' ../run-main.txt   # allowed failure does not trigger on_failure

say "failed deploy triggers rollback"
glci --variable BREAK_DEPLOY=yes > ../run-break.txt
grep -E 'deploy-staging|rollback' ../run-break.txt
grep -q '^ FAIL  deploy-staging' ../run-break.txt
grep -q '^ PASS  rollback' ../run-break.txt
grep -q 'rollback       > restoring last good configs' ../run-break.txt

say "feature branch: rules drop deploy and rollback"
git switch -q -c feature/NET-200-acl
gitlab-ci-local --list-json 2>/dev/null \
    | jq -r '.[] | "\(.name) \(.when)"' | tee ../list-feature.txt
grep -qx 'render-configs on_success' ../list-feature.txt
grep -qx 'deploy-staging never' ../list-feature.txt
grep -qx 'rollback never' ../list-feature.txt
cd ..

say "GitHub Actions: matrix, continue-on-error, if: failure()"
git init -q -b main ghrepo && cd ghrepo
git remote add origin https://github.com/netops/configs.git
mkdir -p .github/workflows
printf -- '-P ubuntu-latest=%s\n--pull=false\n' "$RUNNER_IMAGE" > .actrc
cat > .github/workflows/deploy.yml <<'YAML'
name: deploy
on: push
jobs:
  smoke:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        site: [clt, ral]
    steps:
      - run: echo "smoke test ${{ matrix.site }}"
      - run: exit 1
        continue-on-error: true
  deploy:
    needs: smoke
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: test "$BREAK" != "yes"
  rollback:
    needs: deploy
    if: failure()
    runs-on: ubuntu-latest
    steps:
      - run: echo "redeploy last good build"
YAML
actionlint
yamllint -d '{extends: default, rules: {document-start: disable, truthy: disable, line-length: {max: 52}}}' .github/workflows/deploy.yml
git add . && git commit -qm "ci: add deploy workflow"
# act exits non-zero because a job failed; that failure is the point here
{ act push --env BREAK=yes --json 2>/dev/null || true; } \
  | jq -r 'select(.jobResult) | "\(.job) \(.jobResult)"' | tee ../act.txt
grep -Eq '^deploy/smoke-1 +success$' ../act.txt
grep -Eq '^deploy/smoke-2 +success$' ../act.txt
grep -Eq '^deploy/deploy +failure$' ../act.txt
grep -Eq '^deploy/rollback +success$' ../act.txt
before ../act.txt 'deploy/deploy' 'deploy/rollback'
act push --json 2>/dev/null | jq -r 'select(.jobResult) | "\(.job) \(.jobResult)"' > ../act-ok.txt
cat ../act-ok.txt
grep -Eq '^deploy/deploy +success$' ../act-ok.txt
absent 'rollback' ../act-ok.txt   # if: failure() is false, so the job is skipped

echo
echo "ALL 3.2 ORCHESTRATION CHECKS PASSED"
