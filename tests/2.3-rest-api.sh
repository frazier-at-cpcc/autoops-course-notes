#!/usr/bin/env bash
# Verifies every command and output shown in the 2.3 REST notes
# (2.3-rest-fundamentals.md and 2.3-rest-tools.md).
# Starts a small VLAN inventory REST API (Python standard library only) on
# 127.0.0.1:18300, then drives it with curl, wget, and Newman.
# Needs: curl, wget, jq, shellcheck, newman (npm install -g newman)
# shellcheck disable=SC2016,SC2089,SC2090  # commands are single-quoted on purpose: t() prints, then evals them
set -euo pipefail
WORK=$(mktemp -d)
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
cd "$WORK"
# Talk to 127.0.0.1 directly, never through a configured HTTP proxy
export NO_PROXY='127.0.0.1,localhost' no_proxy='127.0.0.1,localhost'
PORT=18300

# t "command": print it like a terminal, run it, keep output in $OUT and
# the exit code in $RC (a failing command does not stop the script).
t() {
  printf '$ %s\n' "$1"
  RC=0; OUT=$(eval "$1" 2>&1) || RC=$?
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  return 0
}
has() { grep -Eq -- "$1" <<<"$OUT" || { echo "FAIL: expected /$1/"; exit 1; }; }
say() { printf '\n== %s\n' "$*"; }

cat > api.py <<'PY'
"""VLAN inventory API used by the 2.3 notes. Standard library only."""
import hashlib, json, sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

TOKENS = {"s3cr3t-admin": "rw", "s3cr3t-viewer": "ro", "s3cr3t-batch": "ro"}
LIMIT = {"s3cr3t-batch": 10}   # requests per token per 60 s (default 100)
VLANS = {
    10: {"id": 10, "name": "users", "description": "Staff desktops"},
    20: {"id": 20, "name": "servers", "description": "Data center"},
}
hits = {}

class API(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vlan-api/1.0"
    sys_version = ""

    def log_message(self, *a):
        pass

    def version_string(self):
        return self.server_version

    def send(self, code, body=None, headers=None):
        data = b"" if body is None else (json.dumps(body) + "\n").encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if data:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        raw = self.raw
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return None, (415, {"error": "send Content-Type: application/json"})
        try:
            return json.loads(raw or b"null"), None
        except json.JSONDecodeError as e:
            return None, (400, {"error": f"malformed JSON: {e}"})

    def validate(self, v, full):
        errs = {}
        if full and not isinstance(v.get("id"), int):
            errs["id"] = "required integer"
        elif full and not 1 <= v["id"] <= 4094:
            errs["id"] = "must be 1-4094"
        if full or "name" in v:
            if not isinstance(v.get("name"), str) or not v.get("name"):
                errs["name"] = "required string"
        return errs

    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        self.raw = self.rfile.read(n) if n else b""   # always drain the body
        path = self.path.split("?")[0].rstrip("/")
        if path.startswith("/api/vlans"):           # old, unversioned path
            return self.send(301, None, {"Location": path.replace("/api/", "/api/v1/", 1)})
        if not path.startswith("/api/v1/vlans"):
            return self.send(404, {"error": "no such endpoint"})
        auth = self.headers.get("Authorization", "")
        token = auth.removeprefix("Bearer ")
        if token not in TOKENS:
            return self.send(401, {"error": "missing or invalid token"},
                             {"WWW-Authenticate": 'Bearer realm="vlan-api"'})
        now = time.time()
        window = [t for t in hits.get(token, []) if now - t < 60]
        limit = LIMIT.get(token, 100)
        if len(window) >= limit:
            retry = int(60 - (now - window[0])) + 1
            return self.send(429, {"error": "rate limit exceeded"},
                             {"Retry-After": str(retry), "X-RateLimit-Limit": str(limit),
                              "X-RateLimit-Remaining": "0"})
        window.append(now)
        hits[token] = window
        rl = {"X-RateLimit-Limit": str(limit),
              "X-RateLimit-Remaining": str(limit - len(window))}
        if method != "GET" and TOKENS[token] != "rw":
            return self.send(403, {"error": "token is read-only"}, rl)
        parts = path.split("/")[4:]          # [] or ["30"]
        vid = int(parts[0]) if parts and parts[0].isdigit() else None
        if parts and vid is None:
            return self.send(404, {"error": "no such endpoint"}, rl)

        if method == "GET":
            if vid is None:
                result = [VLANS[k] for k in sorted(VLANS)]
            elif vid in VLANS:
                result = VLANS[vid]
            else:
                return self.send(404, {"error": f"VLAN {vid} not found"}, rl)
            etag = '"' + hashlib.sha256(json.dumps(result).encode()).hexdigest()[:12] + '"'
            if self.headers.get("If-None-Match") == etag:
                return self.send(304, None, {**rl, "ETag": etag})
            return self.send(200, result, {**rl, "ETag": etag})

        if method == "POST" and vid is None:
            v, err = self.body()
            if err:
                return self.send(*err, rl)
            errs = self.validate(v or {}, True)
            if errs:
                return self.send(422, {"error": "validation failed", "fields": errs}, rl)
            if v["id"] in VLANS:
                return self.send(409, {"error": f"VLAN {v['id']} already exists"}, rl)
            VLANS[v["id"]] = {"id": v["id"], "name": v["name"],
                              **({"description": v["description"]} if "description" in v else {})}
            return self.send(201, VLANS[v["id"]],
                             {**rl, "Location": f"/api/v1/vlans/{v['id']}"})

        if vid is None:
            return self.send(405, {"error": "method not allowed"}, {**rl, "Allow": "GET, POST"})
        if vid not in VLANS:
            return self.send(404, {"error": f"VLAN {vid} not found"}, rl)

        if method == "DELETE":
            del VLANS[vid]
            return self.send(204, None, rl)
        v, err = self.body()
        if err:
            return self.send(*err, rl)
        if method == "PUT":                  # full replacement
            errs = self.validate({"id": vid, **(v or {})}, True)
            if errs:
                return self.send(422, {"error": "validation failed", "fields": errs}, rl)
            VLANS[vid] = {"id": vid, "name": v["name"],
                          **({"description": v["description"]} if "description" in v else {})}
        else:                                # PATCH: merge the fields sent
            errs = self.validate(v or {}, False)
            if errs:
                return self.send(422, {"error": "validation failed", "fields": errs}, rl)
            VLANS[vid].update({k: v[k] for k in ("name", "description") if k in v})
        return self.send(200, VLANS[vid], rl)

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PUT(self): self.handle_any("PUT")
    def do_PATCH(self): self.handle_any("PATCH")
    def do_DELETE(self): self.handle_any("DELETE")

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), API).serve_forever()
PY
python3 api.py "$PORT" 2>api.log & SRV=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

# v "NAME=value": print the assignment like a terminal, then make it
# (exported) in this shell, so later t commands can use it
v() { printf '$ %s\n' "$1"; eval "export $1"; }
v 'API=http://127.0.0.1:18300/api/v1'
v 'AUTH="Authorization: Bearer s3cr3t-admin"'
v 'CT="Content-Type: application/json"'
v 'RO="Authorization: Bearer s3cr3t-viewer"'
v 'OLD=http://127.0.0.1:18300/api/vlans'

say "fundamentals: request and response headers"
t 'curl -sv -H "$AUTH" $API/vlans/10'
has '^> GET /api/v1/vlans/10 HTTP/1.1'; has '^> Accept: \*/\*'; has '^> Authorization: Bearer s3cr3t-admin'
has '^< HTTP/1.1 200 OK'; has '^< Content-Type: application/json'; has '^< ETag: "bc2bc3803223"'
has '^< X-RateLimit-Remaining: 99'; has '"name": "users"'
v 'ET='"'"'If-None-Match: "bc2bc3803223"'"'"''
t 'curl -si -H "$AUTH" -H "$ET" $API/vlans/10'
has '^HTTP/1.1 304 Not Modified'; has '^Content-Length: 0'
t 'curl -si $API/vlans'
has '^HTTP/1.1 401 Unauthorized'; has '^WWW-Authenticate: Bearer realm="vlan-api"'; has 'missing or invalid token'
t 'curl -si -X DELETE -H "$RO" $API/vlans/10'
has '^HTTP/1.1 403 Forbidden'; has 'read-only'
t 'curl -si -H "$AUTH" $OLD'
has '^HTTP/1.1 301 Moved Permanently'; has '^Location: /api/v1/vlans'
t 'curl -sL -H "$AUTH" $OLD | jq length'
has '^2$'

say "tools: full CRUD with curl"
cat > vlan30.json <<'JSON'
{
  "id": 30,
  "name": "voice",
  "description": "IP phones"
}
JSON
t 'curl -si -H "$AUTH" -H "$CT" -d @vlan30.json $API/vlans'
has '^HTTP/1.1 201 Created'; has '^Location: /api/v1/vlans/30'
has '"id": 30, "name": "voice", "description": "IP phones"'
t 'curl -si -H "$AUTH" -H "$CT" -d @vlan30.json $API/vlans'
has '^HTTP/1.1 409 Conflict'; has 'VLAN 30 already exists'
t "curl -si -H \"\$AUTH\" -H \"\$CT\" -d '{\"id\": 5000, \"name\": \"lab\"}' \$API/vlans"
has '^HTTP/1.1 422 Unprocessable (Content|Entity)'; has 'must be 1-4094'
t "curl -si -H \"\$AUTH\" -H \"\$CT\" -d \"{'id': 50}\" \$API/vlans"
has '^HTTP/1.1 400 Bad Request'; has 'malformed JSON: Expecting property name enclosed in double quotes'
t "curl -s -H \"\$AUTH\" \$API/vlans | jq -r '.[].name'"
has '^users$'; has '^voice$'
t 'curl -s -H "$AUTH" $API/vlans/30 | jq .'
has '"description": "IP phones"'
t "curl -s -X PUT -H \"\$AUTH\" -H \"\$CT\" -d '{\"name\": \"voip\"}' \$API/vlans/30"
has '^\{"id": 30, "name": "voip"\}$'
t "curl -s -X PATCH -H \"\$AUTH\" -H \"\$CT\" -d '{\"description\": \"Desk phones\"}' \$API/vlans/30"
has '^\{"id": 30, "name": "voip", "description": "Desk phones"\}$'
t 'curl -si -X DELETE -H "$AUTH" $API/vlans/30'
has '^HTTP/1.1 204 No Content'
t 'curl -si -X DELETE -H "$AUTH" $API/vlans/30'
has '^HTTP/1.1 404 Not Found'
# -d without a Content-Type header sends form encoding
t 'curl -si -H "$AUTH" -d @vlan30.json $API/vlans'
has '^HTTP/1.1 415 Unsupported Media Type'; has 'send Content-Type: application/json'
# --json is shorthand for -d plus Content-Type and Accept headers
t "curl -s -H \"\$AUTH\" --json '{\"id\": 31, \"name\": \"voice2\"}' \$API/vlans"
has '"id": 31'

say "tools: scripting with -f, -w, and jq"
t 'curl -sSf -H "$AUTH" $API/vlans/30'
has 'curl: \(22\) The requested URL returned error: 404'; [ "$RC" = 22 ]
t 'curl -sf -H "$AUTH" $API/vlans/30 || echo "exit=$?"'
has '^exit=22$'
cat > vlan-exists.sh <<'SH'
#!/usr/bin/env bash
# Exit 0 if VLAN $1 exists, 1 if not, 2 on anything else
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "$AUTH" "$API/vlans/$1")
case $code in
  200) echo "VLAN $1 present" ;;
  404) echo "VLAN $1 missing"; exit 1 ;;
  *)   echo "unexpected HTTP $code"; exit 2 ;;
esac
SH
chmod +x vlan-exists.sh
shellcheck vlan-exists.sh
t './vlan-exists.sh 10'
has '^VLAN 10 present$'; [ "$RC" = 0 ]
t './vlan-exists.sh 30; echo "exit=$?"'
has '^VLAN 30 missing$'; has '^exit=1$'
t 'AUTH="Authorization: Bearer typo" ./vlan-exists.sh 10'
has '^unexpected HTTP 401$'; [ "$RC" = 2 ]
t 'curl -s -H "$AUTH" $API/vlans -o all.json'
t 'jq -r '"'"'.[] | "\(.id) \(.name)"'"'"' all.json'
has '^10 users$'; has '^31 voice2$'
t 'jq '"'"'map(select(.id >= 20)) | length'"'"' all.json'
has '^2$'

say "tools: wget"
t 'wget -qO- --header "$AUTH" $API/vlans/10'
has '"name": "users"'
t "wget -qO- --header \"\$AUTH\" --header \"\$CT\" --post-data '{\"id\": 60, \"name\": \"cameras\"}' \$API/vlans"
has '"id": 60'
t "wget -qO- --method=PATCH --header \"\$AUTH\" --header \"\$CT\" --body-data '{\"name\": \"cctv\"}' \$API/vlans/60"
has '"name": "cctv"'
t 'wget -qS -O /dev/null --method=DELETE --header "$AUTH" $API/vlans/60'
has 'HTTP/1.1 204 No Content'
t 'wget -q --header "$AUTH" $API/vlans/60; echo "exit=$?"'
has '^exit=8$'
t 'wget -O /dev/null --header "$AUTH" $API/vlans/60 2>&1 | grep ERROR'
has 'ERROR 404: Not Found.'

say "tools: Postman collection run with Newman"
cat > vlans.json <<'JSON'
{
  "info": {
    "name": "VLAN API",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
  },
  "auth": {
    "type": "bearer",
    "bearer": [{ "key": "token", "value": "{{token}}", "type": "string" }]
  },
  "variable": [{ "key": "vlanId", "value": "70" }],
  "item": [
    {
      "name": "Create VLAN",
      "request": {
        "method": "POST",
        "url": "{{baseUrl}}/vlans",
        "header": [{ "key": "Content-Type", "value": "application/json" }],
        "body": { "mode": "raw", "raw": "{\"id\": {{vlanId}}, \"name\": \"printers\"}" }
      },
      "event": [{ "listen": "test", "script": { "exec": [
        "pm.test('status is 201', () =>",
        "  pm.response.to.have.status(201));",
        "pm.test('Location header set', () =>",
        "  pm.response.to.have.header('Location'));"
      ] } }]
    },
    {
      "name": "Read VLAN",
      "request": { "method": "GET", "url": "{{baseUrl}}/vlans/{{vlanId}}" },
      "event": [{ "listen": "test", "script": { "exec": [
        "pm.test('name is printers', () =>",
        "  pm.expect(pm.response.json().name).to.eql('printers'));"
      ] } }]
    },
    {
      "name": "Rename VLAN",
      "request": {
        "method": "PATCH",
        "url": "{{baseUrl}}/vlans/{{vlanId}}",
        "header": [{ "key": "Content-Type", "value": "application/json" }],
        "body": { "mode": "raw", "raw": "{\"name\": \"print\"}" }
      },
      "event": [{ "listen": "test", "script": { "exec": [
        "pm.test('status is 200', () =>",
        "  pm.response.to.have.status(200));"
      ] } }]
    },
    {
      "name": "Delete VLAN",
      "request": { "method": "DELETE", "url": "{{baseUrl}}/vlans/{{vlanId}}" },
      "event": [{ "listen": "test", "script": { "exec": [
        "pm.test('status is 204', () =>",
        "  pm.response.to.have.status(204));"
      ] } }]
    }
  ]
}
JSON
cat > lab.json <<JSON
{
  "name": "lab",
  "values": [
    { "key": "baseUrl",
      "value": "http://127.0.0.1:$PORT/api/v1" },
    { "key": "token", "value": "s3cr3t-admin" }
  ]
}
JSON
t 'newman run vlans.json -e lab.json --disable-unicode'
[ "$RC" = 0 ] || { echo "FAIL: newman exit $RC"; exit 1; }
has 'POST http://127.0.0.1:18300/api/v1/vlans \[201 Created'
has 'DELETE http://127.0.0.1:18300/api/v1/vlans/70 \[204 No Content'
has 'assertions .* 5 .* 0'
# The same collection against a viewer token fails, and newman exits 1 for CI
sed 's/s3cr3t-admin/s3cr3t-viewer/' lab.json > ro.json
t 'newman run vlans.json -e ro.json --disable-unicode --color off'
[ "$RC" = 1 ] || { echo "FAIL: newman should exit 1"; exit 1; }
has 'POST http://127.0.0.1:18300/api/v1/vlans \[403 Forbidden'
has 'AssertionError +status is 201'; has 'expected response to have status code 201 but got 403'
has 'GET http://127.0.0.1:18300/api/v1/vlans/70 \[404 Not Found'

say "rate limiting: 429 after 10 requests in a minute"
export BATCH="Authorization: Bearer s3cr3t-batch"
codes=$(for _ in $(seq 12); do curl -s -o /dev/null -w "%{http_code} " -H "$BATCH" "$API/vlans"; done)
[ "$codes" = "200 200 200 200 200 200 200 200 200 200 429 429 " ] || { echo "FAIL: $codes"; exit 1; }
t 'curl -si -H "$BATCH" $API/vlans'
has '^HTTP/1.1 429 Too Many Requests'; has '^Retry-After: [0-9]+'; has '^X-RateLimit-Remaining: 0'

echo; echo "ALL 2.3 REST API CHECKS PASSED"
