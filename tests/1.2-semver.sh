#!/usr/bin/env bash
# Verifies the semantic-versioning range examples in the 1.2 notes (needs: npm install).
set -euo pipefail
cd "$(dirname "$0")/.."
sv() { npx --no-install semver "$@"; }
check() { local want="$1"; shift; local got; got=$(sv "$@" | tr '\n' ' ' | sed 's/ $//'); [ "$got" = "$want" ] || { echo "FAIL: semver $* -> '$got' (want '$want')"; exit 1; }; }
check "1.2.3 1.2.9 1.9.0"     -r '^1.2.3' 1.2.3 1.2.9 1.9.0 2.0.0 1.3.0-beta.1
check "1.2.3 1.2.9"           -r '~1.2.3' 1.2.3 1.2.9 1.3.0
check "1.4.0 1.99.0"          -r '>=1.4.0 <2.0.0' 1.3.9 1.4.0 1.99.0 2.0.0
check "0.2.9"                 -r '^0.2.3' 0.2.9 0.3.0
check "1.0.0 1.5.2"           -r '1.x' 1.0.0 1.5.2 2.0.0
check "1.9.0 2.0.0-alpha 2.0.0-beta.2 2.0.0-rc.1 2.0.0" 2.0.0-rc.1 2.0.0-beta.2 2.0.0 2.0.0-alpha 1.9.0
check "2.0.0-rc.0"            -i premajor --preid rc 1.4.2
check "1.5.0"                 -i minor 1.4.2
check "1.4.2"                 -i patch 1.4.2-rc.1
echo "ALL 1.2 SEMVER CHECKS PASSED"
