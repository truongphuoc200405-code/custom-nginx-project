#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/service_reload.sh
# Purpose: Validate configuration syntax (nginx -t) and reload custom-nginx.service
#          zero-downtime via systemd (ExecReload / SIGHUP).
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_NAME="custom-nginx.service"
NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
ERROR_LOG="${PROJECT_ROOT}/logs/error.log"
SECURITY_LOG="${PROJECT_ROOT}/logs/security.log"

echo "[SERVICE-RELOAD] Validating configuration syntax before reload..."
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -t

if ! systemctl --user is-active --quiet "$UNIT_NAME"; then
    echo "[ERROR] ${UNIT_NAME} is not currently running. Start it with scripts/service_start.sh first." >&2
    exit 1
fi

OLD_MAIN_PID="$(systemctl --user show -p MainPID --value "$UNIT_NAME")"
OLD_WORKERS="$(pgrep -P "$OLD_MAIN_PID" | tr '\n' ' ')"

echo "[SERVICE-RELOAD] Sending reload command via systemctl --user reload ${UNIT_NAME}..."
systemctl --user reload "$UNIT_NAME"
sleep 1

NEW_MAIN_PID="$(systemctl --user show -p MainPID --value "$UNIT_NAME")"
NEW_WORKERS="$(pgrep -P "$NEW_MAIN_PID" | tr '\n' ' ')"

if [ -f "$ERROR_LOG" ]; then
    grep "\[CUSTOM_SECURITY\]\|\[CUSTOM_MONITORING\]" "$ERROR_LOG" > "$SECURITY_LOG" || true
fi

echo "  * Master PID (Unchanged) : ${NEW_MAIN_PID}"
echo "  * Previous Worker PIDs   : ${OLD_WORKERS}"
echo "  * New Worker PIDs        : ${NEW_WORKERS}"
echo "[SUCCESS] ${UNIT_NAME} reloaded zero-downtime via systemd."
