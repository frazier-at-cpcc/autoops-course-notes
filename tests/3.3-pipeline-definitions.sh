#!/usr/bin/env bash
# Verifies the GitHub Actions and GitLab CI definitions in the 3.3 Pipeline
# Definitions notes: actionlint plus a real act run of the workflow, and a real
# gitlab-ci-local run of .gitlab-ci.yml, on a branch push and on a tag.
# gitlab-ci-local uses --force-shell-executor (the image: line is not pulled)
# and simulates the tag pipeline by setting CI_COMMIT_TAG and unsetting
# CI_COMMIT_BRANCH, which is what GitLab does for a tag pipeline.
# The Jenkinsfile is validated and run by tests/3.3-jenkins.sh.
# Needs: act, actionlint, yamllint, gitlab-ci-local, rsync,
#        docker (pulls mirror.gcr.io/library/node:24-bookworm-slim for act).
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name ci && git config --global user.email ci@example.com
unset GITHUB_TOKEN GH_TOKEN || true
RUNNER_IMAGE=mirror.gcr.io/library/node:24-bookworm-slim
docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 || docker pull -q "$RUNNER_IMAGE" >/dev/null
say() { printf '\n== %s\n' "$*"; }
absent() { if grep -q "$@"; then echo "FAIL: did not expect '$1' in $2"; exit 1; fi; }
glci() { gitlab-ci-local --no-color --force-shell-executor --shell-isolation \
  --ignore-predefined-vars CI_COMMIT_TAG,CI_COMMIT_BRANCH "$@" 2>&1 \
  | grep -v -e '^Unable to retrieve' -e 'Command failed' -e '^fatal:' -e '^Using fallback' \
  -e '^error: No such remote' -e '^$' -e 'parsing and downloads' -e 'json schema validated' || true; }
YL='{extends: default, rules: {document-start: disable, truthy: disable, line-length: {max: 52}}}'

git init -q -b main netops && cd netops
git remote add origin https://example.com/netops/configs.git

say "GitHub Actions workflow"
mkdir -p .github/workflows
printf -- '-P ubuntu-latest=%s\n--pull=false\n' "$RUNNER_IMAGE" > .actrc
cat > .github/workflows/github-actions.yml <<'YAML'
name: netops-ci
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - name: Build
        run: |
          mkdir -p dist
          echo "vlan 10" > dist/core-sw1.cfg
      - name: Test
        run: grep -q "vlan 10" dist/core-sw1.cfg

  deploy:
    needs: build
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - run: echo "deploy $GITHUB_SHA"

  release:
    needs: build
    if: github.ref_type == 'tag'
    runs-on: ubuntu-latest
    steps:
      - run: echo "release $GITHUB_REF_NAME"
YAML
actionlint && echo "actionlint: no problems"
yamllint -d "$YL" .github/workflows/github-actions.yml

say "GitLab CI pipeline"
cat > .gitlab-ci.yml <<'YAML'
stages: [build, test, deploy]

default:
  image: alpine:3.20
  timeout: 10m

build:
  stage: build
  script:
    - mkdir -p dist
    - echo "vlan 10" > dist/core-sw1.cfg
  artifacts:
    paths: [dist/]

test:
  stage: test
  script:
    - grep -q "vlan 10" dist/core-sw1.cfg

deploy:
  stage: deploy
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - echo "deploy $CI_COMMIT_SHA"

release:
  stage: deploy
  rules:
    - if: $CI_COMMIT_TAG
  script:
    - echo "release $CI_COMMIT_TAG"
YAML
yamllint -d "$YL" .gitlab-ci.yml
git add . && git commit -qm "ci: add pipelines"
git tag -a v1.4.0 -m "Release 1.4.0"
SHA=$(git rev-parse HEAD)

say "act: push to main"
echo '{"ref":"refs/heads/main"}' > ../main.json
act push -e ../main.json --json 2>/dev/null > ../act-main.json
jq -r 'select(.jobResult) | "\(.jobID) \(.jobResult)"' ../act-main.json | tee ../act-main.txt
jq -j 'select(.raw_output) | .msg' ../act-main.json | tee -a ../act-main.txt
grep -q '^build success$' ../act-main.txt
grep -q '^deploy success$' ../act-main.txt
grep -qx "deploy $SHA" ../act-main.txt
absent '^release' ../act-main.txt

say "act: push of tag v1.4.0"
echo '{"ref":"refs/tags/v1.4.0"}' > ../tag.json
act push -e ../tag.json --json 2>/dev/null > ../act-tag.json
jq -r 'select(.jobResult)
    | "\(.jobID) \(.jobResult)"' ../act-tag.json | tee ../act-tag.txt
jq -j 'select(.raw_output) | .msg' ../act-tag.json | tee -a ../act-tag.txt
grep -q '^release success$' ../act-tag.txt
grep -qx 'release v1.4.0' ../act-tag.txt
absent '^deploy' ../act-tag.txt

say "gitlab-ci-local: branch pipeline on main"
glci > ../gl-main.txt
grep -E 'starting|>|PASS|FAIL|artifacts' ../gl-main.txt
grep -q '^ PASS  build' ../gl-main.txt
grep -q '^ PASS  test' ../gl-main.txt
grep -q "deploy  > deploy $SHA$" ../gl-main.txt
absent 'release' ../gl-main.txt
grep -q 'test    imported artifacts' ../gl-main.txt

say "gitlab-ci-local: tag pipeline (simulated)"
glci --variable CI_COMMIT_TAG=v1.4.0 --unset-variable CI_COMMIT_BRANCH > ../gl-tag.txt
grep -E '>|PASS|FAIL' ../gl-tag.txt
grep -q 'release > release v1.4.0' ../gl-tag.txt
absent 'deploy  >' ../gl-tag.txt

echo
echo "ALL 3.3 PIPELINE DEFINITIONS CHECKS PASSED"
