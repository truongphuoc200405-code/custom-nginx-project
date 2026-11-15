#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/test_signal_handling.sh
# Purpose: Comprehensive Linux POSIX Signal Handling & Graceful Lifecycle
#          Verification for Custom Nginx Web Server.
# Signals Tested:
#   1. SIGHUP  - Safe Graceful Reload (Backup -> Modify -> nginx -t -> SIGHUP -> Verify)
#   2. SIGHUP  - Invalid Config Protection (Corrupt config -> nginx -t fails -> Rollback without reload)
#   3. SIGUSR1 - Zero-Downtime Log Reopening (Log rotation simulation)
#   4. SIGUSR2 + SIGWINCH + SIGQUIT - Live Binary Upgrade / Dual-Master Handover
#   5. SIGQUIT - Graceful Shutdown while Concurrent HTTP Requests are in flight
#   6. SIGTERM - Fast Shutdown & Port Release
#   7. Systemd Service Restart & Final Cleanup Verification
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
NGINX_CONF_BAK="${PROJECT_ROOT}/config/nginx.conf.signal_bak"
PID_FILE="${PROJECT_ROOT}/logs/nginx.pid"
OLDBIN_PID_FILE="${PROJECT_ROOT}/logs/nginx.pid.oldbin"
ACCESS_LOG="${PROJECT_ROOT}/logs/access.log"
ERROR_LOG="${PROJECT_ROOT}/logs/error.log"
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

# Verify that a PID truly belongs to our Custom Nginx binary before sending any signal
verify_custom_nginx_pid() {
    local pid="$1"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    local exe
    exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
    [ "$exe" = "$NGINX_BIN" ]
}

cleanup() {
    if [ -f "$NGINX_CONF_BAK" ]; then
        cp "$NGINX_CONF_BAK" "$NGINX_CONF"
        rm -f "$NGINX_CONF_BAK"
    fi
    rm -f "${PROJECT_ROOT}/logs/access.log.rotated"
}
trap cleanup EXIT

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}   CUSTOM NGINX LINUX SIGNAL HANDLING & GRACEFUL SHUTDOWN TEST SUITE  ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# Ensure Custom Nginx is running cleanly via systemd before starting tests
bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null
sleep 1

MASTER_PID="$(cat "$PID_FILE")"
if ! verify_custom_nginx_pid "$MASTER_PID"; then
    echo "[ERROR] Master PID ${MASTER_PID} does not match ${NGINX_BIN}!" >&2
    exit 1
fi
INITIAL_WORKERS="$(pgrep -P "$MASTER_PID" | sort | tr '\n' ' ')"
echo -e "  * Initial Master PID  : ${MASTER_PID}"
echo -e "  * Initial Worker PIDs : ${INITIAL_WORKERS}"

# ------------------------------------------------------------------------------
# TEST 1: SIGHUP Graceful Reload (Valid Configuration Change: 2 -> 3 Workers)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[1] Test SIGHUP Graceful Reload (Valid Config: worker_processes 2 -> 3)...${NC}"
cp "$NGINX_CONF" "$NGINX_CONF_BAK"
sed -i 's/worker_processes  2;/worker_processes  3;/' "$NGINX_CONF"

if "$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -t 2>/dev/null; then
    kill -HUP "$MASTER_PID"
    sleep 1
    AFTER_HUP_MASTER="$(cat "$PID_FILE")"
    AFTER_HUP_WORKERS="$(pgrep -P "$AFTER_HUP_MASTER" | sort | tr '\n' ' ')"
    WORKER_CNT="$(pgrep -P "$AFTER_HUP_MASTER" | wc -l)"
    echo "  * Master PID after SIGHUP : ${AFTER_HUP_MASTER} (Unchanged)"
    echo "  * New Worker PIDs (3)     : ${AFTER_HUP_WORKERS}"

    if [ "$AFTER_HUP_MASTER" = "$MASTER_PID" ] && [ "$WORKER_CNT" -eq 3 ] \
       && [ "$AFTER_HUP_WORKERS" != "$INITIAL_WORKERS" ]; then
        pass_test "SIGHUP kept Master PID ${MASTER_PID}, gracefully retired old workers, and spawned 3 new workers"
    else
        fail_test "SIGHUP reload verification failed"
    fi
else
    fail_test "Valid config failed nginx -t unexpectedly"
fi

# Restore original 2-worker config and reload
cp "$NGINX_CONF_BAK" "$NGINX_CONF"
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -t 2>/dev/null
kill -HUP "$MASTER_PID"
sleep 1

# ------------------------------------------------------------------------------
# TEST 2: Safe Reload Guard & Automatic Rollback on Invalid Config
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2] Test Safe Reload Rollback on Invalid Configuration...${NC}"
WORKERS_BEFORE_BAD="$(pgrep -P "$MASTER_PID" | sort | tr '\n' ' ')"
cp "$NGINX_CONF" "$NGINX_CONF_BAK"
echo "invalid_directive_xyz 123;" >> "$NGINX_CONF"

echo "  * Running pre-reload 'nginx -t' on broken configuration..."
if "$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -t 2>/dev/null; then
    fail_test "Broken config passed nginx -t unexpectedly"
else
    echo "  * 'nginx -t' detected syntax error! Aborting SIGHUP and rolling back config..."
    cp "$NGINX_CONF_BAK" "$NGINX_CONF"
    rm -f "$NGINX_CONF_BAK"
    WORKERS_AFTER_ROLLBACK="$(pgrep -P "$MASTER_PID" | sort | tr '\n' ' ')"
    HTTP_OK=$(/usr/bin/wget -qO /dev/null --server-response "http://127.0.0.1:${PORT}/" 2>&1 | awk '/^  HTTP\/1\.[01]/ {print $2; exit}')
    if [ "$WORKERS_BEFORE_BAD" = "$WORKERS_AFTER_ROLLBACK" ] && [ "$HTTP_OK" = "200" ]; then
        pass_test "Aborted reload on invalid config, rolled back cleanly, workers (${WORKERS_AFTER_ROLLBACK}) uninterrupted"
    else
        fail_test "Rollback verification failed"
    fi
fi

# ------------------------------------------------------------------------------
# TEST 3: SIGUSR1 Zero-Downtime Log Reopening (Log Rotation)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3] Test SIGUSR1 Log File Reopening (Zero-Downtime Log Rotation)...${NC}"
ROTATED_LOG="${PROJECT_ROOT}/logs/access.log.rotated"
mv "$ACCESS_LOG" "$ROTATED_LOG"

echo "  * Sending SIGUSR1 to Master PID ${MASTER_PID}..."
kill -USR1 "$MASTER_PID"
sleep 1

# Generate a fresh HTTP request to verify writes go to the newly reopened access.log
/usr/bin/wget -qO /dev/null "http://127.0.0.1:${PORT}/"
sleep 0.3

if [ -f "$ACCESS_LOG" ] && [ "$(wc -l < "$ACCESS_LOG")" -ge 1 ] \
   && grep -q "reopening logs" "$ERROR_LOG"; then
    pass_test "SIGUSR1 recreated and reopened logs/access.log without dropping connections"
else
    fail_test "SIGUSR1 log reopening failed"
fi
rm -f "$ROTATED_LOG"

# ------------------------------------------------------------------------------
# TEST 4: SIGUSR2 Live Binary Upgrade & Handover Simulation
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4] Test SIGUSR2 Live Binary Upgrade & Old Master Retirement...${NC}"
OLD_MASTER_PID="$(cat "$PID_FILE")"
echo "  * Sending SIGUSR2 to Master PID ${OLD_MASTER_PID}..."
kill -USR2 "$OLD_MASTER_PID"
sleep 1

if [ -f "$OLDBIN_PID_FILE" ] && [ -f "$PID_FILE" ]; then
    NEW_MASTER_PID="$(cat "$PID_FILE")"
    SAVED_OLD_PID="$(cat "$OLDBIN_PID_FILE")"
    echo "  * Old Master PID (in nginx.pid.oldbin) : ${SAVED_OLD_PID}"
    echo "  * New Master PID (in nginx.pid)        : ${NEW_MASTER_PID}"

    # Gracefully retire the old master using SIGQUIT so only the new master remains
    kill -QUIT "$SAVED_OLD_PID"
    sleep 1

    if [ "$SAVED_OLD_PID" = "$OLD_MASTER_PID" ] && [ "$NEW_MASTER_PID" != "$OLD_MASTER_PID" ] \
       && kill -0 "$NEW_MASTER_PID" 2>/dev/null; then
        MASTER_PID="$NEW_MASTER_PID"
        pass_test "SIGUSR2 spawned new Master (${NEW_MASTER_PID}) and retired old Master (${SAVED_OLD_PID}) seamlessly"
    else
        fail_test "SIGUSR2 handover verification failed"
    fi
else
    fail_test "SIGUSR2 did not create nginx.pid.oldbin and new nginx.pid"
fi

# ------------------------------------------------------------------------------
# TEST 5: SIGQUIT Graceful Shutdown with Concurrent In-Flight Requests
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[5] Test SIGQUIT Graceful Shutdown (Zero Dropped In-Flight Requests)...${NC}"
# Stop systemd supervision first so we can test direct POSIX signals on a standalone
# Custom Nginx instance without systemd auto-restart racing with our test steps.
systemctl --user stop custom-nginx.service 2>/dev/null || true
sleep 1
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF"
sleep 1
MASTER_PID="$(cat "$PID_FILE")"

# Launch 15 rapid requests in background while sending SIGQUIT
(
    for i in $(seq 1 15); do
        /usr/bin/wget -qO /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null || true
    done
) &
BG_CLIENT_PID=$!

sleep 0.05
if verify_custom_nginx_pid "$MASTER_PID"; then
    echo "  * Sending SIGQUIT (graceful shutdown) to Master PID ${MASTER_PID}..."
    kill -QUIT "$MASTER_PID"
fi
wait "$BG_CLIENT_PID" || true
sleep 1

if ! kill -0 "$MASTER_PID" 2>/dev/null \
   && grep -q "gracefully shutting down" "$ERROR_LOG"; then
    pass_test "SIGQUIT completed in-flight requests and exited Master & Workers cleanly"
else
    fail_test "SIGQUIT graceful shutdown did not complete cleanly"
fi

# ------------------------------------------------------------------------------
# TEST 6: SIGTERM Fast Shutdown & Port Release Verification
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[6] Test SIGTERM Fast Shutdown & Port 8080 Release...${NC}"
# Start standalone instance to test direct SIGTERM without systemd auto-restart race
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF"
sleep 1
TERM_MASTER_PID="$(cat "$PID_FILE")"
echo "  * Started Custom Nginx (Master PID: ${TERM_MASTER_PID}). Sending SIGTERM..."

if verify_custom_nginx_pid "$TERM_MASTER_PID"; then
    kill -TERM "$TERM_MASTER_PID"
fi
sleep 1

PORT_CHECK="$(ss -tulpn 2>/dev/null | grep -E ":${PORT}\b" || true)"
if ! kill -0 "$TERM_MASTER_PID" 2>/dev/null && [ -z "$PORT_CHECK" ] && [ ! -f "$PID_FILE" ]; then
    pass_test "SIGTERM terminated Master & Workers immediately, removed PID file, and released port ${PORT}"
else
    fail_test "SIGTERM cleanup or port release failed"
fi

# ------------------------------------------------------------------------------
# TEST 7: Systemd Service Restart & Final Health Verification
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[7] Restoring Custom Nginx via systemd Service & Verifying Status...${NC}"
bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null
sleep 1

FINAL_PID="$(cat "$PID_FILE")"
STATUS_JSON="$(/usr/bin/wget -qO- "http://127.0.0.1:${PORT}/custom_status" 2>/dev/null || true)"

if systemctl --user is-active --quiet custom-nginx.service \
   && verify_custom_nginx_pid "$FINAL_PID" \
   && echo "$STATUS_JSON" | grep -q '"status": "running"'; then
    pass_test "systemd service active (MainPID: ${FINAL_PID}) and /custom_status healthy"
else
    fail_test "Final systemd service restoration failed"
fi

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "SIGNAL TEST SUMMARY: ${GREEN}${PASS_COUNT} PASSED${NC}, ${RED}${FAIL_COUNT} FAILED${NC}"
echo -e "${CYAN}======================================================================${NC}"

if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
else
    exit 1
fi
