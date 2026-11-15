#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/service_start.sh
# Purpose: Install/sync systemd/custom-nginx.service into user systemd directory,
#          verify port/PID safety, start custom-nginx.service, and sync logs.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="custom-nginx.service"
UNIT_SRC="${PROJECT_ROOT}/systemd/${UNIT_NAME}"
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
UNIT_DST="${USER_SYSTEMD_DIR}/${UNIT_NAME}"

NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
PID_FILE="${PROJECT_ROOT}/logs/nginx.pid"
ERROR_LOG="${PROJECT_ROOT}/logs/error.log"
SECURITY_LOG="${PROJECT_ROOT}/logs/security.log"
PORT=8080

echo "[SERVICE-START] Preparing to start ${UNIT_NAME} via systemd..."

if [ ! -x "$NGINX_BIN" ]; then
    echo "[ERROR] Custom Nginx binary not found at ${NGINX_BIN}. Run ./scripts/build_all.sh first." >&2
    exit 1
fi

# Reset any auto-restart/failed state if service is not cleanly active
if [ "$(systemctl --user show -p ActiveState --value "$UNIT_NAME" 2>/dev/null || true)" != "active" ]; then
    systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
    systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true
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
fi

# 1. Safety Check: Ensure PIDFile does not belong to an unrelated process
if [ -f "$PID_FILE" ]; then
    EXISTING_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        PROC_EXE="$(readlink -f "/proc/${EXISTING_PID}/exe" 2>/dev/null || true)"
        if [ "$PROC_EXE" != "$NGINX_BIN" ]; then
            echo "[SAFETY-ABORT] PID ${EXISTING_PID} in ${PID_FILE} belongs to ${PROC_EXE:-another process}, not Custom Nginx!" >&2
            exit 1
        fi
        # If running outside systemd, gracefully stop standalone process before systemd starts it
        if ! systemctl --user is-active --quiet "$UNIT_NAME"; then
            echo "[SERVICE-START] Stopping standalone Custom Nginx (PID ${EXISTING_PID}) before handing over to systemd..."
            "$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -s quit || true
            sleep 1
        fi
    else
        echo "[SERVICE-START] Removing stale PID file (${PID_FILE})..."
        rm -f "$PID_FILE"
    fi
fi

# 2. Safety Check: Ensure Port 8080 is not occupied by another program
if ! systemctl --user is-active --quiet "$UNIT_NAME"; then
    PORT_OWNER="$(ss -tulpn 2>/dev/null | grep -E ":${PORT}\b" || true)"
    if [ -n "$PORT_OWNER" ]; then
        echo "[SAFETY-ABORT] Port ${PORT} is already in use by another process:" >&2
        echo "$PORT_OWNER" >&2
        exit 1
    fi
fi

# 3. Sync unit file into ~/.config/systemd/user/ (no sudo required, never touches system nginx.service)
mkdir -p "$USER_SYSTEMD_DIR" "${PROJECT_ROOT}/logs"
cp "$UNIT_SRC" "$UNIT_DST"

systemctl --user daemon-reload
systemctl --user start "$UNIT_NAME"
sleep 1

# 4. Sync dedicated security log from error.log
touch "$ERROR_LOG" "$SECURITY_LOG"
grep "\[CUSTOM_SECURITY\]\|\[CUSTOM_MONITORING\]" "$ERROR_LOG" > "$SECURITY_LOG" || true

if systemctl --user is-active --quiet "$UNIT_NAME"; then
    MAIN_PID="$(systemctl --user show -p MainPID --value "$UNIT_NAME")"
    echo "[SUCCESS] ${UNIT_NAME} is active and running under systemd (MainPID: ${MAIN_PID}, Port: ${PORT})."
else
    echo "[ERROR] Failed to start ${UNIT_NAME}!" >&2
    systemctl --user status "$UNIT_NAME" --no-pager || true
    exit 1
fi
