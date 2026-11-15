/*
 * Header: include/resource_monitor.h
 * Purpose: Data structures and function prototypes for Custom Nginx Resource
 *          Monitor (CPU & RAM telemetry via Linux /proc filesystem).
 * Project: Customize and Rebuild Nginx Web Server on Ubuntu
 */

#ifndef RESOURCE_MONITOR_H
#define RESOURCE_MONITOR_H

#include <sys/types.h>
#include <limits.h>

#define RES_MAX_PROCS       68
#define RES_MAX_PATH_LEN    PATH_MAX
#define RES_MAX_CMDLINE_LEN 512
#define RES_MAX_STATE_LEN   64

typedef enum {
    RES_ROLE_UNKNOWN = 0,
    RES_ROLE_MASTER  = 1,
    RES_ROLE_WORKER  = 2
} res_proc_role_t;

/*
 * Per-process CPU & Memory snapshot read from /proc/<pid>/stat and
 * /proc/<pid>/status.
 */
typedef struct {
    pid_t               pid;
    pid_t               ppid;
    res_proc_role_t     role;
    char                state_char;                     /* R, S, D, Z, T */
    char                state_desc[RES_MAX_STATE_LEN];  /* e.g. S (sleeping) */
    int                 threads;
    char                cmdline[RES_MAX_CMDLINE_LEN];

    /* CPU ticks (clock ticks / jiffies from /proc/<pid>/stat fields 14..17) */
    unsigned long long  utime_ticks_t1;
    unsigned long long  stime_ticks_t1;
    unsigned long long  cutime_ticks_t1;
    unsigned long long  cstime_ticks_t1;

    unsigned long long  utime_ticks_t2;
    unsigned long long  stime_ticks_t2;
    unsigned long long  cutime_ticks_t2;
    unsigned long long  cstime_ticks_t2;

    unsigned long long  delta_utime_ticks;
    unsigned long long  delta_stime_ticks;
    unsigned long long  delta_total_ticks;

    double              cpu_percent;                    /* Process CPU % */
    int                 alive_at_t2;                    /* 1 if still alive at sample 2 */

    /* Memory metrics from /proc/<pid>/status and /proc/<pid>/stat */
    unsigned long long  vm_rss_kb;                      /* VmRSS in KB (Physical RAM) */
    unsigned long long  vm_size_kb;                     /* VmSize in KB (Virtual Address Space) */
    unsigned long long  vm_peak_kb;                     /* VmPeak in KB */
    unsigned long long  vm_hwm_kb;                      /* VmHWM (Peak RSS) in KB */
    double              mem_percent;                    /* Process RSS / System MemTotal * 100 */
} nginx_proc_resource_t;

/*
 * System-wide CPU jiffies read from /proc/stat ("cpu " aggregate line).
 */
typedef struct {
    unsigned long long  user;
    unsigned long long  nice;
    unsigned long long  system;
    unsigned long long  idle;
    unsigned long long  iowait;
    unsigned long long  irq;
    unsigned long long  softirq;
    unsigned long long  steal;
    unsigned long long  total_jiffies;
} system_cpu_sample_t;

/*
 * System-wide memory metrics read from /proc/meminfo.
 */
typedef struct {
    unsigned long long  mem_total_kb;
    unsigned long long  mem_free_kb;
    unsigned long long  mem_available_kb;
    unsigned long long  buffers_kb;
    unsigned long long  cached_kb;
} system_mem_info_t;

/*
 * Complete aggregated telemetry report for Custom Nginx.
 */
typedef struct {
    char                    project_root[RES_MAX_PATH_LEN];
    char                    target_bin[RES_MAX_PATH_LEN];
    int                     sample_interval_ms;
    long                    clk_tck;
    long                    num_cpus;
    long                    page_size_kb;

    /* System metrics */
    double                  uptime_seconds;
    double                  idle_seconds;
    system_mem_info_t       sys_mem;
    system_cpu_sample_t     sys_cpu_t1;
    system_cpu_sample_t     sys_cpu_t2;
    unsigned long long      delta_sys_jiffies;

    /* Nginx process metrics */
    int                     nginx_running;
    pid_t                   master_pid;
    char                    nginx_state_summary[RES_MAX_STATE_LEN];
    int                     process_count;              /* Master + Workers alive */
    int                     worker_count;               /* Active Worker processes */
    nginx_proc_resource_t   procs[RES_MAX_PROCS];

    /* Aggregated Nginx totals */
    unsigned long long      total_utime_ticks;
    unsigned long long      total_stime_ticks;
    unsigned long long      total_delta_ticks;
    double                  total_cpu_percent;          /* Sum of Master + Workers CPU % */
    unsigned long long      total_rss_kb;               /* Sum of VmRSS across Master + Workers */
    unsigned long long      total_vsize_kb;             /* Sum of VmSize across Master + Workers */
    double                  total_mem_percent;          /* Total RSS / MemTotal * 100 */
} custom_nginx_resource_report_t;

/* Function prototypes */
int collect_nginx_resource_metrics(custom_nginx_resource_report_t *report,
                                   const char *project_root,
                                   const char *target_bin,
                                   int sample_interval_ms);

void print_resource_monitor_report(const custom_nginx_resource_report_t *report);

#endif /* RESOURCE_MONITOR_H */
