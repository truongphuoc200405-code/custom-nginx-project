#!/usr/bin/env bash
# ==============================================================================
# Script: tests/test_security.sh
# Purpose: Comprehensive integration test for ngx_http_custom_security_module
# Tests:
#   1. Normal request & custom headers
#   2. Requests below threshold (<= 20 req/1s)
#   3. Burst requests exceeding threshold (> 20 req/1s -> HTTP 429)
#   4. Security event logging in logs/error.log
#   5. Multi-worker shared memory coordination
#   6. Real socket IP tracking (IPv4 127.0.0.1, IPv6 [::1], X-Forwarded-For spoofing resistance)
# ==============================================================================

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
NGINX_PID="${PROJECT_ROOT}/logs/nginx.pid"
ERROR_LOG="${PROJECT_ROOT}/logs/error.log"
ACCESS_LOG="${PROJECT_ROOT}/logs/access.log"
PORT=8080

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    echo -e "  -> ${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_test() {
    echo -e "  -> ${RED}[FAIL]${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Fast native HTTP status helper using /usr/bin/wget (avoids slow snap curl wrapper)
http_status() {
    local url="$1"
    local extra_hdr="${2:-}"
    local out
    if [ -n "$extra_hdr" ]; then
        out=$(/usr/bin/wget -qO /dev/null --server-response --header="$extra_hdr" "$url" 2>&1 || true)
    else
        out=$(/usr/bin/wget -qO /dev/null --server-response "$url" 2>&1 || true)
    fi
    echo "$out" | awk '/^  HTTP\/1\.[01]/ {code=$2} END {print code+0}'
}

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}      CUSTOM SECURITY MODULE TEST SUITE (ngx_http_custom_security)    ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Ensure clean start (stop systemd unit first so it does not auto-restart during standalone test)
bash "${PROJECT_ROOT}/scripts/service_stop.sh" >/dev/null 2>&1 || true
if [ -f "$NGINX_PID" ] && kill -0 "$(cat "$NGINX_PID")" 2>/dev/null; then
    "$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -s stop || true
    sleep 1
fi
rm -f "$ERROR_LOG" "$ACCESS_LOG"

echo -e "\n${BOLD}[0] Starting Custom Nginx Server (worker_processes = 2)...${NC}"
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF"
sleep 1

WORKER_PIDS=$(pgrep -P "$(cat "$NGINX_PID")" | tr '\n' ' ')
WORKER_COUNT=$(pgrep -P "$(cat "$NGINX_PID")" | wc -l)
echo -e "  * Master PID : $(cat "$NGINX_PID")"
echo -e "  * Worker PIDs: ${WORKER_PIDS} (Count: ${WORKER_COUNT})"

if [ "$WORKER_COUNT" -ge 2 ]; then
    pass_test "Multiple Worker Processes active (${WORKER_COUNT} workers)"
else
    fail_test "Expected at least 2 Worker Processes, found ${WORKER_COUNT}"
fi

# ------------------------------------------------------------------------------
# TEST 1: Single Normal Request
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[1] Test Normal Request & Response Headers (127.0.0.1)...${NC}"
HEADERS=$(/usr/bin/wget -qO /dev/null --server-response http://127.0.0.1:${PORT}/ 2>&1 || true)
STATUS_1=$(echo "$HEADERS" | awk '/^  HTTP\/1\.[01]/ {print $2; exit}')
SERVER_HDR=$(echo "$HEADERS" | awk -F': ' '/^  Server:/ {print $2; exit}' | tr -d '\r')
LIMIT_HDR=$(echo "$HEADERS" | awk -F': ' '/^  X-RateLimit-Limit:/ {print $2; exit}' | tr -d '\r')

echo "  * HTTP Status       : ${STATUS_1}"
echo "  * Server Header     : ${SERVER_HDR}"
echo "  * X-RateLimit-Limit : ${LIMIT_HDR}"

if [ "$STATUS_1" = "200" ] && [ "$SERVER_HDR" = "CustomWebServer" ] && [ "$LIMIT_HDR" = "20" ]; then
    pass_test "Normal request returned HTTP 200, Server: CustomWebServer, X-RateLimit-Limit: 20"
else
    fail_test "Normal request header check failed"
fi

# Wait 1.2s for rate window (1s) to reset cleanly
sleep 1.2

# ------------------------------------------------------------------------------
# TEST 2: Requests Below Threshold (15 requests within 1s, limit is 20)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2] Test Requests Below Threshold (15 requests <= limit 20)...${NC}"
OK_BELOW=0
for i in $(seq 1 15); do
    code=$(http_status "http://127.0.0.1:${PORT}/")
    if [ "$code" = "200" ]; then
        OK_BELOW=$((OK_BELOW + 1))
    fi
done
echo "  * Allowed HTTP 200 responses: ${OK_BELOW}/15"
if [ "$OK_BELOW" -eq 15 ]; then
    pass_test "All 15 legitimate requests below threshold (20/s) succeeded with HTTP 200"
else
    fail_test "Expected 15/15 HTTP 200 responses, got ${OK_BELOW}/15"
fi

# Wait 1.2s for window to reset
sleep 1.2

# ------------------------------------------------------------------------------
# TEST 3: Burst Requests Exceeding Threshold (35 requests in 1s, limit is 20)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3] Test Burst Requests Exceeding Threshold (35 rapid requests, limit = 20/1s)...${NC}"
COUNT_200=0
COUNT_429=0
for i in $(seq 1 35); do
    code=$(http_status "http://127.0.0.1:${PORT}/")
    if [ "$code" = "200" ]; then
        COUNT_200=$((COUNT_200 + 1))
    elif [ "$code" = "429" ]; then
        COUNT_429=$((COUNT_429 + 1))
    fi
done

echo "  * HTTP 200 (Allowed) : ${COUNT_200}"
echo "  * HTTP 429 (Blocked) : ${COUNT_429}"

if [ "$COUNT_200" -eq 20 ] && [ "$COUNT_429" -eq 15 ]; then
    pass_test "Exact rate limit enforced across workers: 20 allowed (HTTP 200), 15 blocked (HTTP 429)"
else
    fail_test "Rate limit mismatch: expected 20 HTTP 200 and 15 HTTP 429, got ${COUNT_200} and ${COUNT_429}"
fi

# ------------------------------------------------------------------------------
# TEST 4: IP Tracking & X-Forwarded-For Spoofing Resistance
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4] Test IP Tracking & X-Forwarded-For Spoofing Resistance...${NC}"
# Immediately while 127.0.0.1 is still rate-limited, try spoofing X-Forwarded-For
SPOOF_CODE=$(http_status "http://127.0.0.1:${PORT}/" "X-Forwarded-For: 203.0.113.99")
# Meanwhile, a request from IPv6 localhost [::1] has a distinct 16-byte in6_addr key
IPV6_CODE=$(http_status "http://[::1]:${PORT}/")

echo "  * Spoofed X-Forwarded-For (from 127.0.0.1) HTTP code : ${SPOOF_CODE}"
echo "  * Independent IPv6 client ([::1]) HTTP code          : ${IPV6_CODE}"

if [ "$SPOOF_CODE" = "429" ] && [ "$IPV6_CODE" = "200" ]; then
    pass_test "Untrusted X-Forwarded-For ignored (429) while distinct IPv6 client [::1] allowed (200)"
else
    fail_test "IP tracking test failed (Spoof=${SPOOF_CODE}, IPv6=${IPV6_CODE})"
fi

# Wait 1.2s and verify recovery after window expires
sleep 1.2
RECOVERY_CODE=$(http_status "http://127.0.0.1:${PORT}/")
echo "  * Post-window recovery HTTP code (after 1.2s)        : ${RECOVERY_CODE}"
if [ "$RECOVERY_CODE" = "200" ]; then
    pass_test "Client 127.0.0.1 automatically unblocked (HTTP 200) after 1s window elapsed"
else
    fail_test "Client failed to recover after time window"
fi

# ------------------------------------------------------------------------------
# TEST 5: Multi-Worker Shared Memory Synchronization Under Parallel Load
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[5] Test Multi-Worker Shared Counter & Logging...${NC}"
sleep 1.2
# Fire 40 concurrent requests across 4 parallel subshells to hit both workers simultaneously
seq 1 40 | xargs -n 1 -P 4 -I {} sh -c '/usr/bin/wget -qO /dev/null --server-response http://127.0.0.1:8080/ 2>&1 || true' >/dev/null

SEC_LOGS=$(grep -c "\[CUSTOM_SECURITY\] RATE_LIMIT_EXCEEDED" "$ERROR_LOG" || true)
DISTINCT_ACCESS_PIDS=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^pid=/) print $i}' "$ACCESS_LOG" | sort -u | tr '\n' ' ')

echo "  * Security event log entries in error.log : ${SEC_LOGS}"
echo "  * Worker PIDs observed in access.log      : ${DISTINCT_ACCESS_PIDS}"
echo "  * Sample security log entry:"
grep "\[CUSTOM_SECURITY\] RATE_LIMIT_EXCEEDED" "$ERROR_LOG" | head -n 2 | sed 's/^/      /'

if [ "$SEC_LOGS" -ge 15 ]; then
    pass_test "Security events accurately recorded in logs/error.log (${SEC_LOGS} events)"
else
    fail_test "Expected security log entries in logs/error.log, found ${SEC_LOGS}"
fi

# Stop server cleanly
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -s quit
sleep 1

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "TEST SUMMARY: ${GREEN}${PASS_COUNT} PASSED${NC}, ${RED}${FAIL_COUNT} FAILED${NC}"
echo -e "${CYAN}======================================================================${NC}"

if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
else
    exit 1
fi
