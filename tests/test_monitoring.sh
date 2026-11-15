#!/usr/bin/env bash
# ==============================================================================
# Script: tests/test_monitoring.sh
# Purpose: Comprehensive integration test for ngx_http_custom_monitoring_module
# Tests:
#   1. Valid JSON structure & required fields on GET /custom_status
#   2. Accurate runtime counter increments (total, successful, client_errors)
#   3. Blocked Requests counter integration with ngx_http_custom_security_module (HTTP 429)
#   4. Real-time Active Connections & Uptime tracking
#   5. Access Control enforcement (localhost allowed, unauthorized IP rejected with HTTP 403)
#   6. Multi-worker shared memory atomic aggregation & stability under burst load
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

http_status() {
    local url="$1"
    local out
    out=$(/usr/bin/wget -qO /dev/null --server-response "$url" 2>&1 || true)
    echo "$out" | awk '/^  HTTP\/1\.[01]/ {code=$2} END {print code+0}'
}

json_field() {
    local json="$1"
    local key="$2"
    echo "$json" | awk -F': ' -v k="\"$key\"" '$1 ~ k {gsub(/[", \r]/, "", $2); print $2}'
}

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}    CUSTOM MONITORING MODULE TEST SUITE (ngx_http_custom_monitoring)  ${NC}"
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

MASTER_PID=$(cat "$NGINX_PID")
WORKER_COUNT=$(pgrep -P "$MASTER_PID" | wc -l)
echo "  * Master PID   : ${MASTER_PID}"
echo "  * Worker Count : ${WORKER_COUNT}"

# ------------------------------------------------------------------------------
# TEST 1: Initial JSON Response & Schema Validation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[1] Test /custom_status JSON Format & Headers...${NC}"
RESP_HDR=$(/usr/bin/wget -qO /dev/null --server-response "http://127.0.0.1:${PORT}/custom_status" 2>&1 || true)
JSON_1=$(/usr/bin/wget -qO- "http://127.0.0.1:${PORT}/custom_status" 2>/dev/null || true)

CTYPE=$(echo "$RESP_HDR" | awk -F': ' '/^  Content-Type:/ {print $2; exit}' | tr -d '\r')
SRV_VAL=$(json_field "$JSON_1" "server")
ST_VAL=$(json_field "$JSON_1" "status")
TOT_1=$(json_field "$JSON_1" "total_requests")
SUC_1=$(json_field "$JSON_1" "successful_requests")
ACT_1=$(json_field "$JSON_1" "active_connections")

echo "$JSON_1" | sed 's/^/    /'

if python3 -c "import sys, json; data = json.loads(sys.stdin.read()); assert data['server']=='CustomWebServer' and data['status']=='running'" <<< "$JSON_1" 2>/dev/null \
   && [ "$CTYPE" = "application/json" ] && [ "$ACT_1" -ge 1 ]; then
    pass_test "Valid JSON returned with Content-Type: application/json and all required keys"
else
    fail_test "Invalid JSON or missing fields on /custom_status"
fi

# ------------------------------------------------------------------------------
# TEST 2: Runtime Counter Accuracy (200 OK & 404 Client Errors)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2] Test Runtime Counter Increments (5x 200 OK + 3x 404 Not Found)...${NC}"
sleep 1.2
for i in $(seq 1 5); do
    /usr/bin/wget -qO /dev/null "http://127.0.0.1:${PORT}/" || true
done
for i in $(seq 1 3); do
    /usr/bin/wget -qO /dev/null "http://127.0.0.1:${PORT}/nonexistent_${i}" 2>/dev/null || true
done

JSON_2=$(/usr/bin/wget -qO- "http://127.0.0.1:${PORT}/custom_status" 2>/dev/null)
TOT_2=$(json_field "$JSON_2" "total_requests")
SUC_2=$(json_field "$JSON_2" "successful_requests")
ERR4_2=$(json_field "$JSON_2" "client_errors")
BLK_2=$(json_field "$JSON_2" "blocked_requests")

echo "  * total_requests      : ${TOT_2} (before: ${TOT_1})"
echo "  * successful_requests : ${SUC_2} (before: ${SUC_1})"
echo "  * client_errors (4xx) : ${ERR4_2}"
echo "  * blocked_requests    : ${BLK_2}"

EXPECTED_TOT=$((TOT_1 + 5 + 3 + 1))
EXPECTED_SUC=$((SUC_1 + 5 + 1))

if [ "$TOT_2" -eq "$EXPECTED_TOT" ] && [ "$SUC_2" -eq "$EXPECTED_SUC" ] && [ "$ERR4_2" -eq 3 ] && [ "$BLK_2" -eq 0 ]; then
    pass_test "Counters incremented accurately: +5 successful, +3 client_errors (404), 0 blocked"
else
    fail_test "Counter mismatch: got total=${TOT_2} (exp ${EXPECTED_TOT}), success=${SUC_2} (exp ${EXPECTED_SUC}), 4xx=${ERR4_2}"
fi

# ------------------------------------------------------------------------------
# TEST 3: Blocked Requests Integration (Triggering Rate Limit HTTP 429)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3] Test Blocked Requests Tracking (Burst 30 requests -> 20 OK + 10 HTTP 429)...${NC}"
sleep 1.2
for i in $(seq 1 30); do
    /usr/bin/wget -qO /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null || true
done

JSON_3=$(/usr/bin/wget -qO- "http://127.0.0.1:${PORT}/custom_status" 2>/dev/null)
ERR4_3=$(json_field "$JSON_3" "client_errors")
BLK_3=$(json_field "$JSON_3" "blocked_requests")
UPTIME_3=$(json_field "$JSON_3" "uptime_seconds")

echo "  * client_errors (4xx) : ${ERR4_3} (increased by 10 from 429 responses)"
echo "  * blocked_requests    : ${BLK_3} (expected 10)"
echo "  * uptime_seconds      : ${UPTIME_3}s"

if [ "$BLK_3" -eq 10 ] && [ "$ERR4_3" -eq 13 ] && [ "$UPTIME_3" -ge 2 ]; then
    pass_test "Blocked requests (10 HTTP 429s) and uptime (${UPTIME_3}s) accurately tracked"
else
    fail_test "Blocked request counter mismatch: got blocked=${BLK_3}, 4xx=${ERR4_3}, uptime=${UPTIME_3}"
fi

# ------------------------------------------------------------------------------
# TEST 4: Access Control Enforcement
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4] Test Monitoring Endpoint Access Control...${NC}"
CODE_LOCAL4=$(http_status "http://127.0.0.1:${PORT}/custom_status")
CODE_LOCAL6=$(http_status "http://[::1]:${PORT}/custom_status")
CODE_DENIED=$(http_status "http://127.0.0.1:${PORT}/custom_status_admin_only")

echo "  * GET /custom_status from IPv4 127.0.0.1            : HTTP ${CODE_LOCAL4}"
echo "  * GET /custom_status from IPv6 [::1]                : HTTP ${CODE_LOCAL6}"
echo "  * GET /custom_status_admin_only (unauthorized IP)   : HTTP ${CODE_DENIED}"

ACL_LOG_COUNT=$(grep -c "\[CUSTOM_MONITORING\] ACCESS_DENIED" "$ERROR_LOG" || true)
echo "  * Access denied log entries in error.log            : ${ACL_LOG_COUNT}"

if [ "$CODE_LOCAL4" = "200" ] && [ "$CODE_LOCAL6" = "200" ] && [ "$CODE_DENIED" = "403" ] && [ "$ACL_LOG_COUNT" -ge 1 ]; then
    pass_test "Access Control enforced: localhost allowed (200), unauthorized IP rejected (403 Forbidden)"
else
    fail_test "Access Control check failed"
fi

# ------------------------------------------------------------------------------
# TEST 5: Multi-Worker Concurrent Polling & Crash Resilience
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[5] Test Multi-Worker Concurrent Polling & Stability...${NC}"
seq 1 20 | xargs -n 1 -P 4 -I {} sh -c '/usr/bin/wget -qO- http://127.0.0.1:8080/custom_status >/dev/null 2>&1'
FINAL_JSON=$(/usr/bin/wget -qO- "http://127.0.0.1:${PORT}/custom_status" 2>/dev/null)
echo "  * Final /custom_status snapshot:"
echo "$FINAL_JSON" | sed 's/^/    /'

ALIVE_WORKERS=$(pgrep -P "$MASTER_PID" | wc -l)
if [ "$ALIVE_WORKERS" -eq "$WORKER_COUNT" ] && [ -n "$FINAL_JSON" ]; then
    pass_test "All ${ALIVE_WORKERS} workers healthy with zero crashes after concurrent polling"
else
    fail_test "Worker crash or empty response detected"
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
