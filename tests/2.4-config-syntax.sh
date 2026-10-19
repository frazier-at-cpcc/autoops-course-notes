#!/usr/bin/env bash
# Verifies every file, command, and parser error shown in 2.4-config-file-syntax.md.
# Needs: python3 with PyYAML, yamllint, jq
# shellcheck disable=SC2016  # commands are single-quoted on purpose: t() prints, then evals them
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

t() {
  printf '$ %s\n' "$1"
  RC=0; OUT=$(eval "$1" 2>&1) || RC=$?
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  return 0
}
has() { grep -Eq -- "$1" <<<"$OUT" || { echo "FAIL: expected /$1/"; exit 1; }; }
say() { printf '\n== %s\n' "$*"; }

cat > check-config.py <<'PY'
#!/usr/bin/env python3
"""Parse INI, YAML, or JSON files; report the error."""
import configparser, json, sys
import yaml  # PyYAML

status = 0
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            if path.endswith(".ini"):
                cp = configparser.ConfigParser()
                cp.read_file(f)
                # reading each value expands %(name)s references
                [dict(cp[s]) for s in cp.sections()]
            elif path.endswith((".yml", ".yaml")):
                yaml.safe_load(f)
            else:
                json.load(f)
        print(f"{path}: OK")
    except Exception as e:
        print(f"{path}: {type(e).__name__}: {e}")
        status = 1
sys.exit(status)
PY
chmod +x check-config.py

say "INI"
cat > agent.ini <<'INI'
; inventory sync agent
[api]
url = https://inv.lab.test:8443
token = s3cr3t
timeout = 10

[logging]
level = info
file = /var/log/invsync/%(level)s.log
INI
t './check-config.py agent.ini'
has '^agent.ini: OK$'
t "python3 -c \"import configparser as c; p=c.ConfigParser(); p.read('agent.ini'); print(p['logging']['file'], p.getint('api','timeout') + 5)\""
has '^/var/log/invsync/info.log 15$'
printf 'url = https://inv.lab.test:8443\n[api]\ntoken = s3cr3t\n' > nohdr.ini
printf '[api]\nurl = https://inv.lab.test:8443\ntimeout = 10\nretries 3\n' > noeq.ini
printf '[api]\nurl = https://inv.lab.test:8443\ntimeout = 10\ntimeout = 30\n' > dup.ini
printf '[db]\nuser = svc_inv\npassword = P@ss%%word\n' > pct.ini
t 'cat noeq.ini'
t './check-config.py nohdr.ini noeq.ini dup.ini pct.ini'
[ "$RC" = 1 ]
has "^nohdr.ini: MissingSectionHeaderError: File contains no section headers.$"
has "^file: 'nohdr.ini', line: 1$"
has "^noeq.ini: ParsingError: Source contains parsing errors: 'noeq.ini'$"
has "\[line  4\]: 'retries 3\\\\n'"
has "^dup.ini: DuplicateOptionError: While reading from 'dup.ini' \[line  4\]: option 'timeout' in section 'api' already exists$"
has "^pct.ini: InterpolationSyntaxError: '%' must be followed by '%' or '\(', found: '%word'$"

# Inline comments are part of the value unless inline_comment_prefixes is set
printf '[api]\ntimeout = 10 ; seconds\n' > inline.ini
OUT=$(python3 -c "import configparser as c; p=c.ConfigParser(); p.read('inline.ini'); print(repr(p['api']['timeout'])); p.getint('api','timeout')" 2>&1 || true)
has "^'10 ; seconds'$"; has "ValueError: invalid literal for int\(\) with base 10: '10 ; seconds'"

say "YAML"
cat > vlans.yml <<'YAML'
---
site: charlotte-dc1
vlans:
  - id: 10
    name: users
  - id: 20
    name: servers
    description: "Rack 4: east wing"
YAML
t './check-config.py vlans.yml'
has '^vlans.yml: OK$'
t 'yamllint vlans.yml && echo clean'
has '^clean$'
printf -- '---\nvlans:\n  - id: 10\n\tname: users\n' > tab.yml
printf -- '---\nvlans:\n  - id: 20\n    description: Rack 4: east wing\n' > colon.yml
printf -- '---\nvlans:\n  - id: 10\n    name: users\n  - id: 20\n   name: servers\n' > indent.yml
printf -- '---\nswitch:\n  hostname:core-sw1\n  mgmt_vlan: 99\n' > nospace.yml
t 'cat -A tab.yml | sed -n 4p'
has '^\^Iname: users\$$'
t './check-config.py tab.yml colon.yml indent.yml nospace.yml'
[ "$RC" = 1 ]
has "^tab.yml: ScannerError: while scanning for the next token$"
has "^found character '\\\\t' that cannot start any token$"
has '^  in "tab.yml", line 4, column 1$'
has '^colon.yml: ScannerError: mapping values are not allowed here$'
has '^  in "colon.yml", line 4, column 24$'
has '^indent.yml: ParserError: while parsing a block collection$'
has "^expected <block end>, but found '<block mapping start>'$"
has '^  in "indent.yml", line 6, column 4$'
has '^nospace.yml: ScannerError: mapping values are not allowed here$'
has '^  in "nospace.yml", line 4, column 12$'
t 'yamllint indent.yml'
has "6:4 +error +syntax error: expected <block end>, but found '<block mapping start>' \(syntax\)"
# Parses fine, but not to what the author meant (YAML 1.1 rules in PyYAML)
cat > site.yml <<'YAML'
---
site:
  country: NO
  file_mode: 0644
  os_version: 7.10
  lldp: on
  vlan:
    name: users
    name: staff
YAML
t "python3 -c \"import yaml; print(yaml.safe_load(open('site.yml')))\""
has "^\{'site': \{'country': False, 'file_mode': 420, 'os_version': 7.1, 'lldp': True, 'vlan': \{'name': 'staff'\}\}\}$"
t 'yamllint site.yml'
has '3:12 +warning +truthy value should be one of \[false, true\] +\(truthy\)'
has '6:9 +warning +truthy value should be one of \[false, true\] +\(truthy\)'
has '9:5 +error +duplication of key "name" in mapping +\(key-duplicates\)'
[ "$RC" = 1 ]

say "JSON"
cat > vlans.json <<'JSON'
{
  "site": "charlotte-dc1",
  "vlans": [
    {"id": 10, "name": "users", "voice": false},
    {"id": 20, "name": "servers", "notes": null}
  ]
}
JSON
t 'jq empty vlans.json && echo valid'
has '^valid$'
t 'jq -r ".vlans[] | .name" vlans.json'
has '^users$'
printf '{\n  "vlans": [\n    {"id": 10, "name": "users"},\n  ]\n}\n' > trailing.json
printf "{\n  'id': 10,\n  \"name\": \"users\"\n}\n" > single.json
printf '{\n  // core VLAN\n  "id": 10\n}\n' > comment.json
printf '{\n  "id": 10\n  "name": "users"\n}\n' > comma.json
printf '{\n  "id": 10,\n  "voice": False\n}\n' > bool.json
t 'for f in trailing single comment comma bool; do jq empty $f.json; done'
has '^jq: parse error: Expected another array element at line 4, column 3$'
has '^jq: parse error: Invalid numeric literal at line 2, column 7$'
has '^jq: parse error: Invalid numeric literal at line 2, column 5$'
has '^jq: parse error: Expected separator between values at line 3, column 8$'
has '^jq: parse error: Invalid numeric literal at line 4, column 0$'
t 'for f in trailing single comment comma bool; do python3 -m json.tool $f.json >/dev/null; done'
has '^Illegal trailing comma before end of array: line 3 column 32 \(char 46\)$'
has '^Expecting property name enclosed in double quotes: line 2 column 3 \(char 4\)$'
has "^Expecting ',' delimiter: line 3 column 3 \(char 15\)$"
has '^Expecting value: line 3 column 12 \(char 25\)$'
t './check-config.py vlans.json trailing.json'
has '^vlans.json: OK$'
has '^trailing.json: JSONDecodeError: Illegal trailing comma before end of array: line 3 column 32 \(char 46\)$'
# JSON is valid YAML: a YAML parser reads it, the reverse is not true
t "python3 -c \"import yaml; print(yaml.safe_load(open('vlans.json'))['vlans'][0])\""
has "^\{'id': 10, 'name': 'users', 'voice': False\}$"

echo; echo "ALL 2.4 CONFIG SYNTAX CHECKS PASSED"
