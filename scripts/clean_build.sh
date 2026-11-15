#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/clean_build.sh
# Purpose: Safely stop any running Custom Nginx instance, clean object files in
#          source/nginx, and reset temporary build/log artifacts while keeping
#          original source and patches intact.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_SRC_DIR="${PROJECT_ROOT}/source/nginx"
NGINX_PID="${PROJECT_ROOT}/logs/nginx.pid"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
CUSTOM_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"

echo "[CLEAN] Checking for running Custom Nginx process..."
systemctl --user stop custom-nginx.service 2>/dev/null || true
if [ -f "$NGINX_PID" ] && kill -0 "$(cat "$NGINX_PID")" 2>/dev/null; then
    if [ -x "$CUSTOM_BIN" ]; then
        "$CUSTOM_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -s stop || true
    else
        kill -TERM "$(cat "$NGINX_PID")" || true
    fi
    sleep 1
    echo "[CLEAN] Stopped running Custom Nginx process."
fi

if [ -d "$WORK_SRC_DIR" ] && [ -f "${WORK_SRC_DIR}/Makefile" ]; then
    echo "[CLEAN] Running 'make clean' in ${WORK_SRC_DIR}..."
    make -C "$WORK_SRC_DIR" clean
fi

echo "[CLEAN] Cleaning temporary runtime directories and old build logs..."
rm -rf "${PROJECT_ROOT}/build/client_body_temp" \
       "${PROJECT_ROOT}/build/proxy_temp" \
       "${PROJECT_ROOT}/build/fastcgi_temp" \
       "${PROJECT_ROOT}/build/uwsgi_temp" \
       "${PROJECT_ROOT}/build/scgi_temp" \
       "${PROJECT_ROOT}/logs/build.log" \
       "${PROJECT_ROOT}/logs/nginx.pid" \
       "${PROJECT_ROOT}/logs/nginx.lock"

# If --full-reset is passed, also reset working source tree from pristine copy
if [ "${1:-}" = "--reset-source" ] && [ -d "${PROJECT_ROOT}/source/nginx-original" ]; then
    echo "[CLEAN] Resetting ${WORK_SRC_DIR} from pristine ${PROJECT_ROOT}/source/nginx-original..."
    rm -rf "$WORK_SRC_DIR"
    cp -a "${PROJECT_ROOT}/source/nginx-original" "$WORK_SRC_DIR"
fi

touch "${PROJECT_ROOT}/build/.gitkeep" "${PROJECT_ROOT}/logs/.gitkeep"
echo "[SUCCESS] Clean completed."
