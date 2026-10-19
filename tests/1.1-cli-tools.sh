#!/usr/bin/env bash
# Verifies the code and output in 1.1-command-line-tools.md.
# Writes the files shown in the notes (extracted by label), then replays
# every console block in the notes and compares the output line for line.
# Needs: pwsh (PowerShell 7), GNU sed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MD="$ROOT/content/domain-1/1.1-command-line-tools.md"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

block() {
  awk -v l="label=\"$1\"" '
    index($0, "```") == 1 && index($0, l) { f = 1; next }
    f && /^```/ { exit }
    f' "$MD"
}
fail() { echo "FAIL: $*"; exit 1; }
# replay_consoles: run every "$ cmd" in every console block of $MD in the
# current directory and require the output to equal the lines that follow.
replay_consoles() {
  python3 - "$MD" <<'PY'
import re, subprocess, sys
md = open(sys.argv[1]).read()
blocks = re.findall(r"^```console[^\n]*\n(.*?)^```", md, re.S | re.M)
bad = 0
for b in blocks:
    steps = []
    for line in b.rstrip("\n").split("\n"):
        if line.startswith("$ "):
            steps.append((line[2:], []))
        else:
            steps[-1][1].append(line)
    for cmd, want in steps:
        r = subprocess.run(["bash", "-c", cmd], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        got = r.stdout.rstrip("\n").split("\n") if r.stdout else []
        print("$", cmd); print(r.stdout, end="")
        if got != want:
            print("MISMATCH, notes show:", want); bad += 1
sys.exit(1 if bad else 0)
PY
}

block sw1.cfg > sw1.cfg
block inv.json > inv.json
block inv.csv > inv.csv
block report.ps1 > report.ps1
block top_ips.sh > top_ips.sh && chmod +x top_ips.sh
jq -e . inv.json >/dev/null
shellcheck top_ips.sh
cat > auth.log <<'LOG'
Oct 19 08:01:12 bastion sshd[811]: Failed password for admin from 203.0.113.9 port 50122 ssh2
Oct 19 08:01:15 bastion sshd[811]: Failed password for admin from 203.0.113.9 port 50122 ssh2
Oct 19 08:02:40 bastion sshd[820]: Accepted publickey for ops from 10.0.4.20 port 41022 ssh2
Oct 19 08:03:02 bastion sshd[833]: Failed password for invalid user bob from 198.51.100.23 port 60311 ssh2
Oct 19 08:03:05 bastion sshd[833]: Failed password for root from 198.51.100.23 port 60311 ssh2
Oct 19 08:04:10 bastion sshd[840]: Failed password for admin from 203.0.113.9 port 50190 ssh2
Oct 19 08:04:13 bastion sshd[840]: Failed password for admin from 203.0.113.9 port 50190 ssh2
Oct 19 08:05:30 bastion sshd[852]: Accepted password for ops from 10.0.4.21 port 41100 ssh2
Oct 19 08:06:01 bastion sshd[860]: Failed password for netops from 10.0.4.17 port 39001 ssh2
Oct 19 08:06:45 bastion sshd[861]: Connection closed by 10.0.4.20 port 41022 [preauth]
LOG

echo "== console blocks"
replay_consoles

echo "== claims in bullets"
[ "$(grep -c 'Failed password' auth.log)" = 7 ] || fail "7 failures"
# without the first sort, uniq -c gives wrong (split) counts
grep 'Failed password' auth.log | awk '{print $(NF-3)}' | uniq -c | grep -q '^ *2 203.0.113.9' || fail "uniq without sort"
# pipefail exposes a missing file
if bash -c 'set -o pipefail; grep x missing.log 2>/dev/null | sort' ; then fail "pipefail"; fi
bash -c 'grep x missing.log 2>/dev/null | sort' || fail "no pipefail should succeed"
# sed without -i leaves the file alone; unescaped dot over-matches
cp sw1.cfg.bak orig.cfg
sed 's/ntp/NTP/' orig.cfg >/dev/null && grep -q '^ntp server 10.0.0.5$' orig.cfg || fail "sed no -i"
[ "$(echo 10a0b0c5 | sed 's/10.0.0.5/X/')" = X ] || fail "unescaped dot"
[ "$(echo 10a0b0c5 | sed 's/10\.0\.0\.5/X/')" = 10a0b0c5 ] || fail "escaped dot"
# grep -q exit codes
grep -q shutdown sw1.cfg && ! grep -q 'no-such' sw1.cfg || fail "grep exit status"
# PowerShell -replace and Measure-Object from the table
[ "$(pwsh -NoProfile -c "'ntp 10.0.0.5' -replace '10\.0\.0\.5', '10.0.0.6'")" = "ntp 10.0.0.6" ] || fail "-replace"
[ "$(pwsh -NoProfile -c "(Get-Content ./auth.log | Measure-Object).Count")" = 10 ] || fail "Measure-Object"

echo "== try-it"
jq '. + [{"name": "fw1", "site": "RDU", "status": "planned", "vlans": [99]}]' inv.json > d2.json
[ "$(jq -r '.[] | select(.status != "active") | .name' d2.json | tr '\n' ' ')" = "dist-sw2 fw1 " ] || fail "jq try-it"
[ "$(pwsh -NoProfile -c "Get-Content ./d2.json -Raw | ConvertFrom-Json | Where-Object status -ne 'active' | ForEach-Object name" | tr '\n' ' ')" = "dist-sw2 fw1 " ] || fail "pwsh try-it"

echo "ALL 1.1 CLI-TOOLS CHECKS PASSED"
