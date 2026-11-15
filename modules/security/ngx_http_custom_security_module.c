/*
 * Module: ngx_http_custom_security_module
 * Purpose: Custom HTTP Security & Multi-Worker Per-IP Rate Limiting Module
 * Project: Customize and Rebuild Nginx Web Server on Ubuntu
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

#define NGX_HTTP_CUSTOM_SECURITY_SHM_NAME   "custom_security_shm_zone"
#define NGX_HTTP_CUSTOM_SECURITY_SHM_SIZE   (2 * 1024 * 1024) /* 2 MB default */
#define NGX_HTTP_CUSTOM_SECURITY_DEFAULT_LIMIT   20
#define NGX_HTTP_CUSTOM_SECURITY_DEFAULT_WINDOW  1000         /* 1000 ms (1s) */

/*
 * Per-IP node stored inside the shared-memory Red-Black Tree + LRU Queue.
 * Overlaps with ngx_rbtree_node_t->color in the standard Nginx rbtree layout.
 */
typedef struct {
    u_char                       color;
    u_char                       len;          /* Binary IP address length (4 or 16 bytes) */
    u_short                      reserved;
    ngx_queue_t                  queue;        /* LRU expiration queue link */
    ngx_msec_t                   window_start; /* Start timestamp of current rate window */
    ngx_msec_t                   last_seen;    /* Last request timestamp for LRU eviction */
    ngx_uint_t                   req_count;    /* Requests inside current window */
    ngx_uint_t                   blocked_count;/* Total blocked requests for this IP */
    u_char                       data[1];      /* Flexible binary IP key (in_addr / in6_addr) */
} ngx_http_custom_security_node_t;


/*
 * Shared memory structure shared across all Nginx Worker Processes.
 */
typedef struct {
    ngx_rbtree_t                 rbtree;
    ngx_rbtree_node_t            sentinel;
    ngx_queue_t                  lru_queue;
    ngx_atomic_t                 total_checked;
    ngx_atomic_t                 total_allowed;
    ngx_atomic_t                 total_blocked;
    ngx_uint_t                   active_nodes;
} ngx_http_custom_security_shctx_t;


/*
 * Main HTTP configuration context holding the shared memory pool pointers.
 */
typedef struct {
    ngx_shm_zone_t                    *shm_zone;
    ngx_slab_pool_t                   *shpool;
    ngx_http_custom_security_shctx_t  *sh;
    size_t                             shm_size;
} ngx_http_custom_security_main_conf_t;


/*
 * Location-level configuration context for directives:
 *   custom_security on|off;
 *   custom_security_limit NUMBER;
 *   custom_security_window TIME;
 */
typedef struct {
    ngx_flag_t                   enable;
    ngx_uint_t                   limit;
    ngx_msec_t                   window;
} ngx_http_custom_security_loc_conf_t;


/* Forward declarations */
static ngx_int_t ngx_http_custom_security_handler(ngx_http_request_t *r);
static void ngx_http_custom_security_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel);
static ngx_http_custom_security_node_t *ngx_http_custom_security_lookup(
    ngx_http_custom_security_main_conf_t *mcf, ngx_str_t *key, uint32_t hash,
    ngx_msec_t now, ngx_msec_t window);
static void ngx_http_custom_security_expire(
    ngx_http_custom_security_main_conf_t *mcf, ngx_uint_t force_oldest,
    ngx_msec_t now, ngx_msec_t window);
static ngx_int_t ngx_http_custom_security_init_zone(ngx_shm_zone_t *shm_zone,
    void *data);

static void *ngx_http_custom_security_create_main_conf(ngx_conf_t *cf);
static char *ngx_http_custom_security_init_main_conf(ngx_conf_t *cf, void *conf);
static void *ngx_http_custom_security_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_custom_security_merge_loc_conf(ngx_conf_t *cf,
    void *parent, void *child);
static ngx_int_t ngx_http_custom_security_init(ngx_conf_t *cf);


/*
 * Module Configuration Directives
 */
static ngx_command_t ngx_http_custom_security_commands[] = {

    { ngx_string("custom_security"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_custom_security_loc_conf_t, enable),
      NULL },

    { ngx_string("custom_security_limit"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_conf_set_num_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_custom_security_loc_conf_t, limit),
      NULL },

    { ngx_string("custom_security_window"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_conf_set_msec_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_custom_security_loc_conf_t, window),
      NULL },

    { ngx_string("custom_security_shm_size"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE1,
      ngx_conf_set_size_slot,
      NGX_HTTP_MAIN_CONF_OFFSET,
      offsetof(ngx_http_custom_security_main_conf_t, shm_size),
      NULL },

    ngx_null_command
};


/*
 * HTTP Module Context
 */
static ngx_http_module_t ngx_http_custom_security_module_ctx = {
    NULL,                                       /* preconfiguration */
    ngx_http_custom_security_init,              /* postconfiguration */

    ngx_http_custom_security_create_main_conf,  /* create main configuration */
    ngx_http_custom_security_init_main_conf,    /* init main configuration */

    NULL,                                       /* create server configuration */
    NULL,                                       /* merge server configuration */

    ngx_http_custom_security_create_loc_conf,   /* create location configuration */
    ngx_http_custom_security_merge_loc_conf     /* merge location configuration */
};


/*
 * Global Module Descriptor
 */
ngx_module_t ngx_http_custom_security_module = {
    NGX_MODULE_V1,
    &ngx_http_custom_security_module_ctx,       /* module context */
    ngx_http_custom_security_commands,          /* module directives */
    NGX_HTTP_MODULE,                            /* module type */
    NULL,                                       /* init master */
    NULL,                                       /* init module */
    NULL,                                       /* init process */
    NULL,                                       /* init thread */
    NULL,                                       /* exit thread */
    NULL,                                       /* exit process */
    NULL,                                       /* exit master */
    NGX_MODULE_V1_PADDING
};


/*
 * Extract binary client IP key from real socket address (IPv4 / IPv6).
 * Deliberately ignores X-Forwarded-For to prevent IP spoofing unless rewritten
 * beforehand by a trusted realip module.
 */
static ngx_int_t
ngx_http_custom_security_extract_ip_key(ngx_connection_t *c, ngx_str_t *key)
{
    struct sockaddr_in   *sin;
#if (NGX_HAVE_INET6)
    struct sockaddr_in6  *sin6;
#endif

    if (c == NULL || c->sockaddr == NULL) {
        return NGX_ERROR;
    }

    switch (c->sockaddr->sa_family) {

    case AF_INET:
        sin = (struct sockaddr_in *) c->sockaddr;
        key->len = sizeof(in_addr_t);
        key->data = (u_char *) &sin->sin_addr;
        return NGX_OK;

#if (NGX_HAVE_INET6)
    case AF_INET6:
        sin6 = (struct sockaddr_in6 *) c->sockaddr;
        key->len = sizeof(struct in6_addr);
        key->data = sin6->sin6_addr.s6_addr;
        return NGX_OK;
#endif

    default:
        /* Fallback to textual address representation for UNIX domain sockets */
        key->len = c->addr_text.len;
        key->data = c->addr_text.data;
        return (key->len > 0) ? NGX_OK : NGX_ERROR;
    }
}


/*
 * Helper to add a custom response header to r->headers_out.headers
 */
static void
ngx_http_custom_security_add_header(ngx_http_request_t *r,
    const char *name, size_t name_len, u_char *val_data, size_t val_len)
{
    ngx_table_elt_t  *h;

    h = ngx_list_push(&r->headers_out.headers);
    if (h == NULL) {
        return;
    }

    h->hash = 1;
    h->key.len = name_len;
    h->key.data = (u_char *) name;
    h->value.len = val_len;
    h->value.data = val_data;
}


/*
 * Main Phase Handler (Registered in NGX_HTTP_PREACCESS_PHASE)
 */
static ngx_int_t
ngx_http_custom_security_handler(ngx_http_request_t *r)
{
    uint32_t                               hash;
    ngx_str_t                              ip_key;
    ngx_msec_t                             now, elapsed;
    ngx_uint_t                             current_count, limit, blocked_total;
    ngx_flag_t                             is_blocked;
    u_char                                *hdr_buf;
    ngx_http_custom_security_node_t       *node;
    ngx_http_custom_security_loc_conf_t   *lcf;
    ngx_http_custom_security_main_conf_t  *mcf;

    /*
     * Only enforce once on the initial external client request, not on
     * subrequests (r != r->main) or internal redirects (r->internal, such as
     * ngx_http_index_module rewriting "/" -> "/index.html").
     */
    if (r != r->main || r->internal) {
        return NGX_DECLINED;
    }

    lcf = ngx_http_get_module_loc_conf(r, ngx_http_custom_security_module);
    if (lcf == NULL || !lcf->enable) {
        return NGX_DECLINED;
    }

    mcf = ngx_http_get_module_main_conf(r, ngx_http_custom_security_module);
    if (mcf == NULL || mcf->sh == NULL || mcf->shpool == NULL) {
        return NGX_DECLINED;
    }

    if (ngx_http_custom_security_extract_ip_key(r->connection, &ip_key)
        != NGX_OK)
    {
        return NGX_DECLINED;
    }

    hash = ngx_crc32_short(ip_key.data, ip_key.len);
    now = ngx_current_msec;
    limit = lcf->limit;
    is_blocked = 0;
    current_count = 0;
    blocked_total = 0;

    /* Acquire shared memory spinlock/semaphore mutex across workers */
    ngx_shmtx_lock(&mcf->shpool->mutex);

    (void) ngx_atomic_fetch_add(&mcf->sh->total_checked, 1);

    node = ngx_http_custom_security_lookup(mcf, &ip_key, hash, now,
                                           lcf->window);
    if (node == NULL) {
        /*
         * If shared memory is completely exhausted even after forced LRU
         * eviction, fail-open gracefully without crashing the worker.
         */
        ngx_shmtx_unlock(&mcf->shpool->mutex);
        ngx_log_error(NGX_LOG_ALERT, r->connection->log, 0,
                      "[CUSTOM_SECURITY] ALERT: shared memory exhausted for "
                      "client=%V uri=\"%V\" pid=%P",
                      &r->connection->addr_text, &r->uri, ngx_pid);
        return NGX_DECLINED;
    }

    elapsed = (ngx_msec_t) (now - node->window_start);

    /* Reset fixed/sliding window if the configured time window has elapsed */
    if ((ngx_msec_int_t) elapsed >= (ngx_msec_int_t) lcf->window
        || (ngx_msec_int_t) elapsed < 0)
    {
        node->window_start = now;
        node->req_count = 1;
    } else {
        node->req_count++;
    }

    node->last_seen = now;
    current_count = node->req_count;

    if (current_count > limit) {
        is_blocked = 1;
        node->blocked_count++;
        blocked_total = node->blocked_count;
        (void) ngx_atomic_fetch_add(&mcf->sh->total_blocked, 1);
    } else {
        (void) ngx_atomic_fetch_add(&mcf->sh->total_allowed, 1);
    }

    ngx_shmtx_unlock(&mcf->shpool->mutex);

    /* Attach rate-limit telemetry header to response */
    hdr_buf = ngx_pnalloc(r->pool, 32);
    if (hdr_buf != NULL) {
        u_char *p = ngx_snprintf(hdr_buf, 32, "%ui", limit);
        ngx_http_custom_security_add_header(r, "X-RateLimit-Limit",
            sizeof("X-RateLimit-Limit") - 1, hdr_buf, p - hdr_buf);
    }

    if (is_blocked) {
        ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                      "[CUSTOM_SECURITY] RATE_LIMIT_EXCEEDED: client=%V "
                      "method=\"%V\" uri=\"%V\" count=%ui limit=%ui "
                      "window=%Mms total_ip_blocks=%ui worker_pid=%P",
                      &r->connection->addr_text, &r->method_name, &r->uri,
                      current_count, limit, lcf->window, blocked_total,
                      ngx_pid);

        return NGX_HTTP_TOO_MANY_REQUESTS; /* HTTP 429 */
    }

    return NGX_DECLINED;
}


/*
 * Lookup or allocate a per-IP node inside the shared-memory Red-Black Tree.
 * Caller MUST hold mcf->shpool->mutex.
 */
static ngx_http_custom_security_node_t *
ngx_http_custom_security_lookup(ngx_http_custom_security_main_conf_t *mcf,
    ngx_str_t *key, uint32_t hash, ngx_msec_t now, ngx_msec_t window)
{
    size_t                            size;
    ngx_int_t                         rc;
    ngx_rbtree_node_t                *node, *sentinel;
    ngx_http_custom_security_node_t  *csn;

    node = mcf->sh->rbtree.root;
    sentinel = mcf->sh->rbtree.sentinel;

    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        /* hash == node->key */
        csn = (ngx_http_custom_security_node_t *) &node->color;

        rc = ngx_memn2cmp(key->data, csn->data, key->len, (size_t) csn->len);
        if (rc == 0) {
            /* Move node to head of LRU queue */
            ngx_queue_remove(&csn->queue);
            ngx_queue_insert_head(&mcf->sh->lru_queue, &csn->queue);
            return csn;
        }

        node = (rc < 0) ? node->left : node->right;
    }

    /* Node not found: opportunistically expire up to 2 stale entries first */
    ngx_http_custom_security_expire(mcf, 0, now, window);

    size = offsetof(ngx_rbtree_node_t, color)
           + offsetof(ngx_http_custom_security_node_t, data)
           + key->len;

    node = ngx_slab_alloc_locked(mcf->shpool, size);
    if (node == NULL) {
        /* Shared memory full: force eviction of oldest LRU entries and retry */
        ngx_http_custom_security_expire(mcf, 1, now, window);
        node = ngx_slab_alloc_locked(mcf->shpool, size);
        if (node == NULL) {
            return NULL;
        }
    }

    node->key = hash;

    csn = (ngx_http_custom_security_node_t *) &node->color;
    csn->len = (u_char) key->len;
    csn->reserved = 0;
    csn->window_start = now;
    csn->last_seen = now;
    csn->req_count = 0;
    csn->blocked_count = 0;

    ngx_memcpy(csn->data, key->data, key->len);

    ngx_rbtree_insert(&mcf->sh->rbtree, node);
    ngx_queue_insert_head(&mcf->sh->lru_queue, &csn->queue);
    mcf->sh->active_nodes++;

    return csn;
}


/*
 * Expire stale IP nodes from the tail of the LRU queue to bound memory usage.
 * If force_oldest == 1, forcefully evicts the oldest entry even if not expired.
 * Caller MUST hold mcf->shpool->mutex.
 */
static void
ngx_http_custom_security_expire(ngx_http_custom_security_main_conf_t *mcf,
    ngx_uint_t force_oldest, ngx_msec_t now, ngx_msec_t window)
{
    ngx_uint_t                        i;
    ngx_msec_int_t                    idle_ms, ttl_ms;
    ngx_queue_t                      *q;
    ngx_rbtree_node_t                *node;
    ngx_http_custom_security_node_t  *csn;

    ttl_ms = (ngx_msec_int_t) (window * 2);
    if (ttl_ms < 10000) {
        ttl_ms = 10000; /* Keep inactive IPs for at least 10s unless forced */
    }

    for (i = 0; i < 3; i++) {
        if (ngx_queue_empty(&mcf->sh->lru_queue)) {
            return;
        }

        q = ngx_queue_last(&mcf->sh->lru_queue);
        csn = ngx_queue_data(q, ngx_http_custom_security_node_t, queue);

        if (!force_oldest || i > 0) {
            idle_ms = (ngx_msec_int_t) (now - csn->last_seen);
            if (idle_ms >= 0 && idle_ms < ttl_ms) {
                return;
            }
        }

        ngx_queue_remove(q);

        node = (ngx_rbtree_node_t *)
                   ((u_char *) csn - offsetof(ngx_rbtree_node_t, color));

        ngx_rbtree_delete(&mcf->sh->rbtree, node);
        ngx_slab_free_locked(mcf->shpool, node);

        if (mcf->sh->active_nodes > 0) {
            mcf->sh->active_nodes--;
        }
    }
}


/*
 * Custom Red-Black Tree insertion comparator supporting 32-bit CRC32 key
 * with binary IP tie-breaking.
 */
static void
ngx_http_custom_security_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t                **p;
    ngx_http_custom_security_node_t   *csn, *csnt;

    for ( ;; ) {

        if (node->key < temp->key) {
            p = &temp->left;

        } else if (node->key > temp->key) {
            p = &temp->right;

        } else { /* node->key == temp->key */
            csn = (ngx_http_custom_security_node_t *) &node->color;
            csnt = (ngx_http_custom_security_node_t *) &temp->color;

            p = (ngx_memn2cmp(csn->data, csnt->data, csn->len, csnt->len) < 0)
                ? &temp->left : &temp->right;
        }

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p = node;
    node->parent = temp;
    node->left = sentinel;
    node->right = sentinel;
    ngx_rbt_red(node);
}


/*
 * Initialize the Shared Memory Zone across Master/Worker processes
 */
static ngx_int_t
ngx_http_custom_security_init_zone(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_custom_security_main_conf_t  *omcf = data;
    ngx_http_custom_security_main_conf_t  *mcf;
    size_t                                 len;

    mcf = shm_zone->data;

    if (omcf) {
        mcf->sh = omcf->sh;
        mcf->shpool = omcf->shpool;
        return NGX_OK;
    }

    mcf->shpool = (ngx_slab_pool_t *) shm_zone->shm.addr;

    if (shm_zone->shm.exists) {
        mcf->sh = mcf->shpool->data;
        return NGX_OK;
    }

    mcf->sh = ngx_slab_alloc(mcf->shpool,
                             sizeof(ngx_http_custom_security_shctx_t));
    if (mcf->sh == NULL) {
        return NGX_ERROR;
    }

    mcf->shpool->data = mcf->sh;

    ngx_rbtree_init(&mcf->sh->rbtree, &mcf->sh->sentinel,
                    ngx_http_custom_security_rbtree_insert_value);
    ngx_queue_init(&mcf->sh->lru_queue);

    mcf->sh->total_checked = 0;
    mcf->sh->total_allowed = 0;
    mcf->sh->total_blocked = 0;
    mcf->sh->active_nodes = 0;

    len = sizeof(" in custom_security_shm_zone \"\"")
          + shm_zone->shm.name.len;

    mcf->shpool->log_ctx = ngx_slab_alloc(mcf->shpool, len);
    if (mcf->shpool->log_ctx == NULL) {
        return NGX_ERROR;
    }

    ngx_sprintf(mcf->shpool->log_ctx, " in custom_security_shm_zone \"%V\"%Z",
                &shm_zone->shm.name);

    mcf->shpool->log_nomem = 0;

    return NGX_OK;
}


static void *
ngx_http_custom_security_create_main_conf(ngx_conf_t *cf)
{
    ngx_http_custom_security_main_conf_t  *mcf;

    mcf = ngx_pcalloc(cf->pool, sizeof(ngx_http_custom_security_main_conf_t));
    if (mcf == NULL) {
        return NULL;
    }

    mcf->shm_size = NGX_CONF_UNSET_SIZE;

    return mcf;
}


static char *
ngx_http_custom_security_init_main_conf(ngx_conf_t *cf, void *conf)
{
    ngx_http_custom_security_main_conf_t  *mcf = conf;
    ngx_str_t                              shm_name;

    ngx_conf_init_size_value(mcf->shm_size,
                             NGX_HTTP_CUSTOM_SECURITY_SHM_SIZE);

    ngx_str_set(&shm_name, NGX_HTTP_CUSTOM_SECURITY_SHM_NAME);

    mcf->shm_zone = ngx_shared_memory_add(cf, &shm_name, mcf->shm_size,
                                          &ngx_http_custom_security_module);
    if (mcf->shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    mcf->shm_zone->init = ngx_http_custom_security_init_zone;
    mcf->shm_zone->data = mcf;

    return NGX_CONF_OK;
}


static void *
ngx_http_custom_security_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_custom_security_loc_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_custom_security_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    conf->enable = NGX_CONF_UNSET;
    conf->limit = NGX_CONF_UNSET_UINT;
    conf->window = NGX_CONF_UNSET_MSEC;

    return conf;
}


static char *
ngx_http_custom_security_merge_loc_conf(ngx_conf_t *cf, void *parent,
    void *child)
{
    ngx_http_custom_security_loc_conf_t *prev = parent;
    ngx_http_custom_security_loc_conf_t *conf = child;

    ngx_conf_merge_value(conf->enable, prev->enable, 0);
    ngx_conf_merge_uint_value(conf->limit, prev->limit,
                              NGX_HTTP_CUSTOM_SECURITY_DEFAULT_LIMIT);
    ngx_conf_merge_msec_value(conf->window, prev->window,
                              NGX_HTTP_CUSTOM_SECURITY_DEFAULT_WINDOW);

    if (conf->limit == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "custom_security_limit must be greater than 0");
        return NGX_CONF_ERROR;
    }

    if (conf->window == 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "custom_security_window must be greater than 0ms");
        return NGX_CONF_ERROR;
    }

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_custom_security_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_PREACCESS_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_custom_security_handler;

    return NGX_OK;
}
