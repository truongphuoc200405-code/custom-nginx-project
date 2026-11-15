/*
 * File: src/ab_bench.c
 * Title: High-Performance Epoll HTTP Benchmark Tool (ApacheBench CLI compatible)
 * Purpose: Measure real HTTP throughput (Requests/sec), latency distribution,
 *          and error rate against local Original Nginx and Custom Nginx servers
 *          when system apache2-utils (/usr/bin/ab) is not installed.
 * Usage:   ab [-n requests] [-c concurrency] [-k] http://127.0.0.1:8080/path
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define MAX_CONCURRENCY 512
#define RECV_BUF_SIZE   8192

typedef enum {
    CONN_IDLE = 0,
    CONN_CONNECTING,
    CONN_SENDING,
    CONN_RECEIVING
} conn_state_t;

typedef struct {
    int             fd;
    conn_state_t    state;
    size_t          write_offset;
    size_t          bytes_received;
    int             status_parsed;
    int             http_status;
    struct timespec req_start;
} bench_conn_t;

static int
set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) {
        return -1;
    }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int
compare_double(const void *a, const void *b)
{
    double da = *(const double *) a;
    double db = *(const double *) b;
    return (da > db) - (da < db);
}

static int
parse_url(const char *url, char *host, size_t host_len, int *port, char *path, size_t path_len)
{
    const char *p = url;
    if (strncmp(p, "http://", 7) == 0) {
        p += 7;
    } else {
        return -1;
    }

    const char *slash = strchr(p, '/');
    const char *colon = strchr(p, ':');

    if (colon != NULL && (slash == NULL || colon < slash)) {
        size_t hlen = (size_t) (colon - p);
        if (hlen == 0 || hlen >= host_len) return -1;
        memcpy(host, p, hlen);
        host[hlen] = '\0';
        *port = atoi(colon + 1);
    } else {
        size_t hlen = (slash != NULL) ? (size_t) (slash - p) : strlen(p);
        if (hlen == 0 || hlen >= host_len) return -1;
        memcpy(host, p, hlen);
        host[hlen] = '\0';
        *port = 80;
    }

    if (slash != NULL) {
        snprintf(path, path_len, "%s", slash);
    } else {
        snprintf(path, path_len, "/");
    }

    return (*port > 0 && *port <= 65535) ? 0 : -1;
}

static int
start_connection(int epfd, bench_conn_t *c, const struct sockaddr_in *srv_addr)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    int flag = 1;
    (void) setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

    if (set_nonblocking(fd) < 0) {
        close(fd);
        return -1;
    }

    clock_gettime(CLOCK_MONOTONIC, &c->req_start);
    int rc = connect(fd, (const struct sockaddr *) srv_addr, sizeof(*srv_addr));
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }

    c->fd = fd;
    c->state = (rc == 0) ? CONN_SENDING : CONN_CONNECTING;
    c->write_offset = 0;
    c->bytes_received = 0;
    c->status_parsed = 0;
    c->http_status = 0;

    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP;
    ev.data.ptr = c;

    if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev) < 0) {
        close(fd);
        c->fd = -1;
        c->state = CONN_IDLE;
        return -1;
    }

    return 0;
}

int
main(int argc, char **argv)
{
    int     total_requests = 1000;
    int     concurrency = 10;
    int     keep_alive = 0;
    int     opt;
    char    host[128];
    int     port = 8080;
    char    path[512];
    char    req_buf[1024];
    size_t  req_len;

    while ((opt = getopt(argc, argv, "n:c:kh")) != -1) {
        switch (opt) {
        case 'n':
            total_requests = atoi(optarg);
            break;
        case 'c':
            concurrency = atoi(optarg);
            break;
        case 'k':
            keep_alive = 1;
            break;
        default:
            fprintf(stderr, "Usage: %s [-n requests] [-c concurrency] [-k] http://host:port/path\n", argv[0]);
            return 1;
        }
    }

    if (optind >= argc || total_requests <= 0 || concurrency <= 0 || concurrency > MAX_CONCURRENCY) {
        fprintf(stderr, "Usage: %s [-n requests] [-c concurrency (1..%d)] [-k] http://host:port/path\n",
                argv[0], MAX_CONCURRENCY);
        return 1;
    }

    if (concurrency > total_requests) {
        concurrency = total_requests;
    }

    if (parse_url(argv[optind], host, sizeof(host), &port, path, sizeof(path)) != 0) {
        fprintf(stderr, "[ERROR] Invalid URL: %s\n", argv[optind]);
        return 1;
    }

    struct sockaddr_in srv_addr;
    memset(&srv_addr, 0, sizeof(srv_addr));
    srv_addr.sin_family = AF_INET;
    srv_addr.sin_port = htons((uint16_t) port);
    if (inet_pton(AF_INET, host, &srv_addr.sin_addr) <= 0) {
        fprintf(stderr, "[ERROR] Invalid IPv4 address: %s\n", host);
        return 1;
    }

    req_len = (size_t) snprintf(req_buf, sizeof(req_buf),
                                "GET %s HTTP/1.0\r\n"
                                "Host: %s:%d\r\n"
                                "User-Agent: ApacheBench/2.3-epoll\r\n"
                                "Accept: */*\r\n"
                                "Connection: %s\r\n\r\n",
                                path, host, port,
                                keep_alive ? "Keep-Alive" : "close");

    double *latencies_ms = calloc((size_t) total_requests, sizeof(double));
    if (latencies_ms == NULL) {
        return 1;
    }

    int epfd = epoll_create1(0);
    if (epfd < 0) {
        free(latencies_ms);
        return 1;
    }

    bench_conn_t conns[MAX_CONCURRENCY];
    memset(conns, 0, sizeof(conns));

    int started = 0;
    int completed = 0;
    int failed = 0;
    int non_2xx = 0;
    unsigned long long total_bytes = 0;
    char server_header[128] = "Unknown";

    struct timespec bench_start, bench_end;
    clock_gettime(CLOCK_MONOTONIC, &bench_start);

    for (int i = 0; i < concurrency && started < total_requests; i++) {
        conns[i].fd = -1;
        if (start_connection(epfd, &conns[i], &srv_addr) == 0) {
            started++;
        } else {
            failed++;
            started++;
            completed++;
        }
    }

    struct epoll_event events[MAX_CONCURRENCY];
    char recv_buf[RECV_BUF_SIZE];

    while (completed < total_requests) {
        int nfds = epoll_wait(epfd, events, concurrency, 5000);
        if (nfds < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (nfds == 0) {
            /* Timeout */
            failed += (total_requests - completed);
            break;
        }

        for (int i = 0; i < nfds; i++) {
            bench_conn_t *c = (bench_conn_t *) events[i].data.ptr;
            uint32_t ev = events[i].events;

            if (c->state == CONN_CONNECTING && (ev & (EPOLLOUT | EPOLLERR | EPOLLHUP))) {
                int err = 0;
                socklen_t elen = sizeof(err);
                if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &err, &elen) < 0 || err != 0) {
                    epoll_ctl(epfd, EPOLL_CTL_DEL, c->fd, NULL);
                    close(c->fd);
                    c->fd = -1;
                    c->state = CONN_IDLE;
                    failed++;
                    completed++;
                    goto next_slot;
                }
                c->state = CONN_SENDING;
            }

            if (c->state == CONN_SENDING && (ev & EPOLLOUT)) {
                ssize_t n = send(c->fd, req_buf + c->write_offset,
                                 req_len - c->write_offset, MSG_NOSIGNAL);
                if (n > 0) {
                    c->write_offset += (size_t) n;
                    if (c->write_offset >= req_len) {
                        c->state = CONN_RECEIVING;
                    }
                } else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                    epoll_ctl(epfd, EPOLL_CTL_DEL, c->fd, NULL);
                    close(c->fd);
                    c->fd = -1;
                    c->state = CONN_IDLE;
                    failed++;
                    completed++;
                    goto next_slot;
                }
            }

            if (c->state == CONN_RECEIVING && (ev & (EPOLLIN | EPOLLHUP | EPOLLERR))) {
                for (;;) {
                    ssize_t n = recv(c->fd, recv_buf, sizeof(recv_buf) - 1, 0);
                    if (n > 0) {
                        recv_buf[n] = '\0';
                        if (!c->status_parsed) {
                            int code = 0;
                            if (sscanf(recv_buf, "HTTP/%*d.%*d %d", &code) == 1) {
                                c->http_status = code;
                                c->status_parsed = 1;
                            }
                            if (strcmp(server_header, "Unknown") == 0) {
                                char *sh = strcasestr(recv_buf, "\r\nServer:");
                                if (sh != NULL) {
                                    sh += 9;
                                    while (*sh == ' ') sh++;
                                    char *eol = strpbrk(sh, "\r\n");
                                    if (eol != NULL) {
                                        size_t slen = (size_t) (eol - sh);
                                        if (slen >= sizeof(server_header)) slen = sizeof(server_header) - 1;
                                        memcpy(server_header, sh, slen);
                                        server_header[slen] = '\0';
                                    }
                                }
                            }
                        }
                        c->bytes_received += (size_t) n;
                        total_bytes += (unsigned long long) n;
                    } else if (n == 0) {
                        /* EOF: response complete */
                        struct timespec req_end;
                        clock_gettime(CLOCK_MONOTONIC, &req_end);
                        double lat_ms = (double) (req_end.tv_sec - c->req_start.tv_sec) * 1000.0 +
                                        (double) (req_end.tv_nsec - c->req_start.tv_nsec) / 1e6;
                        if (completed < total_requests) {
                            latencies_ms[completed] = lat_ms;
                        }
                        if (c->bytes_received == 0 || c->http_status == 0) {
                            failed++;
                        } else if (c->http_status < 200 || c->http_status >= 300) {
                            non_2xx++;
                        }
                        epoll_ctl(epfd, EPOLL_CTL_DEL, c->fd, NULL);
                        close(c->fd);
                        c->fd = -1;
                        c->state = CONN_IDLE;
                        completed++;
                        break;
                    } else {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            break;
                        }
                        epoll_ctl(epfd, EPOLL_CTL_DEL, c->fd, NULL);
                        close(c->fd);
                        c->fd = -1;
                        c->state = CONN_IDLE;
                        failed++;
                        completed++;
                        break;
                    }
                }
            }

        next_slot:
            if (c->state == CONN_IDLE && started < total_requests) {
                if (start_connection(epfd, c, &srv_addr) == 0) {
                    started++;
                } else {
                    failed++;
                    started++;
                    completed++;
                }
            }
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &bench_end);
    close(epfd);

    double total_time_sec = (double) (bench_end.tv_sec - bench_start.tv_sec) +
                            (double) (bench_end.tv_nsec - bench_start.tv_nsec) / 1e9;
    if (total_time_sec <= 0.0001) {
        total_time_sec = 0.0001;
    }

    double rps = (double) completed / total_time_sec;
    double sum_lat = 0.0;
    for (int i = 0; i < completed; i++) {
        sum_lat += latencies_ms[i];
    }
    double avg_lat_ms = (completed > 0) ? (sum_lat / (double) completed) : 0.0;
    double mean_across_all_ms = (total_time_sec * 1000.0) / (double) (completed > 0 ? completed : 1);

    qsort(latencies_ms, (size_t) completed, sizeof(double), compare_double);

    printf("This is ApacheBench-compatible HTTP Benchmark (epoll C engine)\n\n");
    printf("Server Software:        %s\n", server_header);
    printf("Server Hostname:        %s\n", host);
    printf("Server Port:            %d\n\n", port);
    printf("Document Path:          %s\n", path);
    printf("Concurrency Level:      %d\n", concurrency);
    printf("Time taken for tests:   %.4f seconds\n", total_time_sec);
    printf("Complete requests:      %d\n", completed);
    printf("Failed requests:        %d\n", failed);
    if (non_2xx > 0) {
        printf("Non-2xx responses:      %d\n", non_2xx);
    }
    printf("Total transferred:      %llu bytes\n", total_bytes);
    printf("Requests per second:    %.2f [#/sec] (mean)\n", rps);
    printf("Time per request:       %.3f [ms] (mean)\n", avg_lat_ms);
    printf("Time per request:       %.3f [ms] (mean, across all concurrent requests)\n", mean_across_all_ms);
    printf("Transfer rate:          %.2f [Kbytes/sec] received\n\n",
           ((double) total_bytes / 1024.0) / total_time_sec);

    if (completed > 0) {
        printf("Percentage of the requests served within a certain time (ms)\n");
        int pcts[] = { 50, 66, 75, 80, 90, 95, 98, 99, 100 };
        for (size_t p = 0; p < sizeof(pcts) / sizeof(pcts[0]); p++) {
            int idx = (completed * pcts[p]) / 100;
            if (idx >= completed) idx = completed - 1;
            if (idx < 0) idx = 0;
            printf("  %3d%%  %7.3f ms%s\n",
                   pcts[p], latencies_ms[idx],
                   (pcts[p] == 100) ? " (longest request)" : "");
        }
    }

    free(latencies_ms);
    return 0;
}
