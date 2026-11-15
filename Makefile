# ==============================================================================
# Custom Nginx Project – Master Makefile
# Manage lifecycle: check, download, patch, configure, build, install, all, run, stop, test, clean
# ==============================================================================

PROJECT_ROOT   := $(shell pwd)
SCRIPTS_DIR    := $(PROJECT_ROOT)/scripts
BUILD_PREFIX   ?= $(PROJECT_ROOT)/build/custom
NGINX_BIN      := $(BUILD_PREFIX)/sbin/nginx
NGINX_CONF     := $(PROJECT_ROOT)/config/nginx.conf
NGINX_PID      := $(PROJECT_ROOT)/logs/nginx.pid
MON_BIN_DIR    := $(PROJECT_ROOT)/build/bin
PROCESS_MON    := $(MON_BIN_DIR)/process_monitor
RESOURCE_MON   := $(MON_BIN_DIR)/resource_monitor
AB_BIN         := $(MON_BIN_DIR)/ab
LISTEN_PORT    ?= 8080

.PHONY: all check download patch configure build monitors install run stop test clean

# Full automated build pipeline
all:
	@bash $(SCRIPTS_DIR)/build_all.sh

# 1. Check Ubuntu environment & dependencies
check:
	@bash $(SCRIPTS_DIR)/check_environment.sh --build-ready

# 2. Download, verify and extract official Nginx source code
download:
	@bash $(SCRIPTS_DIR)/download_nginx.sh

# 3. Apply C source patches idempotently
patch:
	@bash $(SCRIPTS_DIR)/apply_patches.sh

# 4. Configure Nginx build in isolated prefix with custom C modules
configure: patch
	@BUILD_PREFIX="$(BUILD_PREFIX)" bash $(SCRIPTS_DIR)/configure_nginx.sh

# 5. Compile Nginx source with GCC & GNU Make
build: monitors
	@bash $(SCRIPTS_DIR)/build_nginx.sh

# 5b. Compile Linux C monitoring utilities (Process Monitor & Resource Monitor)
monitors:
	@mkdir -p "$(MON_BIN_DIR)"
	gcc -Wall -Wextra -Wpedantic -Werror -O2 -I"$(PROJECT_ROOT)/include" "$(PROJECT_ROOT)/src/process_monitor.c" -o "$(PROCESS_MON)"
	gcc -Wall -Wextra -Wpedantic -Werror -O2 -I"$(PROJECT_ROOT)/include" "$(PROJECT_ROOT)/src/resource_monitor.c" -o "$(RESOURCE_MON)"
	gcc -Wall -Wextra -Wpedantic -Werror -O2 "$(PROJECT_ROOT)/src/ab_bench.c" -o "$(AB_BIN)"

# 6. Install compiled binary and runtime directories into isolated prefix
install:
	@BUILD_PREFIX="$(BUILD_PREFIX)" bash $(SCRIPTS_DIR)/install_nginx.sh

# 7. Start Custom Nginx using isolated prefix and custom config
run:
	@if [ ! -x "$(NGINX_BIN)" ]; then \
		echo "[ERROR] Nginx binary not found at $(NGINX_BIN). Run 'make install' first."; \
		exit 1; \
	fi
	@if [ -f "$(NGINX_PID)" ] && kill -0 $$(cat "$(NGINX_PID)") 2>/dev/null; then \
		echo "Custom Nginx is already running (PID: $$(cat $(NGINX_PID)))."; \
	else \
		"$(NGINX_BIN)" -p "$(PROJECT_ROOT)" -c "$(NGINX_CONF)"; \
		echo "Custom Nginx started on port $(LISTEN_PORT) (PID: $$(cat $(NGINX_PID)))."; \
	fi

# 8. Stop Custom Nginx gracefully
stop:
	@if [ -f "$(NGINX_PID)" ] && kill -0 $$(cat "$(NGINX_PID)") 2>/dev/null; then \
		"$(NGINX_BIN)" -p "$(PROJECT_ROOT)" -c "$(NGINX_CONF)" -s quit; \
		echo "Custom Nginx stopped."; \
	else \
		echo "Custom Nginx is not currently running."; \
	fi

# 9. Run full integration & audit test suite
test: monitors
	@if [ ! -x "$(NGINX_BIN)" ]; then \
		echo "[ERROR] Nginx binary not found at $(NGINX_BIN)."; \
		exit 1; \
	fi
	@bash $(PROJECT_ROOT)/tests/run_all_tests.sh

# 9b. Run benchmark comparing Original Nginx vs Custom Nginx
benchmark: monitors
	@bash $(SCRIPTS_DIR)/run_benchmark.sh

# 10. Clean build artifacts, object files, and temporary logs
clean:
	@bash $(SCRIPTS_DIR)/clean_build.sh
