#!/usr/bin/env bash
# Verifies the 2.2 Environments, Migrations, and Provisioning notes:
#   an imperative bootstrap script run twice, dbmate schema migrations
#   against persistent and ephemeral SQLite databases, and pull-based
#   provisioning with ansible-pull from a local Git repository.
# Needs: dbmate v2.37.0 (downloaded from GitHub releases), sqlite3,
#        ansible-core (ansible-pull), shellcheck, curl.
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export HOME="$WORK"   # ansible-pull checks out under ~/.ansible/pull
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
git config --global user.name ci && git config --global user.email ci@example.com
git config --global init.defaultBranch main
export ANSIBLE_NOCOLOR=1 ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_LOCAL_TEMP="$WORK/.ansible-tmp" ANSIBLE_HOME="$WORK/.ansible"
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

say "imperative script, run twice"
mkdir -p node
export NODE_ROOT="$WORK/node"
cat > bootstrap-node.sh <<'SH'
#!/usr/bin/env bash
# Imperative: steps run in the order written
set -euo pipefail
conf="${NODE_ROOT:-}/etc/chrony.sources"
mkdir -p "$(dirname "$conf")"
if grep -qs '^server 10.0.20.5' "$conf"; then
  echo "ntp: already set, no change"
else
  echo "server 10.0.20.5 iburst" >> "$conf"
  echo "ntp: added 10.0.20.5"
fi
SH
chmod +x bootstrap-node.sh
shellcheck bootstrap-node.sh
first=$(./bootstrap-node.sh); second=$(./bootstrap-node.sh)
printf '%s\n%s\n' "$first" "$second"
[ "$first" = "ntp: added 10.0.20.5" ] || fail "first run"
[ "$second" = "ntp: already set, no change" ] || fail "second run"
[ "$(grep -c '^server' node/etc/chrony.sources)" = 1 ] || fail "dup line"

say "dbmate"
curl -sSL -o dbmate \
  https://github.com/amacneil/dbmate/releases/download/v2.37.0/dbmate-linux-amd64
chmod +x dbmate
export PATH="$WORK:$PATH" DBMATE_NO_DUMP_SCHEMA=true
dbmate --version | grep -q '2.37.0' || fail "dbmate version"
mkdir -p db/migrations
cat > db/migrations/20261001090000_create_devices.sql <<'SQL'
-- migrate:up
CREATE TABLE devices (
  id       INTEGER PRIMARY KEY,
  hostname TEXT NOT NULL UNIQUE
);

-- migrate:down
DROP TABLE devices;
SQL
cat > db/migrations/20261008090000_add_mgmt_ip.sql <<'SQL'
-- migrate:up
ALTER TABLE devices ADD COLUMN mgmt_ip TEXT;

-- migrate:down
ALTER TABLE devices DROP COLUMN mgmt_ip;
SQL

say "persistent database: first two migrations"
export DATABASE_URL=sqlite:db/net.db
out=$(dbmate up); echo "$out"
grep -q '^Applied: 20261001090000_create_devices.sql' <<<"$out" || fail up1
grep -q '^Applied: 20261008090000_add_mgmt_ip.sql' <<<"$out" || fail up2
sqlite3 db/net.db \
  "INSERT INTO devices (hostname, mgmt_ip) VALUES ('core-sw1','10.0.20.2');"

say "third migration lands; only it runs on the persistent db"
cat > db/migrations/20261015090000_add_site.sql <<'SQL'
-- migrate:up
ALTER TABLE devices ADD COLUMN site TEXT
  NOT NULL DEFAULT 'CLT1';

-- migrate:down
ALTER TABLE devices DROP COLUMN site;
SQL
out=$(dbmate status || true); echo "$out"
grep -q '^\[ \] 20261015090000_add_site.sql' <<<"$out" || fail pending
grep -q '^Pending: 1' <<<"$out" || fail "pending count"
out=$(dbmate up); echo "$out"
[ "$(grep -c '^Applying:' <<<"$out")" = 1 ] || fail "only one applied"
out=$(sqlite3 db/net.db 'SELECT * FROM schema_migrations')
echo "$out"
[ "$(wc -l <<<"$out")" = 3 ] || fail "3 versions recorded"
out=$(sqlite3 db/net.db 'SELECT hostname, site FROM devices;')
echo "$out"
[ "$out" = "core-sw1|CLT1" ] || fail "existing row kept"

say "rollback the newest migration"
out=$(dbmate rollback); echo "$out"
grep -q '^Rolled back: 20261015090000_add_site.sql' <<<"$out" || fail rollback
dbmate up >/dev/null

say "ephemeral database for a pull request: all migrations from zero"
out=$(DATABASE_URL=sqlite:db/pr-142.db dbmate up); echo "$out"
[ "$(grep -c '^Applied:' <<<"$out")" = 3 ] || fail "ephemeral all 3"
rm db/pr-142.db

say "pull provisioning with ansible-pull"
rm -rf node && mkdir -p node
mkdir node-config.git && (
  cd node-config.git && git init -q
  cat > local.yml <<'YML'
- name: Baseline this node
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    root: "{{ lookup('env', 'NODE_ROOT') }}"
  tasks:
    - name: Declare the NTP sources file
      ansible.builtin.copy:
        dest: "{{ root }}/etc/chrony.sources"
        content: "server 10.0.20.5 iburst\n"
        mode: "0644"
YML
  git add local.yml && git commit -qm "feat: chrony sources"
)
mkdir -p node/etc
ansible-playbook --syntax-check -i localhost, node-config.git/local.yml >/dev/null
REPO=file://$PWD/node-config.git
out=$(ansible-pull -U "$REPO" -i localhost, local.yml 2>&1)
echo "$out" | grep -E '^(Starting|PLAY|TASK|changed|ok|localhost +:)'
grep -q '^Starting Ansible Pull at' <<<"$out" || fail "pull start"
grep -q '^changed: \[localhost\]' <<<"$out" || fail "pull changed"
grep -Eq '^localhost +: ok=1 +changed=1 ' <<<"$out" || fail "recap"
grep -q 'server 10.0.20.5 iburst' node/etc/chrony.sources || fail "file"
[ -d "$HOME/.ansible/pull" ] || fail "default checkout dir"

say "ansible-pull -o: nothing new in Git, so nothing runs"
out=$(ansible-pull -o -U "$REPO" -i localhost, local.yml 2>&1)
grep -o '^Repository has not changed, quitting' <<<"$out" || fail "-o"
if grep -q 'PLAY RECAP' <<<"$out"; then fail "-o still ran the play"; fi

echo
echo "ALL 2.2 ENVIRONMENTS-PROVISIONING CHECKS PASSED"
