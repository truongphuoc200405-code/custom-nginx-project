/*
 * Module: ngx_http_custom_monitoring_module
 * Purpose: Real-time HTTP Telemetry, Status Code Accounting & Access-Controlled
 *          JSON Monitoring Endpoint (/custom_status) across Worker Processes.
 * Project: Customize and Rebuild Nginx Web Server on Ubuntu
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

#define NGX_HTTP_CUSTOM_MONITORING_SHM_NAME  "custom_monitoring_shm_zone"
#define NGX_HTTP_CUSTOM_MONITORING_SHM_SIZE  (256 * 1024) /* 256 KB */


/*
 * Shared memory metrics structure shared across all Worker Processes.
 * Updated using lock-free atomic operations (ngx_atomic_fetch_add).
 */
typedef struct {
    time_t          start_time;          /* Master/Cycle start epoch (ngx_time()) */
    ngx_atomic_t    total_requests;      /* Total HTTP requests processed */
    ngx_atomic_t    successful_requests; /* HTTP 1xx, 2xx, 3xx responses */
    ngx_atomic_t    client_errors;       /* HTTP 4xx responses (including 403, 404, 429) */
    ngx_atomic_t    server_errors;       /* HTTP 5xx responses */
    ngx_atomic_t    blocked_requests;    /* Security-blocked requests (HTTP 403 & 429) */
} ngx_http_custom_monitoring_shctx_t;


/*
 * Main HTTP configuration context holding the shared memory zone.
 */
typedef struct {
    ngx_shm_zone_t                      *shm_zone;
    ngx_slab_pool_t                     *shpool;
    ngx_http_custom_monitoring_shctx_t  *sh;
} ngx_http_custom_monitoring_main_conf_t;


/*
 * Location configuration context for /custom_status endpoint and IP ACLs.
 */
typedef struct {
    ngx_flag_t      enable_status;
    ngx_flag_t      allow_localhost;
    ngx_array_t    *allowed_cidrs;  /* Array of ngx_cidr_t admin IPs/subnets */
} ngx_http_custom_monitoring_loc_conf_t;


/* Forward declarations */
static ngx_int_t ngx_http_custom_monitoring_status_handler(
    ngx_http_request_t *r);
static ngx_int_t ngx_http_custom_monitoring_log_handler(
    ngx_http_request_t *r);
static ngx_int_t ngx_http_custom_monitoring_check_access(
    ngx_http_request_t *r, ngx_http_custom_monitoring_loc_conf_t *lcf);
static ngx_int_t ngx_http_custom_monitoring_init_zone(
    ngx_shm_zone_t *shm_zone, void *data);

static char *ngx_http_custom_monitoring_set_status(ngx_conf_t *cf,
    ngx_command_t *cmd, void *conf);
static char *ngx_http_custom_monitoring_set_allow(ngx_conf_t *cf,
    ngx_command_t *cmd, void *conf);
static void *ngx_http_custom_monitoring_create_main_conf(ngx_conf_t *cf);
static char *ngx_http_custom_monitoring_init_main_conf(ngx_conf_t *cf,
    void *conf);
static void *ngx_http_custom_monitoring_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_custom_monitoring_merge_loc_conf(ngx_conf_t *cf,
    void *parent, void *child);
static ngx_int_t ngx_http_custom_monitoring_init(ngx_conf_t *cf);


/*
 * Module Directives:
 *   custom_status;
 *   custom_status_allow <IP_OR_CIDR>;
 */
static ngx_command_t ngx_http_custom_monitoring_commands[] = {

    { ngx_string("custom_status"),
      NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_NOARGS|NGX_CONF_FLAG,
      ngx_http_custom_monitoring_set_status,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("custom_status_allow"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_http_custom_monitoring_set_allow,
      NGX_HTTP_LOC_CONF_OFFSET,
      0,
      NULL },

    { ngx_string("custom_status_localhost"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_custom_monitoring_loc_conf_t, allow_localhost),
      NULL },

    ngx_null_command
};


/*
 * HTTP Module Context
 */
static ngx_http_module_t ngx_http_custom_monitoring_module_ctx = {
    NULL,                                         /* preconfiguration */
    ngx_http_custom_monitoring_init,              /* postconfiguration */

    ngx_http_custom_monitoring_create_main_conf,  /* create main configuration */
    ngx_http_custom_monitoring_init_main_conf,    /* init main configuration */

    NULL,                                         /* create server configuration */
    NULL,                                         /* merge server configuration */

    ngx_http_custom_monitoring_create_loc_conf,   /* create location configuration */
    ngx_http_custom_monitoring_merge_loc_conf     /* merge location configuration */
};


/*
 * Global Module Descriptor
 */
ngx_module_t ngx_http_custom_monitoring_module = {
    NGX_MODULE_V1,
    &ngx_http_custom_monitoring_module_ctx,       /* module context */
    ngx_http_custom_monitoring_commands,          /* module directives */
    NGX_HTTP_MODULE,                              /* module type */
    NULL,                                         /* init master */
    NULL,                                         /* init module */
    NULL,                                         /* init process */
    NULL,                                         /* init thread */
    NULL,                                         /* exit thread */
    NULL,                                         /* exit process */
    NULL,                                         /* exit master */
    NGX_MODULE_V1_PADDING
};


/*
 * Verify whether client socket IP is localhost (127.0.0.0/8, ::1, ::ffff:127.x)
 * or matches an explicitly configured admin IP/CIDR in custom_status_allow.
 */
static ngx_int_t
ngx_http_custom_monitoring_check_access(ngx_http_request_t *r,
    ngx_http_custom_monitoring_loc_conf_t *lcf)
{
    ngx_uint_t           i, n;
    ngx_cidr_t          *cidrs;
    struct sockaddr     *sa;
    struct sockaddr_in  *sin;
    in_addr_t            addr4;
#if (NGX_HAVE_INET6)
    struct sockaddr_in6 *sin6;
    u_char              *p6;
#endif

    if (r->connection == NULL || r->connection->sockaddr == NULL) {
        return NGX_DECLINED;
    }

    sa = r->connection->sockaddr;

    /* 1. Allow loopback (localhost) connections when allow_localhost is enabled (default: on) */
    if (lcf == NULL || lcf->allow_localhost) {
        if (sa->sa_family == AF_INET) {
            sin = (struct sockaddr_in *) sa;
            addr4 = ntohl(sin->sin_addr.s_addr);
            /* 127.0.0.0/8 -> (addr4 >> 24) == 127 */
            if ((addr4 >> 24) == 127) {
                return NGX_OK;
            }
        }
#if (NGX_HAVE_INET6)
        else if (sa->sa_family == AF_INET6) {
            sin6 = (struct sockaddr_in6 *) sa;
            p6 = sin6->sin6_addr.s6_addr;

            /* Native IPv6 loopback ::1 */
            if (IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr)) {
                return NGX_OK;
            }

            /* IPv4-mapped IPv6 loopback ::ffff:127.0.0.1 */
            if (IN6_IS_ADDR_V4MAPPED(&sin6->sin6_addr) && p6[12] == 127) {
                return NGX_OK;
            }
        }
#endif
    }

    /* 2. Check configured admin IP / CIDR whitelist (custom_status_allow) */
    if (lcf != NULL && lcf->allowed_cidrs != NULL) {
        cidrs = lcf->allowed_cidrs->elts;

        for (i = 0; i < lcf->allowed_cidrs->nelts; i++) {
            if (cidrs[i].family != sa->sa_family) {
                continue;
            }

            if (sa->sa_family == AF_INET) {
                sin = (struct sockaddr_in *) sa;
                if ((sin->sin_addr.s_addr & cidrs[i].u.in.mask)
                    == cidrs[i].u.in.addr)
                {
                    return NGX_OK;
                }
            }
#if (NGX_HAVE_INET6)
            else if (sa->sa_family == AF_INET6) {
                sin6 = (struct sockaddr_in6 *) sa;
                p6 = sin6->sin6_addr.s6_addr;

                for (n = 0; n < 16; n++) {
                    if ((p6[n] & cidrs[i].u.in6.mask.s6_addr[n])
                        != cidrs[i].u.in6.addr.s6_addr[n])
                    {
                        goto next_cidr;
                    }
                }
                return NGX_OK;
            }
        next_cidr:
            continue;
#endif
        }
    }

    return NGX_DECLINED;
}


/*
 * Content Handler for /custom_status endpoint.
 * Generates valid, non-cached JSON response from shared runtime counters.
 */
static ngx_int_t
ngx_http_custom_monitoring_status_handler(ngx_http_request_t *r)
{
    size_t                                   buf_size;
    time_t                                   now, uptime;
    ngx_int_t                                rc;
    ngx_buf_t                               *b;
    ngx_chain_t                              out;
    ngx_atomic_uint_t                        total_req, success_req;
    ngx_atomic_uint_t                        err_4xx, err_5xx, blocked_req;
    ngx_atomic_uint_t                        active_conn;
    ngx_http_custom_monitoring_loc_conf_t   *lcf;
    ngx_http_custom_monitoring_main_conf_t  *mcf;

    if (!(r->method & (NGX_HTTP_GET|NGX_HTTP_HEAD))) {
        return NGX_HTTP_NOT_ALLOWED;
    }

    lcf = ngx_http_get_module_loc_conf(r, ngx_http_custom_monitoring_module);

    /* Enforce strict Access Control (localhost or configured admin IP only) */
    if (ngx_http_custom_monitoring_check_access(r, lcf) != NGX_OK) {
        ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                      "[CUSTOM_MONITORING] ACCESS_DENIED: unauthorized client "
                      "%V attempted to access \"%V\"",
                      &r->connection->addr_text, &r->uri);
        return NGX_HTTP_FORBIDDEN;
    }

    rc = ngx_http_discard_request_body(r);
    if (rc != NGX_OK) {
        return rc;
    }

    mcf = ngx_http_get_module_main_conf(r, ngx_http_custom_monitoring_module);
    if (mcf == NULL || mcf->sh == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    /*
     * Snapshot atomic runtime counters.
     * Include the current in-flight /custom_status request (+1 to total &
     * successful) so the JSON snapshot reflects this request immediately
     * without waiting for NGX_HTTP_LOG_PHASE.
     */
    total_req   = mcf->sh->total_requests + 1;
    success_req = mcf->sh->successful_requests + 1;
    err_4xx     = mcf->sh->client_errors;
    err_5xx     = mcf->sh->server_errors;
    blocked_req = mcf->sh->blocked_requests;

    /* Read real-time active connections from Nginx's global atomic counter */
    active_conn = (ngx_stat_active != NULL) ? *ngx_stat_active : 1;

    now = ngx_time();
    uptime = (now >= mcf->sh->start_time) ? (now - mcf->sh->start_time) : 0;

    buf_size = 512;
    b = ngx_create_temp_buf(r->pool, buf_size);
    if (b == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    b->last = ngx_snprintf(b->last, buf_size,
        "{\n"
        "  \"server\": \"CustomWebServer\",\n"
        "  \"status\": \"running\",\n"
        "  \"total_requests\": %uA,\n"
        "  \"successful_requests\": %uA,\n"
        "  \"client_errors\": %uA,\n"
        "  \"server_errors\": %uA,\n"
        "  \"blocked_requests\": %uA,\n"
        "  \"active_connections\": %uA,\n"
        "  \"uptime_seconds\": %T\n"
        "}\n",
        total_req,
        success_req,
        err_4xx,
        err_5xx,
        blocked_req,
        active_conn,
        uptime);

    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_type_len = sizeof("application/json") - 1;
    ngx_str_set(&r->headers_out.content_type, "application/json");
    r->headers_out.content_type_lowcase = NULL;
    r->headers_out.content_length_n = b->last - b->pos;

    b->last_buf = (r == r->main) ? 1 : 0;
    b->last_in_chain = 1;

    out.buf = b;
    out.next = NULL;

    rc = ngx_http_send_header(r);
    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }

    return ngx_http_output_filter(r, &out);
}


/*
 * Log-Phase Handler (Registered in NGX_HTTP_LOG_PHASE).
 * Runs once at the end of every external HTTP request across all locations
 * and updates shared atomic counters without recursion or locks.
 */
static ngx_int_t
ngx_http_custom_monitoring_log_handler(ngx_http_request_t *r)
{
    ngx_uint_t                               status;
    ngx_http_custom_monitoring_main_conf_t  *mcf;

    /* Count only main requests (ignore internal subrequests) */
    if (r != r->main) {
        return NGX_OK;
    }

    mcf = ngx_http_get_module_main_conf(r, ngx_http_custom_monitoring_module);
    if (mcf == NULL || mcf->sh == NULL) {
        return NGX_OK;
    }

    status = r->headers_out.status;
    if (status == 0 && r->err_status) {
        status = r->err_status;
    }

    (void) ngx_atomic_fetch_add(&mcf->sh->total_requests, 1);

    if (status >= 200 && status < 400) {
        (void) ngx_atomic_fetch_add(&mcf->sh->successful_requests, 1);

    } else if (status >= 400 && status < 500) {
        (void) ngx_atomic_fetch_add(&mcf->sh->client_errors, 1);

        if (status == NGX_HTTP_TOO_MANY_REQUESTS
            || status == NGX_HTTP_FORBIDDEN)
        {
            (void) ngx_atomic_fetch_add(&mcf->sh->blocked_requests, 1);
        }

    } else if (status >= 500 && status < 600) {
        (void) ngx_atomic_fetch_add(&mcf->sh->server_errors, 1);
    }

    return NGX_OK;
}


/*
 * Shared Memory Zone Initializer
 */
static ngx_int_t
ngx_http_custom_monitoring_init_zone(ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_custom_monitoring_main_conf_t  *omcf = data;
    ngx_http_custom_monitoring_main_conf_t  *mcf;

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
                             sizeof(ngx_http_custom_monitoring_shctx_t));
    if (mcf->sh == NULL) {
        return NGX_ERROR;
    }

    mcf->shpool->data = mcf->sh;

    mcf->sh->start_time          = ngx_time();
    mcf->sh->total_requests      = 0;
    mcf->sh->successful_requests = 0;
    mcf->sh->client_errors       = 0;
    mcf->sh->server_errors       = 0;
    mcf->sh->blocked_requests    = 0;

    return NGX_OK;
}


/*
 * Directive setter: custom_status [on|off];
 */
static char *
ngx_http_custom_monitoring_set_status(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf)
{
    ngx_http_custom_monitoring_loc_conf_t *lcf = conf;
    ngx_http_core_loc_conf_t              *clcf;
    ngx_str_t                             *value;

    if (cf->args->nelts == 2) {
        value = cf->args->elts;
        if (ngx_strcasecmp(value[1].data, (u_char *) "off") == 0) {
            lcf->enable_status = 0;
            return NGX_CONF_OK;
        }
        if (ngx_strcasecmp(value[1].data, (u_char *) "on") != 0) {
            ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                               "invalid value \"%V\" in \"%V\" directive",
                               &value[1], &cmd->name);
            return NGX_CONF_ERROR;
        }
    }

    lcf->enable_status = 1;

    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_custom_monitoring_status_handler;

    return NGX_CONF_OK;
}


/*
 * Directive setter: custom_status_allow <IP_OR_CIDR>;
 */
static char *
ngx_http_custom_monitoring_set_allow(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf)
{
    ngx_http_custom_monitoring_loc_conf_t *lcf = conf;
    ngx_int_t                              rc;
    ngx_str_t                             *value;
    ngx_cidr_t                            *cidr;

    value = cf->args->elts;

    if (lcf->allowed_cidrs == NULL) {
        lcf->allowed_cidrs = ngx_array_create(cf->pool, 4, sizeof(ngx_cidr_t));
        if (lcf->allowed_cidrs == NULL) {
            return NGX_CONF_ERROR;
        }
    }

    cidr = ngx_array_push(lcf->allowed_cidrs);
    if (cidr == NULL) {
        return NGX_CONF_ERROR;
    }

    ngx_memzero(cidr, sizeof(ngx_cidr_t));

    if (ngx_strcmp(value[1].data, "none") == 0) {
        return NGX_CONF_OK;
    }

    rc = ngx_ptocidr(&value[1], cidr);
    if (rc == NGX_ERROR) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid IP/CIDR parameter \"%V\" in \"%V\"",
                           &value[1], &cmd->name);
        return NGX_CONF_ERROR;
    }

    return NGX_CONF_OK;
}


static void *
ngx_http_custom_monitoring_create_main_conf(ngx_conf_t *cf)
{
    ngx_http_custom_monitoring_main_conf_t  *mcf;

    mcf = ngx_pcalloc(cf->pool, sizeof(ngx_http_custom_monitoring_main_conf_t));
    if (mcf == NULL) {
        return NULL;
    }

    return mcf;
}


static char *
ngx_http_custom_monitoring_init_main_conf(ngx_conf_t *cf, void *conf)
{
    ngx_http_custom_monitoring_main_conf_t  *mcf = conf;
    ngx_str_t                                shm_name;

    ngx_str_set(&shm_name, NGX_HTTP_CUSTOM_MONITORING_SHM_NAME);

    mcf->shm_zone = ngx_shared_memory_add(cf, &shm_name,
                                          NGX_HTTP_CUSTOM_MONITORING_SHM_SIZE,
                                          &ngx_http_custom_monitoring_module);
    if (mcf->shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    mcf->shm_zone->init = ngx_http_custom_monitoring_init_zone;
    mcf->shm_zone->data = mcf;

    return NGX_CONF_OK;
}


static void *
ngx_http_custom_monitoring_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_custom_monitoring_loc_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_custom_monitoring_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    conf->enable_status = NGX_CONF_UNSET;
    conf->allow_localhost = NGX_CONF_UNSET;
    conf->allowed_cidrs = NULL;

    return conf;
}


static char *
ngx_http_custom_monitoring_merge_loc_conf(ngx_conf_t *cf, void *parent,
    void *child)
{
    ngx_http_custom_monitoring_loc_conf_t *prev = parent;
    ngx_http_custom_monitoring_loc_conf_t *conf = child;

    (void) cf;
    ngx_conf_merge_value(conf->enable_status, prev->enable_status, 0);
    ngx_conf_merge_value(conf->allow_localhost, prev->allow_localhost, 1);

    if (conf->allowed_cidrs == NULL) {
        conf->allowed_cidrs = prev->allowed_cidrs;
    }

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_custom_monitoring_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_LOG_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_custom_monitoring_log_handler;

    return NGX_OK;
}
