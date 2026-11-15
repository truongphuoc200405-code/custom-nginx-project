#!/usr/bin/env bash
# ==============================================================================
# Script: scripts/run_benchmark.sh
# Purpose: Benchmark Original Nginx (build/original/sbin/nginx) vs
#          Custom Nginx (build/custom/sbin/nginx) measuring:
#            - Requests per second (RPS)
#            - Average latency (ms) & latency percentiles (p50, p90, p99)
#            - CPU usage (%) under load (via build/bin/resource_monitor)
#            - Memory usage (RSS & Virtual Memory via build/bin/resource_monitor)
#            - Error / Non-2xx rate
# ==============================================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_BIN="${PROJECT_ROOT}/build/original/sbin/nginx"
CUSTOM_BIN="${PROJECT_ROOT}/build/custom/sbin/nginx"
RES_MON="${PROJECT_ROOT}/build/bin/resource_monitor"
NGINX_CONF="${PROJECT_ROOT}/config/nginx.conf"
BENCH_ORIG_CONF="${PROJECT_ROOT}/config/nginx_bench_original.conf"
BENCH_CUSTOM_CONF="${PROJECT_ROOT}/config/nginx_bench_custom.conf"
BENCH_LOG="${PROJECT_ROOT}/logs/benchmark_raw.log"

if command -v ab >/dev/null 2>&1; then
    AB_CMD="$(command -v ab)"
else
    AB_CMD="${PROJECT_ROOT}/build/bin/ab"
fi

cleanup() {
    rm -f "$BENCH_ORIG_CONF" "$BENCH_CUSTOM_CONF"
    pkill -f "nginx_bench_" 2>/dev/null || true
    bash "${PROJECT_ROOT}/scripts/service_start.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

make -C "$PROJECT_ROOT" monitors >/dev/null

# Stop any running Nginx instance before benchmarking
bash "${PROJECT_ROOT}/scripts/service_stop.sh" >/dev/null 2>&1 || true
sleep 1

cat > "$BENCH_ORIG_CONF" <<EOF
worker_processes  2;
error_log  logs/error.log warn;
pid        logs/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    access_log    logs/access.log;
    sendfile      on;
    keepalive_timeout  65;

    server {
        listen       8080;
        server_name  localhost;
        location / {
            root   web;
            index  index.html;
        }
    }
}
EOF

cat > "$BENCH_CUSTOM_CONF" <<EOF
worker_processes  2;
error_log  logs/error.log warn;
pid        logs/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    access_log    logs/access.log;
    sendfile      on;
    keepalive_timeout  65;
    custom_security_shm_size 2m;

    server {
        listen       8080;
        server_name  localhost;

        # Full security + monitoring pipeline active with high threshold for throughput test
        location / {
            root   web;
            index  index.html;
            custom_security on;
            custom_security_limit 100000;
            custom_security_window 60s;
        }

        # Strict rate-limited endpoint for security flood benchmark
        location = /flood_test {
            alias web/index.html;
            custom_security on;
            custom_security_limit 20;
            custom_security_window 1s;
        }

        location = /custom_status {
            custom_status on;
            custom_status_localhost on;
            custom_security off;
        }
    }
}
EOF

echo "==============================================================================" | tee "$BENCH_LOG"
echo "        BENCHMARK: ORIGINAL NGINX vs CUSTOM NGINX (Ubuntu Linux)             " | tee -a "$BENCH_LOG"
echo "        Benchmark Tool : ${AB_CMD}                                           " | tee -a "$BENCH_LOG"
echo "        Date           : $(date -Is)                                         " | tee -a "$BENCH_LOG"
echo "==============================================================================" | tee -a "$BENCH_LOG"

# ------------------------------------------------------------------------------
# 1. BENCHMARK ORIGINAL NGINX (5000 requests, concurrency 50)
# ------------------------------------------------------------------------------
echo -e "\n>>> [1/4] Benchmarking ORIGINAL NGINX (${ORIG_BIN})..." | tee -a "$BENCH_LOG"
"$ORIG_BIN" -p "$PROJECT_ROOT" -c "$BENCH_ORIG_CONF"
sleep 1

# Warmup
"$AB_CMD" -n 200 -c 10 "http://127.0.0.1:8080/index.html" >/dev/null 2>&1

# Run resource monitor in background while benchmark runs
"$RES_MON" -i 400 "$PROJECT_ROOT" "$ORIG_BIN" > "${PROJECT_ROOT}/logs/res_orig.txt" &
RES_PID=$!
"$AB_CMD" -n 5000 -c 50 "http://127.0.0.1:8080/index.html" | tee -a "$BENCH_LOG"
wait "$RES_PID" || true

echo "--- Original Nginx Resource Telemetry Under Load ---" | tee -a "$BENCH_LOG"
cat "${PROJECT_ROOT}/logs/res_orig.txt" | tee -a "$BENCH_LOG"

"$ORIG_BIN" -p "$PROJECT_ROOT" -c "$BENCH_ORIG_CONF" -s quit
sleep 1

# ------------------------------------------------------------------------------
# 2. BENCHMARK CUSTOM NGINX - THROUGHPUT (5000 requests, concurrency 50)
# ------------------------------------------------------------------------------
echo -e "\n>>> [2/4] Benchmarking CUSTOM NGINX (${CUSTOM_BIN}) - Full Security + Monitoring Pipeline..." | tee -a "$BENCH_LOG"
"$CUSTOM_BIN" -p "$PROJECT_ROOT" -c "$BENCH_CUSTOM_CONF"
sleep 1

# Warmup
"$AB_CMD" -n 200 -c 10 "http://127.0.0.1:8080/index.html" >/dev/null 2>&1

"$RES_MON" -i 400 "$PROJECT_ROOT" "$CUSTOM_BIN" > "${PROJECT_ROOT}/logs/res_custom.txt" &
RES_PID=$!
"$AB_CMD" -n 5000 -c 50 "http://127.0.0.1:8080/index.html" | tee -a "$BENCH_LOG"
wait "$RES_PID" || true

echo "--- Custom Nginx Resource Telemetry Under Load ---" | tee -a "$BENCH_LOG"
cat "${PROJECT_ROOT}/logs/res_custom.txt" | tee -a "$BENCH_LOG"

# ------------------------------------------------------------------------------
# 3. BENCHMARK CUSTOM NGINX - SECURITY RATE LIMITING ENFORCEMENT (1000 req, c=25)
# ------------------------------------------------------------------------------
echo -e "\n>>> [3/4] Benchmarking CUSTOM NGINX - Rate-Limit Flood Enforcement (/flood_test, limit=20/1s)..." | tee -a "$BENCH_LOG"
"$AB_CMD" -n 1000 -c 25 "http://127.0.0.1:8080/flood_test" | tee -a "$BENCH_LOG"

# ------------------------------------------------------------------------------
# 4. BENCHMARK CUSTOM NGINX - MONITORING JSON ENDPOINT (/custom_status, 2000 req, c=25)
# ------------------------------------------------------------------------------
echo -e "\n>>> [4/4] Benchmarking CUSTOM NGINX - Monitoring Endpoint (/custom_status)..." | tee -a "$BENCH_LOG"
"$AB_CMD" -n 2000 -c 25 "http://127.0.0.1:8080/custom_status" | tee -a "$BENCH_LOG"

"$CUSTOM_BIN" -p "$PROJECT_ROOT" -c "$BENCH_CUSTOM_CONF" -s quit
sleep 1
rm -f "${PROJECT_ROOT}/logs/res_orig.txt" "${PROJECT_ROOT}/logs/res_custom.txt"

echo -e "\n[SUCCESS] Benchmark completed. Raw results saved to ${BENCH_LOG}"
