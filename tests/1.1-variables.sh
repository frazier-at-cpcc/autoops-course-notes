#!/usr/bin/env bash
# Verifies the code and output in 1.1-variables-and-functions.md.
# Runs the exact code blocks from the notes (extracted by label).
# Needs: pwsh (PowerShell 7). Uses 127.0.0.1:18100 for a listener.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MD="$ROOT/content/domain-1/1.1-variables-and-functions.md"
WORK=$(mktemp -d)
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
cd "$WORK"

# block LABEL: print the fenced block whose fence line has label="LABEL"
block() {
  awk -v l="label=\"$1\"" '
    index($0, "```") == 1 && index($0, l) { f = 1; next }
    f && /^```/ { exit }
    f' "$MD"
}
fail() { echo "FAIL: $*"; exit 1; }
expect() { [ "$1" = "$2" ] || { printf 'FAIL: got\n%s\nwant\n%s\n' "$1" "$2"; exit 1; }; }

echo "== scope.py"
block scope.py > scope.py
out=$(python3 scope.py 2>&1 || true)
echo "$out"
expect "$(head -2 <<<"$out")" "core-sw1 retries=3 timeout=5
core-sw1 retries=4 timeout=5"
tail -1 <<<"$out" | grep -qx "NameError: name 'timeout' is not defined" || fail "NameError"
# the UnboundLocalError claim: same bump() without 'global'
sed 's/^    global retries.*$//' scope.py > noglobal.py
grep -q "UnboundLocalError" <<<"$(python3 noglobal.py 2>&1 || true)" || fail "UnboundLocalError"

echo "== Bash scope claim (global by default, local hides)"
out=$(bash -c 'site=CLT; set_site() { site=RDU; }; show() { local vlan=20; }; set_site; show; echo "$site ${vlan:-unset}"')
expect "$out" "RDU unset"

echo "== check_hosts.sh (listener on 127.0.0.1:18100)"
python3 -m http.server 18100 --bind 127.0.0.1 >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/18100) 2>/dev/null && break; sleep 0.1; done
block check_hosts.sh > check_hosts.sh && chmod +x check_hosts.sh
out=$(./check_hosts.sh 18100)
echo "$out"
expect "$out" "127.0.0.1:18100 up
127.0.0.2:18100 down
192.0.2.10:18100 down
1 of 3 hosts up"
# the try-it: without 'local', $host leaks out of probe()
sed 's/^  local host=/  host=/; $a echo "leak=$host"' check_hosts.sh > leak.sh
grep -qx "leak=192.0.2.10" <<<"$(bash leak.sh 18100)" || fail "leak demo"

echo "== wait_for.py"
block wait_for.py > wait_for.py
out=$(python3 wait_for.py)
echo "$out"
expect "$out" "1
None"

echo "== subnet.ps1"
block subnet.ps1 > subnet.ps1
out=$(pwsh -NoProfile -File subnet.ps1 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)
echo "$out"
expect "$(head -3 <<<"$out")" "CLT VLAN 10 -> 10.10.0.0/24
RDU VLAN 10 -> 10.10.0.0/24
CLT VLAN 20 -> 10.20.0.0/24"
grep -q "^Get-Subnet: .*subnet.ps1:10$" <<<"$out" || fail "error header"
grep -qF "     | Cannot validate argument on parameter 'Vlan'. The 5000 argument is greater than the maximum allowed range of 4094." <<<"$out" || fail "ValidateRange"

echo "== conditional table claims"
pwsh -NoProfile -c "if (('CORE' -eq 'core') -and -not ('CORE' -ceq 'core')) { 'ok' }" | grep -qx ok || fail "-eq / -ceq"
grep -q shutdown <<<"x shutdown" && echo "exit 0 = true"

shellcheck check_hosts.sh
echo "ALL 1.1 VARIABLES CHECKS PASSED"
