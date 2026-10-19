#!/usr/bin/env bash
# Verifies the 2.2 Event-Driven Automation notes against a real RabbitMQ:
#   pub/sub notification (dropped with no subscribers, fanned out with two),
#   a work queue with competing consumers, at-least-once redelivery after
#   worker crashes, a dead-letter queue, and an idempotent consumer.
# The FaaS handler is a Lambda-style Python function; no cloud account is
# used, so the test calls it with an SQS-shaped sample event.
# Needs: docker (rabbitmq:4-management-alpine), pika (pip install pika).
#        Uses 127.0.0.1:18270 and container ao-d-mq.
set -euo pipefail
WORK=$(mktemp -d)
CT=ao-d-mq
trap 'docker rm -f "$CT" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
cd "$WORK"
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

say "start RabbitMQ"
docker rm -f "$CT" >/dev/null 2>&1 || true
docker run -d --name "$CT" -u 100:101 -p 127.0.0.1:18270:5672 \
  rabbitmq:4-management-alpine >/dev/null
for _ in $(seq 1 90); do
  docker exec "$CT" rabbitmq-diagnostics -q check_port_connectivity \
    >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CT" rabbitmq-diagnostics -q server_version | grep -q '^4\.' \
  || fail "RabbitMQ 4.x"

cat > events.py <<'PY'
"""Event-driven automation patterns on RabbitMQ."""
import time

import pika
from pika.exceptions import UnroutableError

PARAMS = pika.ConnectionParameters(
    "127.0.0.1", 18270)
conn = pika.BlockingConnection(PARAMS)
ch = conn.channel()
ch.confirm_delivery()

# 1. Notification: pub/sub on a fanout exchange
ch.exchange_declare("config.changed", "fanout")


def notify(text):
    try:
        ch.basic_publish("config.changed", "",
                         text.encode(),
                         mandatory=True)
        return "delivered"
    except UnroutableError:
        return "dropped, nobody subscribed"


print("notify:", notify("core-sw1 v42"))
for sub in ("audit", "backup"):
    ch.queue_declare(sub, exclusive=True)
    ch.queue_bind(sub, "config.changed")
print("notify:", notify("core-sw1 v43"))
for sub in ("audit", "backup"):
    body = ch.basic_get(sub, auto_ack=True)[2]
    print(f"  {sub} received {body.decode()}")

# 2. Work queue with a dead-letter queue
DLQ = "jobs.backup.dlq"
args = {
    "x-queue-type": "quorum",
    "x-delivery-limit": 2,
    "x-dead-letter-exchange": "",
    "x-dead-letter-routing-key": DLQ,
}
ch.queue_declare(DLQ, durable=True)
ch.queue_declare("jobs.backup", durable=True,
                 arguments=args)


def send(host, msg_id):
    props = pika.BasicProperties(
        message_id=msg_id, delivery_mode=2)
    ch.basic_publish("", "jobs.backup",
                     host.encode(), props)


hosts = ["core-sw1", "core-sw2",
         "edge-rtr1", "edge-rtr2"]
for n, host in enumerate(hosts):
    send(host, f"job-{1001 + n}")

# Two competing consumers share one queue
done, workers = [], []
for name in ("worker-a", "worker-b"):
    w = conn.channel()
    w.basic_qos(prefetch_count=1)

    def work(c, m, p, body, name=name):
        done.append(body.decode())
        print(f"{name} backed up {body.decode()}")
        c.basic_ack(m.delivery_tag)
    w.basic_consume("jobs.backup", work)
    workers.append(w)
while len(done) < 4:
    conn.process_data_events(time_limit=1)
for w in workers:
    w.close()

# 3. At-least-once: a worker that dies before acking
conn2 = pika.BlockingConnection(PARAMS)
send("edge-rtr9", "job-1099")
for attempt in range(1, 5):
    w = conn2.channel()
    m, p, body = w.basic_get("jobs.backup")
    if m is None:
        break
    host = body.decode()
    tag = " (redelivered)" if m.redelivered else ""
    print(f"try {attempt} {host}: crashed{tag}")
    w.close()  # no ack: the message goes back
conn2.close()
for _ in range(25):  # dead-lettering is async
    m, p, body = ch.basic_get(DLQ)
    if m:
        break
    time.sleep(0.2)
reason = p.headers["x-first-death-reason"]
print(f"dead-lettered {body.decode()} ({reason})")
ch.basic_nack(m.delivery_tag)  # keep it in the DLQ

# 4. Idempotent consumer: one message, two copies
seen = set()


def handle(m, p, body):
    mid = p.message_id
    if mid in seen:
        return f"{mid}: duplicate, skipped"
    seen.add(mid)
    return f"{mid}: backed up {body.decode()}"


send("core-sw1", "job-2001")
send("core-sw1", "job-2001")  # publisher retried
for _ in range(2):
    m, p, body = ch.basic_get("jobs.backup")
    print(handle(m, p, body))
    ch.basic_ack(m.delivery_tag)
conn.close()
PY

say "run events.py"
out=$(python3 events.py); echo "$out"
grep -qx 'notify: dropped, nobody subscribed' <<<"$out" || fail "dropped"
grep -qx 'notify: delivered' <<<"$out" || fail "delivered"
grep -qx '  audit received core-sw1 v43' <<<"$out" || fail "audit"
grep -qx '  backup received core-sw1 v43' <<<"$out" || fail "backup"
for h in core-sw1 core-sw2 edge-rtr1 edge-rtr2; do
  [ "$(grep -c "^worker-[ab] backed up $h$" <<<"$out")" = 1 ] \
    || fail "$h processed exactly once"
done
grep -q '^worker-a backed up' <<<"$out" || fail "worker-a idle"
grep -q '^worker-b backed up' <<<"$out" || fail "worker-b idle"
grep -qx 'try 1 edge-rtr9: crashed' <<<"$out" || fail "try 1"
grep -qx 'try 2 edge-rtr9: crashed (redelivered)' <<<"$out" || fail "try 2"
grep -qx 'try 3 edge-rtr9: crashed (redelivered)' <<<"$out" || fail "try 3"
if grep -q '^try 4' <<<"$out"; then fail "delivery limit not applied"; fi
grep -qx 'dead-lettered edge-rtr9 (delivery_limit)' <<<"$out" || fail dlq
grep -qx 'job-2001: backed up core-sw1' <<<"$out" || fail "first"
grep -qx 'job-2001: duplicate, skipped' <<<"$out" || fail "dup"

say "queue depth after the run"
out=$(docker exec "$CT" rabbitmqctl -q list_queues name type messages \
  | { read -r header; echo "$header"; sort; })
echo "$out"
grep -Eq '^jobs\.backup[[:space:]]+quorum[[:space:]]+0$' <<<"$out" \
  || fail "work queue empty"
grep -Eq '^jobs\.backup\.dlq[[:space:]]+classic[[:space:]]+1$' <<<"$out" \
  || fail "poison message waits in the DLQ"

say "FaaS handler (Lambda-style) with an SQS-shaped event"
cat > handler.py <<'PY'
import json

KNOWN = {"core-sw1", "core-sw2", "edge-rtr1"}


def backup(host):
    if host not in KNOWN:
        raise ValueError(f"unknown host {host}")


def handler(event, context):
    """Called once per batch of queue messages."""
    failed = []
    for record in event["Records"]:
        job = json.loads(record["body"])
        try:
            backup(job["host"])
        except ValueError:
            failed.append(record["messageId"])
    # Only the failed messages go back to the queue
    return {"batchItemFailures": [
        {"itemIdentifier": i} for i in failed]}
PY
cat > event.json <<'JSON'
{"Records": [
  {"messageId": "m-1", "eventSource": "aws:sqs",
   "body": "{\"host\": \"core-sw1\"}"},
  {"messageId": "m-2", "eventSource": "aws:sqs",
   "body": "{\"host\": \"edge-rtr9\"}"}
]}
JSON
cat > invoke.py <<'PY'
"""Call the handler the way the platform would."""
import json
import sys

from handler import handler

with open(sys.argv[1]) as f:
    event = json.load(f)
print(json.dumps(handler(event, None)))
PY
out=$(python3 invoke.py event.json)
echo "$out"
[ "$(jq -c . <<<"$out")" = '{"batchItemFailures":[{"itemIdentifier":"m-2"}]}' ] \
  || fail "partial batch response"

echo
echo "ALL 2.2 EVENT-DRIVEN CHECKS PASSED"
