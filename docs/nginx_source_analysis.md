# NGINX OPEN SOURCE CODE & ARCHITECTURE ANALYSIS
## Version: `nginx-1.26.2` (Stable Branch)

---

## 1. Download, Verification & Extraction Summary

- **Official Source URL**: `https://nginx.org/download/nginx-1.26.2.tar.gz`
- **PGP Signature URL**: `https://nginx.org/download/nginx-1.26.2.tar.gz.asc`
- **Signing Key**: `https://nginx.org/keys/pluknet.key` (Sergey Kandaurov `<s.kandaurov@f5.com>`)
- **Archive Size**: `1,244,789` bytes
- **SHA-256 Checksum**: `627fe086209bba80a2853a0add9d958d7ebbdffa1a8467a5784c9a6b4f03d738`
- **MD5 Checksum**: `1588676be2a01a63d3a150fae6c3f4a9`
- **GPG Verification**:
  - RSA Key Fingerprint: `D678 6CE3 03D9 A902 2998 DC6C C846 4D54 9AF7 5C0A`
  - Result: `Good signature from "Sergey Kandaurov <s.kandaurov@f5.com>"`
- **Extracted Location**: `/home/truongphuoc/Desktop/custom-nginx-project/source/nginx/`

---

## 2. Source Code Directory Structure Analysis

### 2.1. `src/core/` — Core Engine, Data Structures & Lifecycle
Contains the entry point (`main()`), foundational memory management, data structures, configuration parser, and cycle management:
- `nginx.c` / `nginx.h`: Entry point `main()`, command-line argument parsing (`-v`, `-V`, `-t`, `-T`, `-s`, `-p`, `-c`), version macros (`NGINX_VERSION`, `NGINX_VER`).
- `ngx_cycle.c` / `ngx_cycle.h`: Implements `ngx_cycle_t` and `ngx_init_cycle()`, representing a full runtime configuration generation (sockets, memory pools, shared memory zones, open log files). Reloading (`SIGHUP`) allocates a brand-new `ngx_cycle_t` alongside the old cycle.
- `ngx_palloc.c` / `ngx_palloc.h`: Region-based memory pool allocator (`ngx_pool_t`, `ngx_palloc()`, `ngx_pcalloc()`). Prevents memory leaks and fragmentation by tying allocations to connection or request lifetimes.
- `ngx_buf.c` / `ngx_buf.h` & `ngx_output_chain.c`: Zero-copy buffer descriptor (`ngx_buf_t`) and linked buffer chains (`ngx_chain_t`) capable of pointing to in-memory buffers or file offsets (`sendfile`).
- `ngx_array.c`, `ngx_list.c`, `ngx_queue.c`, `ngx_rbtree.c`, `ngx_radix_tree.c`, `ngx_hash.c`: High-performance, cache-friendly C containers.
- `ngx_slab.c` / `ngx_shmtx.c`: Slab allocator and atomic spinlock/semaphore mutexes for shared memory zones across worker processes.
- `ngx_conf_file.c`: Configuration file lexer/parser and directive dispatcher.

### 2.2. `src/event/` — Asynchronous Event-Driven Multiplexing Engine
Manages non-blocking network I/O, timers, and connection readiness notifications:
- `ngx_event.c` / `ngx_event.h`: Core event loop (`ngx_process_events_and_timers()`), accept mutex (`ngx_trylock_accept_mutex` to prevent thundering herd), and event flags.
- `ngx_event_timer.c`: Red-black tree (`ngx_event_timer_rbtree`) tracking connection and request timeouts in `O(log N)` time.
- `ngx_event_posted.c`: Deferred event queues (`ngx_posted_accept_events`, `ngx_posted_events`).
- `modules/ngx_epoll_module.c`: Linux-native `epoll` implementation (`epoll_create`, `epoll_ctl`, `epoll_wait`, `EPOLLRDHUP`, `EPOLLEXCLUSIVE`).

### 2.3. `src/http/` — HTTP Protocol Stack, Phase Engine & Built-in Modules
Implements HTTP/1.x, HTTP/2, HTTP/3, request routing, filter chains, and upstream proxying:
- `ngx_http.c`: Initializes the `http {}` block, builds the 11-phase handler array, merges `main`, `server`, and `location` configurations, and sets up listening sockets.
- `ngx_http_request.c` / `ngx_http_request.h`: Defines `ngx_http_request_t`, connection initialization (`ngx_http_Wait_request_handler`), state-machine parsers for request lines and headers, and request finalization (`ngx_http_finalize_request`).
- `ngx_http_core_module.c`: Core HTTP directives (`server`, `location`, `listen`, `root`, `server_tokens`, `keepalive_timeout`) and the phase engine dispatcher (`ngx_http_core_run_phases`).
- `ngx_http_header_filter_module.c`: Terminal header filter that serializes `r->headers_out` into the wire-format HTTP response header buffer.
- `ngx_http_write_filter_module.c`: Terminal body filter that flushes `ngx_chain_t` buffers to the socket using non-blocking I/O or `sendfile()`.
- `ngx_http_special_response.c`: Built-in HTML error page templates (`3xx`, `4xx`, `5xx`) and server footer strings.
- `modules/`: Built-in HTTP modules (`ngx_http_static_module.c`, `ngx_http_access_module.c`, `ngx_http_limit_req_module.c`, `ngx_http_stub_status_module.c`, etc.).

### 2.4. `src/os/unix/` — POSIX & Linux Kernel Integration Layer
Abstracts system calls, process management, shared memory, and signals:
- `ngx_process_cycle.c`: Master process loop (`ngx_master_process_cycle`) and Worker process loop (`ngx_worker_process_cycle`).
- `ngx_process.c`: Process spawning (`ngx_spawn_process` via `fork()`), `socketpair()` IPC channels, and the POSIX signal table (`signals[]` with `ngx_signal_handler`).
- `ngx_linux_init.c` & `ngx_linux_sendfile_chain.c`: Linux kernel identification (`uname`) and zero-copy `sendfile64()` / `writev()` socket transmission.
- `ngx_shmem.c`: Shared memory allocation via `mmap(MAP_ANON | MAP_SHARED)`.
- `ngx_channel.c`: Inter-process control messaging between Master and Workers over UNIX domain `socketpair`.

### 2.5. `auto/` — Build Configuration & Feature Probing Scripts
Shell scripts sourced by `./configure` to inspect the host OS, compiler flags, CPU architecture, and C libraries:
- `auto/options`: Parses CLI flags (`--prefix=`, `--sbin-path=`, `--add-module=`, `--with-*`, `--without-*`).
- `auto/cc/conf` & `auto/cc/gcc`: Configures GCC optimization, warning flags (`-Wall -Wextra -Werror`), and pointer arithmetic checks.
- `auto/os/linux`: Probes Linux kernel capabilities (`epoll`, `eventfd`, `sendfile64`, `prctl`, `SO_REUSEPORT`, `accept4`).
- `auto/modules`: Determines module load order (critically important for HTTP filter chains) and generates `objs/ngx_modules.c`.
- `auto/make`: Generates `objs/Makefile` with explicit compilation rules for core sources, OS sources, and external addon modules.

### 2.6. `conf/` — Default Configuration Templates
Contains default runtime configuration files installed into `--conf-path`:
- `nginx.conf`: Sample HTTP web server configuration.
- `mime.types`: File extension to `Content-Type` MIME mappings.
- `fastcgi.conf`, `fastcgi_params`, `uwsgi_params`, `scgi_params`: Gateway parameter mappings.

---

## 3. Core Architecture Deep Dive

### 3.1. Master Process vs. Worker Processes
- **Master Process (`ngx_master_process_cycle` in `src/os/unix/ngx_process_cycle.c`)**:
  - Runs with privileges required to bind ports and read configuration files.
  - Performs **zero** client network I/O.
  - Parses configuration, initializes shared memory zones, binds listening sockets, and spawns Worker processes via `fork()`.
  - Sits in `sigsuspend()`, waiting for POSIX signals (`SIGHUP` for reload, `SIGTERM`/`SIGINT` for fast shutdown, `SIGQUIT` for graceful shutdown, `SIGUSR1` to reopen logs, `SIGUSR2` for live binary upgrade, `SIGCHLD` to respawn crashed workers).
- **Worker Processes (`ngx_worker_process_cycle` in `src/os/unix/ngx_process_cycle.c`)**:
  - Drop privileges (`setuid`/`setgid`), optionally bind to specific CPU cores (`sched_setaffinity`), and inherit listening file descriptors from the Master.
  - Execute a single-threaded, non-blocking event loop (`ngx_process_events_and_timers()`).
  - Share state only when explicitly configured via `ngx_shm_zone_t` (mmap shared memory).

### 3.2. Event-Driven Architecture (Linux `epoll`)
Instead of spawning one thread or process per connection, each Nginx worker multiplexes thousands of concurrent TCP connections on a single thread:
1. Worker registers listening sockets and active client sockets with the kernel's `epoll` instance (`epoll_ctl`).
2. `epoll_wait()` blocks up to the nearest timer expiration stored in `ngx_event_timer_rbtree`.
3. Ready read/write events invoke their non-blocking callback (`rev->handler(rev)` / `wev->handler(wev)`).
4. Expired timers are swept from the red-black tree and handled cleanly.

### 3.3. HTTP Request Processing Pipeline (11 Phases)
Once an HTTP request header is parsed into `ngx_http_request_t`, `ngx_http_core_run_phases(r)` drives it sequentially through 11 phases (`src/http/ngx_http_core_module.h:L109-128`):
1. `NGX_HTTP_POST_READ_PHASE` — Immediately after reading request headers (e.g., `realip` module).
2. `NGX_HTTP_SERVER_REWRITE_PHASE` — Server-block level URI rewrites.
3. `NGX_HTTP_FIND_CONFIG_PHASE` — Matches URI against location tree (`ngx_http_core_find_config_phase`).
4. `NGX_HTTP_REWRITE_PHASE` — Location-level URI rewrites.
5. `NGX_HTTP_POST_REWRITE_PHASE` — Internal loop protection and re-routing after rewrite.
6. `NGX_HTTP_PREACCESS_PHASE` — Rate/connection limiting (`limit_req`, `limit_conn`) and security pre-checks.
7. `NGX_HTTP_ACCESS_PHASE` — Authorization and access control (`allow`/`deny`, `auth_basic`, custom security rules).
8. `NGX_HTTP_POST_ACCESS_PHASE` — Enforces `satisfy all/any` logic.
9. `NGX_HTTP_PRECONTENT_PHASE` — `try_files` and mirror handlers.
10. `NGX_HTTP_CONTENT_PHASE` — Generates the HTTP response (`ngx_http_static_module`, `proxy_pass`, or custom content handler via `clcf->handler`).
11. `NGX_HTTP_LOG_PHASE` — Writes access logs (`ngx_http_log_module`) right before freeing the request pool.

### 3.4. Configure System & GNU Make Build Process
1. `./configure` runs `auto/options`, `auto/cc/conf`, `auto/os/conf`, `auto/modules`, and `auto/make`.
2. It produces three critical build files in `objs/`:
   - `objs/ngx_auto_config.h`: `#define` macros for all detected OS features and compile-time paths.
   - `objs/ngx_modules.c`: The global `ngx_module_t *ngx_modules[]` array linking all compiled modules in exact execution order.
   - `objs/Makefile`: Full compilation and linking rules.
3. Running `make` delegates to `make -f objs/Makefile`, compiling each `.c` file into `objs/src/.../*.o` and linking `objs/nginx`.

---

## 4. Identification of Server Header, Version & Response Filter

### 4.1. Exact Files & Line Ranges

| Component | Source File | Lines | Symbols / Macros / Functions |
| :--- | :--- | :--- | :--- |
| **Version & Server Macros** | [src/core/nginx.h](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/core/nginx.h#L12-L20) | `L12–L20` | `nginx_version`, `NGINX_VERSION`, `NGINX_VER`, `NGINX_VER_BUILD` |
| **Static Server Header Strings** | [src/http/ngx_http_header_filter_module.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_header_filter_module.c#L49-L51) | `L49–L51` | `ngx_http_server_string`, `ngx_http_server_full_string`, `ngx_http_server_build_string` |
| **Header Length Calculation** | [src/http/ngx_http_header_filter_module.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_header_filter_module.c#L286-L296) | `L286–L296` | Inside `ngx_http_header_filter(ngx_http_request_t *r)` |
| **Header Buffer Serialization** | [src/http/ngx_http_header_filter_module.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_header_filter_module.c#L455-L470) | `L455–L470` | Inside `ngx_http_header_filter(ngx_http_request_t *r)` |
| **Error Page Footer Strings** | [src/http/ngx_http_special_response.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_special_response.c#L21-L39) | `L21–L39` | `ngx_http_error_full_tail`, `ngx_http_error_build_tail`, `ngx_http_error_tail` |

### 4.2. C Definitions & Data Structures

1. **In `src/core/nginx.h` (`L12–L20`)**:
   ```c
   #define nginx_version      1026002
   #define NGINX_VERSION      "1.26.2"
   #define NGINX_VER          "nginx/" NGINX_VERSION

   #ifdef NGX_BUILD
   #define NGINX_VER_BUILD    NGINX_VER " (" NGX_BUILD ")"
   #else
   #define NGINX_VER_BUILD    NGINX_VER
   #endif
   ```

2. **In `src/http/ngx_http_header_filter_module.c` (`L49–L51`)**:
   ```c
   static u_char ngx_http_server_string[] = "Server: nginx" CRLF;
   static u_char ngx_http_server_full_string[] = "Server: " NGINX_VER CRLF;
   static u_char ngx_http_server_build_string[] = "Server: " NGINX_VER_BUILD CRLF;
   ```

3. **Data Structures Involved**:
   - `ngx_http_request_t *r`: Represents the active HTTP transaction.
   - `r->headers_out` (`ngx_http_headers_out_t` in `src/http/ngx_http_request.h:L258-L293`): Holds response status (`r->headers_out.status`), explicit server header pointer (`ngx_table_elt_t *server`), and the linked list of custom response headers (`ngx_list_t headers`).
   - `clcf` (`ngx_http_core_loc_conf_t *`): Retrieved via `ngx_http_get_module_loc_conf(r, ngx_http_core_module)`. Contains `clcf->server_tokens` (`NGX_HTTP_SERVER_TOKENS_ON`, `NGX_HTTP_SERVER_TOKENS_OFF`, or `NGX_HTTP_SERVER_TOKENS_BUILD`).

### 4.3. Request/Response Header Processing Flow
1. A content handler (e.g., `ngx_http_static_module`) populates `r->headers_out.status = NGX_HTTP_OK`, `content_length_n`, and `last_modified_time`, then calls `ngx_http_send_header(r)`.
2. `ngx_http_send_header(r)` invokes `ngx_http_top_header_filter(r)`, passing `r` down the chain of registered header filters until it reaches `ngx_http_header_filter(r)` in `ngx_http_header_filter_module.c`.
3. **Pass 1 (Size computation, `L286–L296`)**: If no upstream/module explicitly set `r->headers_out.server`, `ngx_http_header_filter` inspects `clcf->server_tokens` and adds `sizeof(ngx_http_server_full_string) - 1` (when `server_tokens on`, the default) to `len`.
4. **Buffer Allocation (`L437`)**: Allocates a temporary buffer `b = ngx_create_temp_buf(r->pool, len)` of exact size `len`.
5. **Pass 2 (Serialization, `L455–L470`)**: Copies `"HTTP/1.1 200 OK\r\n"`, then copies `ngx_http_server_full_string` (`"Server: nginx/1.26.2\r\n"`) into `b->last` via `ngx_cpymem(b->last, p, len)`.
6. Appends `Date`, `Content-Type`, `Content-Length`, `Connection`, and iterates over `r->headers_out.headers.part` (`L583–L607`) to serialize any custom headers added by modules.
7. Calls `ngx_http_write_filter(r, &out)` (`L624`) to flush the serialized headers to the socket.
