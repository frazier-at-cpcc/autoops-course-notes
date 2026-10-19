#!/usr/bin/env bash
# Verifies every command shown in the 1.2 Source Control notes.
# Runs in a throwaway directory; exits non-zero on the first failure.
set -euo pipefail
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"   # never touch the real ~/.gitconfig

say() { printf '\n== %s\n' "$*"; }

say "config"
git config --global user.name "Ada Admin"
git config --global user.email "ada@example.com"
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --list --show-origin | grep -q 'user.name=Ada Admin'
git config user.name

say "local: init, add, commit"
git init -q netconfig && cd netconfig
printf 'hostname core-sw1\n' > switch.cfg
git status --short
git add switch.cfg
git status --short | grep -q '^A  switch.cfg'
git commit -q -m "feat: add core switch baseline"
git log --oneline | grep -q 'add core switch baseline'
printf 'vlan 10\n' >> switch.cfg
git add -p <<<'y' >/dev/null 2>&1 || git add switch.cfg
git commit -q -m "feat: add VLAN 10"
git diff HEAD~1 --stat | grep -q 'switch.cfg'
printf 'vlan 11\n' >> switch.cfg && git add switch.cfg
git diff --staged --stat | grep -q 'switch.cfg'
git commit -q -m "feat: add VLAN 11"
touch untracked.txt && printf 'vlan 12\n' >> switch.cfg
git commit -q -am "feat: add VLAN 12"
git status --short | grep -q '^?? untracked.txt'   # commit -a skipped the untracked file
rm untracked.txt

say "remote: push, fetch, pull"
git init -q --bare ../origin.git
git remote add origin ../origin.git
git remote -v | grep -q origin
git push -q -u origin main
cd .. && git clone -q origin.git teammate && cd teammate
printf 'vlan 20\n' >> switch.cfg && git commit -qam "feat: add VLAN 20" && git push -q
cd ../netconfig
git fetch -q origin
git status -sb | grep -q 'behind 1'
git log --oneline main..origin/main | grep -q 'VLAN 20'
git pull -q
grep -q 'vlan 20' switch.cfg

say "semver tags and filtering"
git tag -a v1.0.0 -m "First stable release"
git tag v1.1.0 && git tag v1.10.0 && git tag v1.2.0 && git tag v2.0.0-rc.1 && git tag v2.0.0
git tag -l 'v1.*' | grep -q v1.10.0
[ "$(git tag -l 'v1.*' | sort -V | tail -1)" = "v1.10.0" ]
# Default version sort ranks the pre-release ABOVE the final release
[ "$(git tag -l --sort=-v:refname | head -1)" = "v2.0.0-rc.1" ]
git config versionsort.suffix -
[ "$(git tag -l --sort=-v:refname | head -1)" = "v2.0.0" ]
# Stable releases only: exclude anything with a pre-release suffix
[ "$(git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -c rc || true)" = "0" ]
git describe --tags --abbrev=0 >/dev/null
git push -q origin --tags
git tag v1.2.1 && git push -q origin v1.2.1
git ls-remote --tags origin | grep -q v1.2.1

say "branching"
git switch -q -c feature/NET-142-ntp-servers
printf 'ntp server 10.0.0.1\n' >> switch.cfg && git commit -qam "feat(ntp): add NTP servers"
git push -q -u origin feature/NET-142-ntp-servers
git switch -q main
git merge -q --no-ff feature/NET-142-ntp-servers -m "Merge feature/NET-142-ntp-servers"
git branch -d feature/NET-142-ntp-servers >/dev/null
git switch -q -c release/2.1 main
printf '# fix\n' >> switch.cfg && git commit -qam "fix: correct banner"
git tag v2.1.0
git switch -q main && git cherry-pick -x release/2.1 >/dev/null
git branch --list 'release/*' | grep -q 'release/2.1'

say "hooks: pre-commit secret scan and commit-msg format"
cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/sh
# Block commits that stage something shaped like an AWS access key ID
if git diff --cached -U0 | grep -E '^\+.*AKIA[0-9A-Z]{16}' >/dev/null; then
  echo "pre-commit: possible AWS access key in staged changes" >&2
  exit 1
fi
HOOK
cat > .git/hooks/commit-msg <<'HOOK'
#!/bin/sh
# Enforce Conventional Commits: type(optional scope): summary
pattern='^(feat|fix|docs|chore|refactor|test|ci)(\([a-z0-9-]+\))?!?: .{1,72}$'
if ! head -1 "$1" | grep -Eq "$pattern"; then
  echo "commit-msg: use 'type(scope): summary', e.g. 'fix(dns): correct TTL'" >&2
  exit 1
fi
HOOK
chmod +x .git/hooks/pre-commit .git/hooks/commit-msg
echo 'aws_key = AKIAIOSFODNN7EXAMPLE' > creds.ini && git add creds.ini
if git commit -qm "chore: add creds" 2>/dev/null; then echo "secret hook FAILED to block"; exit 1; fi
git rm -q --cached creds.ini && rm creds.ini
echo 'ok' > notes.txt && git add notes.txt
if git commit -qm "updated stuff" 2>/dev/null; then echo "msg hook FAILED to block"; exit 1; fi
git commit -qm "docs: add operator notes"
git commit --no-verify -q --allow-empty -m "bypass" && git reset -q --soft HEAD~1

say "core.hooksPath for shared hooks"
mkdir -p .githooks && cp .git/hooks/commit-msg .githooks/ && git config core.hooksPath .githooks
[ "$(git config core.hooksPath)" = ".githooks" ]

echo; echo "ALL 1.2 COMMANDS PASSED"
