#!/usr/bin/env bash
# ==============================================================================
# Test Suite: Custom Nginx Resource Monitor (CPU & RAM Telemetry)
# File: tests/test_resource_monitor.sh
# Tests:
#   1. Running Nginx Telemetry (State, Process Count, Workers, Uptime)
#   2. Memory Calculation Verification (RSS vs Virtual Memory, Sum of Workers + Master)
#   3. Real CPU Load & Two-Sample Delta Calculation
#   4. Multi-Worker Scaling (2 Workers -> 4 Workers -> 2 Workers via SIGHUP)
#   5. Process Termination Detection (STOPPED state when Nginx stops)
#   6. Error Handling & Edge Cases (Invalid interval flag, non-existent binary)
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
NGINX_CONF_BAK="${PROJECT_ROOT}/config/nginx.conf.res_test.bak"
RES_MON_BIN="${PROJECT_ROOT}/build/bin/resource_monitor"
WGET_BIN="/usr/bin/wget"

PASSED=0
FAILED=0

pass() {
    echo "  [PASS] $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo "  [FAIL] $1"
    FAILED=$((FAILED + 1))
}

cleanup() {
    if [ -f "$NGINX_CONF_BAK" ]; then
        cp -f "$NGINX_CONF_BAK" "$NGINX_CONF"
        rm -f "$NGINX_CONF_BAK"
    fi
    "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "======================================================================"
echo "TEST SUITE: CUSTOM NGINX RESOURCE MONITOR (CPU & RAM)"
echo "======================================================================"

# Ensure resource_monitor binary is compiled
make -C "$PROJECT_ROOT" monitors >/dev/null

# Ensure Custom Nginx service is running before starting tests
"${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null

# ------------------------------------------------------------------------------
# TEST 1: Running Nginx Telemetry
# ------------------------------------------------------------------------------
echo "[TEST 1] Running Nginx Telemetry Inspection..."
OUT_RUNNING="$("$RES_MON_BIN" -i 300 "$PROJECT_ROOT" "$NGINX_BIN")"
echo "$OUT_RUNNING"

if echo "$OUT_RUNNING" | grep -q "CUSTOM NGINX RESOURCE MONITOR" && \
   echo "$OUT_RUNNING" | grep -q "Nginx Process State: RUNNING" && \
   echo "$OUT_RUNNING" | grep -q "Process Count: 3 (1 Master + 2 Workers)" && \
   echo "$OUT_RUNNING" | grep -q "Workers: 2" && \
   echo "$OUT_RUNNING" | grep -q "System Uptime:"; then
    pass "Running Nginx state, process count (1 Master + 2 Workers), and uptime verified."
else
    fail "Running Nginx output missing expected fields."
fi

# ------------------------------------------------------------------------------
# TEST 2: Memory Calculation Accuracy (RSS vs Virtual Memory & Sum Verification)
# ------------------------------------------------------------------------------
echo ""
echo "[TEST 2] Memory Calculation Verification (VmRSS & VmSize from /proc/PID/status)..."
TOTAL_RSS_KB=$(echo "$OUT_RUNNING" | awk '/^RSS Memory:/ {gsub(/[()]/, "", $5); print $5}')
TOTAL_VSIZE_KB=$(echo "$OUT_RUNNING" | awk '/^Virtual Memory:/ {gsub(/[()]/, "", $5); print $5}')
SYS_TOTAL_MB=$(echo "$OUT_RUNNING" | awk '/^System Memory:/ {print $3}')

# Sum per-process RSS(KB) from breakdown table
SUM_PROC_RSS=$(echo "$OUT_RUNNING" | awk '$2 == "MASTER" || $2 == "WORKER" {sum += $8} END {print sum+0}')
SUM_PROC_VSIZE=$(echo "$OUT_RUNNING" | awk '$2 == "MASTER" || $2 == "WORKER" {sum += $9} END {print sum+0}')

if [ -n "$TOTAL_RSS_KB" ] && [ "$TOTAL_RSS_KB" -gt 0 ] && \
   [ "$TOTAL_VSIZE_KB" -gt "$TOTAL_RSS_KB" ] && \
   [ "$TOTAL_RSS_KB" -eq "$SUM_PROC_RSS" ] && \
   [ "$TOTAL_VSIZE_KB" -eq "$SUM_PROC_VSIZE" ]; then
    pass "Memory metrics verified: Total RSS=${TOTAL_RSS_KB} KB, Total VSize=${TOTAL_VSIZE_KB} KB (VSize > RSS, exact sum of Master + Workers, System RAM=${SYS_TOTAL_MB} MB)."
else
    fail "Memory metrics mismatch: Total RSS=${TOTAL_RSS_KB}, Sum RSS=${SUM_PROC_RSS}, Total VSize=${TOTAL_VSIZE_KB}, Sum VSize=${SUM_PROC_VSIZE}."
fi

# ------------------------------------------------------------------------------
# TEST 3: Real CPU Load & Two-Sample Delta Calculation
# ------------------------------------------------------------------------------
echo ""
echo "[TEST 3] CPU Usage Calculation under Concurrent HTTP Load..."
# Generate concurrent HTTP traffic in background during a 700ms sampling window
(
    for _ in $(seq 1 250); do
        "$WGET_BIN" -q -O /dev/null "http://127.0.0.1:8080/custom_status" 2>/dev/null || true
    done
) &
LOAD_PID=$!

OUT_LOAD="$("$RES_MON_BIN" -i 700 "$PROJECT_ROOT" "$NGINX_BIN")"
wait "$LOAD_PID" 2>/dev/null || true

SYS_DELTA=$(echo "$OUT_LOAD" | awk -F'Delta = ' '/System CPU Jiffies/ {split($2, a, " "); print a[1]}')
NGINX_DELTA=$(echo "$OUT_LOAD" | awk '/Nginx Sample Delta Ticks/ {print $6}')
CPU_PCT=$(echo "$OUT_LOAD" | awk '/^CPU Usage:/ {gsub(/%/, "", $3); print $3}')

echo "  -> Sampled under load: System Delta=${SYS_DELTA} jiffies, Nginx Delta=${NGINX_DELTA} ticks, CPU Usage=${CPU_PCT}%"

if [ -n "$SYS_DELTA" ] && [ "$SYS_DELTA" -gt 0 ] && [ -n "$NGINX_DELTA" ] && [ "$NGINX_DELTA" -ge 1 ]; then
    pass "Two-point CPU sampling verified under load (Delta=${NGINX_DELTA} ticks over 700ms, CPU Usage=${CPU_PCT}%)."
else
    fail "CPU delta under load did not register positive ticks (SYS_DELTA=${SYS_DELTA}, NGINX_DELTA=${NGINX_DELTA})."
fi

# ------------------------------------------------------------------------------
# TEST 4: Multi-Worker Scaling (2 -> 4 -> 2 Workers)
# ------------------------------------------------------------------------------
echo ""
echo "[TEST 4] Multi-Worker Scaling Detection (4 Workers)..."
cp -f "$NGINX_CONF" "$NGINX_CONF_BAK"
sed -i 's/worker_processes[[:space:]]\+2;/worker_processes  4;/' "$NGINX_CONF"
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -t >/dev/null 2>&1
"${PROJECT_ROOT}/scripts/service_reload.sh" >/dev/null
sleep 1

OUT_4W="$("$RES_MON_BIN" -i 200 "$PROJECT_ROOT" "$NGINX_BIN")"
if echo "$OUT_4W" | grep -q "Process Count: 5 (1 Master + 4 Workers)" && \
   echo "$OUT_4W" | grep -q "Workers: 4"; then
    pass "Multi-worker scaling verified: detected 1 Master + 4 Workers (Process Count: 5)."
else
    fail "Multi-worker scaling failed to detect 4 workers."
fi

# Restore 2 workers
cp -f "$NGINX_CONF_BAK" "$NGINX_CONF"
rm -f "$NGINX_CONF_BAK"
"${PROJECT_ROOT}/scripts/service_reload.sh" >/dev/null
sleep 1

# ------------------------------------------------------------------------------
# TEST 5: Process Termination Detection
# ------------------------------------------------------------------------------
echo ""
echo "[TEST 5] Process Termination & Stopped State Verification..."
"${PROJECT_ROOT}/scripts/service_stop.sh" >/dev/null
OUT_STOPPED="$("$RES_MON_BIN" -i 100 "$PROJECT_ROOT" "$NGINX_BIN")"

if echo "$OUT_STOPPED" | grep -q "Nginx Process State: STOPPED" && \
   echo "$OUT_STOPPED" | grep -q "Process Count: 0" && \
   echo "$OUT_STOPPED" | grep -q "Workers: 0" && \
   echo "$OUT_STOPPED" | grep -q "RSS Memory: 0.00 MB (0 KB)"; then
    pass "Stopped state verified when Custom Nginx is terminated."
else
    fail "Failed to report STOPPED state when Custom Nginx was stopped."
fi

# Restart service after stop test
"${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null

# ------------------------------------------------------------------------------
# TEST 6: Error Handling & Edge Cases
# ------------------------------------------------------------------------------
echo ""
echo "[TEST 6] Error Handling & Edge Case Verification..."
if ! "$RES_MON_BIN" -i 10 >/dev/null 2>&1 && \
   "$RES_MON_BIN" -i 100 "$PROJECT_ROOT" "/nonexistent/custom/nginx" | grep -q "Nginx Process State: STOPPED"; then
    pass "Invalid sampling interval (-i 10) rejected with non-zero exit code; non-existent binary handled gracefully."
else
    fail "Error handling check failed."
fi

echo "======================================================================"
echo "RESOURCE MONITOR TEST SUMMARY: ${PASSED} PASSED, ${FAILED} FAILED"
echo "======================================================================"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
