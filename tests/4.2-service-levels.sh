#!/usr/bin/env bash
# Verifies the numbers in the 4.2 Service Levels notes: the allowed-downtime
# table (recomputed here and matched row by row against the topic file), the
# error-budget script, and the MTTR / MTBF / availability worked example.
# Needs: python3 only.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOTES="$ROOT/content/domain-4/4.2-service-levels.md"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*"; exit 1; }

say "allowed downtime table"
cat > downtime.py <<'EOF'
# One markdown row per uptime target: allowed downtime per day,
# per 30-day month, and per 365-day year, rounded to whole seconds.
def fmt(sec):
    sec = round(sec)
    d, sec = divmod(sec, 86400)
    h, sec = divmod(sec, 3600)
    m, s = divmod(sec, 60)
    parts = [f"{v}{u}" for v, u in ((d, "d"), (h, "h"), (m, "m"), (s, "s")) if v]
    return " ".join(parts) or "0s"

for pct in ("99", "99.5", "99.9", "99.95", "99.99", "99.999"):
    down = 1 - float(pct) / 100
    row = [f"{pct}%", fmt(down * 86400), fmt(down * 30 * 86400), fmt(down * 365 * 86400)]
    print("| " + " | ".join(row) + " |")
EOF
python3 downtime.py | tee rows.txt
grep -qx '| 99.9% | 1m 26s | 43m 12s | 8h 45m 36s |' rows.txt || fail "three nines row"
grep -qx '| 99.99% | 9s | 4m 19s | 52m 34s |' rows.txt || fail "four nines row"
if [ -f "$NOTES" ]; then
  while IFS= read -r row; do
    grep -qxF "$row" "$NOTES" || fail "notes table is missing row: $row"
  done < rows.txt
  echo "all rows present in $(basename "$NOTES")"
else
  fail "notes file not found: $NOTES"
fi

say "error budget"
cat > budget.py <<'EOF'
slo = 0.999                 # 99.9% of requests
good, total = 4_996_210, 5_000_000

sli = good / total
allowed = (1 - slo) * total # failures allowed
used = (total - good) / allowed
print(f"SLI          {sli:.4%}")
print(f"SLO met      {sli >= slo}")
print(f"budget       {allowed:,.0f} bad requests")
print(f"budget used  {used:.1%}")
EOF
echo '$ python3 budget.py'
python3 budget.py | tee budget.txt
grep -qx 'SLI          99.9242%' budget.txt || fail "SLI"
grep -qx 'SLO met      True' budget.txt || fail "SLO met"
grep -qx 'budget       5,000 bad requests' budget.txt || fail "budget"
grep -qx 'budget used  75.8%' budget.txt || fail "budget used"

say "MTTR, MTBF, availability"
cat > mtbf.py <<'EOF'
window_h = 30 * 24             # 720 hours
outages_min = [42, 18, 30]     # three incidents
n = len(outages_min)

mttr_h = sum(outages_min) / n / 60
uptime_h = window_h - sum(outages_min) / 60
mtbf_h = uptime_h / n
avail = mtbf_h / (mtbf_h + mttr_h)
print(f"MTTR          {mttr_h * 60:.0f} min")
print(f"MTBF          {mtbf_h:.1f} h")
print(f"availability  {avail:.3%}")
print(f"check         {uptime_h / window_h:.3%}")
EOF
echo '$ python3 mtbf.py'
python3 mtbf.py | tee mtbf.txt
grep -qx 'MTTR          30 min' mtbf.txt || fail "MTTR"
grep -qx 'MTBF          239.5 h' mtbf.txt || fail "MTBF"
grep -qx 'availability  99.792%' mtbf.txt || fail "availability"
grep -qx 'check         99.792%' mtbf.txt || fail "uptime cross-check"

say "composite availability"
python3 - <<'EOF' | tee comp.txt
a = 0.999
print(f"serial   {a * a:.4%}")
print(f"parallel {1 - (1 - a) ** 2:.4%}")
EOF
grep -qx 'serial   99.8001%' comp.txt || fail "serial"
grep -qx 'parallel 99.9999%' comp.txt || fail "parallel"

echo "ALL 4.2 SERVICE-LEVELS CHECKS PASSED"
