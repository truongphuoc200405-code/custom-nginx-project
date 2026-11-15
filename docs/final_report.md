# BÁO CÁO TỔNG KẾT ĐỒ ÁN MÔN HỌC: LINUX VÀ PHẦN MỀM MÃ NGUỒN MỞ
## Đề tài: Tùy biến và Xây dựng lại Máy chủ Web Nginx với Module Bảo mật, Giám sát và Tích hợp Hệ thống Linux trên Ubuntu

---

## Chương 1. Introduction (Giới thiệu Đề tài)

### 1.1. Bối cảnh và Lý do chọn đề tài
Trong hạ tầng dịch vụ trực tuyến hiện đại, máy chủ web đóng vai trò là lớp biên đầu tiên tiếp nhận lưu lượng từ người dùng. Việc hiểu sâu mã nguồn C của một máy chủ web mã nguồn mở hàng đầu như **Nginx**, tự tay tùy biến nhân xử lý HTTP, viết các module mở rộng ở tầng C sử dụng bộ nhớ chia sẻ (*Shared Memory*), và tích hợp chặt chẽ với nhân hệ điều hành **Linux** (`procfs`, POSIX Signals, `systemd`) là minh chứng rõ nét nhất cho kỹ năng lập trình hệ thống Linux (*Linux System Programming*) và phát triển phần mềm mã nguồn mở (*Open-Source Software Engineering*).

### 1.2. Mục tiêu Đồ án
Đồ án thực hiện trọn vẹn chu trình kỹ thuật phần mềm hệ thống trên **Ubuntu Linux**:
1. Tải về, xác thực chữ ký mật mã và phân tích mã nguồn C chính thức của **Nginx 1.26.2**.
2. Tùy biến trực tiếp mã nguồn C của Nginx để thay thế nhận diện máy chủ thành `CustomWebServer` và loại bỏ rò rỉ phiên bản.
3. Thiết kế và lập trình **Custom HTTP Security Module** (`ngx_http_custom_security_module`) bằng C hỗ trợ giới hạn tốc độ truy cập theo IP (IPv4/IPv6) xuyên suốt nhiều Worker.
4. Thiết kế và lập trình **Custom HTTP Monitoring Module** (`ngx_http_custom_monitoring_module`) bằng C xuất số liệu thời gian thực dưới dạng JSON tại `/custom_status`.
5. Xây dựng hệ thống biên dịch tự động hóa bằng **GCC, GNU Make và Bash** với prefix cài đặt cô lập.
6. Tích hợp dịch vụ với **systemd**, nghiên cứu cơ chế xử lý tín hiệu POSIX, và lập trình hai công cụ C giám sát tiến trình & tài nguyên CPU/RAM trực tiếp từ `/proc`.
7. Kiểm thử tự động toàn diện và đánh giá hiệu năng (**Benchmark**) đối chiếu giữa Original Nginx và Custom Nginx.

---

## Chương 2. Open-Source Software (Phần mềm Mã nguồn mở & Quy trình Làm việc)

### 2.1. Giấy phép và Mô hình Phát triển của Nginx
Nginx Open Source được phát hành theo giấy phép **2-Clause BSD License**, cho phép nghiên cứu, sửa đổi mã nguồn, tích hợp các module tùy biến và phân phối lại bản thực thi khi giữ nguyên thông báo bản quyền.

### 2.2. Xác thực Tính toàn vẹn Nguồn mở (Supply-Chain Verification)
Mã nguồn chính thức `nginx-1.26.2.tar.gz` được tải từ `https://nginx.org/download/nginx-1.26.2.tar.gz` và được xác thực hai lớp trong [scripts/download_nginx.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/download_nginx.sh):
- **SHA-256 Checksum**: `627fe086209bba80a2853a0add9d958d7ebbdffa1a8467a5784c9a6b4f03d738`.
- **Chữ ký số PGP**: Xác thực tệp `nginx-1.26.2.tar.gz.asc` bằng khóa công khai chính thức của nhà phát triển Nginx (`Sergey Kandaurov`, RSA key `4100846782B9A168`).
- **Quản lý Bản vá (Patch Management)**: Duy trì cây mã nguồn nguyên bản tại `source/nginx-original/` và cây làm việc tại `source/nginx/`, quản lý thay đổi bằng chuẩn Unified Diff (`diff -uN`) trong [patches/custom_server_header.patch](file:///home/truongphuoc/Desktop/custom-nginx-project/patches/custom_server_header.patch).

---

## Chương 3. Nginx Architecture (Kiến trúc Mã nguồn Nginx)

Phân tích chi tiết tại [docs/nginx_source_analysis.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/nginx_source_analysis.md) và [docs/nginx_module_architecture.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/nginx_module_architecture.md):

1. **Tổ chức Thư mục Mã nguồn**:
   - `src/core/`: Khởi tạo `main()`, vòng lặp `ngx_cycle_t`, quản lý bộ nhớ vùng (`ngx_pool_t`), bộ cấp phát trang (`ngx_slab_pool_t`), cấu trúc dữ liệu (`ngx_rbtree_t`, `ngx_queue_t`, `ngx_array_t`).
   - `src/event/`: Bộ분 phối sự kiện bất đồng bộ (`ngx_epoll_module.c` trên Linux sử dụng `epoll_create1`, `epoll_ctl`, `epoll_wait`).
   - `src/os/unix/`: Quản lý tiến trình Master/Worker (`ngx_process.c`, `ngx_process_cycle.c`), vùng nhớ chia sẻ (`ngx_shmem.c` dùng `mmap(MAP_ANON|MAP_SHARED)`), tín hiệu POSIX và socketpair IPC (`ngx_channel.c`).
   - `src/http/`: Máy trạng thái HTTP/1.1, chuỗi xử lý 11 pha (`ngx_http_phases`) và chuỗi bộ lọc đầu ra (`ngx_http_top_header_filter`, `ngx_http_top_body_filter`).
2. **Mô hình Đa tiến trình Hướng sự kiện (Master–Worker + Non-blocking Epoll)**:
   - **Master Process**: Đọc và kiểm tra cấu hình, mở các socket lắng nghe (`listen 8080`), khởi tạo các vùng nhớ chia sẻ (`ngx_shm_zone_t`), sinh (`fork()`) các tiến trình Worker và giám sát vòng đời của chúng qua tín hiệu.
   - **Worker Processes**: Các tiến trình đơn luồng độc lập chạy vòng lặp sự kiện `epoll_wait()` không khóa (*non-blocking I/O*), chia sẻ trạng thái chung thông qua bộ nhớ chia sẻ `mmap` và các nguyên mẫu đồng bộ hóa (`ngx_atomic_t`, `ngx_shmtx_t`).

---

## Chương 4. Source Code Customization (Tùy biến Trực tiếp Mã nguồn C)

Chi tiết kỹ thuật tại [docs/custom_server_header.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/custom_server_header.md):

1. **Vị trí Mã nguồn C xử lý Server Header**:
   - Trong [src/http/ngx_http_header_filter_module.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_header_filter_module.c#L49-L51), hàm `ngx_http_header_filter(ngx_http_request_t *r)` sử dụng các mảng tĩnh `ngx_http_server_string[]` và `ngx_http_server_full_string[]` khi `r->headers_out.server == NULL`.
   - Trong [src/http/ngx_http_special_response.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_special_response.c#L21-L39), các mảng `ngx_http_error_full_tail[]` và `ngx_http_error_tail[]` định nghĩa phần chân trang HTML của các mã lỗi HTTP (`403`, `404`, `429`, `500`).
2. **Nội dung Bản vá ([patches/custom_server_header.patch](file:///home/truongphuoc/Desktop/custom-nginx-project/patches/custom_server_header.patch))**:
   - Thay thế cả `ngx_http_server_string` và `ngx_http_server_full_string` thành `"Server: CustomWebServer" CRLF`.
   - Thay thế chân trang lỗi thành `"<hr><center>CustomWebServer</center>" CRLF "</body>" CRLF "</html>" CRLF`.
   - Đảm bảo không tiết lộ chuỗi `nginx` hay phiên bản `1.26.2` dù `server_tokens` bật hay tắt, đồng thời giữ nguyên cấu trúc giao thức HTTP/1.1 và chuỗi filter.

---

## Chương 5. Custom Security Module (`ngx_http_custom_security_module`)

Chi tiết kỹ thuật tại [docs/custom_security_module.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/custom_security_module.md) và mã nguồn [modules/security/ngx_http_custom_security_module.c](file:///home/truongphuoc/Desktop/custom-nginx-project/modules/security/ngx_http_custom_security_module.c):

1. **Kiến trúc và Điểm móc (Phase Hook)**:
   - Đăng ký hàm `ngx_http_custom_security_handler()` vào pha `NGX_HTTP_PREACCESS_PHASE`.
   - Kiểm tra `if (r != r->main || r->internal) return NGX_DECLINED;` để tránh đếm kép khi Nginx thực hiện chuyển hướng nội bộ (`/` $\to$ `/index.html`).
2. **Định danh IP thực (IPv4 & IPv6) chống Spoofing**:
   - Trích xuất trực tiếp địa chỉ nhị phân từ `r->connection->sockaddr` (`4 byte` `sin_addr` cho `AF_INET`, `16 byte` `sin6_addr` cho `AF_INET6`), bỏ qua hoàn toàn header `X-Forwarded-For` không đáng tin cậy từ phía client.
3. **Cấu trúc Dữ liệu Shared Memory (`custom_security_shm_zone` – 2 MB)**:
   - Kết hợp **Cây Đỏ-Đen (`ngx_rbtree_t`)** để tìm kiếm nút IP trong thời gian $O(\log N)$ theo khóa băm `ngx_crc32_short()` và **Hàng đợi LRU (`ngx_queue_t`)** để tự động thu hồi các nút IP hết hạn bằng `ngx_slab_free_locked()`, ngăn chặn rò rỉ bộ nhớ (*memory leak*) hoặc cạn kiệt vùng nhớ slab.
   - Đồng bộ hóa đa tiến trình Worker bằng khóa mutex/spinlock `ngx_shmtx_lock(&mcf->shpool->mutex)`.
4. **Hành vi Bảo mật**:
   - Đính kèm header `X-RateLimit-Limit: <limit>` vào phản hồi.
   - Khi số request trong cửa sổ `custom_security_window` vượt quá `custom_security_limit`, trả về `NGX_HTTP_TOO_MANY_REQUESTS` (`HTTP 429`) và ghi sự kiện `[CUSTOM_SECURITY] RATE_LIMIT_EXCEEDED` kèm IP, URI, số lần vi phạm và `worker_pid`.

---

## Chương 6. Custom Monitoring Module (`ngx_http_custom_monitoring_module`)

Chi tiết kỹ thuật tại [docs/custom_monitoring_module.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/custom_monitoring_module.md) và mã nguồn [modules/monitoring/ngx_http_custom_monitoring_module.c](file:///home/truongphuoc/Desktop/custom-nginx-project/modules/monitoring/ngx_http_custom_monitoring_module.c):

1. **Cơ chế Thu thập Số liệu Không khóa (Lock-Free Atomic Accounting)**:
   - Sử dụng vùng nhớ chia sẻ `custom_monitoring_shm_zone` (`256 KB`) chứa các biến nguyên tử `ngx_atomic_t`: `total_requests`, `successful_requests`, `client_errors`, `server_errors`, `blocked_requests` và mốc thời gian khởi chạy `start_time`.
   - Đăng ký `ngx_http_custom_monitoring_log_handler()` vào pha `NGX_HTTP_LOG_PHASE` để cập nhật các bộ đếm bằng chỉ thị CPU nguyên tử `ngx_atomic_fetch_add()` ở cuối mỗi request thực tế mà không gây tranh chấp khóa.
   - Đọc số kết nối đang hoạt động trực tiếp từ biến nguyên tử toàn cục `*ngx_stat_active` của Nginx.
2. **Endpoint `/custom_status` và Kiểm soát Truy cập (Access Control)**:
   - Content handler `ngx_http_custom_monitoring_status_handler()` kiểm tra địa chỉ IP socket của client qua hàm `ngx_http_custom_monitoring_check_access()`: chỉ cho phép `localhost` (`127.0.0.0/8`, `::1`, `::ffff:127.0.0.1`) hoặc các dải mạng quản trị được khai báo trong `custom_status_allow <IP/CIDR>;`. Các truy cập trái phép bị từ chối với `HTTP 403 Forbidden` và ghi cảnh báo `[CUSTOM_MONITORING] ACCESS_DENIED`.

---

## Chương 7. Linux Build System (Hệ thống Tự động hóa Build với GCC & GNU Make)

Chi tiết kỹ thuật tại [docs/build_pipeline.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/build_pipeline.md):

1. **Kiến trúc Các Script Tự động hóa (`scripts/`)**:
   - [scripts/download_nginx.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/download_nginx.sh): Tải nguồn, kiểm tra SHA-256 & PGP, giải nén bảo toàn `source/nginx-original/`.
   - [scripts/apply_patches.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/apply_patches.sh): Kiểm tra `patch --dry-run` để áp dụng bản vá một cách *idempotent* (không vá trùng lặp).
   - [scripts/configure_nginx.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/configure_nginx.sh): Cấu hình Nginx với `--prefix=/home/truongphuoc/Desktop/custom-nginx-project/build/custom`, tích hợp `--add-module=.../modules/security` và `--add-module=.../modules/monitoring`.
   - [scripts/build_nginx.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/build_nginx.sh) & [scripts/install_nginx.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/install_nginx.sh): Biên dịch song song (`make -j$(nproc)`) và cài đặt vào prefix cô lập không cần `sudo`.
   - [scripts/build_all.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/build_all.sh): Điều phối 13 giai đoạn khép kín, kiểm tra bảng ký hiệu ELF (`nm`), kiểm tra `nginx -t` và xác minh phản hồi HTTP thực tế, ghi nhật ký đầy đủ vào `logs/build.log`.
2. **Chuẩn Biên dịch C**:
   - Toàn bộ mã C tùy biến (`ngx_http_custom_security_module.c`, `ngx_http_custom_monitoring_module.c`, `process_monitor.c`, `resource_monitor.c`, `ab_bench.c`) đều vượt qua kiểm tra nghiêm ngặt `gcc -Wall -Wextra -Wpedantic -Werror` với **0 lỗi và 0 cảnh báo**.

---

## Chương 8. Linux Process Management & systemd Integration (Quản lý Tiến trình & Dịch vụ)

Chi tiết kỹ thuật tại [docs/systemd_integration.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/systemd_integration.md) và [docs/linux_process_monitoring.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/linux_process_monitoring.md):

1. **Tích hợp systemd ([systemd/custom-nginx.service](file:///home/truongphuoc/Desktop/custom-nginx-project/systemd/custom-nginx.service))**:
   - Thiết lập `Type=forking`, `PIDFile=.../logs/nginx.pid`, `ExecStartPre=.../nginx -t`, `ExecStart`, `ExecReload=/bin/kill -s HUP $MAINPID`, `ExecStop=/bin/kill -s QUIT $MAINPID`, `Restart=on-failure`, cùng các chỉ thị tăng cường bảo mật (`NoNewPrivileges=true`, `LockPersonality=true`, `RestrictRealtime=true`, `UMask=0027`).
   - Vận hành qua `systemctl --user` hoàn toàn độc lập với `/lib/systemd/system/nginx.service`.
2. **Công cụ C Giám sát Tiến trình ([src/process_monitor.c](file:///home/truongphuoc/Desktop/custom-nginx-project/src/process_monitor.c))**:
   - Quét trực tiếp `/proc/<PID>/exe` (qua `readlink()`) để định danh chính xác tiến trình thuộc `build/custom/sbin/nginx`.
   - Đọc `/proc/<PID>/status`, `/proc/<PID>/stat`, `/proc/<PID>/cmdline`, `/proc/<PID>/task`, đối chiếu inode socket trong `/proc/<PID>/fd/` với bảng `/proc/net/tcp` và `/proc/net/tcp6` (trạng thái `0x0A = TCP_LISTEN`) để phát hiện cổng `8080` mà không cần quyền root hay công cụ ngoài.

---

## Chương 9. Linux Signal Handling (Xử lý Tín hiệu POSIX & Graceful Reload)

Chi tiết kỹ thuật tại [docs/linux_signal_handling.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/linux_signal_handling.md) và script kiểm thử [scripts/test_signal_handling.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/test_signal_handling.sh):

1. **Cơ chế Async-Signal-Safe trong Nginx**:
   - Hàm `ngx_signal_handler()` chỉ đặt các cờ nguyên tử `sig_atomic_t` (`ngx_reconfigure`, `ngx_reopen`, `ngx_quit`, `ngx_terminate`, `ngx_change_binary`); vòng lặp `ngx_master_process_cycle()` thức dậy từ `sigsuspend()` và điều phối Worker qua kênh IPC socketpair (`ngx_channel`).
2. **Quy trình Graceful Reload An toàn & Tự động Rollback**:
   - Sao lưu `config/nginx.conf`, kiểm tra cú pháp bằng `nginx -t` trước khi gửi `SIGHUP`. Nếu `nginx -t` thất bại, chặn lệnh `SIGHUP` và khôi phục bản sao lưu ngay lập tức, đảm bảo tiến trình Master và các Worker hiện tại không bị gián đoạn.

---

## Chương 10. Linux Resource Monitoring (Giám sát Tài nguyên CPU/RAM qua `/proc`)

Chi tiết kỹ thuật tại [docs/linux_resource_monitoring.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/linux_resource_monitoring.md) và mã nguồn [src/resource_monitor.c](file:///home/truongphuoc/Desktop/custom-nginx-project/src/resource_monitor.c):

1. **Lấy mẫu Hai thời điểm (Two-Point Sampling) cho CPU Usage**:
   - Đọc `utime` (trường 14) và `stime` (trường 15) từ `/proc/<PID>/stat` của Master và từng Worker cùng tổng jiffies từ `/proc/stat` tại hai thời điểm $t_1$ và $t_2$ cách nhau $\Delta t$, tính chính xác tốc độ tiêu thụ CPU:
     $$\text{CPU}_p(\%) = \frac{\Delta \text{utime}_p + \Delta \text{stime}_p}{\Delta T_{\text{sys}}} \times N_{\text{cpus}} \times 100\%$$
2. **Đo lường Bộ nhớ (`VmRSS` vs `VmSize`) và Hệ thống**:
   - Đọc `VmRSS` (RAM vật lý thực tế) và `VmSize` (không gian địa chỉ ảo bao gồm cả các vùng nhớ chia sẻ `mmap`) từ `/proc/<PID>/status`, đối chiếu với `MemTotal` và `MemAvailable` trong `/proc/meminfo` và thời gian hoạt động hệ thống từ `/proc/uptime`.

---

## Chương 11. Testing and Benchmark (Kiểm thử Tích hợp & Đánh giá Hiệu năng)

### 11.1. Kết quả Kiểm thử Tổng thể ([tests/run_all_tests.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/tests/run_all_tests.sh))
Toàn bộ **10/10 bộ kiểm thử** (bao gồm 36 phép kiểm chứng chi tiết) đều đạt **PASS (100%)**:

| ID | Hạng mục Kiểm thử | Trạng thái | Kết quả Kiểm chứng Thực tế |
| :--- | :--- | :--- | :--- |
| `01` | **Environment Test** | **PASS** | Ubuntu 20.04.4 LTS, Kernel 5.15.0-139, GCC 9.4.0, Make 4.2.1, systemd 245 |
| `02` | **Build & Binary Test** | **PASS** | Binary `build/custom/sbin/nginx` (5.27 MB), đầy đủ ký hiệu ELF & `nginx -t` OK |
| `03` | **HTTP Functionality Test** | **PASS** | `GET /index.html` trả về `HTTP/1.1 200 OK` và đúng nội dung HTML |
| `04` | **Server Header Test** | **PASS** | `Server: CustomWebServer` trên cả `200` và `404`, không lộ phiên bản Nginx |
| `05` | **Security Module Test** | **PASS** | `7/7 PASS`: Giới hạn `20 req/1s`, chặn request thứ 21+ với `HTTP 429`, chống spoof `X-Forwarded-For` |
| `06` | **Monitoring Module Test** | **PASS** | `5/5 PASS`: JSON hợp lệ tại `/custom_status`, đếm chính xác `200`/`404`/`429`, chặn IP lạ với `403` |
| `07` | **Process Monitoring Test** | **PASS** | `5/5 PASS`: Phát hiện đúng Master/Worker PID, PPID, trạng thái `RUNNING`/`STOPPED`, cổng `8080` |
| `08` | **Resource Monitoring Test** | **PASS** | `6/6 PASS`: Tính đúng CPU% dưới tải, `VmRSS`, `VmSize`, mở rộng 4 Workers, xử lý lỗi |
| `09` | **Signal Handling Test** | **PASS** | `7/7 PASS`: `SIGHUP` zero-downtime reload, rollback cấu hình lỗi, `SIGUSR1` mở lại log, `SIGQUIT`, `SIGTERM` |
| `10` | **systemd Service Test** | **PASS** | Vòng đời `start`, `status`, `reload`, `stop`, `restart` qua `systemctl --user` hoạt động hoàn hảo |

### 11.2. Kết quả Benchmark: Original Nginx vs Custom Nginx ([docs/benchmark_report.md](file:///home/truongphuoc/Desktop/custom-nginx-project/docs/benchmark_report.md))
Đo kiểm thực tế với `5,000 requests`, `concurrency = 50`:
- **Original Nginx (`1.26.2`)**: Đạt **`33,837.25 req/sec`**, độ trễ trung bình **`1.466 ms`**, tỷ lệ lỗi **`0.00%`**, CPU **`19.18%`**, RSS **`3.27 MB`** (`3,352 KB`), Virtual Memory **`12.41 MB`** (`12,708 KB`).
- **Custom Nginx (`CustomWebServer` + Security + Monitoring)**: Đạt **`25,112.52 req/sec`**, độ trễ trung bình **`1.980 ms`** (chỉ tăng `+0.514 ms`), tỷ lệ lỗi **`0.00%`**, CPU **`27.40%`**, RSS **`3.07 MB`** (`3,148 KB`), Virtual Memory **`19.18 MB`** (`19,644 KB` do ánh xạ thêm `2.25 MB` vùng nhớ chia sẻ trên mỗi tiến trình).
- **Endpoint `/custom_status` (`2,000 requests, c = 25`)**: Đạt **`21,836.57 req/sec`**, độ trễ trung bình **`1.135 ms`**, tỷ lệ lỗi **`0.00%`**.

---

## Chương 12. Conclusion (Kết luận và Hướng Phát triển)

### 12.1. Kết quả Đạt được
Dự án đã hoàn thành toàn bộ các mục tiêu đề ra với chất lượng kỹ thuật cao:
- Tùy biến thành công nhân Nginx `1.26.2` ở cấp độ mã nguồn C và tạo bản vá chuẩn mở.
- Xây dựng 2 module C (`ngx_http_custom_security_module` và `ngx_http_custom_monitoring_module`) hoạt động ổn định trong môi trường đa tiến trình Worker với tốc độ trên **25,000 requests/giây** và độ trễ dưới **2 ms**.
- Tích hợp trọn vẹn với hệ sinh thái Linux trên Ubuntu (`systemd`, POSIX Signals, `/proc` Process Monitor & Resource Monitor bằng C).

### 12.2. Hướng Phát triển Tiếp theo
- Bổ sung thuật toán *Token Bucket* hoặc *Sliding Window Log* bên cạnh *Fixed Window Counter* trong `ngx_http_custom_security_module`.
- Xuất thêm định dạng Prometheus metrics (`/metrics`) song song với JSON tại `/custom_status`.
- Tích hợp eBPF (`XDP` / `tc`) để phối hợp chặn sớm các địa chỉ IP vi phạm nặng ngay tại tầng mạng của nhân Linux.
