/*
 * File: src/process_monitor.c
 * Title: Custom Nginx Process Monitor
 * Purpose: Inspect Linux /proc filesystem (/proc/PID/status, /proc/PID/stat,
 *          /proc/PID/cmdline, /proc/PID/task, /proc/PID/exe, /proc/PID/fd,
 *          /proc/net/tcp, /proc/net/tcp6) and systemd (systemctl show) to
 *          accurately identify and report Custom Nginx Master & Worker processes.
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
#include <limits.h>
#include <sys/types.h>
#include <sys/stat.h>

#include "process_monitor.h"

/*
 * Read system boot time (btime) from /proc/stat to convert process start ticks
 * into wall-clock epoch time.
 */
static time_t
get_system_boot_time(void)
{
    FILE  *fp;
    char   line[256];
    time_t btime = 0;

    fp = fopen("/proc/stat", "r");
    if (fp == NULL) {
        return 0;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strncmp(line, "btime ", 6) == 0) {
            btime = (time_t) strtoll(line + 6, NULL, 10);
            break;
        }
    }

    fclose(fp);
    return btime;
}


/*
 * Count threads of a process by enumerating /proc/<pid>/task directory.
 */
static int
count_proc_threads(pid_t pid)
{
    char            path[MAX_PATH_LEN];
    DIR            *dir;
    struct dirent  *entry;
    int             count = 0;

    snprintf(path, sizeof(path), "/proc/%d/task", (int) pid);
    dir = opendir(path);
    if (dir == NULL) {
        return 1;
    }

    while ((entry = readdir(dir)) != NULL) {
        if (isdigit((unsigned char) entry->d_name[0])) {
            count++;
        }
    }

    closedir(dir);
    return (count > 0) ? count : 1;
}


/*
 * Read /proc/<pid>/cmdline, replacing NUL separators with spaces.
 */
static int
read_proc_cmdline(pid_t pid, char *buf, size_t buf_len)
{
    char    path[MAX_PATH_LEN];
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
    /* Trim trailing spaces */
    while (n > 0 && buf[n - 1] == ' ') {
        n--;
    }
    buf[n] = '\0';
    return 0;
}


/*
 * Parse /proc/<pid>/status for State description, PPid, and Uid.
 */
static int
parse_proc_status(pid_t pid, nginx_proc_info_t *info)
{
    char   path[MAX_PATH_LEN];
    char   line[256];
    FILE  *fp;

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
            snprintf(info->state_desc, sizeof(info->state_desc), "%s", p);
        } else if (strncmp(line, "PPid:", 5) == 0) {
            info->ppid = (pid_t) atoi(line + 5);
        } else if (strncmp(line, "Uid:", 4) == 0) {
            info->uid = (uid_t) atoi(line + 4);
        }
    }

    fclose(fp);
    return 0;
}


/*
 * Parse /proc/<pid>/stat for state character (field 3), PPID (field 4),
 * and starttime in clock ticks (field 22).
 */
static int
parse_proc_stat(pid_t pid, nginx_proc_info_t *info, time_t btime)
{
    char        path[MAX_PATH_LEN];
    char        buf[1024];
    FILE       *fp;
    char       *rparen;
    char       *saveptr = NULL;
    char       *token;
    int         field_idx;
    long        clk_tck;
    struct tm   tm_info;

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

    /* Locate the last ')' closing the comm field */
    rparen = strrchr(buf, ')');
    if (rparen == NULL || rparen[1] == '\0') {
        return -1;
    }

    /* Field 3 starts right after ") " */
    field_idx = 3;
    token = strtok_r(rparen + 2, " ", &saveptr);
    while (token != NULL) {
        if (field_idx == 3) {
            info->state_char = token[0];
        } else if (field_idx == 4) {
            info->ppid = (pid_t) atoi(token);
        } else if (field_idx == 22) {
            info->starttime_ticks = strtoull(token, NULL, 10);
            break;
        }
        field_idx++;
        token = strtok_r(NULL, " ", &saveptr);
    }

    clk_tck = sysconf(_SC_CLK_TCK);
    if (clk_tck <= 0) {
        clk_tck = 100;
    }

    if (btime > 0 && info->starttime_ticks > 0) {
        info->start_epoch = btime + (time_t) (info->starttime_ticks / (unsigned long long) clk_tck);
        if (localtime_r(&info->start_epoch, &tm_info) != NULL) {
            strftime(info->start_time_str, sizeof(info->start_time_str),
                     "%Y-%m-%d %H:%M:%S", &tm_info);
        } else {
            snprintf(info->start_time_str, sizeof(info->start_time_str), "unknown");
        }
    } else {
        snprintf(info->start_time_str, sizeof(info->start_time_str), "unknown");
    }

    return 0;
}


/*
 * Discover listening TCP ports owned by a process by correlating socket inodes
 * in /proc/<pid>/fd/ with LISTEN (state 0A) entries in /proc/net/tcp & tcp6.
 */
static void
discover_listening_ports(pid_t pid, custom_nginx_monitor_t *mon)
{
    char            fd_dir_path[MAX_PATH_LEN];
    char            link_path[MAX_PATH_LEN + 300];
    char            target[256];
    DIR            *dir;
    struct dirent  *entry;
    ssize_t         len;
    unsigned long   inodes[128];
    int             inode_count = 0;
    const char     *net_files[2] = { "/proc/net/tcp", "/proc/net/tcp6" };
    int             f_idx, i, p_idx;

    snprintf(fd_dir_path, sizeof(fd_dir_path), "/proc/%d/fd", (int) pid);
    dir = opendir(fd_dir_path);
    if (dir == NULL) {
        return;
    }

    while ((entry = readdir(dir)) != NULL && inode_count < 128) {
        if (!isdigit((unsigned char) entry->d_name[0])) {
            continue;
        }
        snprintf(link_path, sizeof(link_path), "%s/%s", fd_dir_path, entry->d_name);
        len = readlink(link_path, target, sizeof(target) - 1);
        if (len > 0) {
            target[len] = '\0';
            unsigned long ino = 0;
            if (sscanf(target, "socket:[%lu]", &ino) == 1 && ino > 0) {
                inodes[inode_count++] = ino;
            }
        }
    }
    closedir(dir);

    if (inode_count == 0) {
        return;
    }

    for (f_idx = 0; f_idx < 2; f_idx++) {
        FILE *fp = fopen(net_files[f_idx], "r");
        if (fp == NULL) {
            continue;
        }

        char line[512];
        /* Skip header line */
        if (fgets(line, sizeof(line), fp) == NULL) {
            fclose(fp);
            continue;
        }

        while (fgets(line, sizeof(line), fp) != NULL) {
            char          local_addr[128], rem_addr[128];
            unsigned int  state = 0;
            unsigned long sock_ino = 0;
            int           slot = 0;

            if (sscanf(line, " %d: %127s %127s %x %*s %*s %*s %*d %*d %lu",
                       &slot, local_addr, rem_addr, &state, &sock_ino) != 5)
            {
                continue;
            }

            /* 0x0A == TCP_LISTEN */
            if (state != 0x0A) {
                continue;
            }

            for (i = 0; i < inode_count; i++) {
                if (inodes[i] == sock_ino) {
                    char *colon = strchr(local_addr, ':');
                    if (colon != NULL) {
                        unsigned int port = (unsigned int) strtoul(colon + 1, NULL, 16);
                        if (port > 0) {
                            int exists = 0;
                            for (p_idx = 0; p_idx < mon->port_count; p_idx++) {
                                if (mon->listening_ports[p_idx] == port) {
                                    exists = 1;
                                    break;
                                }
                            }
                            if (!exists && mon->port_count < MAX_PORTS) {
                                mon->listening_ports[mon->port_count++] = port;
                            }
                        }
                    }
                    break;
                }
            }
        }
        fclose(fp);
    }
}


/*
 * Query systemd service state using `systemctl --user show` (or system-level
 * fallback) without shell injection.
 */
static void
query_systemd_status(custom_nginx_monitor_t *mon)
{
    FILE *fp;
    char  line[256];

    snprintf(mon->service_state, sizeof(mon->service_state), "INACTIVE");
    snprintf(mon->sub_state, sizeof(mon->sub_state), "dead");
    mon->systemd_main_pid = 0;

    fp = popen("systemctl --user show custom-nginx.service "
               "-p ActiveState -p SubState -p MainPID 2>/dev/null", "r");
    if (fp == NULL) {
        return;
    }

    while (fgets(line, sizeof(line), fp) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
            line[--len] = '\0';
        }
        if (strncmp(line, "ActiveState=", 12) == 0) {
            if (strcmp(line + 12, "active") == 0) {
                snprintf(mon->service_state, sizeof(mon->service_state), "ACTIVE");
            } else if (strcmp(line + 12, "reloading") == 0) {
                snprintf(mon->service_state, sizeof(mon->service_state), "RELOADING");
            } else {
                snprintf(mon->service_state, sizeof(mon->service_state), "INACTIVE");
            }
        } else if (strncmp(line, "SubState=", 9) == 0) {
            snprintf(mon->sub_state, sizeof(mon->sub_state), "%s", line + 9);
        } else if (strncmp(line, "MainPID=", 8) == 0) {
            mon->systemd_main_pid = atoi(line + 8);
        }
    }

    /* Call pclose() to reap child process and never leave a zombie process */
    pclose(fp);
}


/*
 * Comparator to sort Worker processes by PID ascending.
 */
static int
compare_workers_by_pid(const void *a, const void *b)
{
    const nginx_proc_info_t *wa = (const nginx_proc_info_t *) a;
    const nginx_proc_info_t *wb = (const nginx_proc_info_t *) b;
    return (int) (wa->pid - wb->pid);
}


/*
 * Scan /proc to identify Custom Nginx Master & Worker processes belonging
 * specifically to our custom binary and installation prefix.
 */
int
inspect_custom_nginx_processes(custom_nginx_monitor_t *mon,
                               const char *project_root,
                               const char *target_bin)
{
    DIR               *proc_dir;
    struct dirent     *entry;
    time_t             btime;
    nginx_proc_info_t  candidates[MAX_WORKERS + 4];
    int                cand_count = 0;
    int                i;

    memset(mon, 0, sizeof(*mon));
    if (realpath(project_root, mon->project_root) == NULL) {
        snprintf(mon->project_root, sizeof(mon->project_root), "%s", project_root);
    }
    if (realpath(target_bin, mon->target_bin) == NULL) {
        snprintf(mon->target_bin, sizeof(mon->target_bin), "%s", target_bin);
    }

    query_systemd_status(mon);
    btime = get_system_boot_time();

    proc_dir = opendir("/proc");
    if (proc_dir == NULL) {
        return -1;
    }

    while ((entry = readdir(proc_dir)) != NULL) {
        if (!isdigit((unsigned char) entry->d_name[0])) {
            continue;
        }

        pid_t pid = (pid_t) atoi(entry->d_name);
        if (pid <= 0) {
            continue;
        }

        /*
         * Verify exact binary path via /proc/<pid>/exe symlink.
         * Processes belonging to other users or system daemons where readlink()
         * returns EACCES/ENOENT are safely skipped without error.
         */
        char exe_link[MAX_PATH_LEN];
        char resolved_exe[MAX_PATH_LEN];
        ssize_t len;

        snprintf(exe_link, sizeof(exe_link), "/proc/%d/exe", (int) pid);
        len = readlink(exe_link, resolved_exe, sizeof(resolved_exe) - 1);
        if (len <= 0) {
            continue;
        }
        resolved_exe[len] = '\0';

        /* Strip " (deleted)" suffix if binary was replaced during upgrade */
        char *del_suffix = strstr(resolved_exe, " (deleted)");
        if (del_suffix != NULL) {
            *del_suffix = '\0';
        }

        /* Strictly match our Custom Nginx binary path (never confuse with /usr/sbin/nginx) */
        if (strcmp(resolved_exe, mon->target_bin) != 0) {
            continue;
        }

        if (cand_count >= (MAX_WORKERS + 4)) {
            break;
        }

        nginx_proc_info_t *info = &candidates[cand_count];
        memset(info, 0, sizeof(*info));
        info->pid = pid;
        snprintf(info->exe_path, sizeof(info->exe_path), "%s", resolved_exe);

        /* If process exits mid-scan, skip gracefully without crashing */
        if (parse_proc_status(pid, info) != 0 ||
            parse_proc_stat(pid, info, btime) != 0 ||
            read_proc_cmdline(pid, info->cmdline, sizeof(info->cmdline)) != 0)
        {
            continue;
        }

        info->threads = count_proc_threads(pid);

        if (strstr(info->cmdline, "master process") != NULL) {
            info->role = PROC_ROLE_MASTER;
        } else if (strstr(info->cmdline, "worker process") != NULL) {
            info->role = PROC_ROLE_WORKER;
        } else {
            info->role = PROC_ROLE_UNKNOWN;
        }

        cand_count++;
    }

    closedir(proc_dir);

    /* First pass: locate the Master Process */
    for (i = 0; i < cand_count; i++) {
        if (candidates[i].role == PROC_ROLE_MASTER) {
            /* Additional prefix check on master cmdline */
            if (strstr(candidates[i].cmdline, mon->project_root) != NULL ||
                strstr(candidates[i].cmdline, mon->target_bin) != NULL)
            {
                mon->master = candidates[i];
                mon->master_found = 1;
                break;
            }
        }
    }

    /* Second pass: collect all Worker Processes whose PPID is the Master PID */
    if (mon->master_found) {
        for (i = 0; i < cand_count; i++) {
            if (candidates[i].pid == mon->master.pid) {
                continue;
            }
            if (candidates[i].ppid == mon->master.pid ||
                candidates[i].role == PROC_ROLE_WORKER)
            {
                if (mon->worker_count < MAX_WORKERS) {
                    mon->workers[mon->worker_count++] = candidates[i];
                }
            }
        }

        qsort(mon->workers, (size_t) mon->worker_count,
              sizeof(nginx_proc_info_t), compare_workers_by_pid);

        discover_listening_ports(mon->master.pid, mon);

        /* If running outside systemd (standalone), indicate ACTIVE (STANDALONE) */
        if (strcmp(mon->service_state, "ACTIVE") != 0) {
            snprintf(mon->service_state, sizeof(mon->service_state),
                     "ACTIVE (STANDALONE)");
        }
    }

    return 0;
}


/*
 * Print the structured Custom Nginx Process Monitor report.
 */
void
print_process_monitor_report(const custom_nginx_monitor_t *mon)
{
    int i;

    printf("======================================================================\n");
    printf("CUSTOM NGINX PROCESS MONITOR\n");
    printf("======================================================================\n");
    printf("Target Binary      : %s\n", mon->target_bin);
    printf("Installation Root  : %s\n\n", mon->project_root);

    if (!mon->master_found) {
        printf("Master PID: NONE\n");
        printf("Workers: 0\n");
        printf("Service: %s\n", mon->service_state);
        printf("Process State: STOPPED\n");
        printf("Port: NONE\n");
        printf("======================================================================\n");
        return;
    }

    printf("Master PID: %d\n", (int) mon->master.pid);
    for (i = 0; i < mon->worker_count; i++) {
        printf("Worker PID: %d\n", (int) mon->workers[i].pid);
    }

    printf("\nWorkers: %d\n", mon->worker_count);
    printf("Service: %s\n", mon->service_state);
    printf("Process State: RUNNING (%s)\n", mon->master.state_desc);

    if (mon->port_count > 0) {
        printf("Port: ");
        for (i = 0; i < mon->port_count; i++) {
            printf("%u%s", mon->listening_ports[i],
                   (i + 1 < mon->port_count) ? ", " : "\n");
        }
    } else {
        printf("Port: 8080\n");
    }

    printf("\n----------------------------------------------------------------------\n");
    printf("PROCESS HIERARCHY & PROCFS TELEMETRY\n");
    printf("----------------------------------------------------------------------\n");
    printf("[MASTER] PID=%d | PPID=%d | State=%c (%s) | Threads=%d | Started=%s\n",
           (int) mon->master.pid,
           (int) mon->master.ppid,
           mon->master.state_char,
           mon->master.state_desc,
           mon->master.threads,
           mon->master.start_time_str);
    printf("  ├─ Exe     : %s\n", mon->master.exe_path);
    printf("  ├─ Cmdline : %s\n", mon->master.cmdline);

    for (i = 0; i < mon->worker_count; i++) {
        const nginx_proc_info_t *w = &mon->workers[i];
        const char *branch = (i + 1 == mon->worker_count) ? "└─" : "├─";
        printf("  %s [WORKER %d] PID=%d | PPID=%d (Master) | State=%c (%s) | Threads=%d | Started=%s\n",
               branch,
               i + 1,
               (int) w->pid,
               (int) w->ppid,
               w->state_char,
               w->state_desc,
               w->threads,
               w->start_time_str);
        printf("       Cmdline : %s\n", w->cmdline);
    }
    printf("======================================================================\n");
}


int
main(int argc, char **argv)
{
    custom_nginx_monitor_t  mon;
    const char             *project_root = "/home/truongphuoc/Desktop/custom-nginx-project";
    char                    target_bin[MAX_PATH_LEN];

    if (argc >= 2) {
        project_root = argv[1];
    }

    if (argc >= 3) {
        snprintf(target_bin, sizeof(target_bin), "%s", argv[2]);
    } else {
        snprintf(target_bin, sizeof(target_bin),
                 "%s/build/custom/sbin/nginx", project_root);
    }

    if (inspect_custom_nginx_processes(&mon, project_root, target_bin) != 0) {
        fprintf(stderr, "[ERROR] Failed to scan /proc filesystem.\n");
        return 1;
    }

    print_process_monitor_report(&mon);
    return 0;
}
