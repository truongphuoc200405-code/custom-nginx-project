#!/usr/bin/env bash
# ==============================================================================
# Script: tests/run_all_tests.sh
# Purpose: Master End-to-End Integration & Audit Test Runner for Custom Nginx
# Categories Tested:
#   1. Environment Test
#   2. Build & Binary Verification Test
#   3. HTTP Functionality Test
#   4. Server Header Customization Test
#   5. Custom Security Module Test
#   6. Custom Monitoring Module Test
#   7. Linux Process Monitoring Test
#   8. Linux Resource (CPU/RAM) Monitoring Test
#   9. Linux Signal Handling & Graceful Reload Test
#  10. systemd Service Lifecycle Test
# ==============================================================================

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
WGET_BIN="/usr/bin/wget"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

declare -a RESULTS_TABLE=()

record_result() {
    local id="$1"
    local name="$2"
    local status="$3"
    local detail="$4"

    case "$status" in
        PASS)
            TOTAL_PASS=$((TOTAL_PASS + 1))
            ;;
        FAIL)
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            ;;
        SKIPPED)
            TOTAL_SKIP=$((TOTAL_SKIP + 1))
            ;;
    esac

    RESULTS_TABLE+=("$(printf "%-4s | %-34s | %-8s | %s" "$id" "$name" "$status" "$detail")")
}

echo "=============================================================================="
echo "           CUSTOM NGINX WEB SERVER - MASTER TEST SUITE (run_all_tests.sh)     "
echo "           Executed at: $(date -Is)                                           "
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [1/10] Running Environment Test..."
if bash "${PROJECT_ROOT}/scripts/check_environment.sh" --build-ready >/dev/null 2>&1; then
    echo "  [PASS] Environment Test"
    record_result "01" "Environment Test" "PASS" "Ubuntu/Kernel/GCC/Make/systemd verified"
else
    echo "  [FAIL] Environment Test"
    record_result "01" "Environment Test" "FAIL" "check_environment.sh --build-ready failed"
fi

# ------------------------------------------------------------------------------
# 2. BUILD & BINARY VERIFICATION TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [2/10] Running Build & Binary Verification Test..."
if [ -x "$NGINX_BIN" ] && \
   [ -x "${PROJECT_ROOT}/build/bin/process_monitor" ] && \
   [ -x "${PROJECT_ROOT}/build/bin/resource_monitor" ] && \
   "$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -t >/dev/null 2>&1 && \
   grep -aq "Server: CustomWebServer" "$NGINX_BIN" && \
   [ "$(nm "$NGINX_BIN" | grep -c "ngx_http_custom_security_module")" -gt 0 ] && \
   [ "$(nm "$NGINX_BIN" | grep -c "ngx_http_custom_monitoring_module")" -gt 0 ]; then
    echo "  [PASS] Build & Binary Verification Test"
    record_result "02" "Build & Binary Test" "PASS" "ELF symbols, monitors & nginx -t verified"
else
    echo "  [FAIL] Build & Binary Verification Test"
    record_result "02" "Build & Binary Test" "FAIL" "Binary or module symbols missing"
fi

# Ensure Custom Nginx service is running for HTTP & Header tests
bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 3. HTTP FUNCTIONALITY TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [3/10] Running HTTP Functionality Test..."
HTTP_BODY=$("$WGET_BIN" -qO- "http://127.0.0.1:8080/index.html" 2>/dev/null || true)
HTTP_HDR=$("$WGET_BIN" -qO /dev/null --server-response "http://127.0.0.1:8080/index.html" 2>&1 || true)

if echo "$HTTP_HDR" | grep -q "HTTP/1.1 200 OK" && \
   echo "$HTTP_BODY" | grep -qi "Custom Nginx"; then
    echo "  [PASS] HTTP Functionality Test"
    record_result "03" "HTTP Functionality Test" "PASS" "GET /index.html returned HTTP 200 OK + body"
else
    echo "  [FAIL] HTTP Functionality Test"
    record_result "03" "HTTP Functionality Test" "FAIL" "Unexpected HTTP status or body"
fi

# ------------------------------------------------------------------------------
# 4. SERVER HEADER CUSTOMIZATION TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [4/10] Running Server Header Customization Test..."
ERR_BODY=$("$WGET_BIN" -qO- --content-on-error "http://127.0.0.1:8080/nonexistent_audit_check" 2>/dev/null || true)
ERR_HDR=$("$WGET_BIN" -qO /dev/null --server-response "http://127.0.0.1:8080/nonexistent_audit_check" 2>&1 || true)

if echo "$HTTP_HDR" | grep -q "Server: CustomWebServer" && \
   ! echo "$HTTP_HDR" | grep -qi "nginx/1.26" && \
   echo "$ERR_HDR" | grep -q "Server: CustomWebServer" && \
   echo "$ERR_BODY" | grep -q "<center>CustomWebServer</center>" && \
   ! echo "$ERR_BODY" | grep -qi "nginx"; then
    echo "  [PASS] Server Header Customization Test"
    record_result "04" "Server Header Test" "PASS" "Server: CustomWebServer on 200 & 404 (no version leak)"
else
    echo "  [FAIL] Server Header Customization Test"
    record_result "04" "Server Header Test" "FAIL" "Server header or error page leaked nginx version"
fi

# ------------------------------------------------------------------------------
# 5. CUSTOM SECURITY MODULE TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [5/10] Running Custom Security Module Test..."
if bash "${PROJECT_ROOT}/tests/test_security.sh" >/dev/null 2>&1; then
    echo "  [PASS] Custom Security Module Test (7/7 assertions)"
    record_result "05" "Security Module Test" "PASS" "Per-IP rate limiting, HTTP 429 & shm verified"
else
    echo "  [FAIL] Custom Security Module Test"
    record_result "05" "Security Module Test" "FAIL" "test_security.sh reported failures"
fi

# ------------------------------------------------------------------------------
# 6. CUSTOM MONITORING MODULE TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [6/10] Running Custom Monitoring Module Test..."
if bash "${PROJECT_ROOT}/tests/test_monitoring.sh" >/dev/null 2>&1; then
    echo "  [PASS] Custom Monitoring Module Test (5/5 assertions)"
    record_result "06" "Monitoring Module Test" "PASS" "/custom_status JSON, counters & ACL verified"
else
    echo "  [FAIL] Custom Monitoring Module Test"
    record_result "06" "Monitoring Module Test" "FAIL" "test_monitoring.sh reported failures"
fi

# ------------------------------------------------------------------------------
# 7. LINUX PROCESS MONITORING TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [7/10] Running Linux Process Monitoring Test..."
if bash "${PROJECT_ROOT}/tests/test_process_monitor.sh" >/dev/null 2>&1; then
    echo "  [PASS] Linux Process Monitoring Test (5/5 assertions)"
    record_result "07" "Process Monitoring Test" "PASS" "Master/Worker PIDs, /proc & port 8080 verified"
else
    echo "  [FAIL] Linux Process Monitoring Test"
    record_result "07" "Process Monitoring Test" "FAIL" "test_process_monitor.sh reported failures"
fi

# ------------------------------------------------------------------------------
# 8. LINUX RESOURCE (CPU/RAM) MONITORING TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [8/10] Running Linux Resource (CPU/RAM) Monitoring Test..."
if bash "${PROJECT_ROOT}/tests/test_resource_monitor.sh" >/dev/null 2>&1; then
    echo "  [PASS] Linux Resource Monitoring Test (6/6 assertions)"
    record_result "08" "Resource Monitoring Test" "PASS" "Two-sample CPU%, VmRSS, VmSize & scaling verified"
else
    echo "  [FAIL] Linux Resource Monitoring Test"
    record_result "08" "Resource Monitoring Test" "FAIL" "test_resource_monitor.sh reported failures"
fi

# ------------------------------------------------------------------------------
# 9. LINUX SIGNAL HANDLING TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [9/10] Running Linux Signal Handling Test..."
if bash "${PROJECT_ROOT}/scripts/test_signal_handling.sh" >/dev/null 2>&1; then
    echo "  [PASS] Linux Signal Handling Test (7/7 assertions)"
    record_result "09" "Signal Handling Test" "PASS" "SIGHUP, rollback, SIGUSR1, SIGQUIT, SIGTERM verified"
else
    echo "  [FAIL] Linux Signal Handling Test"
    record_result "09" "Signal Handling Test" "FAIL" "test_signal_handling.sh reported failures"
fi

# ------------------------------------------------------------------------------
# 10. SYSTEMD SERVICE LIFECYCLE TEST
# ------------------------------------------------------------------------------
echo -e "\n>>> [10/10] Running systemd Service Lifecycle Test..."
if command -v systemctl >/dev/null 2>&1; then
    if bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null 2>&1 && \
       bash "${PROJECT_ROOT}/scripts/service_status.sh" >/dev/null 2>&1 && \
       bash "${PROJECT_ROOT}/scripts/service_reload.sh" >/dev/null 2>&1 && \
       bash "${PROJECT_ROOT}/scripts/service_stop.sh" >/dev/null 2>&1 && \
       bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null 2>&1; then
        echo "  [PASS] systemd Service Lifecycle Test"
        record_result "10" "systemd Service Test" "PASS" "Start, status, reload, stop & restart verified"
    else
        echo "  [FAIL] systemd Service Lifecycle Test"
        record_result "10" "systemd Service Test" "FAIL" "systemd lifecycle script returned non-zero"
    fi
else
    echo "  [SKIPPED] systemd Service Lifecycle Test (systemctl unavailable)"
    record_result "10" "systemd Service Test" "SKIPPED" "systemctl binary not available"
fi

echo ""
echo "=============================================================================="
echo "                        MASTER TEST EXECUTION SUMMARY                         "
echo "=============================================================================="
printf "%-4s | %-34s | %-8s | %s\n" "ID" "TEST SUITE" "STATUS" "DETAILS"
echo "------------------------------------------------------------------------------"
for row in "${RESULTS_TABLE[@]}"; do
    echo "$row"
done
echo "=============================================================================="
echo "TOTAL SUITES: $((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP)) | PASS: ${TOTAL_PASS} | FAIL: ${TOTAL_FAIL} | SKIPPED: ${TOTAL_SKIP}"
echo "=============================================================================="

if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
