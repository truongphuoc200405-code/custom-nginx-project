#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/build_all.sh
# Purpose: End-to-End Automated Build Pipeline for Custom Nginx Web Server
# Pipeline Stages:
#   1. Environment check
#   2. Download source
#   3. Verify archive
#   4. Extract source (preserving pristine source/nginx-original)
#   5. Apply C source patches (idempotent)
#   6. Configure Nginx
#   7. Integrate Security Module (ngx_http_custom_security_module)
#   8. Integrate Monitoring Module (ngx_http_custom_monitoring_module)
#   9. Compile with GCC & GNU Make
#  10. Install into isolated build/custom/ prefix
#  11. Verify binary (ELF symbols, checksum, nginx -V, nginx -t)
#  12. Verify modules (live HTTP check: Server header, Security, Monitoring)
#  13. Build summary report
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"
LOGS_DIR="${PROJECT_ROOT}/logs"
BUILD_LOG="${LOGS_DIR}/build.log"
NGINX_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

mkdir -p "$LOGS_DIR"
START_TS="$(date +%s)"

echo "======================================================================" | tee "$BUILD_LOG"
echo "       CUSTOM NGINX AUTOMATED BUILD PIPELINE (build_all.sh)           " | tee -a "$BUILD_LOG"
echo "       Started at: $(date -Is)                                        " | tee -a "$BUILD_LOG"
echo "======================================================================" | tee -a "$BUILD_LOG"

# Step 0: Clean previous object artifacts & reset working source from pristine copy
echo -e "\n${CYAN}${BOLD}>>> [STAGE 0] Cleaning previous build state...${NC}" | tee -a "$BUILD_LOG"
bash "${SCRIPTS_DIR}/clean_build.sh" --reset-source

# Step 1: Environment check
echo -e "\n${CYAN}${BOLD}>>> [STAGE 1] Running Environment Check...${NC}" | tee -a "$BUILD_LOG"
bash "${SCRIPTS_DIR}/check_environment.sh" --build-ready | tee -a "$BUILD_LOG"

# Steps 2, 3, 4: Download source, Verify archive, Extract source
echo -e "\n${CYAN}${BOLD}>>> [STAGES 2-4] Downloading, Verifying & Extracting Nginx Source...${NC}" | tee -a "$BUILD_LOG"
bash "${SCRIPTS_DIR}/download_nginx.sh" | tee -a "$BUILD_LOG"

# Step 5: Apply C source patches
echo -e "\n${CYAN}${BOLD}>>> [STAGE 5] Applying C Source Patches...${NC}" | tee -a "$BUILD_LOG"
bash "${SCRIPTS_DIR}/apply_patches.sh" | tee -a "$BUILD_LOG"

# Steps 6, 7, 8: Configure Nginx & Integrate Security + Monitoring Modules
echo -e "\n${CYAN}${BOLD}>>> [STAGES 6-8] Configuring Nginx & Integrating Custom C Modules...${NC}" | tee -a "$BUILD_LOG"
bash "${SCRIPTS_DIR}/configure_nginx.sh"

# Step 9: Compile
echo -e "\n${CYAN}${BOLD}>>> [STAGE 9] Compiling Custom Nginx & C Monitors with GCC & GNU Make...${NC}" | tee -a "$BUILD_LOG"
bash "${SCRIPTS_DIR}/build_nginx.sh"
make -C "$PROJECT_ROOT" monitors | tee -a "$BUILD_LOG"

# Step 10: Install
echo -e "\n${CYAN}${BOLD}>>> [STAGE 10] Installing Custom Nginx into Isolated Prefix...${NC}" | tee -a "$BUILD_LOG"
bash "${SCRIPTS_DIR}/install_nginx.sh"

# Step 11: Verify Binary & Embedded Symbols
echo -e "\n${CYAN}${BOLD}>>> [STAGE 11] Verifying Compiled ELF Binary & Configuration...${NC}" | tee -a "$BUILD_LOG"
"$NGINX_BIN" -V 2>&1 | tee -a "$BUILD_LOG"
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -t 2>&1 | tee -a "$BUILD_LOG"

# Verify custom Server string and module symbols inside the ELF binary
if ! grep -aq "Server: CustomWebServer" "$NGINX_BIN"; then
    echo "[ERROR] Binary verification failed: 'Server: CustomWebServer' not found in ELF!" >&2
    exit 1
fi
if [ "$(nm "$NGINX_BIN" | grep -c "ngx_http_custom_security_module")" -eq 0 ]; then
    echo "[ERROR] Binary verification failed: symbol ngx_http_custom_security_module missing!" >&2
    exit 1
fi
if [ "$(nm "$NGINX_BIN" | grep -c "ngx_http_custom_monitoring_module")" -eq 0 ]; then
    echo "[ERROR] Binary verification failed: symbol ngx_http_custom_monitoring_module missing!" >&2
    exit 1
fi
echo "[VERIFY] ELF symbols & custom Server Header verified in ${NGINX_BIN}." | tee -a "$BUILD_LOG"

# Step 12: Verify Modules at Runtime
echo -e "\n${CYAN}${BOLD}>>> [STAGE 12] Runtime Verification of Custom Server Header, Security & Monitoring...${NC}" | tee -a "$BUILD_LOG"
"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF"
sleep 1

ROOT_HDR=$(/usr/bin/wget -qO /dev/null --server-response http://127.0.0.1:8080/ 2>&1 || true)
STATUS_JSON=$(/usr/bin/wget -qO- http://127.0.0.1:8080/custom_status 2>/dev/null || true)

"$NGINX_BIN" -p "$PROJECT_ROOT" -c "$NGINX_CONF" -s quit
sleep 1

echo "$ROOT_HDR" | grep -E "HTTP/1.1|Server:|X-RateLimit-Limit:" | tee -a "$BUILD_LOG"
echo "$STATUS_JSON" | tee -a "$BUILD_LOG"

if ! echo "$ROOT_HDR" | grep -q "Server: CustomWebServer"; then
    echo "[ERROR] Runtime Server header check failed!" >&2
    exit 1
fi
if ! echo "$ROOT_HDR" | grep -q "X-RateLimit-Limit: 20"; then
    echo "[ERROR] Runtime Security Module header check failed!" >&2
    exit 1
fi
if ! echo "$STATUS_JSON" | grep -q '"server": "CustomWebServer"'; then
    echo "[ERROR] Runtime Monitoring Module JSON check failed!" >&2
    exit 1
fi

# Step 13: Build Summary
END_TS="$(date +%s)"
DURATION=$((END_TS - START_TS))
BIN_SIZE="$(stat -c%s "$NGINX_BIN")"
BIN_SHA256="$(sha256sum "$NGINX_BIN" | awk '{print $1}')"

echo -e "\n${GREEN}======================================================================${NC}" | tee -a "$BUILD_LOG"
echo -e "${BOLD}                    CUSTOM NGINX BUILD SUMMARY                        ${NC}" | tee -a "$BUILD_LOG"
echo -e "${GREEN}======================================================================${NC}" | tee -a "$BUILD_LOG"
echo "  * Build Status       : SUCCESS (Exit Code 0)" | tee -a "$BUILD_LOG"
echo "  * Nginx Base Version : 1.26.2" | tee -a "$BUILD_LOG"
echo "  * Compiler & Make    : $(gcc --version | head -n 1) / $(make --version | head -n 1)" | tee -a "$BUILD_LOG"
echo "  * Installed Binary   : ${NGINX_BIN}" | tee -a "$BUILD_LOG"
echo "  * Binary Size        : ${BIN_SIZE} bytes" | tee -a "$BUILD_LOG"
echo "  * Binary SHA-256     : ${BIN_SHA256}" | tee -a "$BUILD_LOG"
echo "  * Patches Applied    : custom_server_header.patch" | tee -a "$BUILD_LOG"
echo "  * Custom Modules     : ngx_http_custom_security_module, ngx_http_custom_monitoring_module" | tee -a "$BUILD_LOG"
echo "  * Build Duration     : ${DURATION} seconds" | tee -a "$BUILD_LOG"
echo "  * Full Build Log     : ${BUILD_LOG}" | tee -a "$BUILD_LOG"
echo -e "${GREEN}======================================================================${NC}" | tee -a "$BUILD_LOG"
