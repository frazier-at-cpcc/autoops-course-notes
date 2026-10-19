#!/usr/bin/env bash
# Verifies every command and output shown in the 3.1 Secrets Management notes.
# Starts a real Vault dev server and a Postgres container, then exercises KV,
# a short-TTL token, dynamic database credentials, leases, and revocation.
# Needs: docker (images hashicorp/vault:2.2.0, postgres:17-alpine), actionlint.
# Ports: 127.0.0.1:18350 (Vault). Containers: ao-f-vault, ao-f-pg, ao-f-psql.
set -euo pipefail
WORK=$(mktemp -d)
NET=ao-f-secrets-net
rmc() {
  docker rm -f ao-f-vault ao-f-pg ao-f-psql >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap 'rmc; rm -rf "$WORK"' EXIT
rmc   # clear leftovers from an interrupted run

say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
# grep that reads all input, so the writer never dies of SIGPIPE under pipefail
q() { grep "$@" >/dev/null; }
# Pull an image once; fall back to Google's Docker Hub mirror on rate limits.
img() {
  docker image inspect "$1" >/dev/null 2>&1 && return
  docker pull -q "$1" >/dev/null 2>&1 ||
    { docker pull -q "mirror.gcr.io/$2" >/dev/null && docker tag "mirror.gcr.io/$2" "$1"; }
}
img hashicorp/vault:2.2.0 hashicorp/vault:2.2.0
img postgres:17-alpine library/postgres:17-alpine

say "start Vault dev server and Postgres"
docker network create "$NET" >/dev/null
docker run -d --name ao-f-pg --network "$NET" \
  -e POSTGRES_PASSWORD=vaultadmin postgres:17-alpine >/dev/null
docker run -d --name ao-f-vault --network "$NET" --cap-add=IPC_LOCK \
  -e VAULT_DEV_ROOT_TOKEN_ID=root -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  -p 127.0.0.1:18350:8200 hashicorp/vault:2.2.0 >/dev/null
# Use the vault CLI on the host, copied out of the image
mkdir -p "$WORK/bin" && docker cp -q ao-f-vault:/bin/vault "$WORK/bin/vault"
export PATH="$WORK/bin:$PATH" VAULT_ADDR=http://127.0.0.1:18350 VAULT_TOKEN=root
for _ in $(seq 30); do vault status >/dev/null 2>&1 && break; sleep 1; done
vault status | q 'Sealed .*false'
vault version | q '^Vault v2\.2\.0'
for _ in $(seq 30); do docker exec ao-f-pg pg_isready -h 127.0.0.1 -q && break; sleep 1; done

say "KV: put and get a static secret"
out=$(vault kv put -mount=secret ci/netbox \
    api_token=nb-7f3a9c)
echo "$out"
grep -q 'secret/data/ci/netbox' <<<"$out"
grep -Eq '^version +1$' <<<"$out"
got=$(vault kv get -mount=secret -field=api_token \
    ci/netbox)
echo "$got"; [ "$got" = "nb-7f3a9c" ]
vault kv put -mount=secret ci/netbox api_token=nb-2b81e0 | q -E '^version +2$'
[ "$(vault kv get -mount=secret -version=1 -field=api_token ci/netbox)" = "nb-7f3a9c" ]

say "policy and a short-lived token"
vault policy write ci-read - <<'HCL' | q 'Success'
path "secret/data/ci/*" {
  capabilities = ["read"]
}
HCL
out=$(vault token create -policy=ci-read -ttl=15s)
echo "$out"
grep -Eq '^token +hvs\.' <<<"$out"
grep -Eq '^token_duration +15s$' <<<"$out"
grep -q 'token_policies .*\["ci-read" "default"\]' <<<"$out"
CI_TOKEN=$(awk '$1=="token"{print $2}' <<<"$out")
look=$(VAULT_TOKEN=$CI_TOKEN vault token lookup)
echo "$look" | grep -E '^(creation_ttl|policies|ttl) '
grep -Eq '^creation_ttl +15s$' <<<"$look"
grep -Eq '^policies +\[ci-read default\]$' <<<"$look"
[ "$(VAULT_TOKEN=$CI_TOKEN vault kv get -mount=secret -field=api_token ci/netbox)" = "nb-2b81e0" ]
if VAULT_TOKEN=$CI_TOKEN vault kv put -mount=secret ci/netbox api_token=x 2>"$WORK/err"; then
  fail "read-only token was allowed to write"
fi
grep -q 'Code: 403' "$WORK/err" && grep -q 'permission denied' "$WORK/err"
sleep 16   # let the token's TTL run out
if (export VAULT_TOKEN=$CI_TOKEN; vault kv get -mount=secret ci/netbox) 2>"$WORK/err" >/dev/null; then
  fail "expired token still worked"
fi
cat "$WORK/err"
grep -q 'invalid token' "$WORK/err"
# Revoking a token by hand works the same way, before its TTL is up
T2=$(vault token create -policy=ci-read -ttl=1h -field=token)
vault token revoke "$T2" | q 'Success! Revoked token'
if VAULT_TOKEN=$T2 vault token lookup >/dev/null 2>&1; then fail "revoked token still valid"; fi

say "dynamic database credentials with a lease"
vault secrets enable -path=db database | q 'Enabled the database secrets engine at: db/'
vault write db/config/inventory \
  plugin_name=postgresql-database-plugin \
  allowed_roles=ci \
  connection_url='postgresql://{{username}}:{{password}}@ao-f-pg:5432/postgres?sslmode=disable' \
  username=postgres password=vaultadmin \
  username_template='ci-{{random 8 | lowercase}}' >/dev/null
vault write db/roles/ci db_name=inventory default_ttl=2m max_ttl=10m \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" >/dev/null
creds=$(vault read db/creds/ci)
echo "$creds"
grep -Eq '^lease_id +db/creds/ci/[A-Za-z0-9]{24}$' <<<"$creds"
grep -Eq '^lease_duration +2m$' <<<"$creds"
grep -Eq '^lease_renewable +true$' <<<"$creds"
grep -Eq '^username +ci-[a-z0-9]{8}$' <<<"$creds"
LEASE=$(awk '$1=="lease_id"{print $2}' <<<"$creds")
DBUSER=$(awk '$1=="username"{print $2}' <<<"$creds")
DBPASS=$(awk '$1=="password"{print $2}' <<<"$creds")
pgq() { docker exec ao-f-pg psql -U postgres -tAc "$1"; }
# Log in over the network from a second container (inside ao-f-pg, local
# connections are trusted and would ignore the password)
pgc() { docker run --rm --name ao-f-psql --network "$NET" -e PGPASSWORD="$2" \
  postgres:17-alpine psql -h ao-f-pg -U "$1" -d postgres -tAc 'SELECT current_user'; }
[ "$(pgq "SELECT count(*) FROM pg_roles WHERE rolname='$DBUSER'")" = "1" ]
# The credential really logs in, over TCP, as the generated user
pgc "$DBUSER" "$DBPASS" | q -x "$DBUSER"
pgc postgres vaultadmin | q -x postgres   # root password works before rotation

say "lease lookup, renew, revoke"
look=$(vault lease lookup "$LEASE")
echo "$look"
grep -Eq '^id +db/creds/ci/' <<<"$look"
grep -Eq '^renewable +true$' <<<"$look"
grep -Eq '^ttl +(1m5[0-9]s|2m)$' <<<"$look"
grep -Eq '^last_renewal +<nil>$' <<<"$look"
ren=$(vault lease renew -increment=5m "$LEASE")
echo "$ren"
grep -Eq '^lease_duration +5m$' <<<"$ren"
# Renewal past max_ttl is capped, not refused
vault lease renew -increment=1h "$LEASE" | q -E '^lease_duration +(9m5[0-9]s|10m)$'
rev=$(vault lease revoke "$LEASE")
echo "$rev"
[ "$rev" = "All revocation operations queued successfully!" ]
for _ in $(seq 10); do
  [ "$(pgq "SELECT count(*) FROM pg_roles WHERE rolname='$DBUSER'")" = "0" ] && break; sleep 1
done
[ "$(pgq "SELECT count(*) FROM pg_roles WHERE rolname='$DBUSER'")" = "0" ] || fail "revoked user still exists"
pgq "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ci-%'"

say "every read is a new user; revoke them all by prefix"
u1=$(vault read -field=username db/creds/ci); u2=$(vault read -field=username db/creds/ci)
[ "$u1" != "$u2" ] || fail "dynamic secrets were not unique"
[ "$(pgq "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ci-%'")" = "2" ]
vault lease revoke -prefix db/creds/ci | q 'All revocation operations queued successfully!'
for _ in $(seq 10); do
  [ "$(pgq "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ci-%'")" = "0" ] && break; sleep 1
done
[ "$(pgq "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ci-%'")" = "0" ] || fail "prefix revoke left users"

say "rotate the root credential so only Vault knows it"
vault write -f db/rotate-root/inventory | tee "$WORK/rot"
grep -q 'Success! Data written to: db/rotate-root/inventory' "$WORK/rot"
if pgc postgres vaultadmin >/dev/null 2>&1; then
  fail "old root password still works after rotate-root"
fi
vault read -field=username db/creds/ci | q -E '^ci-[a-z0-9]{8}$'   # Vault still can

say "CI workflow that pulls secrets from Vault with OIDC (static check only)"
# A GitHub-hosted runner and a reachable Vault are not available here, so the
# workflow in the notes is validated with actionlint rather than executed.
mkdir -p "$WORK/wf/.github/workflows"
cat > "$WORK/wf/.github/workflows/deploy-acl.yml" <<'YAML'
name: deploy-acl
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # request an OIDC token
      contents: read
    steps:
      - uses: actions/checkout@v6
      - uses: hashicorp/vault-action@v3
        with:
          url: https://vault.example.net
          method: jwt
          role: netops-deploy
          secrets: |
            secret/data/ci/netbox api_token | TOKEN
      - run: ./push-acl.sh  # TOKEN shows as ***
YAML
actionlint -no-color "$WORK/wf/.github/workflows/deploy-acl.yml"
grep -q 'id-token: write' "$WORK/wf/.github/workflows/deploy-acl.yml"

echo; echo "ALL 3.1 SECRETS CHECKS PASSED"
