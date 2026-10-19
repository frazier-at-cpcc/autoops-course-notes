#!/usr/bin/env bash
# Verifies the scanner runs shown in the 3.2 Pipeline Enhancements notes:
# SAST (Bandit), dependency scanning and container image scanning (Trivy),
# secret scanning (gitleaks), and the containerized scan job definition.
# Needs: docker, bandit (pip install bandit), gitlab-ci-local, rsync, curl.
#   Trivy 0.57.1 runs from public.ecr.aws/aquasecurity/trivy (vulnerability DB
#   is downloaded on first use and cached in the ao-g-trivy-cache volume).
#   gitleaks 8.30.1 is downloaded from its GitHub release if not on PATH.
#   The old alpine:3.14.0 image is pulled from mirror.gcr.io.
set -euo pipefail
trap 'echo "FAILED at ${BASH_SOURCE[0]}:$LINENO: $BASH_COMMAND" >&2' ERR
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; docker rm -f ao-g-trivy >/dev/null 2>&1 || true' EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name ci && git config --global user.email ci@example.com
say() { printf '\n== %s\n' "$*"; }
absent() { if grep -q "$@"; then echo "FAIL: did not expect '$1' in $2"; exit 1; fi; }

TRIVY_IMAGE=public.ecr.aws/aquasecurity/trivy:0.57.1
docker image inspect "$TRIVY_IMAGE" >/dev/null 2>&1 || docker pull -q "$TRIVY_IMAGE" >/dev/null
docker image inspect alpine:3.14.0 >/dev/null 2>&1 || {
  docker pull -q mirror.gcr.io/library/alpine:3.14.0 >/dev/null
  docker tag mirror.gcr.io/library/alpine:3.14.0 alpine:3.14.0
}
# The notes show `trivy ...`; here the real Trivy binary runs in its container.
CA_ARGS=()
[ -f /root/.ccr/ca-bundle.crt ] && CA_ARGS=(-v /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro)
trivy() {
  docker run --rm --name ao-g-trivy --network host -e HTTPS_PROXY "${CA_ARGS[@]}" \
    -v /var/run/docker.sock:/var/run/docker.sock -v ao-g-trivy-cache:/root/.cache \
    -v "$PWD":/src:ro -w /src "$TRIVY_IMAGE" "$@"
}
if command -v gitleaks >/dev/null; then GITLEAKS=gitleaks; else
  curl -sSL -o gl.tgz https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
  tar -xzf gl.tgz gitleaks && GITLEAKS="$WORK/gitleaks"
fi
gitleaks() { "$GITLEAKS" "$@"; }

mkdir netops && cd netops
say "SAST with Bandit"
cat > backup.py <<'PY'
import subprocess

PASSWORD = "Sw1tch!Adm1n"


def backup(host):
    cmd = f"scp admin@{host}:running-config ."
    subprocess.run(cmd, shell=True)
PY
rc=0
bandit -q -f custom \
    --msg-template '{line}:{test_id}:{severity}' \
    backup.py > ../bandit.txt || rc=$?
cat ../bandit.txt; echo "exit $rc"
[ "$rc" = 1 ]
grep -qx '8:B602:HIGH' ../bandit.txt
grep -qx '3:B105:LOW' ../bandit.txt
grep -qx '1:B404:LOW' ../bandit.txt
# The :::try exercise: an argument list instead of a shell string
sed 's/subprocess.run(cmd, shell=True)/subprocess.run(["scp", f"admin@{host}:running-config", "."])/' \
  backup.py > ../backup-fixed.py
bandit -q -f custom --msg-template '{test_id}' ../backup-fixed.py > ../bandit-fixed.txt || true
absent B602 ../bandit-fixed.txt
grep -q B603 ../bandit-fixed.txt

say "Dependency (SCA) scanning with Trivy"
printf 'requests==2.19.1\nPyYAML==5.3\n' > requirements.txt
cat requirements.txt
trivy fs -q --scanners vuln \
    --severity HIGH,CRITICAL --format json . \
  | jq -r '.Results[].Vulnerabilities[] |
    [.PkgName, .InstalledVersion, .VulnerabilityID,
     .Severity, .FixedVersion] | join(" ")' > ../sca.txt
cat ../sca.txt
grep -q '^requests 2.19.1 CVE-2018-18074' ../sca.txt
grep -q '^PyYAML 5.3 CVE-2020-14343' ../sca.txt
grep -qx 'PyYAML 5.3 CVE-2020-14343 CRITICAL 5.4' ../sca.txt

say "Container image scanning with Trivy"
cd ..   # the image scan reads no files; write scan.json next to netops/
rc=0
trivy image -q --severity CRITICAL --exit-code 1 \
    --format json alpine:3.14.0 > scan.json || rc=$?
echo "$rc"
[ "$rc" = 1 ]
jq -r '.Results[].Vulnerabilities[] |
    [.PkgName, .VulnerabilityID, .FixedVersion]
    | join(" ")' scan.json | tee image.txt
grep -q '^apk-tools CVE-2021-36159 2.12.6-r0$' image.txt
grep -q '^zlib CVE-2022-37434 1.2.12-r2$' image.txt
cd netops

say "Secret scanning with gitleaks"
printf 'AWS_ACCESS_KEY_ID=AKIAQX4ZL2RBWN3T6YUM\n' > deploy.env
rc=0
gitleaks dir --no-banner --no-color -v . > ../leaks.txt 2>&1 || rc=$?
cat ../leaks.txt; echo "exit $rc"
[ "$rc" = 1 ]
grep -q '^RuleID: *aws-access-token' ../leaks.txt
grep -q '^File: *deploy.env' ../leaks.txt
grep -q 'leaks found: 1' ../leaks.txt

say "Containerized scan job (static validation with gitlab-ci-local)"
cd .. && git init -q -b main gl && cd gl
git remote add origin https://gitlab.example.com/netops/app.git
cat > .gitlab-ci.yml <<'YAML'
stages: [build, scan]

container-scan:
  stage: scan
  image:
    name: aquasec/trivy:0.57.1
    entrypoint: [""]
  variables:
    IMAGE: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  script:
    - trivy image --exit-code 1
      --severity CRITICAL "$IMAGE"
YAML
git add . && git commit -qm ci
gitlab-ci-local --no-color --list 2>/dev/null | tee ../scanjob.txt
grep -q '^container-scan' ../scanjob.txt
gitlab-ci-local --no-color --preview 2>/dev/null \
  | grep -q 'trivy image --exit-code 1 --severity CRITICAL "\$IMAGE"'

echo
echo "ALL 3.2 ENHANCEMENTS CHECKS PASSED"
