#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/service_stop.sh
# Purpose: Safely stop custom-nginx.service via systemd without touching system
#          nginx.service or unrelated processes.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="custom-nginx.service"
NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
PID_FILE="${PROJECT_ROOT}/logs/nginx.pid"
ERROR_LOG="${PROJECT_ROOT}/logs/error.log"
SECURITY_LOG="${PROJECT_ROOT}/logs/security.log"

echo "[SERVICE-STOP] Stopping ${UNIT_NAME} via systemd..."

# Verify PID safety before stopping
if [ -f "$PID_FILE" ]; then
    EXISTING_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        PROC_EXE="$(readlink -f "/proc/${EXISTING_PID}/exe" 2>/dev/null || true)"
        if [ -n "$PROC_EXE" ] && [ "$PROC_EXE" != "$NGINX_BIN" ]; then
            echo "[SAFETY-ABORT] Refusing to touch PID ${EXISTING_PID} (${PROC_EXE})!" >&2
            exit 1
        fi
    fi
fi

systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true

# Also terminate any standalone Custom Nginx master matching our exact binary path
ORPHAN_PIDS="$(pgrep -f "nginx: master process ${NGINX_BIN}" || true)"
if [ -n "$ORPHAN_PIDS" ]; then
    for opid in $ORPHAN_PIDS; do
        PROC_EXE="$(readlink -f "/proc/${opid}/exe" 2>/dev/null || true)"
        if [ "$PROC_EXE" = "$NGINX_BIN" ]; then
            kill -TERM "$opid" 2>/dev/null || true
        fi
    done
    sleep 1
fi
rm -f "$PID_FILE"
echo "[SUCCESS] ${UNIT_NAME} stopped gracefully."

# Update security log snapshot
if [ -f "$ERROR_LOG" ]; then
    grep "\[CUSTOM_SECURITY\]\|\[CUSTOM_MONITORING\]" "$ERROR_LOG" > "$SECURITY_LOG" || true
fi
