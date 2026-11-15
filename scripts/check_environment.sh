#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/check_environment.sh
# Purpose: Check Ubuntu OS, Kernel, Development Tools, and Nginx Dependencies
# Project: Custom Nginx Web Server on Ubuntu
# ==============================================================================

set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CHECK_ONLY="${1:-}"

# ANSI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OVERALL_STATUS="PASS"
CORE_BUILD_STATUS="PASS"
MISSING_TOOLS=()
MISSING_PACKAGES=()

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}         CUSTOM NGINX PROJECT - UBUNTU ENVIRONMENT CHECK              ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# ------------------------------------------------------------------------------
# 1. OS & Kernel Information
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[1] OPERATING SYSTEM & KERNEL INFORMATION${NC}"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-$NAME $VERSION}"
else
    OS_NAME="$(uname -s)"
fi
KERNEL_VER="$(uname -r)"
ARCH="$(uname -m)"

echo -e "  * OS Information : ${GREEN}${OS_NAME}${NC}"
echo -e "  * Kernel Version : ${GREEN}${KERNEL_VER} (${ARCH})${NC}"

# ------------------------------------------------------------------------------
# 2. Core System & Build Tools Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2] CORE DEVELOPMENT & SYSTEM TOOLS${NC}"

check_tool() {
    local cmd="$1"
    local label="$2"
    local version_cmd="$3"
    local pkg_hint="$4"
    local required_for_build="$5"

    if command -v "$cmd" >/dev/null 2>&1; then
        local ver
        ver=$(eval "$version_cmd" 2>&1 | grep -v "Caution:" | grep -v "Snap" | grep -v "^$" | head -n 1)
        printf "  * %-14s : ${GREEN}[FOUND]${NC} %s\n" "$label" "$ver"
    else
        printf "  * %-14s : ${RED}[MISSING]${NC}\n" "$label"
        OVERALL_STATUS="FAIL"
        if [ "$required_for_build" = "yes" ]; then
            CORE_BUILD_STATUS="FAIL"
        fi
        MISSING_TOOLS+=("$cmd")
        if [ -n "$pkg_hint" ]; then
            MISSING_PACKAGES+=("$pkg_hint")
        fi
    fi
}

check_tool "gcc"        "GCC"        "gcc --version"        "build-essential" "yes"
check_tool "make"       "GNU Make"   "make --version"       "build-essential" "yes"
check_tool "git"        "Git"        "git --version"        "git"             "yes"
check_tool "bash"       "Bash"       "bash --version"       "bash"            "yes"
check_tool "curl"       "curl"       "curl --version"       "curl"            "no"
check_tool "wget"       "wget"       "wget --version"       "wget"            "yes"
check_tool "pkg-config" "pkg-config" "pkg-config --version" "pkg-config"      "yes"
check_tool "systemctl"  "systemd"    "systemctl --version"  "systemd"         "yes"

# ------------------------------------------------------------------------------
# 3. Nginx Build & Benchmark Package Dependencies (APT / dpkg)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3] NGINX BUILD & BENCHMARK DEPENDENCIES (dpkg)${NC}"

REQUIRED_PACKAGES=(
    "build-essential:required"
    "libpcre2-dev:optional"
    "zlib1g-dev:optional"
    "libssl-dev:optional"
    "pkg-config:required"
    "apache2-utils:optional"
)

for entry in "${REQUIRED_PACKAGES[@]}"; do
    pkg="${entry%%:*}"
    req_type="${entry##*:}"
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        pkg_ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
        printf "  * %-18s : ${GREEN}[INSTALLED]${NC} (version: %s)\n" "$pkg" "$pkg_ver"
    else
        if [ "$BUILD_CHECK_ONLY" = "--build-ready" ] && [ "$req_type" = "optional" ]; then
            printf "  * %-18s : ${YELLOW}[OPTIONAL/AUTO-FALLBACK]${NC}\n" "$pkg"
        else
            printf "  * %-18s : ${RED}[MISSING]${NC}\n" "$pkg"
            OVERALL_STATUS="FAIL"
            if [ "$req_type" = "required" ]; then
                CORE_BUILD_STATUS="FAIL"
            fi
        fi
        MISSING_PACKAGES+=("$pkg")
    fi
done

# ------------------------------------------------------------------------------
# 4. Workspace Directories Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4] PROJECT WORKSPACE STRUCTURE${NC}"
REQUIRED_DIRS=("source" "patches" "modules" "scripts" "config" "web" "tests" "logs" "build" "docs")
for dir in "${REQUIRED_DIRS[@]}"; do
    if [ -d "${PROJECT_ROOT}/${dir}" ]; then
        printf "  * %-18s : ${GREEN}[OK]${NC}\n" "${dir}/"
    else
        printf "  * %-18s : ${RED}[MISSING]${NC}\n" "${dir}/"
        OVERALL_STATUS="FAIL"
        CORE_BUILD_STATUS="FAIL"
    fi
done

# ------------------------------------------------------------------------------
# 5. Summary & Remediation Instructions
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}======================================================================${NC}"
if [ "$OVERALL_STATUS" = "PASS" ]; then
    echo -e "OVERALL ENVIRONMENT STATUS: ${GREEN}${BOLD}PASS${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    exit 0
elif [ "$BUILD_CHECK_ONLY" = "--build-ready" ] && [ "$CORE_BUILD_STATUS" = "PASS" ]; then
    echo -e "CORE BUILD TOOLCHAIN STATUS: ${GREEN}${BOLD}PASS (GCC + Make + Linux Headers Ready)${NC}"
    echo -e "${CYAN}======================================================================${NC}"
    exit 0
else
    echo -e "OVERALL ENVIRONMENT STATUS: ${RED}${BOLD}FAIL${NC}"
    echo -e "${CYAN}======================================================================${NC}"

    UNIQUE_MISSING=($(printf "%s\n" "${MISSING_PACKAGES[@]}" | sort -u))

    echo -e "\n${YELLOW}${BOLD}[!] Missing Packages Detected:${NC}"
    for p in "${UNIQUE_MISSING[@]}"; do
        echo -e "    - ${RED}${p}${NC}"
    done

    echo -e "\n${YELLOW}${BOLD}[!] Suggested APT Command (Run manually or confirm sudo):${NC}"
    echo -e "    sudo apt update && sudo apt install -y ${UNIQUE_MISSING[*]}"
    echo ""
    exit 1
fi
