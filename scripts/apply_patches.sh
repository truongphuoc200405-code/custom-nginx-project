#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/apply_patches.sh
# Purpose: Idempotently apply C source patches from patches/ onto source/nginx/
#          without duplicating patches or corrupting the pristine original tree.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_SRC_DIR="${PROJECT_ROOT}/source/nginx"
PATCH_DIR="${PROJECT_ROOT}/patches"

if [ ! -d "$WORK_SRC_DIR" ] || [ ! -f "${WORK_SRC_DIR}/configure" ]; then
    echo "[ERROR] Working source directory ${WORK_SRC_DIR} not found. Run download_nginx.sh first." >&2
    exit 1
fi

echo "[PATCH] Inspecting patches in ${PATCH_DIR}..."

shopt -s nullglob
PATCH_FILES=("${PATCH_DIR}"/*.patch)
shopt -u nullglob

if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
    echo "[PATCH] No .patch files found in ${PATCH_DIR}."
    exit 0
fi

for patch_file in "${PATCH_FILES[@]}"; do
    patch_name="$(basename "$patch_file")"
    echo "[PATCH] Processing ${patch_name}..."

    # 1. Check if patch can be applied forward cleanly (--dry-run -N)
    if patch -p1 -N --dry-run -d "$WORK_SRC_DIR" < "$patch_file" >/dev/null 2>&1; then
        patch -p1 -N -d "$WORK_SRC_DIR" < "$patch_file"
        echo "  -> [APPLIED] ${patch_name} applied cleanly."
    # 2. Otherwise check if patch is ALREADY applied (reverse --dry-run -R succeeds)
    elif patch -p1 -R --dry-run -d "$WORK_SRC_DIR" < "$patch_file" >/dev/null 2>&1; then
        echo "  -> [SKIPPED] ${patch_name} is already applied (idempotent check passed)."
    else
        echo "[ERROR] Patch ${patch_name} failed dry-run check and cannot be applied cleanly!" >&2
        exit 1
    fi
done

echo "[SUCCESS] All C source patches verified and active."
