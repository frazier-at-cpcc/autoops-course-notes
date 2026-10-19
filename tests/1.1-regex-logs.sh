#!/usr/bin/env bash
# Verifies the code and output in 1.1-regex-and-logs.md.
# Writes the files shown in the notes (extracted by label), then replays
# every console block in the notes and compares the output line for line.
# Needs: GNU grep (for -P).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MD="$ROOT/content/domain-1/1.1-regex-and-logs.md"
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

block job.py > job.py
block "backup.log (unstructured)" > backup.log
block "backup.jsonl (structured)" > backup.jsonl
block parse_log.py > parse_log.py
jq -e . backup.jsonl >/dev/null

echo "== console blocks"
replay_consoles

echo "== parse_log.py"
out=$(python3 parse_log.py); echo "$out"
[ "$out" = "edge-rtr1  auth failed from 10.0.4.17
edge-rtr2  timeout after 30s
edge-rtr1  auth failed from 10.0.4.17
{'INFO': 2, 'WARNING': 1, 'ERROR': 3}" ] || fail "parse_log.py output"

echo "== claims in bullets"
# logging writes to stderr by default
[ -z "$(python3 job.py 2>/dev/null)" ] || fail "logging not on stderr"
# greedy vs lazy
python3 - <<'PY'
import re
s = 'name "core-sw1" site "CLT"'
assert re.findall(r'"(.*)"', s) == ['core-sw1" site "CLT']
assert re.findall(r'"(.*?)"', s) == ['core-sw1', 'CLT']
assert re.search(r"10.0.4.17", "10a0b4c17")            # unescaped dot
assert not re.search(r"10\.0\.4\.17", "10a0b4c17")
assert re.fullmatch(r"vlans?", "vlan") and re.fullmatch(r"vlans?", "vlans")
assert re.fullmatch(r"Gi0.1", "Gi0/1")
print("regex table claims ok")
PY
# \d in ERE matches a literal d
[ "$(printf 'd\n4\n' | grep -E '\d')" = "d" ] || fail "grep -E \\d"
# BRE needs \+ ; ERE does not
[ "$(echo 'vlan 10' | grep -o '[0-9]\+')" = "10" ] || fail "BRE \\+"
[ "$(echo 'vlan 10' | grep -oE '[0-9]+')" = "10" ] || fail "ERE +"
# try-it: a CRITICAL line is parsed and counted
echo '08:15:00 CRITICAL core-sw1 PSU 2 failed' >> backup.log
python3 parse_log.py | grep -q "'CRITICAL': 1" || fail "try-it"

echo "ALL 1.1 REGEX-LOGS CHECKS PASSED"
