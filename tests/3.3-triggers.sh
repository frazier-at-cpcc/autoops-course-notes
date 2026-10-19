#!/usr/bin/env bash
# Verifies the 3.3 Webhooks, ChatOps, and Pipeline Triggers notes:
# a signed webhook checked with HMAC-SHA256, cron validation, manual, scheduled,
# and chat-started jobs, and the Git variables each platform exposes.
# GitHub Actions runs with act; GitLab CI runs with gitlab-ci-local, which reads
# branch and SHA from the local repo, so tag, schedule, and chat pipelines are
# simulated by setting CI_PIPELINE_SOURCE / CI_COMMIT_TAG as GitLab would.
# Jenkins output for BRANCH_NAME, TAG_NAME, and GIT_COMMIT comes from
# tests/3.3-jenkins.sh.
# Needs: python3, openssl, curl, act, actionlint, gitlab-ci-local, rsync,
#        docker (pulls mirror.gcr.io/library/node:24-bookworm-slim for act).
# Uses port 127.0.0.1:18400.
set -euo pipefail
WORK=$(mktemp -d)
HOOK_PID=
trap '[ -n "$HOOK_PID" ] && kill "$HOOK_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name ci && git config --global user.email ci@example.com
unset GITHUB_TOKEN GH_TOKEN || true
RUNNER_IMAGE=mirror.gcr.io/library/node:24-bookworm-slim
docker image inspect "$RUNNER_IMAGE" >/dev/null 2>&1 || docker pull -q "$RUNNER_IMAGE" >/dev/null
say() { printf '\n== %s\n' "$*"; }
absent() { if grep -q "$@"; then echo "FAIL: did not expect '$1' in $2"; exit 1; fi; }
# Silence gitlab-ci-local's warning about overriding predefined variables
export GCL_IGNORE_PREDEFINED_VARS=CI_PIPELINE_SOURCE,CI_COMMIT_TAG,CI_COMMIT_BRANCH
glci() { gitlab-ci-local --no-color "$@" 2>&1 | grep -v -e '^Unable to retrieve' -e 'Command failed' \
  -e '^fatal:' -e '^Using fallback' -e '^error: No such remote' -e '^$' -e 'parsing and downloads' \
  -e 'json schema validated' || true; }

say "HMAC method matches GitHub's published test vector"
printf '%s' 'Hello, World!' | openssl dgst \
    -sha256 -hmac "It's a Secret to Everybody" \
    -r | cut -c1-64 | fold -w 32 | tee vector.txt
[ "$(tr -d '\n' < vector.txt)" = 757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17 ]

say "webhook receiver verifies X-Hub-Signature-256"
cat > hook.py <<'PY'
import hashlib
import hmac
import os
from http.server import BaseHTTPRequestHandler
from http.server import HTTPServer

SECRET = os.environ["WEBHOOK_SECRET"].encode()


class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers["Content-Length"])
        body = self.rfile.read(size)
        mac = hmac.new(SECRET, body, hashlib.sha256)
        want = "sha256=" + mac.hexdigest()
        got = self.headers.get(
            "X-Hub-Signature-256", "")
        ok = hmac.compare_digest(want, got)
        # 202: queue the pipeline; 401: drop it
        self.send_response(202 if ok else 401)
        self.end_headers()


server = HTTPServer(("127.0.0.1", 18400), Hook)
server.serve_forever()
PY
awk 'length > 52 { print "line too long: " $0; exit 1 }' hook.py
export WEBHOOK_SECRET='lab-only-secret'
python3 hook.py 2>hook.log &
HOOK_PID=$!
until curl -s -o /dev/null http://127.0.0.1:18400/ 2>/dev/null; do sleep 0.2; done
BODY='{"ref":"refs/heads/main"}'
SIG=$(printf '%s' "$BODY" | openssl dgst \
    -sha256 -hmac "$WEBHOOK_SECRET" -r | cut -c1-64)
post() { curl -s -o /dev/null -w '%{http_code}\n' \
    -H "X-Hub-Signature-256: sha256=$SIG" \
    -d "$1" http://127.0.0.1:18400/; }
r1=$(post "$BODY"); echo "$r1"
r2=$(post '{"ref":"refs/heads/evil"}'); echo "$r2"
[ "$r1" = 202 ] && [ "$r2" = 401 ]
SIG=0000; r3=$(post "$BODY"); [ "$r3" = 401 ]   # wrong signature, original body

say "GitHub Actions triggers (actionlint + act)"
git init -q -b main gh && cd gh
git remote add origin https://github.com/netops/configs.git
mkdir -p .github/workflows
printf -- '-P ubuntu-latest=%s\n--pull=false\n' "$RUNNER_IMAGE" > .actrc
cat > .github/workflows/netops.yml <<'YAML'
name: netops
on:
  push:
    branches: [main]
    tags: ['v*']
  schedule:
    - cron: '17 6 * * 1-5'
  workflow_dispatch:
    inputs:
      target:
        type: choice
        options: [staging, production]
        default: staging
jobs:
  info:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "event=${{ github.event_name }}"
          echo "ref_name=${{ github.ref_name }}"
          echo "ref_type=${{ github.ref_type }}"
          echo "sha=${{ github.sha }}"
          echo "target=${{ inputs.target }}"
YAML
actionlint
git add . && git commit -qm "ci: add netops workflow"
git tag -a v1.4.0 -m "Release 1.4.0"
SHA=$(git rev-parse HEAD)
echo '{"ref":"refs/tags/v1.4.0"}' > ../tag.json
act push -e ../tag.json --json 2>/dev/null \
  | jq -j 'select(.raw_output) | .msg' | tee ../act-tag.txt
grep -qx 'event=push' ../act-tag.txt
grep -qx 'ref_name=v1.4.0' ../act-tag.txt
grep -qx 'ref_type=tag' ../act-tag.txt
grep -qx "sha=$SHA" ../act-tag.txt
echo '{"ref":"refs/heads/main","inputs":{"target":"production"}}' > ../dispatch.json
act workflow_dispatch -e ../dispatch.json --json 2>/dev/null \
  | jq -j 'select(.raw_output) | .msg' | tee ../act-dispatch.txt
grep -qx 'event=workflow_dispatch' ../act-dispatch.txt
grep -qx 'ref_name=main' ../act-dispatch.txt
grep -qx 'ref_type=branch' ../act-dispatch.txt
grep -qx 'target=production' ../act-dispatch.txt

say "actionlint rejects a bad cron expression"
sed "s/'17 6 \* \* 1-5'/'0 25 * * *'/" .github/workflows/netops.yml > bad.yml
rc=0; actionlint bad.yml > ../cron.txt 2>&1 || rc=$?
head -1 ../cron.txt
[ "$rc" = 1 ]
grep -q 'end of range (25) above maximum (23)' ../cron.txt
cd ..

say "GitLab CI: variables, manual, schedule, and chat jobs"
git init -q -b main gl && cd gl
git remote add origin https://gitlab.example.com/netops/configs.git
cat > .gitlab-ci.yml <<'YAML'
vars:
  script:
    - echo "source=$CI_PIPELINE_SOURCE"
    - echo "branch=$CI_COMMIT_BRANCH"
    - echo "tag=$CI_COMMIT_TAG"
    - echo "sha=$CI_COMMIT_SHA"

deploy-prod:
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
  script: [echo "deploying to production"]

nightly-backup:
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  script: [echo "backing up configs"]

show-vlans:
  rules:
    - if: $CI_PIPELINE_SOURCE == "chat"
  script:
    - echo "VLANs on $CHAT_INPUT are 10 20 30"
YAML
git add . && git commit -qm "ci: add pipeline"
SHA=$(git rev-parse HEAD)
glci vars > ../gl-push.txt
grep -E '^vars +> ' ../gl-push.txt
grep -qx 'vars > source=push' ../gl-push.txt
grep -qx 'vars > branch=main' ../gl-push.txt
grep -qx "vars > sha=$SHA" ../gl-push.txt
glci > ../gl-all.txt
grep -q 'vars *> source=push' ../gl-all.txt
absent 'deploying to production' ../gl-all.txt   # manual job waits
glci --manual deploy-prod deploy-prod > ../gl-manual.txt
grep -q 'deploy-prod *> deploying to production' ../gl-manual.txt
glci --variable CI_COMMIT_TAG=v1.4.0 --unset-variable CI_COMMIT_BRANCH vars > ../gl-tag.txt
grep -E '^vars +> ' ../gl-tag.txt
grep -q '^vars *> tag=v1.4.0$' ../gl-tag.txt
grep -q '^vars *> branch=$' ../gl-tag.txt
gitlab-ci-local --variable CI_PIPELINE_SOURCE=schedule \
    --list-json 2>/dev/null \
  | jq -r '.[] | "\(.name) \(.when)"' | tee ../gl-schedule.txt
grep -qx 'nightly-backup on_success' ../gl-schedule.txt
grep -qx 'deploy-prod manual' ../gl-schedule.txt
grep -qx 'show-vlans never' ../gl-schedule.txt
glci --variable CI_PIPELINE_SOURCE=chat \
  --variable CHAT_INPUT=core-sw1 show-vlans > ../gl-chat.txt
grep 'show-vlans *>' ../gl-chat.txt
grep -q 'show-vlans *> VLANs on core-sw1 are 10 20 30' ../gl-chat.txt

echo
echo "ALL 3.3 TRIGGERS CHECKS PASSED"
