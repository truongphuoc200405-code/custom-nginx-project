#!/usr/bin/env bash
# ==============================================================================
# Script: tests/test_process_monitor.sh
# Purpose: Integration test suite for Custom Nginx Process Monitor (C binary)
# Tests:
#   1. Compilation of src/process_monitor.c with GCC (-Wall -Wextra -Werror)
#   2. Detection of Running Custom Nginx (Master PID, Worker PIDs, Worker count,
#      Service ACTIVE, Listening Port 8080, procfs hierarchy)
#   3. Resilience on Worker termination (kill -9 worker -> Master respawns new
#      worker -> Process Monitor accurately detects new Worker PID)
#   4. Detection of Stopped Custom Nginx (Master PID: NONE, Workers: 0,
#      Service: INACTIVE, Process State: STOPPED)
#   5. Recovery when started again via systemd
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON_BIN="${PROJECT_ROOT}/build/bin/process_monitor"
PID_FILE="${PROJECT_ROOT}/logs/nginx.pid"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

pass_test() {
    echo -e "  -> ${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail_test() {
    echo -e "  -> ${RED}[FAIL]${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}        CUSTOM NGINX PROCESS MONITOR TEST SUITE (C / procfs)          ${NC}"
echo -e "${CYAN}======================================================================${NC}"

# ------------------------------------------------------------------------------
# TEST 1: Compile C Process Monitor
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[1] Compiling src/process_monitor.c with GCC...${NC}"
mkdir -p "${PROJECT_ROOT}/build/bin"
if gcc -Wall -Wextra -Werror -O2 -I"${PROJECT_ROOT}/include" \
       "${PROJECT_ROOT}/src/process_monitor.c" -o "$MON_BIN"; then
    pass_test "Compiled build/bin/process_monitor cleanly with -Wall -Wextra -Werror"
else
    fail_test "Compilation of src/process_monitor.c failed"
    exit 1
fi

# ------------------------------------------------------------------------------
# TEST 2: Verify Running Nginx Detection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2] Testing Process Monitor on RUNNING Custom Nginx...${NC}"
bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null
sleep 1

OUT_RUNNING="$("$MON_BIN")"
echo "$OUT_RUNNING" | sed 's/^/    /'

EXPECTED_MASTER="$(cat "$PID_FILE")"
MON_MASTER="$(echo "$OUT_RUNNING" | awk '/^Master PID:/ {print $3}')"
MON_WORKERS="$(echo "$OUT_RUNNING" | awk '/^Workers:/ {print $2}')"
MON_SERVICE="$(echo "$OUT_RUNNING" | awk '/^Service:/ {print $2}')"
MON_PORT="$(echo "$OUT_RUNNING" | awk '/^Port:/ {print $2}')"

if [ "$MON_MASTER" = "$EXPECTED_MASTER" ] && [ "$MON_WORKERS" = "2" ] \
   && [ "$MON_SERVICE" = "ACTIVE" ] && [ "$MON_PORT" = "8080" ]; then
    pass_test "Detected exact Master PID (${MON_MASTER}), Workers (${MON_WORKERS}), Service (${MON_SERVICE}), Port (${MON_PORT})"
else
    fail_test "Running state mismatch: Master=${MON_MASTER} (exp ${EXPECTED_MASTER}), Workers=${MON_WORKERS}, Service=${MON_SERVICE}, Port=${MON_PORT}"
fi

# ------------------------------------------------------------------------------
# TEST 3: Worker Termination & Respawn Detection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3] Testing Worker Process Termination & Master Respawn...${NC}"
FIRST_WORKER="$(echo "$OUT_RUNNING" | awk '/^Worker PID:/ {print $3; exit}')"
echo "  * Terminating Worker PID ${FIRST_WORKER} with SIGKILL..."
kill -9 "$FIRST_WORKER"
sleep 1

OUT_RESPAWN="$("$MON_BIN")"
NEW_WORKERS="$(echo "$OUT_RESPAWN" | awk '/^Worker PID:/ {print $3}' | tr '\n' ' ')"
RESPAWN_COUNT="$(echo "$OUT_RESPAWN" | awk '/^Workers:/ {print $2}')"
echo "  * Active Worker PIDs after respawn : ${NEW_WORKERS} (Count: ${RESPAWN_COUNT})"

if [ "$RESPAWN_COUNT" = "2" ] && ! echo " $NEW_WORKERS " | grep -q " ${FIRST_WORKER} "; then
    pass_test "Master respawned killed worker (${FIRST_WORKER}) and Process Monitor detected new Worker PIDs (${NEW_WORKERS})"
else
    fail_test "Worker respawn detection failed"
fi

# ------------------------------------------------------------------------------
# TEST 4: Verify Stopped Nginx Detection
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4] Testing Process Monitor on STOPPED Custom Nginx...${NC}"
bash "${PROJECT_ROOT}/scripts/service_stop.sh" >/dev/null
sleep 1

OUT_STOPPED="$("$MON_BIN")"
echo "$OUT_STOPPED" | sed 's/^/    /'

STOP_MASTER="$(echo "$OUT_STOPPED" | awk '/^Master PID:/ {print $3}')"
STOP_WORKERS="$(echo "$OUT_STOPPED" | awk '/^Workers:/ {print $2}')"
STOP_SERVICE="$(echo "$OUT_STOPPED" | awk '/^Service:/ {print $2}')"
STOP_STATE="$(echo "$OUT_STOPPED" | awk '/^Process State:/ {print $3}')"

if [ "$STOP_MASTER" = "NONE" ] && [ "$STOP_WORKERS" = "0" ] \
   && [ "$STOP_SERVICE" = "INACTIVE" ] && [ "$STOP_STATE" = "STOPPED" ]; then
    pass_test "Stopped state accurately reported (Master: NONE, Workers: 0, Service: INACTIVE, State: STOPPED)"
else
    fail_test "Stopped state mismatch"
fi

# ------------------------------------------------------------------------------
# TEST 5: Restart Service & Confirm Monitor Recovery
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[5] Restarting Service & Verifying Monitor Recovery...${NC}"
bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null
sleep 1

OUT_RECOVER="$("$MON_BIN")"
REC_WORKERS="$(echo "$OUT_RECOVER" | awk '/^Workers:/ {print $2}')"
REC_SERVICE="$(echo "$OUT_RECOVER" | awk '/^Service:/ {print $2}')"

if [ "$REC_WORKERS" = "2" ] && [ "$REC_SERVICE" = "ACTIVE" ]; then
    pass_test "Service recovered to ACTIVE with 2 Workers"
else
    fail_test "Service recovery check failed"
fi

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "TEST SUMMARY: ${GREEN}${PASS_COUNT} PASSED${NC}, ${RED}${FAIL_COUNT} FAILED${NC}"
echo -e "${CYAN}======================================================================${NC}"

if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
else
    exit 1
fi
