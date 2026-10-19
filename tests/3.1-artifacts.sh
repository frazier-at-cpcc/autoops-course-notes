#!/usr/bin/env bash
# Verifies every command and output shown in the 3.1 Artifact Management notes.
# Runs a private registry:2 with htpasswd authentication, pushes an image,
# moves a tag, pulls by digest, and generates SPDX and CycloneDX SBOMs.
# Needs: docker (images registry:2, alpine:3.20, ghcr.io/anchore/syft:v1.54.1),
#        python3 with bcrypt (pip install --break-system-packages bcrypt).
# Ports: 127.0.0.1:18352 (registry). Containers: ao-f-registry, ao-f-syftcp.
set -euo pipefail
WORK=$(mktemp -d)
rmc() {
  docker rm -f ao-f-registry ao-f-syftcp >/dev/null 2>&1 || true
  docker image ls --format '{{.Repository}}:{{.Tag}}' |
    grep '^localhost:18352/' | xargs -r docker rmi -f >/dev/null 2>&1 || true
  docker image ls --digests --format '{{.Repository}}@{{.Digest}}' |
    grep '^localhost:18352/' | xargs -r docker rmi -f >/dev/null 2>&1 || true
}
trap 'rmc; rm -rf "$WORK"' EXIT
rmc
cd "$WORK"
# Keep docker login credentials out of the real ~/.docker/config.json
export DOCKER_CONFIG="$WORK/docker"
mkdir -p "$DOCKER_CONFIG"
[ -d "$HOME/.docker/cli-plugins" ] && ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"

say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
# grep that reads all input, so the writer never dies of SIGPIPE under pipefail
q() { grep "$@" >/dev/null; }
img() {
  docker image inspect "$1" >/dev/null 2>&1 && return
  docker pull -q "$1" >/dev/null 2>&1 ||
    { docker pull -q "mirror.gcr.io/$2" >/dev/null && docker tag "mirror.gcr.io/$2" "$1"; }
}
img registry:2 library/registry:2
img alpine:3.20 library/alpine:3.20
img ghcr.io/anchore/syft:v1.54.1 anchore/syft:v1.54.1
mkdir -p bin
docker create --name ao-f-syftcp ghcr.io/anchore/syft:v1.54.1 >/dev/null
docker cp -q ao-f-syftcp:/syft bin/syft && docker rm ao-f-syftcp >/dev/null
export PATH="$WORK/bin:$PATH"
syft version | q -E '^Version: +1\.54\.1$'

say "private registry with htpasswd authentication"
mkdir -p auth
python3 - <<'PY' > auth/htpasswd
import bcrypt
for user, pw in (("ci-bot", b"Pipel1ne!"), ("auditor", b"ReadOnly?")):
    print(user + ":" + bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
PY
docker run -d --name ao-f-registry -p 127.0.0.1:18352:5000 \
  -v "$WORK/auth:/auth:ro" -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM=netops \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2 >/dev/null
for _ in $(seq 30); do curl -s -o /dev/null http://localhost:18352/v2/ && break; sleep 1; done

REG=localhost:18352/netops/cfg-backup
mkdir app && cd app
cat > Dockerfile <<'EOF'
FROM alpine:3.20
COPY backup.sh /usr/local/bin/backup.sh
CMD ["backup.sh"]
EOF
printf '#!/bin/sh\necho "backup v1"\n' > backup.sh && chmod +x backup.sh
docker build -q -t "$REG:1.4.0" . >/dev/null

say "authentication: anonymous requests are refused"
code=$(curl -s -o /dev/null -w '%{http_code}\n' \
    http://localhost:18352/v2/_catalog)
echo "$code"; [ "$code" = "401" ]
if docker push "$REG:1.4.0" >"$WORK/push.out" 2>&1; then fail "anonymous push succeeded"; fi
grep -o 'push access denied.*' "$WORK/push.out"
grep -q 'no basic auth credentials' "$WORK/push.out"

say "log in, push, record the digest"
out=$(echo 'Pipel1ne!' | docker login localhost:18352 \
    -u ci-bot --password-stdin 2>&1)
echo "$out"
grep -q 'Login Succeeded' <<<"$out"
grep -q 'credentials are stored unencrypted' <<<"$out"
V1=$(docker push "$REG:1.4.0" \
    | awk '/digest:/{print $3}')
echo "$V1"
[[ "$V1" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "no digest from push"
curl -s -u 'ci-bot:Pipel1ne!' http://localhost:18352/v2/netops/cfg-backup/tags/list
curl -s -u 'ci-bot:Pipel1ne!' http://localhost:18352/v2/netops/cfg-backup/tags/list |
  jq -e '.tags == ["1.4.0"]' >/dev/null

say "a mutable tag moves; a digest does not"
printf '#!/bin/sh\necho "backup v2"\n' > backup.sh
docker build -q -t "$REG:1.4.0" . >/dev/null
V2=$(docker push "$REG:1.4.0" | awk '/digest:/{print $3}')   # the notes print this value directly
echo "$V2"
[ "$V1" != "$V2" ] || fail "rebuilt image has the same digest"
# Drop local copies so both runs really pull from the registry
docker rmi -f "$REG:1.4.0" >/dev/null
[ "$(docker run --rm "$REG:1.4.0" 2>/dev/null)" = "backup v2" ]
[ "$(docker run --rm "$REG@$V1" 2>/dev/null)" = "backup v1" ]
docker run --rm "$REG:1.4.0" 2>/dev/null
docker run --rm "$REG@$V1" 2>/dev/null
# The old manifest is still stored, though no tag points at it any more
curl -s -o /dev/null -w '%{http_code}\n' -u 'ci-bot:Pipel1ne!' \
  -H 'Accept: application/vnd.oci.image.index.v1+json' \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  "http://localhost:18352/v2/netops/cfg-backup/manifests/$V1" | q -x 200
curl -s -u 'ci-bot:Pipel1ne!' http://localhost:18352/v2/netops/cfg-backup/tags/list |
  jq -e '.tags == ["1.4.0"]' >/dev/null

say "authenticated is not authorized: htpasswd has no per-repo permissions"
docker logout localhost:18352 >/dev/null
echo 'ReadOnly?' | docker login localhost:18352 -u auditor --password-stdin >/dev/null 2>&1
docker tag "$REG@$V1" "$REG:audit-test"
docker push -q "$REG:audit-test" >/dev/null || fail "auditor push should succeed on plain registry:2"
curl -s -u 'auditor:ReadOnly?' http://localhost:18352/v2/netops/cfg-backup/tags/list |
  jq -e '.tags | index("audit-test")' >/dev/null
docker logout localhost:18352 >/dev/null
echo 'Pipel1ne!' | docker login localhost:18352 -u ci-bot --password-stdin >/dev/null 2>&1

say "SBOM with syft, read straight from the registry"
cd "$WORK"
export SYFT_REGISTRY_INSECURE_USE_HTTP=true   # the lab registry has no TLS
syft scan -q "registry:$REG@$V1" -o table | tee table.txt
head -1 table.txt | q -E '^NAME +VERSION +TYPE'
for p in alpine-baselayout busybox ca-certificates-bundle libcrypto3 libssl3 musl zlib; do
  grep -Eq "^$p +[^ ]+ +apk" table.txt || fail "SBOM table missing $p"
done
# Our own backup.sh is a loose file, not a package, so it is not in the table
if grep -q backup table.txt; then fail "unexpected package for backup.sh"; fi
syft scan -q "registry:$REG@$V1" \
  -o spdx-json=sbom.spdx.json -o cyclonedx-json=sbom.cdx.json
jq -r .spdxVersion sbom.spdx.json
jq -r '.bomFormat + " " + .specVersion' sbom.cdx.json
[ "$(jq -r .spdxVersion sbom.spdx.json)" = "SPDX-2.3" ]
[ "$(jq -r .bomFormat sbom.cdx.json)" = "CycloneDX" ]
jq '.components[]
    | select(.name=="libssl3")
    | {name, version, type,
       license: .licenses[0].license.id}' \
    sbom.cdx.json | tee ssl.json
jq -e '.license == "Apache-2.0" and .type == "library" and (.version | startswith("3."))' ssl.json >/dev/null
jq -r '.components[] | select(.name=="libssl3") | .purl' sbom.cdx.json |
  grep -Eq '^pkg:apk/alpine/libssl3@3\.[^?]+\?arch='
jq -e '[.packages[].name] | index("musl")' sbom.spdx.json >/dev/null

echo; echo "ALL 3.1 ARTIFACT CHECKS PASSED"
