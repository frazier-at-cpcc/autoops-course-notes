#!/usr/bin/env bash
# Verifies the 4.1 QA Testing, Validation, and Hotfixes notes: a pytest
# regression test, an ab load test, a curl smoke script against a good and
# a broken deployment, the pipeline gate (actionlint), and the hotfix flow.
# Needs: docker (pulls nginx:1.27-alpine), curl, pytest, actionlint,
#   ab (apt-get install apache2-utils)
set -euo pipefail
IMG=${NGINX_IMAGE:-mirror.gcr.io/library/nginx:1.27-alpine}
GOOD=18451 BAD=18452
WORK=$(mktemp -d)
cleanup() {
  docker rm -f ao-h-qa-good ao-h-qa-bad >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

say "regression test"
mkdir reg && cd reg
cat > vlans.py <<'EOF'
def parse_vlans(spec):
    """'10,20-22' -> [10, 20, 21, 22]"""
    out = []
    for part in spec.split(","):
        if "-" in part:
            lo, hi = part.split("-")
            out.extend(range(int(lo), int(hi) + 1))
        else:
            out.append(int(part))
    return out
EOF
cat > test_vlans.py <<'EOF'
from vlans import parse_vlans

def test_single():
    assert parse_vlans("10") == [10]

def test_range():
    assert parse_vlans("20-22") == [20, 21, 22]

# NET-311: a trailing comma crashed the parser
def test_trailing_comma():
    assert parse_vlans("10,20,") == [10, 20]
EOF
echo '$ pytest -q --tb=no -rN'
out=$(COLUMNS=40 pytest -q --tb=no -rN -p no:cacheprovider 2>&1 || true); echo "$out"
grep -q '1 failed, 2 passed' <<<"$out" || fail "regression test should fail on the old code"
# the fix: skip empty parts
sed -i 's/    for part in spec.split(","):/    for part in filter(None, spec.split(",")):/' vlans.py
grep -q 'filter(None' vlans.py || fail "fix not applied"
echo '$ pytest -q --tb=no -rN'
out=$(COLUMNS=40 pytest -q --tb=no -rN -p no:cacheprovider 2>&1); echo "$out"
grep -q '3 passed' <<<"$out" || fail "regression test should pass after the fix"
cd "$WORK"

say "a good and a broken deployment"
mkdir good bad
cat > good/default.conf <<'EOF'
server {
    listen 80;
    location = /healthz { return 200 "ok"; }
    location = /version { return 200 "2.1.1"; }
    location / { return 200 "home"; }
}
EOF
sed -e 's/return 200 "ok"/return 503 "db down"/' -e 's/2\.1\.1/2.1.0/' good/default.conf > bad/default.conf
docker run -d -q --name ao-h-qa-good -p "127.0.0.1:$GOOD:80" -v "$WORK/good:/etc/nginx/conf.d:ro" "$IMG" >/dev/null
docker run -d -q --name ao-h-qa-bad -p "127.0.0.1:$BAD:80" -v "$WORK/bad:/etc/nginx/conf.d:ro" "$IMG" >/dev/null
for p in $GOOD $BAD; do
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$p/" && break; sleep 0.2; done
done

say "smoke test"
cat > smoke.sh <<'EOF'
#!/bin/sh
# Usage: ./smoke.sh BASE_URL EXPECTED_VERSION
base=$1 want=$2 rc=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; rc=1; }

code=$(curl -s -o /dev/null -m 5 \
  -w '%{http_code}' "$base/healthz")
if [ "$code" = 200 ]; then ok "healthz 200"
else bad "healthz returned $code"; fi

ver=$(curl -s -m 5 "$base/version")
if [ "$ver" = "$want" ]; then ok "version $ver"
else bad "version $ver, want $want"; fi

t=$(curl -s -o /dev/null -m 5 \
  -w '%{time_total}' "$base/")
if awk "BEGIN{exit !($t < 0.5)}"; then
  ok "home page in ${t}s"
else bad "home page took ${t}s"; fi
exit $rc
EOF
chmod +x smoke.sh
shellcheck smoke.sh || fail "shellcheck smoke.sh"
echo "\$ ./smoke.sh http://127.0.0.1:$GOOD 2.1.1"
./smoke.sh "http://127.0.0.1:$GOOD" 2.1.1; rc=$?
echo "\$ echo \$?"; echo $rc
[ $rc -eq 0 ] || fail "smoke should pass on the good deployment"
echo "\$ ./smoke.sh http://127.0.0.1:$BAD 2.1.1"
set +e; ./smoke.sh "http://127.0.0.1:$BAD" 2.1.1 > bad.txt; rc=$?; set -e
cat bad.txt; echo "\$ echo \$?"; echo $rc
[ $rc -eq 1 ] || fail "smoke should fail on the broken deployment"
grep -q 'FAIL  healthz returned 503' bad.txt || fail "503 not reported"
grep -q 'FAIL  version 2.1.0, want 2.1.1' bad.txt || fail "version mismatch not reported"

say "load test"
echo "\$ ab -n 2000 -c 20 http://127.0.0.1:$GOOD/"
ab -n 2000 -c 20 "http://127.0.0.1:$GOOD/" > ab.txt 2>&1
cat ab.txt
grep -Eq '^Complete requests:[[:space:]]+2000$' ab.txt || fail "expected 2000 complete"
grep -Eq '^Failed requests:[[:space:]]+0$' ab.txt || fail "expected 0 failed"
grep -q '^Requests per second:' ab.txt || fail "no throughput line"
grep -Eq '^ +99%' ab.txt || fail "no p99 line"

say "pipeline gate (static validation only)"
mkdir -p .github/workflows
cat > .github/workflows/deploy.yml <<'EOF'
name: deploy
on:
  push:
    tags: ["v*"]
jobs:
  production:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v6
      - name: Deploy to the idle color
        run: ./switch.sh green
      - name: Smoke test (gate)
        run: ./smoke.sh "$APP_URL" "${TAG#v}"
        env:
          APP_URL: https://app.example.com
          TAG: ${{ github.ref_name }}
      - name: Roll back on failure
        if: failure()
        run: ./switch.sh blue
EOF
actionlint .github/workflows/deploy.yml || fail "actionlint"
echo "actionlint: deploy.yml OK"

say "hotfix flow"
git config --global user.name "Ada Admin"; git config --global user.email ada@example.com
git config --global init.defaultBranch main; git config --global advice.detachedHead false
git init -q hf && cd hf
echo 'ttl 3' > zone.conf && git add . && git commit -qm "feat: dns zone"   # ships the bug
git switch -qc release/2.1 && git tag -a v2.1.0 -m "2.1.0"
git switch -q main && echo 'ns2' > ns.conf && git add . && git commit -qm "feat: second name server"
git switch -q release/2.1
cmds=$(cat <<'EOF'
git switch -c hotfix/NET-207 release/2.1
sed -i 's/ttl 3$/ttl 300/' zone.conf
git commit -qam "fix(dns): restore TTL"
git switch -q release/2.1
git merge --no-ff --no-edit hotfix/NET-207
git tag -a v2.1.1 -m "Hotfix: zone TTL"
git switch -q main
git cherry-pick -x hotfix/NET-207
EOF
)
while IFS= read -r c; do echo "\$ $c"; eval "$c"; done <<<"$cmds"
git log --oneline -1 v2.1.1 | grep -q "Merge branch 'hotfix/NET-207' into release/2.1" || fail "tag not on merge"
grep -qx 'ttl 300' zone.conf || fail "fix not on main"
git log -1 --format=%b main | grep -q 'cherry picked from commit' || fail "no -x trailer"
echo '$ git log -1 --format=%B main'
git log -1 --format=%B main
echo '$ git describe --tags release/2.1'
git describe --tags release/2.1
[ "$(git describe --tags release/2.1)" = v2.1.1 ] || fail "describe"
cd "$WORK"

echo "ALL 4.1 TESTING-AND-VALIDATION CHECKS PASSED"
