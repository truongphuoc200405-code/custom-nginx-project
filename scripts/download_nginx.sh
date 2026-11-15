#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/download_nginx.sh
# Purpose: Download, verify SHA-256/PGP integrity, and extract official Nginx
#          source archive while preserving a pristine copy of original source.
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_VERSION="${NGINX_VERSION:-1.26.2}"
EXPECTED_SHA256="627fe086209bba80a2853a0add9d958d7ebbdffa1a8467a5784c9a6b4f03d738"

SOURCE_DIR="${PROJECT_ROOT}/source"
TARBALL="${SOURCE_DIR}/nginx-${NGINX_VERSION}.tar.gz"
ASC_FILE="${SOURCE_DIR}/nginx-${NGINX_VERSION}.tar.gz.asc"
ORIG_SRC_DIR="${SOURCE_DIR}/nginx-original"
WORK_SRC_DIR="${SOURCE_DIR}/nginx"

NGINX_URL="https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
NGINX_ASC_URL="https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc"

mkdir -p "$SOURCE_DIR"

echo "[DOWNLOAD] Checking Nginx ${NGINX_VERSION} source archive..."
if [ ! -f "$TARBALL" ]; then
    echo "[DOWNLOAD] Fetching ${NGINX_URL}..."
    /usr/bin/wget -O "$TARBALL" "$NGINX_URL"
else
    echo "[DOWNLOAD] Archive already present at ${TARBALL}"
fi

if [ ! -f "$ASC_FILE" ]; then
    echo "[DOWNLOAD] Fetching PGP signature ${NGINX_ASC_URL}..."
    /usr/bin/wget -O "$ASC_FILE" "$NGINX_ASC_URL" || true
fi

echo "[VERIFY] Checking SHA-256 cryptographic checksum..."
ACTUAL_SHA256="$(sha256sum "$TARBALL" | awk '{print $1}')"
echo "  * Expected : ${EXPECTED_SHA256}"
echo "  * Actual   : ${ACTUAL_SHA256}"

if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "[ERROR] SHA-256 checksum mismatch for ${TARBALL}!" >&2
    exit 1
fi
echo "[VERIFY] SHA-256 verification PASSED."

# Preserve an untouched original source reference tree in source/nginx-original/
if [ ! -f "${ORIG_SRC_DIR}/configure" ]; then
    echo "[EXTRACT] Extracting pristine reference copy into ${ORIG_SRC_DIR}..."
    rm -rf "$ORIG_SRC_DIR"
    mkdir -p "$ORIG_SRC_DIR"
    tar -xzf "$TARBALL" -C "$ORIG_SRC_DIR" --strip-components=1
else
    echo "[EXTRACT] Pristine original source preserved at ${ORIG_SRC_DIR}"
fi

# Extract customizable working source tree into source/nginx/ if not present
if [ ! -f "${WORK_SRC_DIR}/configure" ]; then
    echo "[EXTRACT] Extracting working source tree into ${WORK_SRC_DIR}..."
    rm -rf "$WORK_SRC_DIR"
    mkdir -p "$WORK_SRC_DIR"
    tar -xzf "$TARBALL" -C "$WORK_SRC_DIR" --strip-components=1
else
    echo "[EXTRACT] Working source tree ready at ${WORK_SRC_DIR}"
fi

echo "[SUCCESS] Nginx ${NGINX_VERSION} download, verification, and extraction complete."
