/*
 * Header: include/process_monitor.h
 * Purpose: Data structures and prototypes for Custom Nginx Process Monitor
 *          using Linux procfs (/proc) and systemd inspection.
 * Project: Customize and Rebuild Nginx Web Server on Ubuntu
 */

#ifndef PROCESS_MONITOR_H
#define PROCESS_MONITOR_H

#include <sys/types.h>
#include <time.h>

#include <limits.h>

#define MAX_WORKERS        64
#define MAX_PORTS          16
#define MAX_PATH_LEN       PATH_MAX
#define MAX_CMDLINE_LEN    512
#define MAX_STATE_LEN      64
#define MAX_TIME_STR_LEN   64

typedef enum {
    PROC_ROLE_UNKNOWN = 0,
    PROC_ROLE_MASTER  = 1,
    PROC_ROLE_WORKER  = 2
} proc_role_t;

typedef struct {
    pid_t                pid;
    pid_t                ppid;
    uid_t                uid;
    proc_role_t          role;
    char                 state_char;                     /* R, S, D, Z, T from /proc/PID/stat */
    char                 state_desc[MAX_STATE_LEN];      /* Human-readable state from /proc/PID/status */
    int                  threads;                        /* Thread count from /proc/PID/task */
    unsigned long long   starttime_ticks;                /* Field 22 in /proc/PID/stat */
    time_t               start_epoch;                    /* Calculated epoch timestamp */
    char                 start_time_str[MAX_TIME_STR_LEN];
    char                 exe_path[MAX_PATH_LEN];         /* Resolved /proc/PID/exe */
    char                 cmdline[MAX_CMDLINE_LEN];       /* Decoded /proc/PID/cmdline */
} nginx_proc_info_t;

typedef struct {
    char                 target_bin[MAX_PATH_LEN];
    char                 project_root[MAX_PATH_LEN];
    int                  master_found;
    nginx_proc_info_t    master;
    int                  worker_count;
    nginx_proc_info_t    workers[MAX_WORKERS];
    char                 service_state[64];              /* ACTIVE / INACTIVE / STANDALONE */
    char                 sub_state[64];
    int                  systemd_main_pid;
    int                  port_count;
    unsigned int         listening_ports[MAX_PORTS];
} custom_nginx_monitor_t;

/* Function prototypes */
int inspect_custom_nginx_processes(custom_nginx_monitor_t *mon,
                                   const char *project_root,
                                   const char *target_bin);
void print_process_monitor_report(const custom_nginx_monitor_t *mon);

#endif /* PROCESS_MONITOR_H */
