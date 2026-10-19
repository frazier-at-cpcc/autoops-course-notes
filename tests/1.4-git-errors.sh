#!/usr/bin/env bash
# Verifies every command and output shown in 1.4-git-errors.md
# Needs: docker (pulls gitea/gitea:1.22.6, which also supplies the git and
#        OpenSSH client used for the authentication examples)
# Uses 127.0.0.1:18150 for the Gitea web/API port, containers and a network
# named ao-b-*, and fixed commit dates so commit IDs match the notes.
set -euo pipefail
WORK=$(mktemp -d)
IMG=gitea/gitea:1.22.6
NET=ao-b-net-git
SRV=ao-b-gitea
CLI=ao-b-gitclient
cleanup() {
  docker rm -f "$SRV" "$CLI" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"   # never touch the real ~/.gitconfig
export GIT_CONFIG_NOSYSTEM=1 GIT_PAGER=cat
export GIT_AUTHOR_DATE="2026-10-05T09:00:00Z" GIT_COMMITTER_DATE="2026-10-05T09:00:00Z"
git config --global user.name "Ada Admin"
git config --global user.email "ada@example.com"
git config --global init.defaultBranch main
git config --global advice.detachedHead true

say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
# ssh ends its error lines with CRLF; strip the CR so line matches work.
expect_fail() {
  set +e; out=$("$@" 2>&1); rc=$?; set -e
  out=${out//$'\r'/}; echo "$out"; echo "(exit $rc)"
}

# ------------------------------------------------------------------
say "Merge conflict: two branches change the same line"
git init -q netconfig && cd netconfig
printf 'hostname core-sw1\nntp server 10.0.0.1\nlogging host 10.0.0.50\n' > switch.cfg
git add switch.cfg && git commit -qm "feat: baseline config"
git tag v1.0.0
git switch -q -c feature/ntp
sed -i 's/ntp server 10.0.0.1/ntp server 10.0.0.2/' switch.cfg
git commit -qam "fix(ntp): use new NTP server"
git switch -q main
sed -i 's/ntp server 10.0.0.1/ntp server 10.0.0.3/' switch.cfg
git commit -qam "fix(ntp): use regional NTP server"
expect_fail git merge feature/ntp
[ "$rc" = "1" ] || fail "merge rc"
grep -q "^CONFLICT (content): Merge conflict in switch.cfg$" <<<"$out" || fail "conflict line"
grep -q "^Automatic merge failed; fix conflicts and then commit the result.$" <<<"$out" || fail "auto merge failed"
st=$(git status); echo "$st"
grep -q "You have unmerged paths." <<<"$st" || fail "unmerged"
grep -Eq "both modified: +switch.cfg" <<<"$st" || fail "both modified"
git status --short | grep -q '^UU switch.cfg$' || fail "UU"
cat switch.cfg
[ "$(cat switch.cfg)" = "$(printf 'hostname core-sw1\n<<<<<<< HEAD\nntp server 10.0.0.3\n=======\nntp server 10.0.0.2\n>>>>>>> feature/ntp\nlogging host 10.0.0.50')" ] \
  || fail "markers"

expect_fail git diff --check
[ "$rc" = "2" ] || fail "diff --check rc"
grep -q "^switch.cfg:2: leftover conflict marker$" <<<"$out" || fail "diff --check marker"

say "Abort puts everything back"
git merge --abort
git status --short | grep -q . && fail "abort should leave a clean tree"
grep -q '<<<<<<<' switch.cfg && fail "markers after abort"

say "zdiff3 shows the common ancestor too"
git config merge.conflictStyle zdiff3
git merge feature/ntp >/dev/null 2>&1 || true
cat switch.cfg
grep -q '^||||||| ' switch.cfg || fail "zdiff3 base marker"
grep -qx 'ntp server 10.0.0.1' switch.cfg || fail "zdiff3 base content"

say "Resolve: edit, add, commit"
printf 'hostname core-sw1\nntp server 10.0.0.3\nntp server 10.0.0.2\nlogging host 10.0.0.50\n' > switch.cfg
grep -q -E '^(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)' switch.cfg && fail "markers left"
git add switch.cfg
git commit -q --no-edit
out=$(git log --oneline --graph); echo "$out"
[ "$out" = "$(printf '%s\n' "*   0917bc4 Merge branch 'feature/ntp'" '|\  ' '| * d651f7b fix(ntp): use new NTP server' '* | 57ca5a0 fix(ntp): use regional NTP server' '|/  ' '* 309f3f2 feat: baseline config')" ] \
  || fail "merge graph (commit IDs changed?)"
git status --short | grep -q . && fail "tree should be clean"
git config --unset merge.conflictStyle

say "Choosing one whole side with --ours / --theirs"
git switch -q -c feature/syslog v1.0.0
sed -i 's/10.0.0.50/10.0.0.51/' switch.cfg && git commit -qam "fix: move syslog"
git switch -q main
sed -i 's/10.0.0.50/10.0.0.52/' switch.cfg && git commit -qam "fix: move syslog again"
git merge feature/syslog >/dev/null 2>&1 || true
git checkout --theirs switch.cfg
grep -qx 'logging host 10.0.0.51' switch.cfg || fail "--theirs"
git add switch.cfg && git commit -q --no-edit

# ------------------------------------------------------------------
say "Detached HEAD: check out a tag"
expect_fail git checkout v1.0.0
[ "$rc" = "0" ] || fail "checkout tag"
grep -q "You are in 'detached HEAD' state." <<<"$out" || fail "detached msg"
grep -q "HEAD is now at 309f3f2 feat: baseline config" <<<"$out" || fail "detached head id (commit IDs changed?)"
out=$(git status); echo "$out"
[ "$(head -1 <<<"$out")" = "HEAD detached at v1.0.0" ] || fail "status detached"
[ "$(git branch --show-current)" = "" ] || fail "no current branch"
git branch | grep -qx '\* (HEAD detached at v1.0.0)' || fail "git branch detached"

say "Commit while detached, then try to push"
git init -q --bare ../origin.git
git remote add origin ../origin.git
echo "banner motd ^Authorized access only^" >> switch.cfg
out=$(git commit -am "fix: add login banner"); echo "$out"
grep -q '^\[detached HEAD bc51973\] fix: add login banner$' <<<"$out" || fail "detached commit id"
expect_fail git push origin
[ "$rc" = "128" ] || fail "push rc"
grep -q "^fatal: You are not currently on a branch.$" <<<"$out" || fail "push not on branch"

say "Switch away: Git warns about the orphaned commit"
expect_fail git switch main
grep -q "Warning: you are leaving 1 commit behind, not connected to" <<<"$out" || fail "leaving warning"
grep -q "git branch <new-branch-name> bc51973" <<<"$out" || fail "rescue hint"

say "Recover it from the reflog"
out=$(git reflog -3); echo "$out"
grep -q "^bc51973 HEAD@{1}: commit: fix: add login banner$" <<<"$out" || fail "reflog"
git branch hotfix/banner bc51973
git log --oneline -1 hotfix/banner | grep -q "bc51973 fix: add login banner" || fail "rescued"
git push -q -u origin hotfix/banner
git ls-remote --heads origin | grep -q refs/heads/hotfix/banner || fail "pushed"

say "Detach on purpose, then make a branch before committing"
git switch -q --detach v1.0.0
git switch -q -c hotfix/ntp
[ "$(git branch --show-current)" = "hotfix/ntp" ] || fail "switch -c from detached"
cd "$WORK"

# ------------------------------------------------------------------
say "Authentication: start a private Gitea server"
docker rm -f "$SRV" "$CLI" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null
docker run -d --name "$SRV" --network "$NET" --network-alias git.corp.example \
  -p 127.0.0.1:18150:3000 \
  -e GITEA__security__INSTALL_LOCK=true \
  -e GITEA__database__DB_TYPE=sqlite3 \
  -e GITEA__server__DOMAIN=git.corp.example \
  -e GITEA__server__SSH_DOMAIN=git.corp.example \
  -e GITEA__server__ROOT_URL=http://git.corp.example:3000/ \
  -e GITEA__service__DISABLE_REGISTRATION=true \
  -e GITEA__log__LEVEL=Warn \
  "$IMG" >/dev/null
for _ in $(seq 1 90); do curl -sf http://127.0.0.1:18150/api/healthz >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:18150/api/healthz >/dev/null || fail "gitea did not start"
PW='Lab-Only-Passw0rd'
API=http://127.0.0.1:18150/api/v1
docker exec -u git "$SRV" gitea admin user create --username ada --password "$PW" \
  --email ada@example.com --admin --must-change-password=false >/dev/null
curl -sf -u "ada:$PW" -H 'Content-Type: application/json' \
  -d '{"name":"netconfig","private":true,"auto_init":true,"default_branch":"main"}' \
  "$API/user/repos" >/dev/null
new_token() {
  curl -sf -u "ada:$PW" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$1\",\"scopes\":[\"write:repository\"]}" \
    "$API/users/ada/tokens" | jq -r .sha1
}
TOKEN1=$(new_token laptop-2026q3)
[ "${#TOKEN1}" = "40" ] || fail "token"

# The client is a second container from the same image (git + OpenSSH client)
docker run -d --name "$CLI" --network "$NET" --entrypoint sleep \
  -e GIT_TERMINAL_PROMPT=0 -e GIT_CONFIG_NOSYSTEM=1 -w /root "$IMG" 900 >/dev/null
c() { docker exec "$CLI" sh -c "$1"; }
c 'git config --global user.name "Ada Admin" && git config --global user.email ada@example.com'
REPO_HTTP=http://git.corp.example:3000/ada/netconfig.git
REPO_SSH=git@git.corp.example:ada/netconfig.git

say "HTTPS-style auth: no credentials and no prompt (what a CI job sees)"
expect_fail c "git clone $REPO_HTTP nocreds"
grep -q "^fatal: could not read Username for 'http://git.corp.example:3000': terminal prompts disabled$" <<<"$out" \
  || fail "no creds"

say "Wrong password or token"
expect_fail c "git clone http://ada:WrongToken@git.corp.example:3000/ada/netconfig.git bad"
grep -q "^fatal: Authentication failed for '$REPO_HTTP/'$" <<<"$out" || fail "bad creds"

say "A stored token works, until it is revoked"
c "git config --global credential.helper store"
c "printf 'http://ada:%s@git.corp.example:3000\n' $TOKEN1 > ~/.git-credentials && chmod 600 ~/.git-credentials"
c "git clone -q $REPO_HTTP netconfig"
curl -sf -u "ada:$PW" -X DELETE "$API/users/ada/tokens/laptop-2026q3" >/dev/null
expect_fail c "cd netconfig && git pull"
[ "$rc" = "1" ] || fail "pull rc"
grep -q "^remote: Verify$" <<<"$out" || fail "gitea remote line"
grep -q "^fatal: Authentication failed for '$REPO_HTTP/'$" <<<"$out" || fail "revoked"

say "Fix: drop the stale credential, store the new token"
TOKEN2=$(new_token laptop-2026q4)
c "printf 'protocol=http\nhost=git.corp.example:3000\n\n' | git credential reject"
c "grep -c . ~/.git-credentials || true" | grep -qx 0 || fail "credential reject"
c "printf 'http://ada:%s@git.corp.example:3000\n' $TOKEN2 > ~/.git-credentials"
c "cd netconfig && git pull -q" || fail "pull with new token"

say "SSH: unknown host key in a non-interactive session"
c "ssh-keygen -q -t ed25519 -N '' -C ada@laptop -f ~/.ssh/id_ed25519"
expect_fail c "ssh -o BatchMode=yes -T git@git.corp.example"
grep -q "^Host key verification failed.$" <<<"$out" || fail "host key"
expect_fail c "git clone $REPO_SSH viassh"
grep -q "^Host key verification failed.$" <<<"$out" || fail "host key via git"
grep -q "^fatal: Could not read from remote repository.$" <<<"$out" || fail "could not read"

say "SSH: host trusted, but the public key is not registered"
c "ssh-keyscan -t ed25519 git.corp.example 2>/dev/null >> ~/.ssh/known_hosts"
expect_fail c "ssh -T git@git.corp.example"
[ "$rc" = "255" ] || fail "ssh rc"
grep -q "^git@git.corp.example: Permission denied (publickey).$" <<<"$out" || fail "publickey"
expect_fail c "git clone $REPO_SSH viassh"
grep -q "^git@git.corp.example: Permission denied (publickey).$" <<<"$out" || fail "publickey via git"
grep -q "Please make sure you have the correct access rights" <<<"$out" || fail "access rights"

say "SSH: register the public key, then test"
PUB=$(c "cat ~/.ssh/id_ed25519.pub")
curl -sf -u "ada:$PW" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg k "$PUB" '{title:"laptop",key:$k}')" "$API/user/keys" >/dev/null
expect_fail c "ssh -T git@git.corp.example"
[ "$rc" = "0" ] || fail "ssh ok rc"
grep -q "^Hi there, ada! You've successfully authenticated with the key named laptop, but Gitea does not provide shell access.$" <<<"$out" || fail "ssh greeting"
c "git clone -q $REPO_SSH viassh" || fail "ssh clone"
c "cd viassh && git remote -v" | grep -q "^origin	$REPO_SSH (fetch)$" || fail "ssh remote"

say "SSH: private key readable by others is refused"
c "chmod 644 ~/.ssh/id_ed25519"
expect_fail c "ssh -T git@git.corp.example"
grep -q "WARNING: UNPROTECTED PRIVATE KEY FILE!" <<<"$out" || fail "unprotected"
grep -q "Permissions 0644 for '/root/.ssh/id_ed25519' are too open." <<<"$out" || fail "too open"
c "chmod 600 ~/.ssh/id_ed25519"

say "Switch an existing clone from HTTPS to SSH"
c "cd netconfig && git remote set-url origin $REPO_SSH && git fetch -q && git remote get-url origin" \
  | grep -qx "$REPO_SSH" || fail "set-url"

echo; echo "ALL 1.4 GIT ERRORS CHECKS PASSED"
