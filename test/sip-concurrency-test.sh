#!/bin/bash
# sip concurrency test suite
#
# Verifies the mkdir-lock guarantees exactly one sip-managed caffeinate under
# serial, concurrent, and adversarial (stale-lock, wedged-holder) conditions.
#
# Run:  bash test/sip-concurrency-test.sh
# Reads SIP from repo root (./sip.sh) so it tests the working tree, not the
# installed copy. Override with SIP_BIN=... to test another path.

set -uo pipefail

SIP_BIN="${SIP_BIN:-$(cd "$(dirname "$0")/.." && pwd)/sip.sh}"
MARKER="sip-caffeinate"
LOCK_DIR="${TMPDIR:-/tmp}/sip.lock"

PASS=0
FAIL=0
FAILMSGS=()

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILMSGS+=("$1"); echo "  ❌ $1"; }

# ── helpers ───────────────────────────────────────────────────────────────────

count_proc() { pgrep -f "$MARKER" 2>/dev/null | wc -l | tr -d ' '; }
clear_all()  { "$SIP_BIN" stop >/dev/null 2>&1; sleep 0.4; rm -rf "$LOCK_DIR" 2>/dev/null; }
hook_reset()  { echo "" | "$SIP_BIN" >/dev/null 2>&1; }
hook_ensure() { echo "" | "$SIP_BIN" ensure >/dev/null 2>&1; }
assert_proc_count() {  # $1=expected  $2=label
    local got expected="$1"
    sleep 0.3
    got=$(count_proc)
    if [ "$got" -eq "$expected" ]; then pass "$2 (got=$got)"; else fail "$2 (expected=$expected, got=$got)"; fi
}

# ── tests ────────────────────────────────────────────────────────────────────

echo "=== sip concurrency tests ==="
echo "binary: $SIP_BIN"
echo ""

clear_all

# 1. serial baseline
echo "[1] serial baseline"
hook_reset;  assert_proc_count 1 "serial reset → 1"
hook_reset;  assert_proc_count 1 "serial reset again → 1"
hook_ensure; assert_proc_count 1 "serial ensure (already running) → 1"
clear_all
hook_ensure; assert_proc_count 1 "serial ensure (from empty) → 1"
clear_all

# 2. concurrent reset (the original bug: N concurrent → N procs)
echo "[2] concurrent reset"
for n in 5 10 20; do
    for i in $(seq 1 "$n"); do hook_reset & done
    wait
    assert_proc_count 1 "concurrent reset x$n → 1"
    clear_all
done

# 3. concurrent ensure
echo "[3] concurrent ensure"
for n in 10 30; do
    for i in $(seq 1 "$n"); do hook_ensure & done
    wait
    assert_proc_count 1 "concurrent ensure x$n → 1"
    clear_all
done

# 4. mixed concurrent reset + ensure
echo "[4] mixed concurrent"
for i in $(seq 1 8); do
    hook_reset &
    hook_ensure &
    hook_ensure &
done
wait
assert_proc_count 1 "mixed concurrent (8 reset + 16 ensure) → 1"
clear_all

# 5. stale lock recovery (holder is a dead pid)
echo "[5] stale-lock recovery"
mkdir "$LOCK_DIR" 2>/dev/null
echo "99999" > "$LOCK_DIR/pid"   # a pid that does not exist
hook_reset
assert_proc_count 1 "reclaim stale lock → 1"
clear_all

# 6. wedged holder does not block IDE (acquire times out, hook returns silently)
echo "[6] wedged-holder does not block"
mkdir "$LOCK_DIR" 2>/dev/null
echo "$$" > "$LOCK_DIR/pid"   # this test script itself is alive → looks wedged
start=$(date +%s)
hook_reset
end=$(date +%s)
elapsed=$((end - start))
if [ "$elapsed" -lt 4 ]; then pass "wedged-holder returned in ${elapsed}s (< 4s, did not block)"; else fail "wedged-holder blocked ${elapsed}s"; fi
# should NOT have started a caffeinate (couldn't get the lock)
assert_proc_count 0 "wedged-holder did not start caffeinate"
rm -rf "$LOCK_DIR" 2>/dev/null
clear_all

# 7. stop concurrent with reset (must not stack; final count is whoever ran last)
echo "[7] stop + reset concurrency (no stacking)"
for i in 1 2 3 4 5; do hook_reset & "$SIP_BIN" stop >/dev/null 2>&1 & done
wait
sleep 0.3
got=$(count_proc)
if [ "$got" -le 1 ]; then pass "stop+reset concurrency → ≤1 (got=$got, no stacking)"; else fail "stop+reset concurrency → expected ≤1, got $got (stacked)"; fi
rm -rf "$LOCK_DIR" 2>/dev/null
clear_all

# 8. final state: single healthy instance
echo "[8] final healthy state"
hook_reset
assert_proc_count 1 "final reset → 1 healthy instance"
clear_all

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    for m in "${FAILMSGS[@]}"; do echo "  - $m"; done
    exit 1
fi
echo "✅ all passed"
exit 0
