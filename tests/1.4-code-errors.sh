#!/usr/bin/env bash
# Verifies every command and output shown in 1.4-syntax-and-runtime-errors.md
# Needs: python3 (3.13 for the exact traceback wording), terraform (1.9+;
#        downloads hashicorp/local), ansible-core, shellcheck
# Port 18159 on 127.0.0.1 must have nothing listening (the connection
# refused example relies on it).
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export CHECKPOINT_DISABLE=1 TF_IN_AUTOMATION=1 TF_CLI_ARGS="-no-color"
export TF_CLI_CONFIG_FILE="$WORK/terraformrc"
export ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False
export ANSIBLE_CONFIG="$WORK/none.cfg"
: > "$TF_CLI_CONFIG_FILE"

say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
# Run a command that is expected to fail; capture output and exit code.
expect_fail() { set +e; out=$("$@" 2>&1); rc=$?; set -e; echo "$out"; echo "(exit $rc)"; }

# ------------------------------------------------------------------
say "Python syntax error: nothing runs"
mkdir py && cd py
cat > vlans.py <<'EOF'
print("starting")

def render(vlan_ids):
    for vid in vlan_ids
        print(f"vlan {vid}")
EOF
expect_fail python3 vlans.py
[ "$rc" = "1" ] || fail "syntax rc"
grep -q 'File ".*vlans.py", line 4' <<<"$out" || fail "syntax line"
grep -q "^SyntaxError: expected ':'$" <<<"$out" || fail "syntax msg"
grep -q "starting" <<<"$out" && fail "a syntax error must stop the whole file"
expect_fail python3 -m py_compile vlans.py
grep -q "SyntaxError: expected ':'" <<<"$out" || fail "py_compile"

say "Python undefined variable: NameError at run time"
cat > render.py <<'EOF'
def render(vlans):
    lines = []
    for vlan_id, name in vlans.items():
        lines.append(f"vlan {vlanid}")
        lines.append(f" name {name}")
    return "\n".join(lines)

print("rendering")
print(render({10: "users"}))
EOF
python3 -m py_compile render.py            # compiles fine: no syntax error
expect_fail python3 render.py
[ "$rc" = "1" ] || fail "nameerror rc"
grep -q "^rendering$" <<<"$out" || fail "code before the error runs"
grep -q "^Traceback (most recent call last):$" <<<"$out" || fail "traceback header"
grep -q 'File ".*render.py", line 9, in <module>' <<<"$out" || fail "frame 1"
grep -q 'File ".*render.py", line 4, in render' <<<"$out" || fail "frame 2"
grep -q "^NameError: name 'vlanid' is not defined. Did you mean: 'vlan_id'?$" <<<"$out" || fail "nameerror msg"

say "Python runtime error: connection refused"
cat > push.py <<'EOF'
import socket

def push(host, port, text):
    with socket.create_connection(
            (host, port), timeout=3) as s:
        s.sendall(text.encode())

push("127.0.0.1", 18159, "vlan 10\n")
EOF
expect_fail python3 push.py
grep -q "^ConnectionRefusedError: \[Errno 111\] Connection refused$" <<<"$out" || fail "refused"
grep -q 'File ".*push.py", line 8, in <module>' <<<"$out" || fail "refused frame"

say "Python: handle the runtime error instead of crashing"
cat > push_safe.py <<'EOF'
import socket
import sys

def push(host, port, text):
    with socket.create_connection(
            (host, port), timeout=3) as s:
        s.sendall(text.encode())

try:
    push("127.0.0.1", 18159, "vlan 10\n")
except ConnectionRefusedError as err:
    print(f"push failed: {err}", file=sys.stderr)
    sys.exit(2)
EOF
expect_fail python3 push_safe.py
[ "$rc" = "2" ] || fail "handled rc"
[ "$out" = "push failed: [Errno 111] Connection refused" ] || fail "handled msg"
cd "$WORK"

# ------------------------------------------------------------------
say "Bash: syntax check with bash -n"
mkdir sh && cd sh
cat > backup.sh <<'EOF'
#!/usr/bin/env bash
if [ -d /backups ]; then
  echo "backing up"
EOF
expect_fail bash -n backup.sh
[ "$rc" = "2" ] || fail "bash -n rc"
grep -q "^backup.sh: line 4: syntax error: unexpected end of file" <<<"$out" || fail "bash -n msg"

say "Bash: undefined variable without and with set -u"
cat > banner.sh <<'EOF'
#!/usr/bin/env bash
set -eo pipefail
site="CLT-01"
echo "site: ${site}"
echo "contact: ${site_contact}"
echo "done"
EOF
expect_fail bash banner.sh
[ "$rc" = "0" ] || fail "without -u the script succeeds"
grep -q "^contact: $" <<<"$out" || fail "empty expansion"
sed -i 's/^set -eo pipefail$/set -euo pipefail/' banner.sh
expect_fail bash banner.sh
[ "$rc" = "1" ] || fail "set -u rc"
grep -q "^banner.sh: line 5: site_contact: unbound variable$" <<<"$out" || fail "set -u msg"
grep -q "^done$" <<<"$out" && fail "set -u must stop the script"
expect_fail shellcheck banner.sh
grep -q "site_contact is referenced but not assigned" <<<"$out" || fail "shellcheck SC2154"
cd "$WORK"

# ------------------------------------------------------------------
say "Terraform: undeclared variable caught by validate"
mkdir tf && cd tf
cat > versions.tf <<'EOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
EOF
cat > main.tf <<'EOF'
variable "hostname" {
  type = string
}

resource "local_file" "motd" {
  filename = "${path.module}/motd.txt"
  content  = "Welcome to ${var.host_name}\n"
}
EOF
terraform init -input=false >/dev/null
expect_fail terraform validate
[ "$rc" = "1" ] || fail "validate rc"
grep -q "Error: Reference to undeclared input variable" <<<"$out" || fail "tf undeclared"
grep -q 'An input variable with the name "host_name" has not been declared. Did you' <<<"$out" || fail "tf msg"
grep -q 'mean "hostname"?' <<<"$out" || fail "tf suggestion"

say "Terraform: missing value for a declared variable"
sed -i 's/var.host_name/var.hostname/' main.tf
terraform validate | grep -q "Success! The configuration is valid." || fail "validate ok"
expect_fail terraform plan -input=false
grep -q "Error: No value for required variable" <<<"$out" || fail "no value"

say "Terraform: unclosed block is a syntax error"
cp main.tf main.ok
head -n -1 main.tf > main.tmp && mv main.tmp main.tf
expect_fail terraform validate
grep -q "Error: Unclosed configuration block" <<<"$out" || fail "unclosed"
mv main.ok main.tf

say "Terraform: valid code, runtime failure at apply"
sed -i 's|"${path.module}/motd.txt"|"/proc/motd/${var.hostname}.txt"|' main.tf
grep -q '/proc/motd/' main.tf || fail "sed"
terraform validate | grep -qx "Success! The configuration is valid." || fail "still valid"
expect_fail terraform apply -auto-approve -input=false -var hostname=core-sw1
grep -q "^local_file.motd: Creating...$" <<<"$out" || fail "creating"
grep -q "^Error: Create local file error$" <<<"$out" || fail "create error"
grep -q "An unexpected error occurred while creating file directory" <<<"$out" || fail "apply error"
grep -q "Original Error: mkdir /proc/motd: no such file or directory" <<<"$out" || fail "apply cause"
cd "$WORK"

# ------------------------------------------------------------------
say "Ansible: syntax-check passes, the run fails on an undefined variable"
mkdir ans && cd ans
cat > motd.yml <<'EOF'
- name: Set the login banner
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    site: CLT-01
  tasks:
    - name: Write the banner
      ansible.builtin.copy:
        dest: "{{ playbook_dir }}/motd"
        content: "{{ site }} {{ site_contact }}\n"
        mode: "0644"
EOF
ansible-playbook motd.yml --syntax-check | grep -q "playbook: motd.yml" || fail "syntax-check"
expect_fail ansible-playbook motd.yml
[ "$rc" = "2" ] || fail "ansible rc"
grep -q "Error while resolving value for 'content': 'site_contact' is undefined" <<<"$out" || fail "undefined"
grep -q "^fatal: \[localhost\]: FAILED!" <<<"$out" || fail "fatal"
grep -Eq "^localhost +: ok=0 +changed=0 +unreachable=0 +failed=1" <<<"$out" || fail "recap"
grep -q "^<<< caused by >>>$" <<<"$out" || fail "caused by"
grep -q "^11         content: \"{{ site }} {{ site_contact }}\\\\n\"$" <<<"$out" || fail "origin excerpt"
grep -q "^                    \^ column 18$" <<<"$out" || fail "column marker"

say "Ansible: a default filter makes the variable optional"
sed -i "s/{{ site_contact }}/{{ site_contact | default('noc@example.com') }}/" motd.yml
ansible-playbook motd.yml >/dev/null
[ "$(cat motd)" = "CLT-01 noc@example.com" ] || fail "default filter"

say "Ansible: YAML indentation error caught by --syntax-check"
cat > vlans.yml <<'EOF'
- name: VLAN report
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Show VLAN 10
      ansible.builtin.debug:
        msg: users
     - name: Show VLAN 20
      ansible.builtin.debug:
        msg: voice
EOF
expect_fail ansible-playbook vlans.yml --syntax-check
[ "$rc" = "4" ] || fail "yaml rc"
grep -q "YAML parsing failed" <<<"$out" || fail "yaml parse"
grep -q "vlans.yml:8:6" <<<"$out" || fail "yaml position"

echo; echo "ALL 1.4 CODE ERRORS CHECKS PASSED"
