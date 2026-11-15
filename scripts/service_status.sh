#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/service_status.sh
# Purpose: Display comprehensive systemd service state, Master/Worker PIDs,
#          listening port status, log file summaries, and live /custom_status.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="custom-nginx.service"
PID_FILE="${PROJECT_ROOT}/logs/nginx.pid"
ACCESS_LOG="${PROJECT_ROOT}/logs/access.log"
ERROR_LOG="${PROJECT_ROOT}/logs/error.log"
SECURITY_LOG="${PROJECT_ROOT}/logs/security.log"
BUILD_LOG="${PROJECT_ROOT}/logs/build.log"
PORT=8080

# Sync security log entries from error.log
if [ -f "$ERROR_LOG" ]; then
    grep "\[CUSTOM_SECURITY\]\|\[CUSTOM_MONITORING\]" "$ERROR_LOG" > "$SECURITY_LOG" || true
fi

echo "======================================================================"
echo "          CUSTOM NGINX SYSTEMD SERVICE STATUS & TELEMETRY             "
echo "======================================================================"

echo -e "\n[1] SYSTEMD UNIT STATUS (${UNIT_NAME})"
systemctl --user status "$UNIT_NAME" --no-pager || true

echo -e "\n[2] PROCESS & PORT VERIFICATION"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    MASTER_PID="$(cat "$PID_FILE")"
    echo "  * PIDFile (${PID_FILE}) : ${MASTER_PID}"
    ps -o pid,ppid,user,%cpu,%mem,cmd -p "$MASTER_PID" --ppid "$MASTER_PID" || true
else
    echo "  * Custom Nginx is not currently running (no active PID)."
fi

echo -e "\n  * Listening Sockets on Port ${PORT}:"
ss -tulpn 2>/dev/null | grep -E ":${PORT}\b" || echo "    (Port ${PORT} not listening)"

echo -e "\n[3] LOG MANAGEMENT SUMMARY (logs/)"
for lf in "$ACCESS_LOG" "$ERROR_LOG" "$SECURITY_LOG" "$BUILD_LOG"; do
    if [ -f "$lf" ]; then
        lines=$(wc -l < "$lf")
        size=$(stat -c%s "$lf")
        printf "  * %-22s : %6d lines (%d bytes)\n" "$(basename "$lf")" "$lines" "$size"
    else
        printf "  * %-22s : [NOT CREATED YET]\n" "$(basename "$lf")"
    fi
done

if systemctl --user is-active --quiet "$UNIT_NAME"; then
    echo -e "\n[4] LIVE MONITORING ENDPOINT (/custom_status)"
    /usr/bin/wget -qO- "http://127.0.0.1:${PORT}/custom_status" 2>/dev/null || echo "  (Failed to query /custom_status)"
fi
echo "======================================================================"
