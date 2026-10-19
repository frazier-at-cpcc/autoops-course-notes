#!/usr/bin/env bash
# Verifies the 2.1 "Drift Detection and State Management" notes:
# Terraform state, an S3 remote backend with native locking (use_lockfile),
# drift detection with plan -detailed-exitcode, remediation by apply and
# refresh-only, and Ansible --check --diff drift detection.
#
# Needs: Terraform >= 1.10 for use_lockfile (if the terraform on PATH is
#        older, a pinned 1.16.6 is downloaded into the cache below),
#        python3 venv + pip (installs moto[server] as a local S3 endpoint),
#        ansible-core, curl, network access to releases.hashicorp.com,
#        PyPI, and the Terraform registry.
# Port: moto S3 server on 127.0.0.1:18200. No containers.
# Cache: ${AO_CACHE:-~/.cache/autoops-notes} holds the venv, the pinned
#        Terraform, and the provider plugin cache between runs.
set -euo pipefail
WORK=$(mktemp -d)
MOTO_PID=""
cleanup() {
  if [ -n "$MOTO_PID" ]; then kill "$MOTO_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

CACHE="${AO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/autoops-notes}"
mkdir -p "$CACHE/tf-plugins"
export TF_PLUGIN_CACHE_DIR="$CACHE/tf-plugins"
export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=1   # reuse the cache in fresh dirs
export TF_CLI_CONFIG_FILE="$WORK/terraformrc"   # ignore the user's ~/.terraformrc
: > "$TF_CLI_CONFIG_FILE"
export CHECKPOINT_DISABLE=1
# Never read real AWS credentials or config
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
export ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False
export ANSIBLE_NOCOLOR=1 ANSIBLE_CONFIG="$WORK/ansible.cfg"   # ignore ~/.ansible.cfg
: > "$ANSIBLE_CONFIG"

# ---- Terraform >= 1.10 (use_lockfile needs it)
TF=terraform
ver=$(terraform version -json 2>/dev/null | jq -r .terraform_version || echo 0.0.0)
if [ "$(printf '%s\n1.10.0\n' "$ver" | sort -V | head -1)" != "1.10.0" ]; then
  TF_PIN=1.16.6
  TF="$CACHE/terraform-$TF_PIN/terraform"
  if [ ! -x "$TF" ]; then
    mkdir -p "$CACHE/terraform-$TF_PIN"
    curl -fsSLo "$WORK/tf.zip" \
      "https://releases.hashicorp.com/terraform/$TF_PIN/terraform_${TF_PIN}_linux_amd64.zip"
    python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
      "$WORK/tf.zip" "$CACHE/terraform-$TF_PIN"
    chmod +x "$TF"
  fi
fi
tf() { "$TF" "$@" -no-color; }
echo "using $("$TF" version | head -1)"

say "1. local state: apply, list, inspect"
mkdir "$WORK/motd" && cd "$WORK/motd"
cat > main.tf <<'EOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

resource "local_file" "motd" {
  filename        = "${path.module}/motd.txt"
  content         = "Authorized access only\n"
  file_permission = "0644"
}
EOF
tf init >/dev/null
tf apply -auto-approve | tail -1 | grep -q 'Resources: 1 added'
"$TF" state list
"$TF" state list | grep -qx 'local_file.motd'
jq '{version, serial, lineage}' terraform.tfstate
[ "$(jq -r '.resources[0].instances[0].attributes.filename' terraform.tfstate)" = "./motd.txt" ] \
  || fail "state does not record the filename"

say "2. no drift: plan -detailed-exitcode returns 0"
set +e; tf plan -detailed-exitcode >"$WORK/plan0.txt"; rc=$?; set -e
grep 'No changes' "$WORK/plan0.txt"
[ "$rc" = 0 ] || fail "expected exit 0 with no drift, got $rc"

say "3. drift: someone edits the file by hand"
echo "Free Wi-Fi password: guest123" > motd.txt
set +e; tf plan -detailed-exitcode >"$WORK/plan2.txt"; rc=$?; set -e
grep -E 'Refreshing state|will be created|Plan:' "$WORK/plan2.txt"
echo "exit=$rc"
[ "$rc" = 2 ] || fail "expected exit 2 with drift, got $rc"
grep -q '# local_file.motd will be created' "$WORK/plan2.txt" || fail "plan text changed"

say "3b. refresh-only plan reports the drift without fixing it"
set +e; tf plan -refresh-only -detailed-exitcode >"$WORK/refresh.txt"; rc=$?; set -e
grep -E 'Objects have changed outside of Terraform|has been deleted|refresh-only plan' "$WORK/refresh.txt"
grep -q 'local_file.motd has been deleted' "$WORK/refresh.txt" || fail "refresh-only text changed"
grep -q 'guest123' motd.txt || fail "refresh-only must not touch the file"

say "4. remediate: apply puts the declared content back"
tf apply -auto-approve | tail -1
[ "$(cat motd.txt)" = "Authorized access only" ] || fail "apply did not restore the file"
set +e; tf plan -detailed-exitcode >/dev/null; rc=$?; set -e
[ "$rc" = 0 ] || fail "expected a clean plan after remediation, got $rc"

say "5. remote state: S3 backend with native locking (moto as S3)"
VENV="$CACHE/moto-venv"
if [ ! -x "$VENV/bin/moto_server" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q 'moto[server]'
fi
"$VENV/bin/moto_server" -H 127.0.0.1 -p 18200 >"$WORK/moto.log" 2>&1 &
MOTO_PID=$!
export AWS_ACCESS_KEY_ID=lab AWS_SECRET_ACCESS_KEY=lab
export AWS_ENDPOINT_URL=http://127.0.0.1:18200
for _ in $(seq 1 50); do curl -fs "$AWS_ENDPOINT_URL" >/dev/null 2>&1 && break; sleep 0.2; done
"$VENV/bin/python" -c "import boto3;boto3.client('s3',region_name='us-east-1').create_bucket(Bucket='netops-tfstate')"

mkdir "$WORK/remote" && cd "$WORK/remote"
cp "$WORK/motd/main.tf" .
cat > backend.tf <<'EOF'
terraform {
  backend "s3" {
    bucket       = "netops-tfstate"
    key          = "core/motd.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
cat > slow.tf <<'EOF'
resource "terraform_data" "slow" {
  provisioner "local-exec" {
    command = "sleep 8"
  }
}
EOF
# Partial configuration: the lab-only settings for the local S3 endpoint
tf init -backend-config=use_path_style=true \
  -backend-config=skip_credentials_validation=true \
  -backend-config=skip_requesting_account_id=true >"$WORK/init.txt"
grep 'Successfully configured the backend "s3"' "$WORK/init.txt"
[ ! -f terraform.tfstate ] || fail "state should not be written locally"

tf apply -auto-approve >"$WORK/apply1.txt" 2>&1 &
APPLY_PID=$!
for _ in $(seq 1 50); do
  "$VENV/bin/python" -c "import boto3,sys;r=boto3.client('s3',region_name='us-east-1').list_objects_v2(Bucket='netops-tfstate');sys.exit(0 if any(o['Key'].endswith('.tflock') for o in r.get('Contents',[])) else 1)" && break
  sleep 0.3
done
"$VENV/bin/python" -c "import boto3;[print(o['Key']) for o in boto3.client('s3',region_name='us-east-1').list_objects_v2(Bucket='netops-tfstate')['Contents']]" | tee "$WORK/keys.txt"
grep -qx 'core/motd.tfstate.tflock' "$WORK/keys.txt" || fail "no lock file while apply runs"
set +e; tf plan >"$WORK/locked.txt" 2>&1; rc=$?; set -e
grep -E 'Error acquiring the state lock|PreconditionFailed|Lock Info:|ID:|Path:|Operation:|Who:|Version:' "$WORK/locked.txt"
[ "$rc" = 1 ] || fail "second run should fail on the lock"
grep -q 'Error acquiring the state lock' "$WORK/locked.txt" || fail "lock error text changed"
grep -q 'Operation: OperationTypeApply' "$WORK/locked.txt" || fail "lock info text changed"
wait "$APPLY_PID"
tail -1 "$WORK/apply1.txt" | grep -q 'Resources: 2 added' || fail "first apply failed"
"$VENV/bin/python" -c "import boto3;[print(o['Key']) for o in boto3.client('s3',region_name='us-east-1').list_objects_v2(Bucket='netops-tfstate')['Contents']]" | tee "$WORK/keys.txt"
! grep -q tflock "$WORK/keys.txt" || fail "lock not released"
"$TF" state pull | jq '{serial, resources: [.resources[].type]}'
"$TF" state pull | jq -e '.resources | length == 2' >/dev/null

say "6. Ansible: --check --diff finds config drift, a normal run fixes it"
mkdir "$WORK/ansible" && cd "$WORK/ansible"
cat > ntp.yml <<'EOF'
- name: Enforce the NTP baseline
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Chrony points at the site NTP servers
      ansible.builtin.copy:
        dest: chrony.conf
        mode: "0644"
        content: |
          server 10.0.0.1 iburst
          server 10.0.0.2 iburst
          makestep 1.0 3
EOF
ansible-playbook ntp.yml >"$WORK/run1.txt"; grep -q 'changed=1' "$WORK/run1.txt"
ansible-playbook ntp.yml >"$WORK/run2.txt"; grep -q 'changed=0' "$WORK/run2.txt"   # idempotent
sed -i 's/10.0.0.2/192.0.2.99/' chrony.conf            # someone edits by hand
set +e; ansible-playbook ntp.yml --check --diff >"$WORK/check.txt"; rc=$?; set -e
sed -n '/^TASK/,/^PLAY RECAP/p' "$WORK/check.txt"; grep 'localhost *:' "$WORK/check.txt"
grep -q '^-server 192.0.2.99 iburst' "$WORK/check.txt" || fail "diff missing drifted line"
grep -q '^+server 10.0.0.2 iburst' "$WORK/check.txt" || fail "diff missing desired line"
grep -q 'changed=1' "$WORK/check.txt" || fail "check mode should report changed=1"
[ "$rc" = 0 ] || fail "check mode exits 0 even when it finds drift (got $rc)"
grep -q '192.0.2.99' chrony.conf || fail "--check must not change the file"
ansible-playbook ntp.yml | grep 'localhost *:'
grep -q '^server 10.0.0.2 iburst' chrony.conf || fail "normal run did not remediate"

echo; echo "ALL 2.1 DRIFT-AND-STATE CHECKS PASSED"
