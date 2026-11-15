#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/build_nginx.sh
# Purpose: Compile Custom Nginx using GCC and GNU Make with parallel jobs
#          and full build logging.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_SRC_DIR="${PROJECT_ROOT}/source/nginx"
LOGS_DIR="${PROJECT_ROOT}/logs"
BUILD_LOG="${LOGS_DIR}/build.log"

mkdir -p "$LOGS_DIR"

if [ ! -f "${WORK_SRC_DIR}/Makefile" ] || [ ! -f "${WORK_SRC_DIR}/objs/Makefile" ]; then
    echo "[ERROR] Nginx is not configured yet. Run scripts/configure_nginx.sh first." >&2
    exit 1
fi

JOBS="$(nproc 2>/dev/null || echo 2)"
echo "[BUILD] Compiling Custom Nginx with GCC & GNU Make (-j${JOBS})..."

make -C "$WORK_SRC_DIR" -j"$JOBS" 2>&1 | tee -a "$BUILD_LOG"

if [ ! -f "${WORK_SRC_DIR}/objs/nginx" ]; then
    echo "[ERROR] Compilation finished but ${WORK_SRC_DIR}/objs/nginx binary was not produced!" >&2
    exit 1
fi

echo "[SUCCESS] Compilation complete: ${WORK_SRC_DIR}/objs/nginx"
