#!/usr/bin/env bash
# Verifies the 2.1 "Workload Configuration: Certificates and ACLs" notes:
# a lab CA and server certificate with openssl, expiry checks, the same PKI
# with the Terraform tls provider, POSIX file ACLs, and a network ACL
# rendered from data with an Ansible template.
#
# Needs: openssl 3.x, terraform (any 1.x; uses the tls provider from the
#        registry), ansible-core, acl (setfacl/getfacl) on a filesystem
#        that supports ACLs, and the www-data group (Debian/Ubuntu default).
# No ports or containers.
# shellcheck disable=SC2012  # ls -l is the point: it shows the ACL '+'
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

CACHE="${AO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/autoops-notes}"
mkdir -p "$CACHE/tf-plugins"
export TF_PLUGIN_CACHE_DIR="$CACHE/tf-plugins"
export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1   # reuse the cache in fresh dirs
export TF_CLI_CONFIG_FILE="$WORK/terraformrc"; : > "$TF_CLI_CONFIG_FILE"
export CHECKPOINT_DISABLE=1
export ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False
export ANSIBLE_NOCOLOR=1 ANSIBLE_CONFIG="$WORK/ansible.cfg"; : > "$ANSIBLE_CONFIG"

say "1. openssl: lab root CA"
mkdir "$WORK/pki" && cd "$WORK/pki"
# 1. Root CA: key and self-signed cert, 10 years
openssl req -x509 -newkey ec \
  -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -keyout ca.key -out ca.crt -days 3650 \
  -subj "/CN=Lab Root CA" 2>/dev/null
openssl x509 -in ca.crt -noout -subject -ext basicConstraints
openssl x509 -in ca.crt -noout -ext basicConstraints | grep -q 'CA:TRUE' \
  || fail "root is not a CA"

say "2. openssl: server key, CSR with SAN, signed by the CA"
# 2. Server key and CSR with a SAN
openssl req -newkey ec \
  -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -keyout web.key -out web.csr \
  -subj "/CN=web01.lab.example" \
  -addext "subjectAltName=DNS:web01.lab.example" 2>/dev/null
# 3. The CA signs the CSR: 90-day certificate
openssl x509 -req -in web.csr -CA ca.crt \
  -CAkey ca.key -CAcreateserial -days 90 \
  -copy_extensions copy -out web.crt 2>&1
openssl verify -CAfile ca.crt web.crt
[ "$(openssl verify -CAfile ca.crt web.crt)" = "web.crt: OK" ] || fail "verify"
openssl x509 -in web.crt -noout -enddate
openssl x509 -in web.crt -noout -subject -issuer -ext subjectAltName
openssl x509 -in web.crt -noout -ext subjectAltName | grep -q 'DNS:web01.lab.example' \
  || fail "SAN not copied into the certificate"
# 90 days from now, to the day
want=$(date -u -d '+90 days' '+%b %e')
openssl x509 -in web.crt -noout -enddate | grep -q "notAfter=$want" || fail "lifetime is not 90 days"

say "3. openssl: expiry checks a renewal job can act on"
set +e
[ $((30*86400)) = 2592000 ] && [ $((100*86400)) = 8640000 ]
openssl x509 -in web.crt -noout -checkend 2592000; rc30=$?
openssl x509 -in web.crt -noout -checkend 8640000; rc100=$?
set -e
echo "30-day check exit=$rc30, 100-day check exit=$rc100"
[ "$rc30" = 0 ] || fail "30-day checkend"
[ "$rc100" = 1 ] || fail "100-day checkend"
# A certificate for the wrong name fails verification by hostname
set +e
openssl verify -CAfile ca.crt -verify_hostname db01.lab.example web.crt 2>&1 | grep 'hostname mismatch'
set -e
if openssl verify -CAfile ca.crt -verify_hostname db01.lab.example web.crt >/dev/null 2>&1; then
  fail "hostname mismatch should fail"
fi

say "4. Terraform tls provider: the same CA and server cert as code"
mkdir "$WORK/tls" && cd "$WORK/tls"
cat > main.tf <<'EOF'
terraform {
  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
EOF
cat > ca.tf <<'EOF'
resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600 # 10 years
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject {
    common_name = "Lab Root CA"
  }
}
EOF
cat > web.tf <<'EOF'
resource "tls_private_key" "web" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "web" {
  private_key_pem = tls_private_key.web.private_key_pem
  dns_names       = ["web01.lab.example"]
  subject {
    common_name = "web01.lab.example"
  }
}

locals {
  ca_key  = tls_private_key.ca.private_key_pem
  ca_cert = tls_self_signed_cert.ca.cert_pem
  web_csr = tls_cert_request.web.cert_request_pem
}

resource "tls_locally_signed_cert" "web" {
  cert_request_pem   = local.web_csr
  ca_private_key_pem = local.ca_key
  ca_cert_pem        = local.ca_cert

  validity_period_hours = 2160 # 90 days
  early_renewal_hours   = 720  # 30 days left
  allowed_uses = [
    "digital_signature",
    "server_auth",
  ]
}

output "web_cert_pem" {
  value = tls_locally_signed_cert.web.cert_pem
}

output "web_ready_for_renewal" {
  value = tls_locally_signed_cert.web.ready_for_renewal
}
EOF
terraform fmt -check || fail "terraform fmt"
terraform init -no-color >/dev/null
terraform validate -no-color
terraform apply -auto-approve -no-color | grep -E '^Apply complete'
terraform output -no-color web_ready_for_renewal
[ "$(terraform output -raw web_ready_for_renewal)" = "false" ] || fail "ready_for_renewal"
terraform output -raw web_cert_pem | openssl x509 -noout -issuer -enddate
terraform output -raw web_cert_pem | openssl x509 -noout -issuer | grep -q 'CN = Lab Root CA' \
  || fail "issuer"
# The private keys live in state in plain text
jq -r '.resources[] | select(.type=="tls_private_key") | .instances[0].attributes.private_key_pem' \
  terraform.tfstate | head -1
jq -r '.resources[] | select(.type=="tls_private_key") | .instances[0].attributes.private_key_pem' \
  terraform.tfstate | grep -q 'BEGIN EC PRIVATE KEY\|BEGIN PRIVATE KEY' || fail "key not in state?"

say "5. file ACLs: let the web server group read one private key"
mkdir "$WORK/acl" && cd "$WORK/acl"
mkdir tls && cp "$WORK/pki/web.key" tls/
getent group www-data >/dev/null || fail "needs the www-data group"
chmod 600 tls/web.key
setfacl -m g:www-data:r tls/web.key
ls -l tls/web.key | cut -c1-11
[ "$(ls -l tls/web.key | cut -c1-11)" = "-rw-r-----+" ] || fail "ls does not show the ACL +"
getfacl -p tls/web.key 2>/dev/null | grep -v -E '^# (owner|group):'
getfacl -p tls/web.key 2>/dev/null | grep -qx 'group:www-data:r--' || fail "named group entry"
getfacl -p tls/web.key 2>/dev/null | grep -qx 'mask::r--' || fail "mask"
# Default ACL: new files in tls/ inherit the entry
setfacl -d -m g:www-data:r tls
touch tls/web02.key
getfacl -p tls/web02.key 2>/dev/null | grep 'www-data'
getfacl -p tls/web02.key 2>/dev/null | grep -q '^group:www-data:r--' || fail "default ACL not inherited"
setfacl -b tls/web.key
[ "$(ls -l tls/web.key | cut -c1-11)" = "-rw------- " ] || fail "setfacl -b"

say "6. network ACL as code: render a Cisco ACL from data"
mkdir "$WORK/netacl" && cd "$WORK/netacl"
cat > acl_vars.yml <<'EOF'
acl_name: WEB-IN
web: host 10.20.1.10
rules:
  - seq: 10
    action: permit
    src: any
    port: 443
  - seq: 20
    action: permit
    src: host 10.99.0.5
    port: 22
EOF
cat > acl.j2 <<'EOF'
ip access-list extended {{ acl_name }}
{% for r in rules %}
 {{ r.seq }} {{ r.action }} tcp {{ r.src }}
 {{- " " ~ web ~ " eq " ~ r.port }}
{% endfor %}
 1000 deny ip any any log
EOF
cat > acl.yml <<'EOF'
- name: Build edge ACLs from data
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - acl_vars.yml
  tasks:
    - name: Render WEB-IN
      ansible.builtin.template:
        src: acl.j2
        dest: WEB-IN.cfg
        mode: "0644"
EOF
ansible-playbook --syntax-check acl.yml >/dev/null
ansible-playbook acl.yml >"$WORK/acl1.txt"; grep -q 'changed=1' "$WORK/acl1.txt"
cat WEB-IN.cfg
cat > "$WORK/want.cfg" <<'EOF'
ip access-list extended WEB-IN
 10 permit tcp any host 10.20.1.10 eq 443
 20 permit tcp host 10.99.0.5 host 10.20.1.10 eq 22
 1000 deny ip any any log
EOF
diff -u "$WORK/want.cfg" WEB-IN.cfg || fail "rendered ACL differs"
# Add a rule in the data, see the change as a diff before it lands
cat >> acl_vars.yml <<'EOF'
  - seq: 30
    action: permit
    src: any
    port: 80
EOF
ansible-playbook acl.yml --check --diff >"$WORK/acl2.txt"
sed -n '/^@@/,/^$/p' "$WORK/acl2.txt"
grep -q '^+ 30 permit tcp any host 10.20.1.10 eq 80' "$WORK/acl2.txt" \
  || fail "check-mode diff for the new rule"
ansible-playbook acl.yml >"$WORK/acl3.txt"; grep -q 'changed=1' "$WORK/acl3.txt"
ansible-playbook acl.yml >"$WORK/acl4.txt"; grep -q 'changed=0' "$WORK/acl4.txt"

echo; echo "ALL 2.1 WORKLOAD-CONFIGURATION CHECKS PASSED"
