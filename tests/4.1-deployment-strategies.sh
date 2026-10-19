#!/usr/bin/env bash
# Verifies the 4.1 Deployment Strategies notes: a blue-green switch and a
# canary split behind an nginx proxy, plus a statically validated rolling
# update manifest.
# Needs: docker (pulls nginx:1.27-alpine), curl, kubeconform
#   (go install github.com/yannh/kubeconform/cmd/kubeconform@latest;
#   downloads Kubernetes JSON schemas from GitHub on first run).
set -euo pipefail
IMG=${NGINX_IMAGE:-mirror.gcr.io/library/nginx:1.27-alpine}
PORT=18450
NET=ao-h-bg
WORK=$(mktemp -d)
cleanup() {
  docker rm -f ao-h-blue ao-h-green ao-h-proxy >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

say "two versions of the app"
docker network create "$NET" >/dev/null
for v in "blue:v1 blue" "green:v2 green"; do
  name=${v%%:*}; body=${v#*:}
  mkdir -p "app-$name"
  cat > "app-$name/default.conf" <<EOF
server {
    listen 80;
    location /healthz { return 200 "ok"; }
    location / { return 200 "$body"; }
}
EOF
  docker run -d -q --name "ao-h-$name" --network "$NET" --network-alias "$name" \
    -v "$WORK/app-$name:/etc/nginx/conf.d:ro" "$IMG" >/dev/null
done

say "proxy in front, pointing at blue"
mkdir -p conf.d
cat > conf.d/default.conf <<'EOF'
server {
    listen 80;
    location / { proxy_pass http://app; }
}
EOF
cat > switch.sh <<'EOF'
#!/bin/sh
# Usage: ./switch.sh blue|green
# $PROXY is the proxy container's name
set -e
cat > conf.d/upstream.conf <<CONF
upstream app {
    server $1:80;
}
CONF
docker exec "$PROXY" nginx -t -q
docker exec "$PROXY" nginx -s reload
EOF
chmod +x switch.sh
export PROXY=ao-h-proxy
cat > conf.d/upstream.conf <<'EOF'
upstream app {
    server blue:80;
}
EOF
docker run -d -q --name ao-h-proxy --network "$NET" -p "127.0.0.1:$PORT:80" \
  -v "$WORK/conf.d:/etc/nginx/conf.d" "$IMG" >/dev/null
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.2; done
[ "$(curl -s "http://127.0.0.1:$PORT/")" = "v1 blue" ] || fail "proxy not serving blue"

cat > traffic.sh <<EOF
#!/bin/sh
# Usage: ./traffic.sh COUNT (one request per 10 ms)
for i in \$(seq "\$1"); do
  curl -s -m 2 -w ' %{http_code}\n' \\
    http://127.0.0.1:$PORT/ || echo "FAILED"
  sleep 0.01
done
EOF
chmod +x traffic.sh
cat traffic.sh

say "blue-green switch under load"
echo '$ ./traffic.sh 300 > log.txt &'
./traffic.sh 300 > log.txt &
sleep 4
echo '$ ./switch.sh green'
./switch.sh green 2>/dev/null
wait
echo '$ wait; sort log.txt | uniq -c'
sort log.txt | uniq -c
[ "$(wc -l < log.txt)" -eq 300 ] || fail "expected 300 results"
grep -q FAILED log.txt && fail "a request failed during the switch"
grep -vqE '^v[12] (blue|green) 200$' log.txt && fail "unexpected response"
[ "$(sort log.txt | uniq -c | wc -l)" -eq 2 ] || fail "expected only blue and green 200s"
head -1 log.txt | grep -q 'v1 blue 200' || fail "blue first"
tail -1 log.txt | grep -q 'v2 green 200' || fail "green last"

say "rollback is the same switch"
echo '$ ./switch.sh blue'
./switch.sh blue 2>/dev/null
for _ in $(seq 20); do [ "$(curl -s "http://127.0.0.1:$PORT/")" = "v1 blue" ] && break; sleep 0.2; done
echo '$ curl -s http://127.0.0.1:'"$PORT"'/'
curl -s "http://127.0.0.1:$PORT/"; echo
[ "$(curl -s "http://127.0.0.1:$PORT/")" = "v1 blue" ] || fail "rollback"

say "canary: 10 percent of requests to green"
cat > conf.d/upstream.conf <<'EOF'
upstream app {
    zone app 64k;
    server blue:80  weight=9;
    server green:80 weight=1;
}
EOF
docker exec "$PROXY" nginx -t -q
docker exec "$PROXY" nginx -s reload 2>/dev/null
sleep 2
cat conf.d/upstream.conf
echo '$ ./traffic.sh 100 | sort | uniq -c'
out=$(./traffic.sh 100 | sort | uniq -c)
echo "$out"
blue=$(awk '/v1 blue 200/{print $1}' <<<"$out"); green=$(awk '/v2 green 200/{print $1}' <<<"$out")
[ "$blue" -eq 90 ] && [ "$green" -eq 10 ] || fail "canary split $blue/$green"

say "rolling update manifest (static validation only)"
cat > deploy.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 4
  selector:
    matchLabels: {app: web}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1  # at most 1 pod down
      maxSurge: 1        # at most 1 extra pod
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
        - name: web
          image: registry.example.com/web:2.0.0
          readinessProbe:
            httpGet: {path: /healthz, port: 80}
EOF
kubeconform -strict -summary deploy.yaml
kubeconform -strict deploy.yaml >/dev/null || fail "deployment manifest invalid"

echo "ALL 4.1 DEPLOYMENT-STRATEGIES CHECKS PASSED"
