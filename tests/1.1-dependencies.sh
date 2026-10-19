#!/usr/bin/env bash
# Verifies the code and output in 1.1-dependency-management.md:
# a venv install from the pinned requirements.txt, then a Docker build of
# the Dockerfile in the notes, a run, and a cached rebuild after a code edit.
# Needs: Docker (pulls python:3.13-slim), network access to PyPI.
# Image tag cfg-render:1.0 is removed on exit.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MD="$ROOT/content/domain-1/1.1-dependency-management.md"
WORK=$(mktemp -d)
IMG=cfg-render:1.0
cleanup() { docker rmi -f "$IMG" ao-a-pyca:3.13-slim >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
cd "$WORK"

block() {  # block LABEL [FILE]
  awk -v l="label=\"$1\"" '
    index($0, "```") == 1 && index($0, l) { f = 1; next }
    f && /^```/ { exit }
    f' "${2:-$MD}"
}
fail() { echo "FAIL: $*"; exit 1; }
expect() { [ "$1" = "$2" ] || { printf 'FAIL: got\n%s\nwant\n%s\n' "$1" "$2"; exit 1; }; }

block requirements.txt > requirements.txt
block render.py > render.py
block Dockerfile > Dockerfile
block switch.yaml "$ROOT/content/domain-1/1.1-data-types.md" > switch.yaml

RENDERED="hostname core-sw1
vlan 10
vlan 20
vlan 30"

echo "== venv"
python3 -m venv .venv
# shellcheck disable=SC1091
. .venv/bin/activate
pip install -q --disable-pip-version-check -r requirements.txt
out=$(pip freeze); echo "$out"
# MarkupSafe is the unpinned transitive dependency; the notes show 3.0.4
expect "$(sed 's/^MarkupSafe==3\.[0-9.]*$/MarkupSafe==X/' <<<"$out")" "Jinja2==3.1.6
MarkupSafe==X
PyYAML==6.0.3"
out=$(python render.py switch.yaml); echo "$out"
expect "$out" "$RENDERED"
deactivate

echo "== specifier table"
python3 - <<'PY'
from packaging.specifiers import SpecifierSet as S
assert "3.1.6" in S("==3.1.6") and "3.1.5" not in S("==3.1.6")
assert "3.9.0" in S(">=3.1,<4") and "4.0.0" not in S(">=3.1,<4")
assert "3.1.9" in S("~=3.1.2") and "3.2.0" not in S("~=3.1.2") and "3.1.1" not in S("~=3.1.2")
print("specifiers ok")
PY

echo "== docker build and run"
# base image: Docker Hub, or the Google mirror when Hub rate-limits us
docker image inspect python:3.13-slim >/dev/null 2>&1 ||
  docker pull -q python:3.13-slim ||
  { docker pull -q mirror.gcr.io/library/python:3.13-slim &&
    docker tag mirror.gcr.io/library/python:3.13-slim python:3.13-slim; }
# In a sandbox whose egress proxy re-signs TLS, pip inside the build needs the
# proxy CA. The Dockerfile from the notes stays untouched: BuildKit's
# --build-context swaps FROM python:3.13-slim for that same image plus the CA.
DBUILD=(docker build)
if [ -f "${CCR_CA:-/root/.ccr/ca-bundle.crt}" ]; then
  mkdir ca && cp "${CCR_CA:-/root/.ccr/ca-bundle.crt}" ca/ca.pem
  printf 'FROM python:3.13-slim\nCOPY ca.pem /etc/ssl/certs/proxy-ca.pem\nENV PIP_CERT=/etc/ssl/certs/proxy-ca.pem\n' > ca/Dockerfile
  docker build -q -t ao-a-pyca:3.13-slim ca >/dev/null
  DBUILD+=(--build-context python:3.13-slim=docker-image://ao-a-pyca:3.13-slim)
fi
"${DBUILD[@]}" -q -t "$IMG" . | grep -E '^sha256:[0-9a-f]{64}$'
out=$(docker run --rm --name ao-a-render "$IMG"); echo "$out"
expect "$out" "$RENDERED"

echo "== cached rebuild after editing render.py only"
echo '# edited' >> render.py
log=$("${DBUILD[@]}" --progress=plain -t "$IMG" . 2>&1)
# step numbers differ when the CA override is active, so match on the instruction
step() { grep -A1 -E "^#[0-9]+ \[[0-9]/5\] $1" <<<"$log" | sed -n 2p; }
for s in 'WORKDIR /app' 'COPY requirements.txt' 'RUN pip install' 'COPY render.py'; do
  printf '%-22s %s\n' "$s" "$(step "$s")"
done
step 'WORKDIR /app' | grep -q CACHED || fail "workdir layer not cached"
step 'COPY requirements.txt' | grep -q CACHED || fail "requirements layer not cached"
step 'RUN pip install' | grep -q CACHED || fail "pip layer not cached"
step 'COPY render.py' | grep -q CACHED && fail "code layer cached"

echo "== try-it: changing a pin rebuilds the install layer"
sed -i 's/Jinja2==3.1.6/Jinja2==3.1.5/' requirements.txt
log=$("${DBUILD[@]}" --progress=plain -t "$IMG" . 2>&1)
step 'RUN pip install' | grep -q CACHED && fail "pip layer should rebuild"
docker run --rm --entrypoint pip "$IMG" freeze | grep -qx 'Jinja2==3.1.5' || fail "pin 3.1.5"

echo "ALL 1.1 DEPENDENCIES CHECKS PASSED"
