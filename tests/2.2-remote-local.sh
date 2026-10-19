#!/usr/bin/env bash
# Verifies the 2.2 Remote and Local Automation notes:
#   SSH-based remote execution with Ansible against a container,
#   a WinRM inventory (validated statically: no Windows host here),
#   bash job control under a pseudo-terminal, and PowerShell jobs.
# Needs: docker, openssh-client, ansible-core, pywinrm (pip install pywinrm), pwsh,
#        script (util-linux). Uses 127.0.0.1:18250 and container ao-d-ssh.
set -euo pipefail
WORK=$(mktemp -d)
CT=ao-d-ssh
IMG=ao-d-ssh-img
cleanup() {
  docker rm -f "$CT" >/dev/null 2>&1 || true
  docker rmi -f "$IMG" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"
export ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_NOCOLOR=1
export ANSIBLE_LOCAL_TEMP="$WORK/.ansible-tmp" ANSIBLE_HOME="$WORK/.ansible"
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

say "SSH target container"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/id_ed25519"
mkdir img && cp id_ed25519.pub img/key.pub
# Behind an egress proxy, give the build the proxy CA (empty otherwise)
: > img/extra-ca.crt
[ -n "${SSL_CERT_FILE:-}" ] && cp "$SSL_CERT_FILE" img/extra-ca.crt
[ -f /root/.ccr/ca-bundle.crt ] && cp /root/.ccr/ca-bundle.crt img/extra-ca.crt
cat > img/Dockerfile <<'DOCKER'
FROM alpine:3.20
COPY extra-ca.crt /tmp/extra-ca.crt
RUN cat /tmp/extra-ca.crt >> /etc/ssl/certs/ca-certificates.crt \
 && apk add --no-cache openssh-server python3 \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh netops && passwd -u netops \
 && mkdir -p /home/netops/.ssh
COPY key.pub /home/netops/.ssh/authorized_keys
RUN chown -R netops /home/netops/.ssh \
 && chmod 700 /home/netops/.ssh \
 && chmod 600 /home/netops/.ssh/authorized_keys
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKER
docker build -q --network host --build-arg HTTPS_PROXY \
  -t "$IMG" img >/dev/null
docker run -d --name "$CT" --hostname lab-srv1 \
  -p 127.0.0.1:18250:22 "$IMG" >/dev/null
for _ in $(seq 1 30); do
  ssh-keyscan -p 18250 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5
done

say "plain ssh with a per-project config"
cat > ssh_config <<'CFG'
Host lab-srv1
  HostName 127.0.0.1
  Port 18250
  User netops
  IdentityFile ./id_ed25519
  BatchMode yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ./known_hosts
CFG
out=$(ssh -F ssh_config lab-srv1 'uname -n; id -un' 2>/dev/null)
echo "$out"
[ "$out" = "$(printf 'lab-srv1\nnetops')" ] || fail "ssh"
out=$(ssh -F ssh_config -o User=root lab-srv1 true 2>&1 || true)
echo "$out"
grep -q 'Permission denied (publickey' <<<"$out" || fail "batchmode"

cat > inventory.ini <<'INI'
[linux]
lab-srv1 ansible_host=127.0.0.1 ansible_port=18250

[linux:vars]
ansible_user=netops
ansible_connection=ssh
ansible_python_interpreter=/usr/bin/python3
INI
export ANSIBLE_PRIVATE_KEY_FILE="$WORK/id_ed25519"

say "ansible -m ping over SSH"
out=$(ansible linux -i inventory.ini -m ping)
echo "$out"
grep -q 'lab-srv1 | SUCCESS' <<<"$out" || fail "ping"
grep -q '"ping": "pong"' <<<"$out" || fail "pong"

say "ad hoc command over SSH"
out=$(ansible linux -i inventory.ini -a "uname -n")
echo "$out"
grep -q 'lab-srv1 | CHANGED | rc=0 >>' <<<"$out" || fail "uname"
grep -qx 'lab-srv1' <<<"$out" || fail "hostname"

say "verbose run shows the SSH transport"
out=$(ansible linux -i inventory.ini -m ping -vvv 2>&1)
grep -m1 'ESTABLISH SSH CONNECTION' <<<"$out"
grep -q 'ESTABLISH SSH CONNECTION FOR USER: netops' <<<"$out" || fail "ssh"
grep -q 'PUT .*AnsiballZ_ping.py' <<<"$out" || fail "module copy"
grep -m1 -o 'PUT .*AnsiballZ_ping.py' <<<"$out" | sed 's|/[^ ]*/|.../|g'

say "local connection: same module, no network"
out=$(ansible localhost -c local -m ping 2>/dev/null)
echo "$out"
grep -q 'localhost | SUCCESS' <<<"$out" || fail "local"

say "WinRM inventory (static: no Windows host available)"
cat > windows.yml <<'YML'
windows:
  hosts:
    win-dc1:
      ansible_host: win-dc1.corp.example.com
  vars:
    ansible_connection: winrm
    ansible_port: 5986
    ansible_winrm_scheme: https
    ansible_winrm_transport: kerberos
YML
out=$(ansible-inventory -i windows.yml --host win-dc1)
echo "$out"
[ "$(jq -r .ansible_connection <<<"$out")" = winrm ] || fail "winrm"
[ "$(jq -r .ansible_port <<<"$out")" = 5986 ] || fail "5986"
ansible-doc -t connection winrm | grep -q 'port' || fail "winrm doc"
ansible-doc -t connection winrm -j \
  | jq -e '.winrm.doc.options.port.default == 5986' >/dev/null \
  || fail "winrm default port"

say "bash job control (interactive shell in a pty)"
cat > poll-switches.sh <<'SH'
#!/bin/sh
while true; do sleep 5; done
SH
chmod +x poll-switches.sh
cat > session.txt <<'TXT'
./poll-switches.sh &
jobs
kill -STOP %1
sleep 0.3
bg %1
jobs
sleep 1 &
fg %2
kill %1
sleep 0.3
nohup ./poll-switches.sh >poll.log 2>&1 &
disown %1
jobs
kill $!
exit
TXT
# Type one line every 0.5 s, as a person would, into an interactive bash
raw=$( (while IFS= read -r line; do printf '%s\n' "$line"; sleep 0.5; done \
  < session.txt) | timeout 60 script -q -c "bash --norc --noprofile -i" \
  /dev/null || true)
# Each prompt is followed by the echoed command, then its output
clean=$(printf '%s' "$raw" | python3 -c '
import re, sys
text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", sys.stdin.read())
text = text.replace("\r", "")
for part in re.split(r"bash-[0-9.]+[#$] ", text)[1:]:
    lines = [ln for ln in part.splitlines() if ln.strip()]
    if not lines or lines[0] == "exit":
        continue
    if not lines[0].startswith(("sleep 0", "kill $!")):
        print("$ " + lines[0])
    for line in lines[1:]:
        print(line)
')
echo "$clean"
grep -Eq '^\[1\] [0-9]+$' <<<"$clean" || fail "job start"
grep -q '^\[1\]+  Running .*\./poll-switches.sh &$' <<<"$clean" || fail running
[ "$(grep -c '^\[1\]+  Running' <<<"$clean")" = 2 ] || fail "running after bg"
grep -q '^\[1\]+  Stopped .*\./poll-switches.sh$' <<<"$clean" || fail stopped
grep -q '^\[1\]+ \./poll-switches.sh &$' <<<"$clean" || fail bg
grep -qx 'sleep 1' <<<"$clean" || fail fg
grep -A1 '^\$ nohup' <<<"$clean" | grep -Eq '^\[1\] [0-9]+$' || fail nohup
[ "$(tail -1 <<<"$clean")" = '$ jobs' ] || fail "disown left a job"
[ ! -e nohup.out ] || fail "output was redirected, so no nohup.out"

say "PowerShell background job"
cat > backup-job.ps1 <<'PS1'
Start-Job -Name backup -ScriptBlock {
    Start-Sleep -Seconds 2
    "Saved 14 configs"
} | Out-Null
Get-Job | Format-Table Id, Name, State
Receive-Job -Name backup -Wait -AutoRemoveJob
PS1
# TERM=dumb: plain table output when stdout is not a terminal
out=$(TERM=dumb pwsh -File backup-job.ps1)
echo "$out"
grep -Eq '^ *[0-9]+ backup Running' <<<"$out" || fail "job running"
grep -q '^Saved 14 configs$' <<<"$out" || fail "receive"

echo
echo "ALL 2.2 REMOTE-LOCAL CHECKS PASSED"
