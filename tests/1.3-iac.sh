#!/usr/bin/env bash
# Verifies every command and output shown in the 1.3 IaC notes:
#   1.3-iac-principles.md and 1.3-declarative-and-idempotent.md
# Needs: terraform (1.9+; downloads hashicorp/local from the registry),
#        ansible-core (ansible-playbook, ansible-galaxy)
# Everything runs against local files in a throwaway directory; no cloud
# account, container, or network port is used.
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export CHECKPOINT_DISABLE=1 TF_IN_AUTOMATION=1 TF_CLI_ARGS="-no-color"
export TF_CLI_CONFIG_FILE="$WORK/terraformrc"   # never read the real ~/.terraformrc
export ANSIBLE_NOCOLOR=1 ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False
export ANSIBLE_CONFIG="$WORK/none.cfg"          # never read a real ansible.cfg
: > "$TF_CLI_CONFIG_FILE"

say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

# ------------------------------------------------------------------
say "Reusability: one Terraform module, called twice"
mkdir -p tf/modules/switch_config && cd tf
cat > modules/switch_config/variables.tf <<'EOF'
variable "hostname" {
  type = string
}

variable "vlans" {
  type = map(string)
}
EOF
cat > modules/switch_config/main.tf <<'EOF'
resource "local_file" "config" {
  filename = "out/${var.hostname}.cfg"
  content = templatefile(
    "${path.module}/switch.tftpl",
    { hostname = var.hostname, vlans = var.vlans }
  )
}
EOF
cat > modules/switch_config/switch.tftpl <<'EOF'
hostname ${hostname}
%{ for id, name in vlans ~}
vlan ${id}
 name ${name}
%{ endfor ~}
EOF
cat > main.tf <<'EOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

module "sw1" {
  source   = "./modules/switch_config"
  hostname = "access-sw1"
  vlans    = { "10" = "users", "20" = "voice" }
}

module "sw2" {
  source   = "./modules/switch_config"
  hostname = "access-sw2"
  vlans    = { "10" = "users", "30" = "printers" }
}
EOF
terraform fmt -check -recursive
terraform init -input=false >/dev/null
terraform validate
out=$(terraform apply -auto-approve -input=false)
echo "$out" | grep -E "Creation complete|Apply complete"
grep -q "Apply complete! Resources: 2 added, 0 changed, 0 destroyed." <<<"$out" || fail "first apply"
ls out
[ "$(ls out | tr '\n' ' ')" = "access-sw1.cfg access-sw2.cfg " ] || fail "ls out"
cat out/access-sw1.cfg
[ "$(cat out/access-sw1.cfg)" = "$(printf 'hostname access-sw1\nvlan 10\n name users\nvlan 20\n name voice')" ] \
  || fail "rendered config"

say "Idempotency: the same apply a second time changes nothing"
out=$(terraform apply -auto-approve -input=false)
echo "$out" | grep -E "No changes|Apply complete"
grep -q "No changes. Your infrastructure matches the configuration." <<<"$out" || fail "second apply"
grep -q "Apply complete! Resources: 0 added, 0 changed, 0 destroyed." <<<"$out" || fail "second apply count"

say "Try it: a third module call plans exactly one addition"
cp main.tf main.tf.bak
cat >> main.tf <<'EOF'

module "sw3" {
  source   = "./modules/switch_config"
  hostname = "access-sw3"
  vlans    = { "10" = "users" }
}
EOF
terraform init -input=false >/dev/null
terraform plan -input=false | grep -q "Plan: 1 to add, 0 to change, 0 to destroy." || fail "sw3 plan"
mv main.tf.bak main.tf

say "Immutability: changing content forces replacement"
sed -i 's/"30" = "printers" }/"30" = "printers", "40" = "cameras" }/' main.tf
grep -q '"40" = "cameras"' main.tf
out=$(terraform plan -input=false)
echo "$out" | grep -E "must be replaced|-/\+ resource|forces replacement|^Plan:"
grep -q "# module.sw2.local_file.config must be replaced" <<<"$out" || fail "replace"
grep -q -- '-/+ resource "local_file" "config" {' <<<"$out" || fail "replace symbol"
grep -q "content              = <<-EOT # forces replacement" <<<"$out" || fail "forces"
grep -q "Plan: 1 to add, 0 to change, 1 to destroy." <<<"$out" || fail "plan count"
cd "$WORK"

# ------------------------------------------------------------------
say "Reusability: an Ansible role skeleton"
mkdir ans && cd ans
ansible-galaxy role init roles/resolver
[ "$(ls roles/resolver | tr '\n' ' ')" = "README.md defaults files handlers meta tasks templates tests vars " ] \
  || fail "role layout: $(ls roles/resolver)"
ls roles/resolver
cat > roles/resolver/defaults/main.yml <<'EOF'
resolver_servers:
  - 10.0.0.53
resolver_root: /etc
EOF
cat > roles/resolver/tasks/main.yml <<'EOF'
- name: Resolver uses the site DNS servers
  ansible.builtin.lineinfile:
    path: "{{ resolver_root }}/resolv.conf"
    line: "nameserver {{ item }}"
    create: true
    mode: "0644"
  loop: "{{ resolver_servers }}"
EOF
mkdir -p clt dfw
cat > sites.yml <<'EOF'
- name: Charlotte site
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - role: resolver
      resolver_root: "{{ playbook_dir }}/clt"

- name: Dallas site
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - role: resolver
      resolver_root: "{{ playbook_dir }}/dfw"
      resolver_servers: [10.20.0.53, 10.20.0.54]
EOF
ansible-playbook sites.yml --syntax-check
ansible-playbook sites.yml >/dev/null
[ "$(cat clt/resolv.conf)" = "nameserver 10.0.0.53" ] || fail "clt role defaults"
[ "$(cat dfw/resolv.conf)" = "$(printf 'nameserver 10.20.0.53\nnameserver 10.20.0.54')" ] || fail "dfw role vars"
cd "$WORK"

# ------------------------------------------------------------------
say "Imperative Bash: running twice duplicates the line"
mkdir bash && cd bash
cat > add-dns.sh <<'EOF'
#!/usr/bin/env bash
# Imperative: steps, run in order, every time
set -euo pipefail
mkdir -p etc
echo "nameserver 10.0.0.53" >> etc/resolv.conf
EOF
chmod +x add-dns.sh
shellcheck add-dns.sh
./add-dns.sh; ./add-dns.sh
cat etc/resolv.conf
[ "$(grep -c nameserver etc/resolv.conf)" = "2" ] || fail "bash should duplicate"

say "Imperative Bash with a guard: now idempotent"
cat > add-dns-safe.sh <<'EOF'
#!/usr/bin/env bash
# Check the current state before acting
set -euo pipefail
mkdir -p etc
line="nameserver 10.0.0.53"
grep -qxF "$line" etc/resolv.conf 2>/dev/null ||
  echo "$line" >> etc/resolv.conf
EOF
chmod +x add-dns-safe.sh
shellcheck add-dns-safe.sh
rm -rf etc
./add-dns-safe.sh; ./add-dns-safe.sh
[ "$(grep -c nameserver etc/resolv.conf)" = "1" ] || fail "guarded bash should not duplicate"
cd "$WORK"

# ------------------------------------------------------------------
say "Declarative Ansible: run twice, changed=2 then changed=0"
mkdir play && cd play
cat > site.yml <<'EOF'
- name: Baseline resolver config
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    etc: "{{ playbook_dir }}/etc"
  tasks:
    - name: Config directory exists
      ansible.builtin.file:
        path: "{{ etc }}"
        state: directory
        mode: "0755"

    - name: Resolver points at internal DNS
      ansible.builtin.copy:
        dest: "{{ etc }}/resolv.conf"
        content: "nameserver 10.0.0.53\n"
        mode: "0644"
EOF
ansible-playbook site.yml --syntax-check
run1=$(ansible-playbook site.yml)
echo "$run1"
grep -Eq "^localhost +: ok=2 +changed=2 " <<<"$run1" || fail "run 1 recap"
[ "$(grep -c '^changed: \[localhost\]' <<<"$run1")" = "2" ] || fail "run 1 tasks"
run2=$(ansible-playbook site.yml)
echo "$run2"
grep -Eq "^localhost +: ok=2 +changed=0 " <<<"$run2" || fail "run 2 recap"
[ "$(grep -c '^ok: \[localhost\]' <<<"$run2")" = "2" ] || fail "run 2 tasks"
[ "$(grep -c nameserver etc/resolv.conf)" = "1" ] || fail "ansible duplicated"

say "Drift: a hand edit, then --check --diff reports it without fixing it"
sed -i 's/10.0.0.53/8.8.8.8/' etc/resolv.conf
chk=$(ansible-playbook site.yml --check --diff)
echo "$chk"
grep -q '^-nameserver 8.8.8.8$' <<<"$chk" || fail "diff remove"
grep -q '^+nameserver 10.0.0.53$' <<<"$chk" || fail "diff add"
grep -Eq "^localhost +: ok=2 +changed=1 " <<<"$chk" || fail "check recap"
[ "$(cat etc/resolv.conf)" = "nameserver 8.8.8.8" ] || fail "check mode must not change files"
ansible-playbook site.yml >/dev/null
grep -qx "nameserver 10.0.0.53" etc/resolv.conf || fail "real run should correct drift"
cd "$WORK"

# ------------------------------------------------------------------
say "shell module is never idempotent on its own; creates: guards it"
mkdir cmd && cd cmd
cat > cmd.yml <<'EOF'
- name: Commands need a guard
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Append with shell
      ansible.builtin.shell: echo "vlan 10" >> vlans.txt

    - name: Generate an API token once
      ansible.builtin.command:
        cmd: openssl rand -hex -out api.token 16
        creates: api.token
EOF
ansible-playbook cmd.yml >/dev/null
run2=$(ansible-playbook cmd.yml)
echo "$run2"
grep -A1 'TASK \[Append with shell\]' <<<"$run2" | grep -q '^changed: \[localhost\]' || fail "shell changed"
grep -A1 'TASK \[Generate an API token once\]' <<<"$run2" | grep -q '^ok: \[localhost\]' || fail "creates ok"
grep -Eq "^localhost +: ok=2 +changed=1 " <<<"$run2" || fail "cmd recap"
[ "$(grep -c 'vlan 10' vlans.txt)" = "2" ] || fail "shell duplicated"

echo; echo "ALL 1.3 IAC CHECKS PASSED"
