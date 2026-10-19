#!/usr/bin/env bash
# Verifies every command and output shown in 2.4-troubleshooting-configuration.md:
# API communication failures, an agent that cannot reach its server,
# application failures (systemd unit, containers, reverse proxy 5xx), and
# certificate failures against local openssl s_server instances.
# Needs: docker (privileged containers for the systemd demo; images
#   nginx:1.27-alpine, zabbix/zabbix-agent2:alpine-7.0-latest, and an Ubuntu
#   24.04 image with systemd that this script builds as ao-e-systemd),
#   curl, openssl
# Ports: 127.0.0.1:18310-18335 only. Containers: ao-e-*.
# shellcheck disable=SC2016  # commands are single-quoted on purpose: t() prints, then evals them
set -euo pipefail
WORK=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  docker rm -f ao-e-web ao-e-proxy ao-e-zbx ao-e-zbx2 ao-e-app ao-e-kill >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"
# Local test hosts bypass any configured proxy; trust only what we pass in
export NO_PROXY='127.0.0.1,localhost,.invalid' no_proxy='127.0.0.1,localhost,.invalid'
unset CURL_CA_BUNDLE SSL_CERT_FILE

t() {
  printf '$ %s\n' "$1"
  RC=0; OUT=$(eval "$1" 2>&1) || RC=$?
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  return 0
}
has() { grep -Eq -- "$1" <<<"$OUT" || { echo "FAIL: expected /$1/"; exit 1; }; }
say() { printf '\n== %s\n' "$*"; }
bg() { "$@" >/dev/null 2>&1 & PIDS+=($!); }
wait_port() { for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0; sleep 0.1; done; echo "port $1 never opened"; exit 1; }

say "API communication: DNS, refused, timeout, proxy"
t 'curl -sS http://inv.lab.invalid:18300/'
has '^curl: \(6\) Could not resolve host: inv.lab.invalid$'; [ "$RC" = 6 ]
t 'getent hosts inv.lab.invalid; echo "exit=$?"'
has '^exit=2$'
t 'curl -sS http://127.0.0.1:18319/'
has "^curl: \(7\) Failed to connect to 127.0.0.1 port 18319 after [0-9]+ ms: Couldn't connect to server$"; [ "$RC" = 7 ]
# A listener that completes the TCP handshake but never answers (hung app)
cat > hang.py <<'PY'
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
conns = []
while True:
    c, _ = s.accept(); conns.append(c)   # accept, read nothing, say nothing
PY
bg python3 hang.py 18318; wait_port 18318
t 'curl -sS -m 3 http://127.0.0.1:18318/'
has '^curl: \(28\) Operation timed out after 30[0-9][0-9] milliseconds with 0 bytes received$'; [ "$RC" = 28 ]
# A proxy that demands credentials
cat > proxy.py <<'PY'
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
class P(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_CONNECT(self):
        self.send_response(407, "Proxy Authentication Required")
        self.send_header("Proxy-Authenticate", 'Basic realm="corp-proxy"')
        self.send_header("Content-Length", "0"); self.end_headers()
HTTPServer(("127.0.0.1", int(sys.argv[1])), P).serve_forever()
PY
bg python3 proxy.py 18317; wait_port 18317
t 'https_proxy=http://127.0.0.1:18317 curl -sS https://api.example.com/'
has '^curl: \(56\) CONNECT tunnel failed, response 407$'; [ "$RC" = 56 ]

say "Agent communication: Zabbix agent 2 that cannot reach its server"
docker image inspect zabbix/zabbix-agent2:alpine-7.0-latest >/dev/null 2>&1 ||
  docker pull -q zabbix/zabbix-agent2:alpine-7.0-latest >/dev/null
docker run -d --name ao-e-zbx --network host -e ZBX_HOSTNAME=edge-sw-mon \
  -e ZBX_LISTENPORT=18316 -e ZBX_SERVER_HOST=zbx.lab.invalid \
  zabbix/zabbix-agent2:alpine-7.0-latest >/dev/null
docker run -d --name ao-e-zbx2 --network host -e ZBX_HOSTNAME=edge-sw-mon \
  -e ZBX_LISTENPORT=18315 -e ZBX_SERVER_HOST=127.0.0.1 \
  zabbix/zabbix-agent2:alpine-7.0-latest >/dev/null
for _ in $(seq 40); do
  docker logs ao-e-zbx 2>&1 | grep -q 'started to fail' &&
    docker logs ao-e-zbx2 2>&1 | grep -q 'started to fail' && break
  sleep 0.5
done
t 'docker logs ao-e-zbx 2>&1 | grep -m2 -E "cannot connect|started to fail"'
has 'cannot connect to \[zbx.lab.invalid:10051\]: dial tcp: lookup zbx.lab.invalid .*no such host'
has 'active check configuration update from host \[edge-sw-mon\] started to fail'
t 'docker logs ao-e-zbx2 2>&1 | grep -m1 "cannot connect"'
has 'cannot connect to \[127.0.0.1:10051\]: dial tcp .*127.0.0.1:10051: connect: connection refused'
docker rm -f ao-e-zbx ao-e-zbx2 >/dev/null

say "Application failure: a systemd service"
cat > Dockerfile <<'DOCKER'
FROM mirror.gcr.io/library/ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      --no-install-recommends systemd systemd-sysv python3 \
 && rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
DOCKER
docker build -q -t ao-e-systemd . >/dev/null
docker run -d --name ao-e-app --hostname app01 --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  ao-e-systemd >/dev/null
for _ in $(seq 50); do
  s=$(docker exec ao-e-app systemctl is-system-running 2>/dev/null || true)
  case $s in running|degraded) break ;; esac; sleep 0.2
done
app() { docker exec -i ao-e-app "$@"; }
# tc "cmd": like t, but the command runs on app01 (inside the container)
tc() {
  printf '$ %s\n' "$1"
  RC=0; OUT=$(docker exec -e SYSTEMD_COLORS=0 ao-e-app bash -c "$1" 2>&1) || RC=$?
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  return 0
}
app mkdir -p /opt/invsync /etc/invsync /srv/inv
app tee /opt/invsync/agent.py >/dev/null <<'PY'
"""Inventory sync agent: checks in with the inventory server."""
import json, sys, time, urllib.request
cfg = json.load(open("/etc/invsync/agent.json"))
while True:
    try:
        urllib.request.urlopen(cfg["server"] + "/health", timeout=3)
        print("checked in with", cfg["server"], flush=True)
    except OSError as e:
        print(f"cannot reach {cfg['server']}: {e}", file=sys.stderr, flush=True)
    time.sleep(cfg.get("interval", 5))
PY
app tee /etc/systemd/system/invsync.service >/dev/null <<'UNIT'
[Unit]
Description=Inventory sync agent
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/invsync/agent.py
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT
# Broken config: trailing comma
app tee /etc/invsync/agent.json >/dev/null <<'JSON'
{
  "server": "http://inv.lab.invalid:8080",
  "interval": 5,
}
JSON
app systemctl daemon-reload
app systemctl enable --now invsync 2>/dev/null
sleep 8   # five quick failures trip the start limit (StartLimitBurst=5 per 10 s)
tc 'systemctl status invsync --no-pager'
has 'Active: failed \(Result: exit-code\)'; has 'status=1/FAILURE'; has "Failed with result 'exit-code'"
tc 'journalctl -u invsync -o cat --no-pager | grep -E "Error|repeated" | tail -2'
has 'json.decoder.JSONDecodeError: Expecting property name enclosed in double quotes: line 4 column 1 \(char 62\)'
has 'Start request repeated too quickly'
tc 'systemctl show invsync -p NRestarts -p ExecMainStatus'
has '^NRestarts=5$'; has '^ExecMainStatus=1$'
# Fix the JSON; now the service runs but cannot reach its server
app tee /etc/invsync/agent.json >/dev/null <<'JSON'
{
  "server": "http://inv.lab.invalid:8080",
  "interval": 5
}
JSON
app systemctl reset-failed invsync
app systemctl restart invsync
sleep 2
tc 'systemctl is-active invsync'
has '^active$'
tc 'journalctl -u invsync -n 1 --no-pager -o cat'
has 'cannot reach http://inv.lab.invalid:8080: <urlopen error \[Errno -2\] Name or service not known>'
# Point it at a server that answers
app touch /srv/inv/health
app systemd-run -q --unit inv-api python3 -m http.server 8080 --bind 127.0.0.1 --directory /srv/inv
app sed -i 's#inv.lab.invalid#127.0.0.1#' /etc/invsync/agent.json
app systemctl restart invsync
sleep 2
tc 'journalctl -u invsync -n 1 --no-pager -o cat'
has '^checked in with http://127.0.0.1:8080$'
docker rm -f ao-e-app >/dev/null

say "Application failure: containers and exit codes"
cat > bad.conf <<'NGINX'
server {
    listen 127.0.0.1:18313;
    location / {
        proxy_pas http://127.0.0.1:18312;
    }
}
NGINX
docker run -d --name ao-e-web --network host \
  -v "$PWD/bad.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null
for _ in $(seq 30); do [ "$(docker inspect -f '{{.State.Status}}' ao-e-web)" = exited ] && break; sleep 0.2; done
t 'docker ps -a --filter name=ao-e-web --format "{{.Names}}: {{.Status}}"'
has '^ao-e-web: Exited \(1\) '
t 'docker logs ao-e-web 2>&1 | tail -1'
has 'nginx: \[emerg\] unknown directive "proxy_pas" in /etc/nginx/conf.d/default.conf:4'
t 'docker inspect -f "{{.State.ExitCode}}" ao-e-web'
has '^1$'
docker rm -f ao-e-web >/dev/null
t 'docker run --rm -v "$PWD/bad.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine nginx -t'
has 'configuration file /etc/nginx/nginx.conf test failed'; [ "$RC" = 1 ]
t 'docker run --rm alpine:3.20 inventory-sync 2>&1 | grep -o "exec:.*"'
has '^exec: "inventory-sync": executable file not found in \$PATH$'
t 'docker run --rm alpine:3.20 inventory-sync 2>/dev/null; echo "exit=$?"'
has '^exit=127$'
docker run -d --name ao-e-kill alpine:3.20 sleep 300 >/dev/null
docker kill ao-e-kill >/dev/null
t 'docker inspect -f "{{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}" ao-e-kill'
has '^137 OOMKilled=false$'
docker rm -f ao-e-kill >/dev/null

say "Application failure: 502 and 504 from a reverse proxy"
cat > slow.py <<'PY'
import sys, time
from http.server import HTTPServer, BaseHTTPRequestHandler
class S(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        time.sleep(5)
        self.send_response(200); self.send_header("Content-Length", "3")
        self.end_headers(); self.wfile.write(b"ok\n")
HTTPServer(("127.0.0.1", int(sys.argv[1])), S).serve_forever()
PY
bg python3 slow.py 18311; wait_port 18311
cat > proxy.conf <<'NGINX'
server {
    listen 127.0.0.1:18310;
    location /down/ { proxy_pass http://127.0.0.1:18312/; }
    location /slow/ {
        proxy_pass http://127.0.0.1:18311/;
        proxy_read_timeout 2s;
    }
}
NGINX
docker run -d --name ao-e-proxy --network host \
  -v "$PWD/proxy.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null
wait_port 18310
printf '$ %s\n' 'P=http://127.0.0.1:18310'; export P=http://127.0.0.1:18310
t 'curl -s -o /dev/null -w "%{http_code}\n" $P/down/'
has '^502$'
start=$(date +%s)
t 'curl -s -o /dev/null -w "%{http_code}\n" $P/slow/'
has '^504$'
[ $(( $(date +%s) - start )) -lt 5 ] || { echo "FAIL: 504 should arrive after the 2 s proxy timeout"; exit 1; }
t 'docker logs ao-e-proxy 2>&1 | grep -oE "(connect\(\) failed|upstream timed out) \([0-9]+: [^)]*\)"'
has 'connect\(\) failed \(111: Connection refused\)'; has 'upstream timed out \(110: (Operation|Connection) timed out\)'
docker rm -f ao-e-proxy >/dev/null

say "Certificates: build a lab CA, then break TLS four ways"
q() { "$@" >/dev/null 2>&1; }
q openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout root.key -out root.pem -days 3650 -subj "/CN=Lab Root CA" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
q openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout int.key -out int.csr -subj "/CN=Lab Issuing CA"
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > int.ext
q openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial \
  -days 1825 -extfile int.ext -out int.pem
q openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout api.key -out api.csr -subj "/CN=api.lab.test"
printf 'subjectAltName=DNS:api.lab.test,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > leaf.ext
q openssl x509 -req -in api.csr -CA int.pem -CAkey int.key -CAcreateserial \
  -days 90 -extfile leaf.ext -out api.pem
cat api.pem int.pem > fullchain.pem
# Expired leaf: openssl ca can set explicit validity dates in the past
mkdir ca && touch ca/index.txt && echo 1000 > ca/serial
cat > ca.cnf <<'CNF'
[ca]
default_ca = lab
[lab]
dir = ./ca
database = $dir/index.txt
serial = $dir/serial
new_certs_dir = $dir
certificate = int.pem
private_key = int.key
default_md = sha256
policy = any
[any]
commonName = supplied
[leaf]
subjectAltName = DNS:api.lab.test,IP:127.0.0.1
extendedKeyUsage = serverAuth
CNF
q openssl ca -batch -config ca.cnf -extensions leaf -notext \
  -startdate 20250101000000Z -enddate 20250401000000Z -in api.csr -out old.pem
# Self-signed leaf
q openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout self.key -out self.pem -days 30 -subj "/CN=api.lab.test" \
  -addext subjectAltName=DNS:api.lab.test,IP:127.0.0.1
srv() { bg openssl s_server -accept "127.0.0.1:$1" -www -quiet "${@:2}"; wait_port "$1"; }
srv 18320 -cert api.pem -key api.key -cert_chain int.pem   # correct: leaf + intermediate
srv 18321 -cert api.pem -key api.key                       # incomplete chain
srv 18322 -cert old.pem -key api.key -cert_chain int.pem   # expired
srv 18323 -cert self.pem -key self.key                     # self-signed

t 'openssl x509 -in api.pem -noout -subject -issuer -enddate -ext subjectAltName'
has '^subject=CN = api.lab.test$'; has '^issuer=CN = Lab Issuing CA$'; has 'DNS:api.lab.test, IP Address:127.0.0.1'
t 'curl -sS --cacert root.pem https://127.0.0.1:18320/ -o /dev/null -w "%{http_code}\n"'
has '^200$'
t 'curl -sS https://127.0.0.1:18320/'
has '^curl: \(60\) SSL certificate problem: unable to get local issuer certificate$'; [ "$RC" = 60 ]
t 'curl -sS https://127.0.0.1:18323/'
has '^curl: \(60\) SSL certificate problem: self-signed certificate$'
t 'curl -sS --cacert root.pem https://localhost:18320/'
has "^curl: \(60\) SSL: no alternative certificate subject name matches target host name 'localhost'$"
t 'curl -sS --cacert root.pem https://127.0.0.1:18322/'
has '^curl: \(60\) SSL certificate problem: certificate has expired$'
t 'curl -sS --cacert root.pem https://127.0.0.1:18321/'
has '^curl: \(60\) SSL certificate problem: unable to get local issuer certificate$'
t 'openssl s_client -connect 127.0.0.1:18321 -CAfile root.pem -brief </dev/null 2>&1 | grep -E "depth|error"'
has '^verify error:num=20:unable to get local issuer certificate$'
has '^verify error:num=21:unable to verify the first certificate$'
t 'openssl s_client -connect 127.0.0.1:18320 -CAfile root.pem -showcerts </dev/null 2>/dev/null | grep -E "^ [0-9] s:|^Verify return"'
has '^ 0 s:CN = api.lab.test$'; has '^ 1 s:CN = Lab Issuing CA$'; has 'Verify return code: 0 \(ok\)'
t 'openssl s_client -connect 127.0.0.1:18322 -CAfile root.pem </dev/null 2>/dev/null | grep "^Verify return"'
has 'Verify return code: 10 \(certificate has expired\)'
t 'openssl verify -CAfile root.pem api.pem'
has 'error 20 at 0 depth lookup: unable to get local issuer certificate'
t 'openssl verify -CAfile root.pem -untrusted int.pem api.pem'
has '^api.pem: OK$'
t 'openssl x509 -in api.pem -noout -checkend 2592000; echo "exit=$?"'
has '^Certificate will not expire$'; has '^exit=0$'
t 'openssl x509 -in api.pem -noout -checkend 7776000; echo "exit=$?"'
has '^Certificate will expire$'; has '^exit=1$'
t 'curl -sSk https://127.0.0.1:18322/ -o /dev/null -w "%{http_code}\n"'
has '^200$'

echo; echo "ALL 2.4 TROUBLESHOOTING CHECKS PASSED"
