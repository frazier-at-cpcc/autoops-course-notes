#!/usr/bin/env bash
# Verifies the code and output in 1.1-data-types.md.
# Runs the exact code blocks from the notes (extracted by label).
# Needs: PyYAML 6.0.3 and ruamel.yaml (pip install PyYAML ruamel.yaml),
#        yamllint, and Docker (mikefarah/yq image for the yq -o json claim).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MD="$ROOT/content/domain-1/1.1-data-types.md"
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
expect() { [ "$1" = "$2" ] || { printf 'FAIL: got\n%s\nwant\n%s\n' "$1" "$2"; exit 1; }; }

python3 -c 'import yaml; assert yaml.__version__ == "6.0.3", yaml.__version__'

echo "== primitive conversion"
out=$(python3 -c 'print("10" + 1)' 2>&1 || true)
tail -1 <<<"$out" | grep -qx 'TypeError: can only concatenate str (not "int") to str' || fail "TypeError"
expect "$(python3 -c 'print(int("10") + 1)')" "11"

echo "== JSON strictness"
out=$(echo '{"vlan": 10,}' | jq . 2>&1 || true); echo "$out"
expect "$out" "jq: parse error: Expected another key-value pair at line 1, column 13"
out=$(echo "{'vlan': 10}" | jq . 2>&1 || true); echo "$out"
expect "$out" "jq: parse error: Invalid numeric literal at line 1, column 8"
python3 -c 'import json; json.loads("{\"a\": True}")' 2>/dev/null && fail "True accepted"
python3 -c 'import json; json.loads("{\"a\": 1 /* c */}")' 2>/dev/null && fail "comment accepted"

echo "== same data in both formats"
block switch.json > switch.json
block switch.yaml > switch.yaml
block load.py > load.py
jq -e . switch.json >/dev/null
yamllint -d relaxed switch.yaml
out=$(python3 load.py); echo "$out"
expect "$out" "same data: True
hostname     str
mgmt_ip      str
vlans        list
stp_enabled  bool
uplink       NoneType
mtu          int"
# yq -o json (Go yq) produces the same object as the JSON file
docker run --rm -i mikefarah/yq -o json < switch.yaml > from_yq.json
jq -e --slurpfile a switch.json --slurpfile b from_yq.json -n '$a == $b' >/dev/null || fail "yq -o json"

echo "== try-it: Norway breaks equality, quoting fixes it"
jq '. + {country: "NO"}' switch.json > switch.json.new && mv switch.json.new switch.json
cp switch.yaml orig.yaml
echo 'country: NO' >> switch.yaml
grep -qx "same data: False" <<<"$(python3 load.py)" || fail "Norway try-it"
cp orig.yaml switch.yaml && echo 'country: "NO"' >> switch.yaml
grep -qx "same data: True" <<<"$(python3 load.py)" || fail "quoted try-it"

echo "== gotchas"
block show.py > show.py
block vlans.yaml > vlans.yaml
block site.yaml > site.yaml
out=$(python3 show.py vlans.yaml); echo "$out"
expect "$out" "vlans      ['10 - 20'] (list)"
printf 'vlans:\n\t- 10\n' > tab.yaml
grep -qF "found character '\\t' that cannot start any token" <<<"$(python3 show.py tab.yaml 2>&1 || true)" || fail "tab error"
out=$(python3 show.py site.yaml); echo "$out"
expect "$out" "country    False (bool)
vlan_name  False (bool)
version    1.1 (float)
ssh_map    1342 (int)
quoted     'NO' (str)"
# YAML 1.2 (ruamel.yaml): strings stay strings, 1.10 still a float
python3 - <<'PY'
from ruamel.yaml import YAML
d = YAML(typ="safe").load(open("site.yaml"))
assert d["country"] == "NO" and d["vlan_name"] == "off", d
assert d["ssh_map"] == "22:22" and d["version"] == 1.1, d
print("ruamel.yaml (YAML 1.2):", dict(d))
PY
# yamllint truthy rule
grep -q "truthy value should be one of" <<<"$(yamllint -d default site.yaml 2>&1 || true)" || fail "yamllint truthy"

echo "ALL 1.1 DATA-TYPES CHECKS PASSED"
