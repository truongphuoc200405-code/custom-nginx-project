# NGINX MODULE ARCHITECTURE & C API REFERENCE
## Technical Guide for Custom Security & Monitoring Modules

---

## 1. Overview of Nginx Module System

Nginx is fundamentally a modular event-driven engine. Even core features (`http`, `epoll`, `static`, `gzip`) are implemented as modules. All modules are statically linked (or dynamically loaded) through the global `ngx_modules[]` array generated in `objs/ngx_modules.c` during `./configure`.

There are 5 primary module types in Nginx:
1. `NGX_CORE_MODULE` (`core`, `errlog`, `events`, `http`, `mail`, `stream`)
2. `NGX_CONF_MODULE` (configuration syntax parser)
3. `NGX_EVENT_MODULE` (`epoll`, `select`, `poll`)
4. `NGX_HTTP_MODULE` (HTTP handlers, filters, upstreams, load balancers)
5. `NGX_MAIL_MODULE` / `NGX_STREAM_MODULE`

---

## 2. Core Data Structures & Interfaces

### 2.1. `ngx_module_t` (`src/core/ngx_module.h:L227-L262`)
Every Nginx module must export a global `ngx_module_t` descriptor:

```c
struct ngx_module_s {
    ngx_uint_t            ctx_index;      /* Index within its module category (e.g., HTTP) */
    ngx_uint_t            index;          /* Global index in ngx_modules[] */
    char                 *name;           /* Module name string */
    ngx_uint_t            spare0;
    ngx_uint_t            spare1;
    ngx_uint_t            version;        /* nginx_version (1026002) */
    const char           *signature;      /* Binary compatibility signature */

    void                 *ctx;            /* Pointer to category context (e.g., ngx_http_module_t *) */
    ngx_command_t        *commands;       /* Array of configuration directives (ngx_command_t[]) */
    ngx_uint_t            type;           /* Module type: NGX_HTTP_MODULE */

    /* Lifecycle Hooks */
    ngx_int_t           (*init_master)(ngx_log_t *log);
    ngx_int_t           (*init_module)(ngx_cycle_t *cycle);   /* Called in Master after config parse */
    ngx_int_t           (*init_process)(ngx_cycle_t *cycle);  /* Called in each Worker after fork() */
    ngx_int_t           (*init_thread)(ngx_cycle_t *cycle);
    void                (*exit_thread)(ngx_cycle_t *cycle);
    void                (*exit_process)(ngx_cycle_t *cycle);  /* Called in each Worker before exit */
    void                (*exit_master)(ngx_cycle_t *cycle);   /* Called in Master before exit */

    uintptr_t             spare_hook0;
    /* ... spare_hook1..7 (initialized via NGX_MODULE_V1_PADDING) */
};
```

### 2.2. `ngx_http_module_t` (`src/http/ngx_http_config.h:L24-L36`)
For an `NGX_HTTP_MODULE`, the `ctx` field of `ngx_module_t` points to an `ngx_http_module_t` struct that manages configuration creation, inheritance, and phase/filter registration during configuration parsing:

```c
typedef struct {
    ngx_int_t   (*preconfiguration)(ngx_conf_t *cf);
    ngx_int_t   (*postconfiguration)(ngx_conf_t *cf);

    void       *(*create_main_conf)(ngx_conf_t *cf);
    char       *(*init_main_conf)(ngx_conf_t *cf, void *conf);

    void       *(*create_srv_conf)(ngx_conf_t *cf);
    char       *(*merge_srv_conf)(ngx_conf_t *cf, void *prev, void *conf);

    void       *(*create_loc_conf)(ngx_conf_t *cf);
    char       *(*merge_loc_conf)(ngx_conf_t *cf, void *prev, void *conf);
} ngx_http_module_t;
```
- **`create_loc_conf` & `merge_loc_conf`**: Allocate a custom C struct in `cf->pool` for each `location {}` block and inherit settings from parent `server {}` or `http {}` scopes using macros like `ngx_conf_merge_value(conf->enable, prev->enable, 0)`.
- **`postconfiguration`**: The standard hook where custom modules register phase handlers (into `cmcf->phases[...].handlers`) or insert themselves into the HTTP header/body filter chain.

### 2.3. `ngx_http_request_t` (`src/http/ngx_http_request.h:L371-L595`)
The central structure passed to every HTTP handler and filter. Key fields include:
- `r->pool` (`ngx_pool_t *`): Request-scoped memory pool. All memory allocated via `ngx_palloc(r->pool, size)` is automatically freed when the request completes.
- `r->connection` (`ngx_connection_t *`): Underlying client TCP socket, client IP (`r->connection->addr_text`), and log object (`r->connection->log`).
- `r->method` (`ngx_uint_t`) & `r->method_name` (`ngx_str_t`): HTTP method (`NGX_HTTP_GET`, `NGX_HTTP_POST`, `NGX_HTTP_DELETE`, etc.).
- `r->uri` (`ngx_str_t`): Normalized request URI path.
- `r->args` (`ngx_str_t`): Query string after `?`.
- `r->headers_in` (`ngx_http_headers_in_t`): Parsed incoming request headers (`host`, `user_agent`, `authorization`, `headers` list).
- `r->headers_out` (`ngx_http_headers_out_t`): Outgoing response status (`status`), `content_type`, `content_length_n`, and `headers` list.
- `r->start_sec` / `r->start_msec`: Timestamp when the request started (useful for latency monitoring).

---

## 3. Configuration Directives (`ngx_command_t`)

Modules declare configuration directives using a `ngx_null_command`-terminated array of `ngx_command_t` (`src/core/ngx_conf_file.h:L79-L87`):

```c
struct ngx_command_s {
    ngx_str_t             name;   /* Directive name in nginx.conf */
    ngx_uint_t            type;   /* Where valid + argument count (e.g. NGX_HTTP_LOC_CONF|NGX_CONF_FLAG) */
    char               *(*set)(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
    ngx_uint_t            conf;   /* NGX_HTTP_LOC_CONF_OFFSET, SRV_CONF_OFFSET, or MAIN_CONF_OFFSET */
    ngx_uint_t            offset; /* offsetof(ngx_http_my_loc_conf_t, field) */
    void                 *post;
};
```
Built-in setter functions include:
- `ngx_conf_set_flag_slot`: Parses `on` / `off` into `ngx_flag_t`.
- `ngx_conf_set_str_slot`: Parses a string into `ngx_str_t`.
- `ngx_conf_set_num_slot`: Parses an integer into `ngx_int_t`.
- Custom setter function: Used when activating a content handler on a location (`clcf->handler = ngx_http_my_handler`).

---

## 4. HTTP Handlers vs. HTTP Filters

### 4.1. HTTP Handlers
Handlers inspect or respond to a request. There are two ways to attach an HTTP handler:

1. **Phase Handler (e.g., Access / Security Module)**:
   Registered in `postconfiguration` into `NGX_HTTP_PREACCESS_PHASE` or `NGX_HTTP_ACCESS_PHASE`:
   ```c
   ngx_http_core_main_conf_t *cmcf;
   ngx_http_handler_pt       *h;

   cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);
   h = ngx_array_push(&cmcf->phases[NGX_HTTP_ACCESS_PHASE].handlers);
   if (h == NULL) {
       return NGX_ERROR;
   }
   *h = ngx_http_security_handler;
   ```
   - Return values:
     - `NGX_DECLINED`: Pass to the next handler in the pipeline.
     - `NGX_OK`: Access granted in current phase.
     - `NGX_HTTP_FORBIDDEN` (`403`), `NGX_HTTP_TOO_MANY_REQUESTS` (`429`), `NGX_HTTP_BAD_REQUEST` (`400`): Immediately abort request and return status code.

2. **Content Handler (e.g., Monitoring Endpoint `/nginx_status` or `/metrics`)**:
   Attached directly to `ngx_http_core_loc_conf_t *clcf` inside a directive setter:
   ```c
   clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
   clcf->handler = ngx_http_monitoring_handler;
   ```
   A content handler constructs a response buffer (`ngx_buf_t`), attaches it to an `ngx_chain_t out`, sets `r->headers_out.status = NGX_HTTP_OK`, calls `ngx_http_send_header(r)`, and returns `ngx_http_output_filter(r, &out)`.

### 4.2. HTTP Filters (Header & Body Filters)
Filters form a singly-linked chain using module-local `static` function pointers (`ngx_http_next_header_filter` and `ngx_http_next_body_filter`):

```c
static ngx_http_output_header_filter_pt  ngx_http_next_header_filter;
static ngx_http_output_body_filter_pt    ngx_http_next_body_filter;

static ngx_int_t
ngx_http_custom_filter_init(ngx_conf_t *cf)
{
    ngx_http_next_header_filter = ngx_http_top_header_filter;
    ngx_http_top_header_filter = ngx_http_custom_header_filter;

    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter = ngx_http_custom_body_filter;

    return NGX_OK;
}
```
- **Header Filter**: Executes on every response before headers are serialized. Ideal for injecting security headers (`X-Content-Type-Options`, `X-Frame-Options`, `X-Custom-Nginx`) or recording response status codes (`2xx`, `4xx`, `5xx`).
- **Body Filter**: Inspects or transforms outgoing `ngx_chain_t *in` response chunks on the fly.

---

## 5. Shared Memory Zones (`ngx_shm_zone_t`)

Because Nginx runs multiple isolated Worker processes, global counters (such as total requests, blocked requests, per-IP rate limits, status code tallies) **cannot** use ordinary C global variables if they need to be aggregated across all workers.

Nginx provides `ngx_shared_memory_add()` (`src/core/ngx_cycle.c`):
1. During configuration (`preconfiguration` / `init_main_conf`), call:
   ```c
   shm_zone = ngx_shared_memory_add(cf, &name, size, &ngx_http_my_module);
   shm_zone->init = ngx_http_my_shm_zone_init;
   ```
2. Master process allocates anonymous shared memory via `mmap(MAP_ANON | MAP_SHARED)` and initializes a slab pool (`ngx_slab_pool_t *shpool = (ngx_slab_pool_t *) shm_zone->shm.addr`).
3. All Worker processes inherit the mapped memory pages across `fork()`.
4. Workers update shared counters safely using atomic operations (`ngx_atomic_fetch_add(&stats->total_requests, 1)`) or `ngx_shmtx_lock(&shpool->mutex)` / `ngx_shmtx_unlock(&shpool->mutex)` for complex structures like red-black trees.
