#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/configure_nginx.sh
# Purpose: Configure Custom Nginx in isolated build prefix with GCC and
#          custom C modules (ngx_http_custom_security_module &
#          ngx_http_custom_monitoring_module).
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_SRC_DIR="${PROJECT_ROOT}/source/nginx"
BUILD_PREFIX="${BUILD_PREFIX:-${PROJECT_ROOT}/build/custom}"
NGINX_BIN="${BUILD_PREFIX}/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
LOGS_DIR="${PROJECT_ROOT}/logs"
BUILD_LOG="${LOGS_DIR}/build.log"

SECURITY_MOD_DIR="${PROJECT_ROOT}/modules/security"
MONITORING_MOD_DIR="${PROJECT_ROOT}/modules/monitoring"

mkdir -p "$BUILD_PREFIX" "$LOGS_DIR"

if [ ! -f "${WORK_SRC_DIR}/configure" ]; then
    echo "[ERROR] Nginx source not found at ${WORK_SRC_DIR}." >&2
    exit 1
fi

if [ ! -f "${SECURITY_MOD_DIR}/config" ] || [ ! -f "${SECURITY_MOD_DIR}/ngx_http_custom_security_module.c" ]; then
    echo "[ERROR] Custom Security Module missing at ${SECURITY_MOD_DIR}." >&2
    exit 1
fi

if [ ! -f "${MONITORING_MOD_DIR}/config" ] || [ ! -f "${MONITORING_MOD_DIR}/ngx_http_custom_monitoring_module.c" ]; then
    echo "[ERROR] Custom Monitoring Module missing at ${MONITORING_MOD_DIR}." >&2
    exit 1
fi

# Detect optional system development libraries
EXTRA_FLAGS=()
if ! dpkg-query -W -f='${Status}' libpcre2-dev 2>/dev/null | grep -q "install ok installed"; then
    EXTRA_FLAGS+=("--without-http_rewrite_module")
fi
if ! dpkg-query -W -f='${Status}' zlib1g-dev 2>/dev/null | grep -q "install ok installed"; then
    EXTRA_FLAGS+=("--without-http_gzip_module")
fi
if dpkg-query -W -f='${Status}' libssl-dev 2>/dev/null | grep -q "install ok installed"; then
    EXTRA_FLAGS+=("--with-http_ssl_module")
fi

echo "[CONFIGURE] Configuring Custom Nginx (Prefix: ${BUILD_PREFIX})..."
echo "[CONFIGURE] Integrating Security Module   : ${SECURITY_MOD_DIR}"
echo "[CONFIGURE] Integrating Monitoring Module : ${MONITORING_MOD_DIR}"

cd "$WORK_SRC_DIR"

bash ./configure \
    --with-cc=gcc \
    --prefix="$BUILD_PREFIX" \
    --sbin-path="$NGINX_BIN" \
    --conf-path="$NGINX_CONF" \
    --error-log-path="${LOGS_DIR}/error.log" \
    --http-log-path="${LOGS_DIR}/access.log" \
    --pid-path="${LOGS_DIR}/nginx.pid" \
    --lock-path="${LOGS_DIR}/nginx.lock" \
    --with-http_stub_status_module \
    "${EXTRA_FLAGS[@]}" \
    --add-module="$SECURITY_MOD_DIR" \
    --add-module="$MONITORING_MOD_DIR" \
    2>&1 | tee -a "$BUILD_LOG"

# Verify that both custom modules were registered in objs/ngx_modules.c
if ! grep -q "ngx_http_custom_security_module" "${WORK_SRC_DIR}/objs/ngx_modules.c"; then
    echo "[ERROR] ngx_http_custom_security_module was not registered in objs/ngx_modules.c!" >&2
    exit 1
fi
if ! grep -q "ngx_http_custom_monitoring_module" "${WORK_SRC_DIR}/objs/ngx_modules.c"; then
    echo "[ERROR] ngx_http_custom_monitoring_module was not registered in objs/ngx_modules.c!" >&2
    exit 1
fi

echo "[SUCCESS] Custom Nginx configured successfully with Security & Monitoring modules."
