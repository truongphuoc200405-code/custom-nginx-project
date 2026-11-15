/*
 * File: src/resource_monitor.c
 * Title: Custom Nginx Resource Monitor (CPU & RAM Telemetry)
 * Purpose: Collect real-time Linux CPU and Memory telemetry for Custom Nginx
 *          Master and Worker processes directly from /proc/<pid>/stat,
 *          /proc/<pid>/status, /proc/stat, /proc/meminfo, and /proc/uptime.
 * Project: Customize and Rebuild Nginx Web Server on Ubuntu
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>
#include <limits.h>
#include <sys/types.h>
#include <sys/stat.h>

#include "resource_monitor.h"

/*
 * Read system uptime and idle time in seconds from /proc/uptime.
 */
static int
read_system_uptime(double *uptime_sec, double *idle_sec)
{
    FILE *fp;
    double up = 0.0, idle = 0.0;

    fp = fopen("/proc/uptime", "r");
    if (fp == NULL) {
        return -1;
    }

    if (fscanf(fp, "%lf %lf", &up, &idle) != 2) {
        fclose(fp);
        return -1;
    }

    fclose(fp);
    *uptime_sec = up;
    *idle_sec = idle;
    return 0;
}


/*
 * Read system-wide memory information from /proc/meminfo.
 * Values in /proc/meminfo are reported in KiB (kB).
 */
static int
read_system_meminfo(system_mem_info_t *mem)
{
    FILE *fp;
    char  line[256];
    char  key[64];
    unsigned long long val = 0;

    memset(mem, 0, sizeof(*mem));
    fp = fopen("/proc/meminfo", "r");
    if (fp == NULL) {
        return -1;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        if (sscanf(line, "%63[^:]: %llu", key, &val) == 2) {
            if (strcmp(key, "MemTotal") == 0) {
                mem->mem_total_kb = val;
            } else if (strcmp(key, "MemFree") == 0) {
                mem->mem_free_kb = val;
            } else if (strcmp(key, "MemAvailable") == 0) {
                mem->mem_available_kb = val;
            } else if (strcmp(key, "Buffers") == 0) {
                mem->buffers_kb = val;
            } else if (strcmp(key, "Cached") == 0) {
                mem->cached_kb = val;
            }
        }
    }

    fclose(fp);
    return (mem->mem_total_kb > 0) ? 0 : -1;
}


/*
 * Read aggregate system CPU time jiffies from first line of /proc/stat:
 * cpu  user nice system idle iowait irq softirq steal [guest guest_nice]
 */
static int
read_system_cpu_sample(system_cpu_sample_t *sample)
{
    FILE *fp;
    char  line[512];

    memset(sample, 0, sizeof(*sample));
    fp = fopen("/proc/stat", "r");
    if (fp == NULL) {
        return -1;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strncmp(line, "cpu ", 4) == 0) {
            int n = sscanf(line + 4, "%llu %llu %llu %llu %llu %llu %llu %llu",
                           &sample->user,
                           &sample->nice,
                           &sample->system,
                           &sample->idle,
                           &sample->iowait,
                           &sample->irq,
                           &sample->softirq,
                           &sample->steal);
            if (n >= 4) {
                sample->total_jiffies = sample->user + sample->nice +
                                        sample->system + sample->idle +
                                        sample->iowait + sample->irq +
                                        sample->softirq + sample->steal;
                fclose(fp);
                return 0;
            }
        }
    }

    fclose(fp);
    return -1;
}


/*
 * Read /proc/<pid>/cmdline, replacing NUL bytes with spaces.
 */
static int
read_proc_cmdline(pid_t pid, char *buf, size_t buf_len)
{
    char    path[RES_MAX_PATH_LEN];
    FILE   *fp;
    size_t  n, i;

    snprintf(path, sizeof(path), "/proc/%d/cmdline", (int) pid);
    fp = fopen(path, "rb");
    if (fp == NULL) {
        return -1;
    }

    n = fread(buf, 1, buf_len - 1, fp);
    fclose(fp);

    if (n == 0) {
        buf[0] = '\0';
        return -1;
    }

    for (i = 0; i < n; i++) {
        if (buf[i] == '\0') {
            buf[i] = ' ';
        }
    }
    while (n > 0 && buf[n - 1] == ' ') {
        n--;
    }
    buf[n] = '\0';
    return 0;
}


/*
 * Parse /proc/<pid>/stat for:
 *  - Field 3  : state (char)
 *  - Field 4  : ppid (int)
 *  - Field 14 : utime (unsigned long long, clock ticks in user mode)
 *  - Field 15 : stime (unsigned long long, clock ticks in kernel/system mode)
 *  - Field 16 : cutime (waited-for children user ticks)
 *  - Field 17 : cstime (waited-for children kernel ticks)
 *  - Field 20 : num_threads
 *  - Field 23 : vsize (virtual memory size in bytes)
 *  - Field 24 : rss (resident set size in pages)
 */
static int
parse_proc_stat_metrics(pid_t pid,
                        char *state_char,
                        pid_t *ppid,
                        unsigned long long *utime,
                        unsigned long long *stime,
                        unsigned long long *cutime,
                        unsigned long long *cstime,
                        int *threads,
                        unsigned long long *vsize_bytes,
                        long *rss_pages)
{
    char    path[RES_MAX_PATH_LEN];
    char    buf[1024];
    FILE   *fp;
    char   *rparen;
    char   *saveptr = NULL;
    char   *token;
    int     field_idx;

    snprintf(path, sizeof(path), "/proc/%d/stat", (int) pid);
    fp = fopen(path, "r");
    if (fp == NULL) {
        return -1;
    }

    if (fgets(buf, sizeof(buf), fp) == NULL) {
        fclose(fp);
        return -1;
    }
    fclose(fp);

    rparen = strrchr(buf, ')');
    if (rparen == NULL || rparen[1] == '\0') {
        return -1;
    }

    field_idx = 3;
    token = strtok_r(rparen + 2, " ", &saveptr);
    while (token != NULL) {
        switch (field_idx) {
        case 3:
            if (state_char) *state_char = token[0];
            break;
        case 4:
            if (ppid) *ppid = (pid_t) atoi(token);
            break;
        case 14:
            if (utime) *utime = strtoull(token, NULL, 10);
            break;
        case 15:
            if (stime) *stime = strtoull(token, NULL, 10);
            break;
        case 16:
            if (cutime) *cutime = strtoull(token, NULL, 10);
            break;
        case 17:
            if (cstime) *cstime = strtoull(token, NULL, 10);
            break;
        case 20:
            if (threads) *threads = atoi(token);
            break;
        case 23:
            if (vsize_bytes) *vsize_bytes = strtoull(token, NULL, 10);
            break;
        case 24:
            if (rss_pages) *rss_pages = strtol(token, NULL, 10);
            return 0;
        default:
            break;
        }
        field_idx++;
        token = strtok_r(NULL, " ", &saveptr);
    }

    return -1;
}


/*
 * Parse /proc/<pid>/status for human-readable State, VmSize, VmRSS, VmPeak,
 * VmHWM, and Threads.
 */
static int
parse_proc_status_memory(pid_t pid, nginx_proc_resource_t *proc, long page_size_kb)
{
    char                path[RES_MAX_PATH_LEN];
    char                line[256];
    FILE               *fp;
    unsigned long long  val = 0;

    snprintf(path, sizeof(path), "/proc/%d/status", (int) pid);
    fp = fopen(path, "r");
    if (fp == NULL) {
        return -1;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strncmp(line, "State:", 6) == 0) {
            char *p = line + 6;
            while (*p && isspace((unsigned char) *p)) {
                p++;
            }
            size_t len = strlen(p);
            while (len > 0 && (p[len - 1] == '\n' || p[len - 1] == '\r')) {
                p[--len] = '\0';
            }
            snprintf(proc->state_desc, sizeof(proc->state_desc), "%s", p);
        } else if (sscanf(line, "VmSize: %llu kB", &val) == 1) {
            proc->vm_size_kb = val;
        } else if (sscanf(line, "VmRSS: %llu kB", &val) == 1) {
            proc->vm_rss_kb = val;
        } else if (sscanf(line, "VmPeak: %llu kB", &val) == 1) {
            proc->vm_peak_kb = val;
        } else if (sscanf(line, "VmHWM: %llu kB", &val) == 1) {
            proc->vm_hwm_kb = val;
        } else if (strncmp(line, "Threads:", 8) == 0) {
            proc->threads = atoi(line + 8);
        }
    }

    fclose(fp);
    (void) page_size_kb;
    return 0;
}


/*
 * Check whether a given PID belongs to our Custom Nginx binary via /proc/<pid>/exe.
 */
static int
is_matching_nginx_binary(pid_t pid, const char *target_bin)
{
    char    exe_link[RES_MAX_PATH_LEN];
    char    resolved[RES_MAX_PATH_LEN];
    ssize_t len;

    snprintf(exe_link, sizeof(exe_link), "/proc/%d/exe", (int) pid);
    len = readlink(exe_link, resolved, sizeof(resolved) - 1);
    if (len <= 0) {
        return 0;
    }
    resolved[len] = '\0';

    char *del_suffix = strstr(resolved, " (deleted)");
    if (del_suffix != NULL) {
        *del_suffix = '\0';
    }

    return (strcmp(resolved, target_bin) == 0);
}


/*
 * Comparator to place Master Process first, followed by Workers sorted by PID.
 */
static int
compare_procs_role_pid(const void *a, const void *b)
{
    const nginx_proc_resource_t *pa = (const nginx_proc_resource_t *) a;
    const nginx_proc_resource_t *pb = (const nginx_proc_resource_t *) b;

    if (pa->role != pb->role) {
        if (pa->role == RES_ROLE_MASTER) return -1;
        if (pb->role == RES_ROLE_MASTER) return 1;
    }
    return (int) (pa->pid - pb->pid);
}


/*
 * Sleep for `ms` milliseconds using nanosleep(), resuming if interrupted by signal.
 */
static void
sleep_milliseconds(int ms)
{
    struct timespec req, rem;

    if (ms <= 0) {
        return;
    }

    req.tv_sec = ms / 1000;
    req.tv_nsec = (long) (ms % 1000) * 1000000L;

    while (nanosleep(&req, &rem) == -1 && errno == EINTR) {
        req = rem;
    }
}


/*
 * Collect a two-point CPU & RAM telemetry snapshot for Custom Nginx.
 *
 * Step 1 (Sample t1):
 *   - Read /proc/stat aggregate CPU jiffies (sys_cpu_t1).
 *   - Scan /proc for all Custom Nginx processes and record (utime_t1, stime_t1).
 * Step 2 (Sampling Interval):
 *   - Sleep for `sample_interval_ms` milliseconds.
 * Step 3 (Sample t2):
 *   - Read /proc/stat aggregate CPU jiffies (sys_cpu_t2).
 *   - Read /proc/uptime and /proc/meminfo.
 *   - Re-scan /proc for active Custom Nginx processes, read (utime_t2, stime_t2)
 *     and memory metrics (VmRSS, VmSize, VmPeak, VmHWM), and compute CPU% delta.
 */
int
collect_nginx_resource_metrics(custom_nginx_resource_report_t *report,
                               const char *project_root,
                               const char *target_bin,
                               int sample_interval_ms)
{
    DIR                    *proc_dir;
    struct dirent          *entry;
    nginx_proc_resource_t   t1_procs[RES_MAX_PROCS];
    int                     t1_count = 0;
    nginx_proc_resource_t   t2_candidates[RES_MAX_PROCS];
    int                     t2_cand_count = 0;
    int                     i, j;
    struct timespec         ts_start, ts_end;
    double                  elapsed_sec;

    memset(report, 0, sizeof(*report));

    if (realpath(project_root, report->project_root) == NULL) {
        snprintf(report->project_root, sizeof(report->project_root), "%s", project_root);
    }
    if (realpath(target_bin, report->target_bin) == NULL) {
        snprintf(report->target_bin, sizeof(report->target_bin), "%s", target_bin);
    }

    report->sample_interval_ms = (sample_interval_ms > 0) ? sample_interval_ms : 500;
    report->clk_tck = sysconf(_SC_CLK_TCK);
    if (report->clk_tck <= 0) {
        report->clk_tck = 100;
    }

    report->num_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (report->num_cpus <= 0) {
        report->num_cpus = 1;
    }

    long page_bytes = sysconf(_SC_PAGESIZE);
    report->page_size_kb = (page_bytes > 0) ? (page_bytes / 1024) : 4;

    /* ---------------- SAMPLE T1 ---------------- */
    clock_gettime(CLOCK_MONOTONIC, &ts_start);
    if (read_system_cpu_sample(&report->sys_cpu_t1) != 0) {
        return -1;
    }

    proc_dir = opendir("/proc");
    if (proc_dir == NULL) {
        return -1;
    }

    while ((entry = readdir(proc_dir)) != NULL) {
        if (!isdigit((unsigned char) entry->d_name[0])) {
            continue;
        }
        pid_t pid = (pid_t) atoi(entry->d_name);
        if (pid <= 0 || !is_matching_nginx_binary(pid, report->target_bin)) {
            continue;
        }
        if (t1_count >= RES_MAX_PROCS) {
            break;
        }

        nginx_proc_resource_t *p1 = &t1_procs[t1_count];
        memset(p1, 0, sizeof(*p1));
        p1->pid = pid;

        if (parse_proc_stat_metrics(pid,
                                    &p1->state_char,
                                    &p1->ppid,
                                    &p1->utime_ticks_t1,
                                    &p1->stime_ticks_t1,
                                    &p1->cutime_ticks_t1,
                                    &p1->cstime_ticks_t1,
                                    &p1->threads,
                                    NULL,
                                    NULL) == 0)
        {
            t1_count++;
        }
    }
    closedir(proc_dir);

    /* ---------------- SAMPLING INTERVAL ---------------- */
    sleep_milliseconds(report->sample_interval_ms);

    /* ---------------- SAMPLE T2 ---------------- */
    clock_gettime(CLOCK_MONOTONIC, &ts_end);
    elapsed_sec = (double) (ts_end.tv_sec - ts_start.tv_sec) +
                  (double) (ts_end.tv_nsec - ts_start.tv_nsec) / 1e9;
    if (elapsed_sec <= 0.001) {
        elapsed_sec = (double) report->sample_interval_ms / 1000.0;
    }

    if (read_system_cpu_sample(&report->sys_cpu_t2) != 0) {
        return -1;
    }
    if (read_system_uptime(&report->uptime_seconds, &report->idle_seconds) != 0) {
        return -1;
    }
    if (read_system_meminfo(&report->sys_mem) != 0) {
        return -1;
    }

    if (report->sys_cpu_t2.total_jiffies >= report->sys_cpu_t1.total_jiffies) {
        report->delta_sys_jiffies =
            report->sys_cpu_t2.total_jiffies - report->sys_cpu_t1.total_jiffies;
    } else {
        report->delta_sys_jiffies = 0;
    }

    proc_dir = opendir("/proc");
    if (proc_dir == NULL) {
        return -1;
    }

    while ((entry = readdir(proc_dir)) != NULL) {
        if (!isdigit((unsigned char) entry->d_name[0])) {
            continue;
        }
        pid_t pid = (pid_t) atoi(entry->d_name);
        if (pid <= 0 || !is_matching_nginx_binary(pid, report->target_bin)) {
            continue;
        }
        if (t2_cand_count >= RES_MAX_PROCS) {
            break;
        }

        nginx_proc_resource_t *p2 = &t2_candidates[t2_cand_count];
        memset(p2, 0, sizeof(*p2));
        p2->pid = pid;
        p2->alive_at_t2 = 1;

        unsigned long long vsize_bytes = 0;
        long rss_pages = 0;

        /* If process exited right during read, skip safely */
        if (parse_proc_stat_metrics(pid,
                                    &p2->state_char,
                                    &p2->ppid,
                                    &p2->utime_ticks_t2,
                                    &p2->stime_ticks_t2,
                                    &p2->cutime_ticks_t2,
                                    &p2->cstime_ticks_t2,
                                    &p2->threads,
                                    &vsize_bytes,
                                    &rss_pages) != 0)
        {
            continue;
        }

        if (parse_proc_status_memory(pid, p2, report->page_size_kb) != 0) {
            continue;
        }

        if (read_proc_cmdline(pid, p2->cmdline, sizeof(p2->cmdline)) != 0) {
            continue;
        }

        /* Fallback to stat vsize/rss if status fields were 0 */
        if (p2->vm_size_kb == 0 && vsize_bytes > 0) {
            p2->vm_size_kb = vsize_bytes / 1024ULL;
        }
        if (p2->vm_rss_kb == 0 && rss_pages > 0) {
            p2->vm_rss_kb = (unsigned long long) rss_pages * (unsigned long long) report->page_size_kb;
        }

        if (strstr(p2->cmdline, "master process") != NULL) {
            p2->role = RES_ROLE_MASTER;
        } else if (strstr(p2->cmdline, "worker process") != NULL) {
            p2->role = RES_ROLE_WORKER;
        } else {
            p2->role = RES_ROLE_UNKNOWN;
        }

        t2_cand_count++;
    }
    closedir(proc_dir);

    /* Identify Master Process belonging to our project_root / target_bin */
    report->master_pid = 0;
    for (i = 0; i < t2_cand_count; i++) {
        if (t2_candidates[i].role == RES_ROLE_MASTER) {
            if (strstr(t2_candidates[i].cmdline, report->project_root) != NULL ||
                strstr(t2_candidates[i].cmdline, report->target_bin) != NULL)
            {
                report->master_pid = t2_candidates[i].pid;
                report->nginx_running = 1;
                break;
            }
        }
    }

    if (!report->nginx_running) {
        snprintf(report->nginx_state_summary, sizeof(report->nginx_state_summary), "STOPPED");
        return 0;
    }

    /* Filter processes belonging to this Master instance (Master + its Workers) */
    for (i = 0; i < t2_cand_count; i++) {
        nginx_proc_resource_t *cand = &t2_candidates[i];
        if (cand->pid == report->master_pid ||
            cand->ppid == report->master_pid ||
            cand->role == RES_ROLE_WORKER)
        {
            /* Match against t1 snapshot by PID to compute CPU time delta */
            cand->utime_ticks_t1 = cand->utime_ticks_t2;
            cand->stime_ticks_t1 = cand->stime_ticks_t2;
            for (j = 0; j < t1_count; j++) {
                if (t1_procs[j].pid == cand->pid) {
                    cand->utime_ticks_t1 = t1_procs[j].utime_ticks_t1;
                    cand->stime_ticks_t1 = t1_procs[j].stime_ticks_t1;
                    cand->cutime_ticks_t1 = t1_procs[j].cutime_ticks_t1;
                    cand->cstime_ticks_t1 = t1_procs[j].cstime_ticks_t1;
                    break;
                }
            }

            cand->delta_utime_ticks = (cand->utime_ticks_t2 >= cand->utime_ticks_t1)
                                      ? (cand->utime_ticks_t2 - cand->utime_ticks_t1) : 0;
            cand->delta_stime_ticks = (cand->stime_ticks_t2 >= cand->stime_ticks_t1)
                                      ? (cand->stime_ticks_t2 - cand->stime_ticks_t1) : 0;
            cand->delta_total_ticks = cand->delta_utime_ticks + cand->delta_stime_ticks;

            /*
             * CPU Usage (%) calculation:
             * When system jiffies delta is positive, normalize against total system
             * CPU jiffies across online cores (matching top/ps where 100% = 1 core):
             *   CPU% = (delta_proc_ticks / delta_sys_jiffies) * num_cpus * 100.0
             * Otherwise fallback to wall-clock elapsed time * CLK_TCK.
             */
            if (report->delta_sys_jiffies > 0) {
                cand->cpu_percent = ((double) cand->delta_total_ticks /
                                     (double) report->delta_sys_jiffies) *
                                    (double) report->num_cpus * 100.0;
            } else {
                double max_ticks = elapsed_sec * (double) report->clk_tck;
                cand->cpu_percent = (max_ticks > 0.0)
                                    ? (((double) cand->delta_total_ticks / max_ticks) * 100.0)
                                    : 0.0;
            }

            if (report->sys_mem.mem_total_kb > 0) {
                cand->mem_percent = ((double) cand->vm_rss_kb /
                                     (double) report->sys_mem.mem_total_kb) * 100.0;
            }

            if (cand->role == RES_ROLE_MASTER) {
                snprintf(report->nginx_state_summary,
                         sizeof(report->nginx_state_summary),
                         "RUNNING (Master: %s)", cand->state_desc);
            } else if (cand->role == RES_ROLE_WORKER) {
                report->worker_count++;
            }

            report->total_utime_ticks += cand->utime_ticks_t2;
            report->total_stime_ticks += cand->stime_ticks_t2;
            report->total_delta_ticks += cand->delta_total_ticks;
            report->total_cpu_percent += cand->cpu_percent;
            report->total_rss_kb      += cand->vm_rss_kb;
            report->total_vsize_kb    += cand->vm_size_kb;

            report->procs[report->process_count++] = *cand;
        }
    }

    if (report->sys_mem.mem_total_kb > 0) {
        report->total_mem_percent = ((double) report->total_rss_kb /
                                     (double) report->sys_mem.mem_total_kb) * 100.0;
    }

    qsort(report->procs, (size_t) report->process_count,
          sizeof(nginx_proc_resource_t), compare_procs_role_pid);

    return 0;
}


/*
 * Format uptime seconds into human-readable string (e.g. "5 hours, 12 minutes, 34 seconds").
 */
static void
format_uptime_human(double uptime_seconds, char *buf, size_t buf_len)
{
    unsigned long long total_sec = (unsigned long long) uptime_seconds;
    unsigned long long days      = total_sec / 86400ULL;
    unsigned long long hours     = (total_sec % 86400ULL) / 3600ULL;
    unsigned long long minutes   = (total_sec % 3600ULL) / 60ULL;
    unsigned long long seconds   = total_sec % 60ULL;

    if (days > 0) {
        snprintf(buf, buf_len, "%llu days, %llu hours, %llu minutes, %llu seconds (%.2f s)",
                 days, hours, minutes, seconds, uptime_seconds);
    } else {
        snprintf(buf, buf_len, "%llu hours, %llu minutes, %llu seconds (%.2f s)",
                 hours, minutes, seconds, uptime_seconds);
    }
}


/*
 * Print the structured Custom Nginx Resource Monitor output.
 */
void
print_resource_monitor_report(const custom_nginx_resource_report_t *report)
{
    char uptime_str[128];
    int  i;

    format_uptime_human(report->uptime_seconds, uptime_str, sizeof(uptime_str));

    printf("======================================================================\n");
    printf("CUSTOM NGINX RESOURCE MONITOR\n");
    printf("======================================================================\n");
    printf("Target Binary      : %s\n", report->target_bin);
    printf("Installation Root  : %s\n", report->project_root);
    printf("Sampling Interval  : %d ms (CLK_TCK=%ld Hz, Online CPUs=%ld)\n\n",
           report->sample_interval_ms, report->clk_tck, report->num_cpus);

    if (!report->nginx_running) {
        printf("Nginx Process State: STOPPED\n");
        printf("CPU Usage: 0.00%%\n");
        printf("RSS Memory: 0.00 MB (0 KB)\n");
        printf("Virtual Memory: 0.00 MB (0 KB)\n");
        printf("Memory Usage: 0.00%%\n");
        printf("Process Count: 0\n");
        printf("Workers: 0\n");
        printf("System Memory: %.2f MB Total / %.2f MB Available\n",
               (double) report->sys_mem.mem_total_kb / 1024.0,
               (double) report->sys_mem.mem_available_kb / 1024.0);
        printf("System Uptime: %s\n", uptime_str);
        printf("======================================================================\n");
        return;
    }

    printf("CPU Usage: %.2f%%\n", report->total_cpu_percent);
    printf("RSS Memory: %.2f MB (%llu KB)\n",
           (double) report->total_rss_kb / 1024.0,
           report->total_rss_kb);
    printf("Virtual Memory: %.2f MB (%llu KB)\n",
           (double) report->total_vsize_kb / 1024.0,
           report->total_vsize_kb);
    printf("Memory Usage: %.2f%%\n", report->total_mem_percent);
    printf("System Memory: %.2f MB Total / %.2f MB Available (%.2f MB Free)\n",
           (double) report->sys_mem.mem_total_kb / 1024.0,
           (double) report->sys_mem.mem_available_kb / 1024.0,
           (double) report->sys_mem.mem_free_kb / 1024.0);
    printf("Process Count: %d (1 Master + %d Workers)\n",
           report->process_count, report->worker_count);
    printf("Workers: %d\n", report->worker_count);
    printf("Nginx Process State: %s\n", report->nginx_state_summary);
    printf("System Uptime: %s\n", uptime_str);

    printf("\n----------------------------------------------------------------------\n");
    printf("CPU TIME & SAMPLING TELEMETRY (/proc/stat & /proc/<PID>/stat)\n");
    printf("----------------------------------------------------------------------\n");
    printf("System CPU Jiffies (t1 -> t2) : %llu -> %llu (Delta = %llu jiffies)\n",
           report->sys_cpu_t1.total_jiffies,
           report->sys_cpu_t2.total_jiffies,
           report->delta_sys_jiffies);
    printf("Nginx Total User Time (utime) : %llu ticks (%.2f s cumulative)\n",
           report->total_utime_ticks,
           (double) report->total_utime_ticks / (double) report->clk_tck);
    printf("Nginx Total Sys Time (stime)  : %llu ticks (%.2f s cumulative)\n",
           report->total_stime_ticks,
           (double) report->total_stime_ticks / (double) report->clk_tck);
    printf("Nginx Sample Delta Ticks      : %llu ticks over %d ms\n",
           report->total_delta_ticks,
           report->sample_interval_ms);

    printf("\n----------------------------------------------------------------------\n");
    printf("PER-PROCESS RESOURCE BREAKDOWN (Master & Workers)\n");
    printf("----------------------------------------------------------------------\n");
    printf("%-8s %-8s %-6s %-10s %-10s %-8s %-8s %-12s %-12s %-8s\n",
           "PID", "ROLE", "STATE", "UTIME(tk)", "STIME(tk)", "dTICKS",
           "CPU(%)", "RSS(KB)", "VSIZE(KB)", "MEM(%)");
    printf("----------------------------------------------------------------------\n");

    for (i = 0; i < report->process_count; i++) {
        const nginx_proc_resource_t *p = &report->procs[i];
        const char *role_str = (p->role == RES_ROLE_MASTER) ? "MASTER" :
                               (p->role == RES_ROLE_WORKER) ? "WORKER" : "OTHER";

        printf("%-8d %-8s %-6c %-10llu %-10llu %-8llu %-8.2f %-12llu %-12llu %-8.2f\n",
               (int) p->pid,
               role_str,
               p->state_char,
               p->utime_ticks_t2,
               p->stime_ticks_t2,
               p->delta_total_ticks,
               p->cpu_percent,
               p->vm_rss_kb,
               p->vm_size_kb,
               p->mem_percent);
    }
    printf("======================================================================\n");
}


static void
print_usage(const char *prog)
{
    printf("Usage: %s [-i interval_ms] [project_root] [target_bin]\n", prog);
}


int
main(int argc, char **argv)
{
    custom_nginx_resource_report_t  report;
    const char                     *project_root = "/home/truongphuoc/Desktop/custom-nginx-project";
    char                            target_bin[RES_MAX_PATH_LEN];
    int                             interval_ms = 500;
    int                             opt;

    target_bin[0] = '\0';

    while ((opt = getopt(argc, argv, "i:h")) != -1) {
        switch (opt) {
        case 'i':
            interval_ms = atoi(optarg);
            if (interval_ms < 50 || interval_ms > 10000) {
                fprintf(stderr, "[ERROR] Sampling interval must be between 50 and 10000 ms.\n");
                return 1;
            }
            break;
        case 'h':
            print_usage(argv[0]);
            return 0;
        default:
            print_usage(argv[0]);
            return 1;
        }
    }

    if (optind < argc) {
        project_root = argv[optind++];
    }
    if (optind < argc) {
        snprintf(target_bin, sizeof(target_bin), "%s", argv[optind++]);
    } else {
        snprintf(target_bin, sizeof(target_bin),
                 "%s/build/custom/sbin/nginx", project_root);
    }

    if (collect_nginx_resource_metrics(&report, project_root, target_bin, interval_ms) != 0) {
        fprintf(stderr, "[ERROR] Failed to read Linux /proc resource metrics.\n");
        return 1;
    }

    print_resource_monitor_report(&report);
    return 0;
}
