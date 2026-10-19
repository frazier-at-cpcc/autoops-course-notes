#!/usr/bin/env bash
# Verifies every file, command, and output shown in the 3.1 Task Runners notes.
# A Makefile and a Taskfile provision a throwaway Postgres with Docker Compose,
# run a test against it, and tear it down; the CI workflow that calls the same
# entry point is validated with actionlint (no GitHub runner here).
# Needs: docker with compose v2+, make, yamllint, actionlint,
#        task (go install github.com/go-task/task/v3/cmd/task@latest).
# Ports: 127.0.0.1:18353 (Postgres). Compose project / containers: ao-f-inventory-*.
set -euo pipefail
WORK=$(mktemp -d)
export COMPOSE_PROJECT_NAME=ao-f-inventory   # unique name so runs never collide
rmc() { (cd "$WORK" 2>/dev/null && docker compose -f compose.test.yml down -v >/dev/null 2>&1) || true; }
trap 'rmc; rm -rf "$WORK"' EXIT
cd "$WORK"

say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
# grep that reads all input, so the writer never dies of SIGPIPE under pipefail
q() { grep "$@" >/dev/null; }
img() {
  docker image inspect "$1" >/dev/null 2>&1 && return
  docker pull -q "$1" >/dev/null 2>&1 ||
    { docker pull -q "mirror.gcr.io/$2" >/dev/null && docker tag "mirror.gcr.io/$2" "$1"; }
}
img postgres:17-alpine library/postgres:17-alpine

mkdir inventory
cat > inventory/hosts.yml <<'EOF'
---
all:
  hosts:
    core-sw1:
      ansible_host: 10.0.0.1
EOF

cat > compose.test.yml <<'EOF'
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: ci
      POSTGRES_PASSWORD: throwaway-test-only
      POSTGRES_DB: inventory
    ports:
      - "127.0.0.1:18353:5432"
    volumes:
      - ./seed:/docker-entrypoint-initdb.d:ro
    healthcheck:
      # -h 127.0.0.1: TCP is up only after seeding
      test: pg_isready -h 127.0.0.1 -U ci
      interval: 2s
      retries: 15
EOF

mkdir seed
cat > seed/seed.sql <<'EOF'
CREATE TABLE devices (name text, mgmt_ip inet);
INSERT INTO devices VALUES
  ('core-sw1', '10.0.0.1'),
  ('core-sw2', '10.0.0.2'),
  ('edge-rtr1', '10.0.0.254');
EOF

# Recipe lines in a Makefile must start with a real tab character.
cat > Makefile <<'EOF'
COMPOSE := docker compose -f compose.test.yml
PSQL := $(COMPOSE) exec -T db psql -U ci -tA
.PHONY: lint test-env test clean

lint:
	yamllint -s inventory/

test-env:
	$(COMPOSE) up -d --wait

test: lint test-env
	@$(PSQL) -c "SELECT count(*) FROM devices" \
	  inventory | grep -qx 3
	@echo "inventory: 3 devices, tests passed"

clean:
	$(COMPOSE) down -v
EOF
grep -qP '^\tyamllint' Makefile || fail "Makefile recipes must be tab-indented"

say "make -n: print the plan without running it"
make -n test | tee dry.txt
head -1 dry.txt | q -x 'yamllint -s inventory/'
sed -n 2p dry.txt | q -x 'docker compose -f compose.test.yml up -d --wait'
if docker ps --format '{{.Names}}' | q '^ao-f-inventory-db-1$'; then fail "dry run started a container"; fi

say "make test: lint, provision, test"
make test 2>&1 | tee run.txt
grep -qx 'yamllint -s inventory/' run.txt
grep -q 'Container ao-f-inventory-db-1 *Healthy' run.txt
tail -1 run.txt | q -x 'inventory: 3 devices, tests passed'
# The database is reachable from the host on the published port
(exec 3<>/dev/tcp/127.0.0.1/18353) || fail "port 18353 not published"

say "make test again: the environment is reused, not rebuilt"
make test >again.txt 2>&1
grep Container again.txt
grep -q 'Container ao-f-inventory-db-1 *Running' again.txt || fail "second run did not reuse the container"

say "a failing step stops make with a non-zero exit"
cat > inventory/broken.yml <<'EOF'
---
all:
  hosts:
    core-sw2:
      ansible_host: 10.0.0.2
      ansible_host: 10.0.0.3
EOF
set +e; make lint >lint.txt 2>&1; rc=$?; set -e
cat lint.txt; echo "$rc"
[ "$rc" = "2" ] || fail "make lint should exit 2 on broken YAML (got $rc)"
grep -q 'duplication of key "ansible_host"' lint.txt
grep -qx 'make: \*\*\* \[Makefile:6: lint\] Error 1' lint.txt
rm inventory/broken.yml

say "make clean: tear it all down"
make clean 2>&1 | tee clean.txt
grep -q 'Container ao-f-inventory-db-1 *Removed' clean.txt
docker ps -a --format '{{.Names}}' | q '^ao-f-inventory-db-1$' && fail "container left behind"

say "the same pipeline as a Taskfile (go-task)"
cat > Taskfile.yml <<'EOF'
version: '3'
vars:
  COMPOSE: docker compose -f compose.test.yml
tasks:
  test-env:
    desc: Start a throwaway Postgres
    cmds:
      - '{{.COMPOSE}} up -d --wait'
  test:
    desc: Lint, provision, and test
    deps: [test-env]
    cmds:
      - yamllint -s inventory/
      - >-
        {{.COMPOSE}} exec -T db psql -U ci -tA
        -c "SELECT count(*) FROM devices"
        inventory | grep -qx 3
  clean:
    desc: Remove the test environment
    cmds:
      - '{{.COMPOSE}} down -v'
EOF
task --list | tee list.txt
grep -Eq '^\* clean: +Remove the test environment' list.txt
grep -Eq '^\* test: +Lint, provision, and test' list.txt
[ "$(grep -c '^\* ' list.txt)" = "3" ]
task test >/dev/null 2>&1 || fail "task test failed"
# A broken inventory makes the task fail too
printf -- '---\na: 1\na: 2\n' > inventory/dup.yml
if task test >/dev/null 2>&1; then fail "task test passed on broken YAML"; fi
rm inventory/dup.yml
task clean >/dev/null 2>&1

say "CI calls the same entry point (static check only)"
mkdir -p .github/workflows
cat > .github/workflows/inventory.yml <<'EOF'
name: inventory
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - run: make test
      - if: always()   # tear down even on failure
        run: make clean
EOF
actionlint -no-color .github/workflows/inventory.yml

echo; echo "ALL 3.1 TASK-RUNNER CHECKS PASSED"
