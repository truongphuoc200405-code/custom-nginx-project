#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/install_nginx.sh
# Purpose: Install compiled Custom Nginx binary and runtime directories into
#          isolated build/custom prefix (never touches /usr/sbin/nginx).
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_SRC_DIR="${PROJECT_ROOT}/source/nginx"
BUILD_PREFIX="${BUILD_PREFIX:-${PROJECT_ROOT}/build/custom}"
NGINX_BIN="${BUILD_PREFIX}/sbin/nginx"
LOGS_DIR="${PROJECT_ROOT}/logs"
BUILD_LOG="${LOGS_DIR}/build.log"

mkdir -p "$LOGS_DIR"

if [ ! -f "${WORK_SRC_DIR}/objs/nginx" ]; then
    echo "[ERROR] Compiled binary ${WORK_SRC_DIR}/objs/nginx not found. Run scripts/build_nginx.sh first." >&2
    exit 1
fi

echo "[INSTALL] Installing Custom Nginx into isolated prefix: ${BUILD_PREFIX}..."

make -C "$WORK_SRC_DIR" install 2>&1 | tee -a "$BUILD_LOG"

# Ensure isolated temporary directories exist for non-root worker processes
mkdir -p "${PROJECT_ROOT}/build/client_body_temp" \
         "${PROJECT_ROOT}/build/proxy_temp" \
         "${PROJECT_ROOT}/build/fastcgi_temp" \
         "${PROJECT_ROOT}/build/uwsgi_temp" \
         "${PROJECT_ROOT}/build/scgi_temp"

if [ ! -x "$NGINX_BIN" ]; then
    echo "[ERROR] Installed binary not found or not executable at ${NGINX_BIN}!" >&2
    exit 1
fi

echo "[SUCCESS] Custom Nginx installed at ${NGINX_BIN}"
