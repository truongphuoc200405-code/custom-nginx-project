# KỊCH BẢN & NỘI DUNG LÀM SLIDE THUYẾT TRÌNH ĐỒ ÁN (DÀNH CHO 2 NGƯỜI)
**Môn học:** Linux và Phần mềm Mã nguồn mở  
**Đề tài:** Tùy biến và Xây dựng lại Máy chủ Web Nginx với Module Bảo mật, Giám sát và Tích hợp Hệ thống Linux trên Ubuntu  
**Repository:** `https://github.com/truongphuoc200405-code/custom-nginx-project`

---

## PHÂN CHIA PHẦN THUYẾT TRÌNH CHO 2 NGƯỜI (CÂN ĐỐI 50% – 50%)

| Người thuyết trình | Vai trò chuyên môn | Phụ trách các Slide | Nội dung chính |
| :--- | :--- | :---: | :--- |
| **NGƯỜI 1** | **Kiến trúc Mã nguồn Mở, Lập trình C Module Nginx & Bảo mật** | **Slide 1 $\to$ Slide 8** | Giới thiệu đề tài, Kiến trúc Nginx Open Source `1.26.2`, Tùy biến mã nguồn C (`Server: CustomWebServer`), Thiết kế **Custom Security Module** (Rate Limit, RBTree + LRU Shared Memory) và **Custom Monitoring Module** (`/custom_status` JSON). |
| **NGƯỜI 2** | **Lập trình Hệ thống Linux (`procfs`, Signals, `systemd`), Tự động hóa Build, Benchmark & Demo** | **Slide 9 $\to$ Slide 16** | Tự động hóa Build (GCC, GNU Make, Bash), Tích hợp `systemd`, Xử lý tín hiệu POSIX (`SIGHUP`, `SIGUSR1`, `SIGQUIT`), Công cụ C giám sát tiến trình & tài nguyên CPU/RAM qua `/proc`, Kiểm thử `10/10 PASS`, Benchmark và Demo trực tiếp. |

---

# PHẦN I – NỘI DUNG CỦA NGƯỜI 1 (SLIDE 1 $\to$ SLIDE 8)

---

## SLIDE 1: TRANG BÌA (TITLE SLIDE)
### Nội dung đặt lên Slide:
- **ĐỒ ÁN MÔN HỌC: LINUX VÀ PHẦN MỀM MÃ NGUỒN MỞ**
- **Đề tài:** Customize and Rebuild Nginx Web Server with Custom Security, Monitoring and Linux System Integration on Ubuntu
- **Sinh viên thực hiện:**
  1. [Họ và tên Người 1] – MSSV: [...]
  2. [Họ và tên Người 2] – MSSV: [...]
- **Giảng viên hướng dẫn:** [Tên Giảng viên]
- **Môi trường triển khai:** Ubuntu Linux 20.04 LTS • Kernel 5.15 • GCC 9.4.0 • Nginx 1.26.2

### Lời dẫn thuyết trình (Người 1):
> "Xin chào thầy/cô và các bạn. Hôm nay nhóm chúng em gồm [Tên Người 1] và [Tên Người 2] xin trình bày đồ án môn Linux và Phần mềm mã nguồn mở với đề tài: **Tùy biến và Biên dịch lại Máy chủ Web Nginx tích hợp Module Bảo mật, Giám sát và Quản trị Hệ thống Linux trên Ubuntu**. Nhóm sẽ đi từ việc can thiệp trực tiếp vào mã nguồn C của Nginx đến việc lập trình các công cụ hệ thống đọc trực tiếp từ nhân Linux."

---

## SLIDE 2: ĐẶT VẤN ĐỀ & MỤC TIÊU ĐỒ ÁN
### Nội dung đặt lên Slide:
- **Tại sao chọn Nginx Open Source?**
  - Máy chủ web mã nguồn mở phổ biến nhất thế giới (Giấy phép 2-Clause BSD).
  - Kiến trúc hướng sự kiện bất đồng bộ (*Event-Driven, Non-blocking I/O*) viết hoàn toàn bằng ngôn ngữ C.
- **Vấn đề thực tế khi vận hành Web Server mặc định:**
  - Mặc định tiết lộ tên và phiên bản (`Server: nginx/1.26.2`) $\to$ dễ bị dò tìm lỗ hổng (*Banner Grabbing*).
  - Cần cơ chế chống tấn công làm ngập (*Rate Limiting*) và giám sát thời gian thực ngay tại tầng C mà không phụ thuộc phần mềm bên thứ ba.
- **4 Mục tiêu cốt lõi của nhóm:**
  1. **Can thiệp mã nguồn C gốc:** Thay đổi định danh máy chủ thành `CustomWebServer`.
  2. **Phát triển 2 Module C mới:** `ngx_http_custom_security_module` & `ngx_http_custom_monitoring_module`.
  3. **Tích hợp sâu với Linux:** Tự động hóa Build (GCC/Make), quản lý dịch vụ `systemd`, xử lý tín hiệu POSIX.
  4. **Lập trình công cụ C đọc `/proc` (`procfs`):** Theo dõi Master/Worker PID, cổng mạng, `% CPU` và `RAM` (`VmRSS`/`VmSize`).

### Lời dẫn thuyết trình (Người 1):
> "Thay vì chỉ cài đặt và cấu hình Nginx qua apt như thông thường, mục tiêu của đồ án này là làm chủ hoàn toàn một dự án mã nguồn mở lớn bằng ngôn ngữ C: tải mã nguồn chính thức, xác thực chữ ký mật mã, sửa mã C lõi, tự viết thêm 2 module C mới chạy trong không gian tiến trình Worker, và viết các công cụ C giao tiếp trực tiếp với nhân Linux."

---

## SLIDE 3: XÁC THỰC MÃ NGUỒN MỞ & CẤU TRÚC DỰ ÁN
### Nội dung đặt lên Slide:
- **Nguồn mã nguồn chính thức:** `https://nginx.org/download/nginx-1.26.2.tar.gz`
- **Xác thực chuỗi cung ứng phần mềm (Supply-Chain Verification):**
  - Kiểm tra mã băm **SHA-256**: `627fe086209bba80a2853a0add9d958d7ebbdffa1a8467a5784c9a6b4f03d738`
  - Xác thực chữ ký số **PGP (`nginx-1.26.2.tar.gz.asc`)** với khóa công khai RSA của nhà phát triển Nginx.
- **Tổ chức cây thư mục chuẩn hóa:**
  - `source/nginx-original/` (bản gốc đối chiếu) & `source/nginx/` (cây biên dịch).
  - `patches/` (chứa file `.patch` chuẩn Unified Diff).
  - `modules/security/` & `modules/monitoring/` (2 module C tự phát triển).
  - `src/` & `include/` (các chương trình C giám sát Linux `/proc`).
  - `build/original/` & `build/custom/` (cài đặt cô lập, **tuyệt đối không ghi đè `/usr/sbin/nginx` của hệ thống**).

### Lời dẫn thuyết trình (Người 1):
> "Nguyên tắc đầu tiên khi làm việc với phần mềm mã nguồn mở trên Linux là tính toàn vẹn và tính cô lập. Nhóm xác thực gói nguồn bằng SHA-256 và PGP, đồng thời tách biệt hoàn toàn thư mục cài đặt vào `build/custom/` để không ảnh hưởng tới hệ điều hành chủ."

---

## SLIDE 4: KIẾN TRÚC ĐA TIẾN TRÌNH & HƯỚNG SỰ KIỆN CỦA NGINX
### Nội dung đặt lên Slide:
- **Mô hình Tiến trình (Master – Worker Architecture):**
  - **Master Process (`ngx_master_process_cycle`):** Đọc `nginx.conf`, mở socket cổng `8080`, cấp phát vùng nhớ chia sẻ (`mmap`), sinh (`fork()`) các tiến trình con và quản lý tín hiệu.
  - **Worker Processes (`ngx_worker_process_cycle`):** Xử lý trực tiếp HTTP request bằng vòng lặp sự kiện phi đồng bộ **Linux `epoll` (`epoll_wait`)**, không tạo thread mới cho mỗi kết nối.
- **Chuỗi 11 Pha Xử lý HTTP (`ngx_http_phases`) & Vị trí can thiệp của Nhóm:**
  1. `NGX_HTTP_PREACCESS_PHASE` $\to$ **Gắn `ngx_http_custom_security_module` (Chặn sớm IP vi phạm với HTTP 429)**.
  2. `NGX_HTTP_CONTENT_PHASE` $\to$ **Gắn handler `/custom_status` xuất JSON thời gian thực**.
  3. `HTTP Header Filter Chain` $\to$ **Can thiệp đổi `Server: CustomWebServer`**.
  4. `NGX_HTTP_LOG_PHASE` $\to$ **Gắn bộ đếm nguyên tử (`ngx_atomic_fetch_add`) thống kê request**.

### Lời dẫn thuyết trình (Người 1):
> "Trên sơ đồ này là kiến trúc cốt lõi của Nginx trong `src/core/`, `src/event/` và `src/http/`. Nhóm đã phân tích chuỗi 11 pha xử lý HTTP để đặt các module tùy biến vào đúng vị trí tối ưu nhất: module bảo mật đặt ở `PREACCESS_PHASE` để chặn tấn công ngay từ cửa ngõ trước khi đọc đĩa, còn bộ đếm giám sát đặt ở `LOG_PHASE` để ghi nhận chính xác mọi mã trạng thái trả về."

---

## SLIDE 5: TÙY BIẾN MÃ NGUỒN C – ẨN ĐỊNH DANH SERVER HEADER
### Nội dung đặt lên Slide:
- **Phân tích mã nguồn C gốc của Nginx:**
  - File 1: `src/http/ngx_http_header_filter_module.c` (dòng 49–51) định nghĩa `ngx_http_server_string` và `ngx_http_server_full_string`.
  - File 2: `src/http/ngx_http_special_response.c` (dòng 21–39) định nghĩa chân trang HTML khi báo lỗi (`<center>nginx/1.26.2</center>`).
- **Kỹ thuật tùy biến & Tạo bản vá (`patches/custom_server_header.patch`):**
  ```c
  static u_char ngx_http_server_string[] = "Server: CustomWebServer" CRLF;
  static u_char ngx_http_server_full_string[] = "Server: CustomWebServer" CRLF;
  ```
  ```c
  static u_char ngx_http_error_tail[] =
      "<hr><center>CustomWebServer</center>" CRLF
      "</body>" CRLF
      "</html>" CRLF;
  ```
- **Kết quả đạt được:**
  - Mọi phản hồi HTTP (`200`, `403`, `404`, `429`) đều trả về `Server: CustomWebServer`.
  - Không rò rỉ tên hay phiên bản Nginx ở cả HTTP Header lẫn nội dung trang lỗi HTML.

### Lời dẫn thuyết trình (Người 1):
> "Ở bước tùy biến đầu tiên, nhóm đi thẳng vào 2 tệp C trong `src/http/`. Thay vì chỉ tắt `server_tokens` trong cấu hình (vẫn lộ chữ `nginx`), bản vá `custom_server_header.patch` của nhóm thay thế hoàn toàn chuỗi hằng trong bộ lọc header và trang lỗi đặc biệt thành `CustomWebServer`."

---

## SLIDE 6: MODULE C BẢO MẬT (`ngx_http_custom_security_module`) – KIẾN TRÚC & SHARED MEMORY
### Nội dung đặt lên Slide:
- **File mã nguồn:** `modules/security/ngx_http_custom_security_module.c` (681 dòng code C).
- **Các chỉ thị cấu hình tự thiết kế trong `nginx.conf`:**
  ```nginx
  location / {
      custom_security on;
      custom_security_limit 20;
      custom_security_window 1s;
  }
  ```
- **Giải bài toán Đồng bộ hóa Đa Tiến trình Worker (Multi-Worker State):**
  - Tạo vùng nhớ chia sẻ **`custom_security_shm_zone` (2 MB)** qua `ngx_shared_memory_add()`.
  - Cấu trúc dữ liệu kết hợp:
    1. **Cây Đỏ-Đen (`ngx_rbtree_t`):** Tìm kiếm nút IP theo khóa băm CRC32 chỉ tốn thời gian $O(\log N)$.
    2. **Hàng đợi LRU (`ngx_queue_t`):** Tự động giải phóng các IP không còn hoạt động bằng `ngx_slab_free_locked()`, chống rò rỉ bộ nhớ (*No Memory Leak*).
    3. **Khóa Mutex/Spinlock (`ngx_shmtx_lock`):** Chống Race Condition khi nhiều Worker cùng cập nhật bộ đếm của 1 IP.

### Lời dẫn thuyết trình (Người 1):
> "Thách thức lớn nhất khi viết module bảo mật cho Nginx là Nginx chạy nhiều tiến trình Worker độc lập. Nếu lưu biến đếm trong RAM riêng của từng Worker thì kẻ tấn công có thể vượt qua giới hạn khi request rơi vào Worker khác. Vì vậy nhóm sử dụng API `ngx_shm_zone_t` tạo vùng nhớ chia sẻ 2 MB kết hợp Cây Đỏ-Đen và hàng đợi LRU được bảo vệ bởi spinlock `ngx_shmtx_lock`."

---

## SLIDE 7: MODULE C BẢO MẬT – CHỐNG SPOOFING IP & PHẢN HỒI HTTP 429
### Nội dung đặt lên Slide:
- **Trích xuất IP nhị phân từ Socket thật (`r->connection->sockaddr`):**
  - Hỗ trợ cả **IPv4 (`AF_INET` – 4 bytes `sin_addr`)** và **IPv6 (`AF_INET6` – 16 bytes `sin6_addr`)**.
  - **Bỏ qua `X-Forwarded-For` giả mạo:** Kẻ tấn công tự gắn header `X-Forwarded-For: 203.0.113.99` vẫn bị nhận diện đúng theo IP socket thật và bị chặn.
- **Chống đếm kép (Internal Redirect Guard):**
  - Kiểm tra `if (r != r->main || r->internal) return NGX_DECLINED;` để khi Nginx chuyển hướng nội bộ `/` $\to$ `/index.html`, mỗi request từ client chỉ tính đúng 1 lần.
- **Hành động khi vượt ngưỡng (`> 20 req/1s`):**
  - Đính kèm header `X-RateLimit-Limit: 20`.
  - Trả về mã **`HTTP 429 Too Many Requests`**.
  - Ghi nhật ký bảo mật vào `logs/error.log` và `logs/security.log`:
    `[CUSTOM_SECURITY] RATE_LIMIT_EXCEEDED: client=127.0.0.1 method="GET" uri="/" count=21 limit=20 window=1000ms worker_pid=...`

### Lời dẫn thuyết trình (Người 1):
> "Để đảm bảo an toàn tuyệt đối, module không tin cậy header `X-Forwarded-For` do client gửi lên mà đọc trực tiếp cấu trúc `sockaddr` nhị phân từ nhân Linux cho cả IPv4 và IPv6. Ngay khi request thứ 21 đến trong vòng 1 giây, module lập tức trả về HTTP 429 và ghi log cảnh báo kèm PID của Worker xử lý."

---

## SLIDE 8: MODULE C GIÁM SÁT (`ngx_http_custom_monitoring_module`)
### Nội dung đặt lên Slide:
- **File mã nguồn:** `modules/monitoring/ngx_http_custom_monitoring_module.c` (600 dòng code C).
- **Kỹ thuật Đếm Nguyên tử Không khóa (Lock-Free Atomic Operations):**
  - Sử dụng vùng nhớ chia sẻ `custom_monitoring_shm_zone` (`256 KB`).
  - Tại `NGX_HTTP_LOG_PHASE`, cập nhật các bộ đếm bằng chỉ thị nguyên tử của CPU: `ngx_atomic_fetch_add()` $\to$ không gây nghẽn cổ chai ở tốc độ hàng chục nghìn request/giây.
- **Endpoint `/custom_status` & Kiểm soát Truy cập (ACL):**
  - Chỉ cho phép `localhost` (`127.0.0.1`, `::1`) hoặc dải mạng quản trị khai báo qua `custom_status_allow <IP/CIDR>;`.
  - Truy cập trái phép bị chặn với **`HTTP 403 Forbidden`** và ghi log `[CUSTOM_MONITORING] ACCESS_DENIED`.
- **Định dạng JSON trả về thời gian thực:**
  ```json
  {
    "server": "CustomWebServer",
    "status": "running",
    "total_requests": 42,
    "successful_requests": 30,
    "client_errors": 12,
    "server_errors": 0,
    "blocked_requests": 10,
    "active_connections": 1,
    "uptime_seconds": 125
  }
  ```

### Lời dẫn thuyết trình (Người 1 – Chuyển giao sang Người 2):
> "Module thứ hai nhóm phát triển là `ngx_http_custom_monitoring_module`. Khác với module bảo mật cần khóa cây đỏ-đen, module giám sát sử dụng hoàn toàn các phép toán nguyên tử `ngx_atomic_fetch_add` không khóa và đọc trực tiếp biến `*ngx_stat_active` của Nginx để xuất JSON thời gian thực tại `/custom_status`. Tiếp theo, xin mời bạn [Tên Người 2] trình bày về phần Hệ thống Build tự động, Tích hợp Linux và Kết quả thực nghiệm."

---

# PHẦN II – NỘI DUNG CỦA NGƯỜI 2 (SLIDE 9 $\to$ SLIDE 16)

---

## SLIDE 9: HỆ THỐNG BUILD TỰ ĐỘNG HÓA VỚI GCC, GNU MAKE & BASH
### Nội dung đặt lên Slide:
- **Pipeline Tự động hóa 13 Giai đoạn (`scripts/build_all.sh` & `Makefile`):**
  1. `check_environment.sh` (Kiểm tra OS, Kernel, GCC, Make, systemd).
  2. `download_nginx.sh` (Tải & kiểm tra SHA-256, giải nén bảo toàn bản gốc).
  3. `apply_patches.sh` (Kiểm tra `patch --dry-run` chống vá lặp *idempotent*).
  4. `configure_nginx.sh` (`--prefix=.../build/custom` + `--add-module` cho 2 module C).
  5. `build_nginx.sh` & `make monitors` (Biên dịch song song `make -j$(nproc)`).
  6. `install_nginx.sh` (Cài đặt cô lập không cần `sudo`).
  7. Kiểm định nhị phân ELF bằng `nm`, `nginx -V`, `nginx -t` và kiểm thử HTTP sống.
- **Chất lượng Mã nguồn C (Compiler Flags Audit):**
  - Toàn bộ mã C tùy biến đạt **0 lỗi, 0 cảnh báo** với cờ nghiêm ngặt:
    `gcc -Wall -Wextra -Wpedantic -Werror -O2`

### Lời dẫn thuyết trình (Người 2):
> "Cảm ơn [Tên Người 1]. Em xin tiếp tục với phần Tích hợp Hệ thống Linux. Để toàn bộ quá trình từ mã nguồn C ra file thực thi hoàn toàn tự động và tái lập được trên mọi máy Ubuntu, nhóm đã xây dựng bộ 7 script Bash với chế độ an toàn `set -euo pipefail` và `Makefile`. Chỉ với một lệnh `./scripts/build_all.sh`, toàn bộ 13 bước kiểm tra, vá lỗi, biên dịch và kiểm định ký hiệu ELF trong binary hoàn tất chỉ trong 15 giây."

---

## SLIDE 10: TÍCH HỢP DỊCH VỤ SYSTEMD & QUẢN LÝ AN TOÀN
### Nội dung đặt lên Slide:
- **Unit File:** `systemd/custom-nginx.service`
  - Chạy trực tiếp `build/custom/sbin/nginx` (hoàn toàn tách biệt với `/lib/systemd/system/nginx.service`).
  - Cấu hình đầy đủ vòng đời:
    - `ExecStartPre=.../nginx -t` (Kiểm tra cú pháp cấu hình trước khi chạy).
    - `ExecStart=.../nginx -p .../custom-nginx-project -c .../config/nginx.conf`
    - `ExecReload=/bin/kill -s HUP $MAINPID`
    - `ExecStop=/bin/kill -s QUIT $MAINPID`
    - `Restart=on-failure` (`RestartSec=3s`)
  - **Systemd Security Hardening:** `NoNewPrivileges=true`, `LockPersonality=true`, `RestrictRealtime=true`, `UMask=0027`, `LimitNOFILE=65535`.
- **Bộ Script Quản trị Dịch vụ An toàn (`scripts/service_*.sh`):**
  - Kiểm tra xung đột cổng `8080` (`ss -tulpn`) và xác thực `/proc/<PID>/exe` trước khi dừng hoặc xóa PID file.

### Lời dẫn thuyết trình (Người 2):
> "Sau khi biên dịch xong binary Custom Nginx, nhóm tích hợp máy chủ vào hệ thống quản lý dịch vụ `systemd` của Ubuntu. Unit file được thiết kế kèm các chỉ thị tăng cường bảo mật như `NoNewPrivileges=true` và các script quản lý tự động kiểm tra an toàn PID cũng như cổng 8080 trước khi thao tác."

---

## SLIDE 11: CÔNG CỤ C GIÁM SÁT TIẾN TRÌNH LINUX (`src/process_monitor.c`)
### Nội dung đặt lên Slide:
- **Bài toán:** Làm sao phân biệt chính xác tiến trình của Custom Nginx với Nginx hệ thống mà không dùng `ps | grep` dễ nhầm lẫn?
- **Giải pháp Lập trình C trực tiếp trên `/proc` (`procfs`):**
  - Quét thư mục `/proc/<PID>/` và gọi system call `readlink("/proc/<PID>/exe")` để đối chiếu đường dẫn tuyệt đối với `build/custom/sbin/nginx`.
  - Đọc `/proc/<PID>/status` & `/proc/<PID>/stat`: Lấy `PID`, `PPID`, `State` (`S - sleeping`, `R - running`), thời điểm khởi chạy (`btime + starttime / CLK_TCK`).
  - Đọc `/proc/<PID>/cmdline` & `/proc/<PID>/task`: Phân biệt vai trò `MASTER` vs `WORKER` và đếm số luồng.
  - **Phát hiện cổng mạng ở tầng nhân:** Đối chiếu `socket:[inode]` trong `/proc/<PID>/fd/` với bảng `/proc/net/tcp` và `/proc/net/tcp6` (trạng thái `0x0A = TCP_LISTEN`) $\to$ xác định chính xác cổng `8080`.

### Lời dẫn thuyết trình (Người 2):
> "Để giám sát tiến trình ở cấp độ hệ điều hành, nhóm tự viết công cụ `process_monitor` bằng ngôn ngữ C. Thay vì gọi lệnh shell, chương trình đọc trực tiếp hệ thống tệp ảo `/proc` của nhân Linux: dùng `readlink` trên `/proc/PID/exe` để nhận diện chính xác binary Custom Nginx, và tự ánh xạ inode socket trong `/proc/PID/fd` sang bảng `/proc/net/tcp` để tìm ra cổng lắng nghe 8080."

---

## SLIDE 12: XỬ LÝ TÍN HIỆU LINUX (POSIX SIGNALS & ZERO-DOWNTIME RELOAD)
### Nội dung đặt lên Slide:
- **Cơ chế `ngx_signal_handler` trong Nginx (`src/os/unix/ngx_process.c`):**
  - Tuân thủ nguyên tắc **Async-Signal-Safe**: Hàm bắt tín hiệu chỉ bật các cờ nguyên tử `sig_atomic_t`; tiến trình Master thức dậy từ `sigsuspend()` và gửi lệnh qua IPC Socketpair (`ngx_channel`) tới các Worker.
- **Bảng Tín hiệu Đã Kiểm thử Thực nghiệm (`scripts/test_signal_handling.sh` – `7/7 PASS`):**
  - **`SIGHUP` (Graceful Reload):** Master đọc cấu hình mới, `fork()` thế hệ Worker mới, Worker cũ xử lý nốt request đang mở rồi tự thoát (**Zero-downtime**).
  - **Cơ chế Tự động Rollback:** Kiểm tra `nginx -t` trước khi gửi `SIGHUP`. Nếu cấu hình lỗi $\to$ chặn `SIGHUP` và tự động khôi phục bản backup, dịch vụ không bị sập.
  - **`SIGUSR1` (Log Reopening):** Mở lại `access.log` & `error.log` (inode mới) phục vụ Log Rotation mà không cần khởi động lại tiến trình.
  - **`SIGQUIT` (Graceful Shutdown) vs `SIGTERM` (Fast Shutdown):** Dừng an toàn hoặc dừng tức thời, dọn sạch `nginx.pid`.

### Lời dẫn thuyết trình (Người 2):
> "Về quản lý tín hiệu POSIX trên Linux, nhóm đã phân tích mã nguồn `ngx_process_cycle.c` và xây dựng kịch bản kiểm thử tự động 7 tình huống. Đặc biệt là quy trình Graceful Reload với `SIGHUP` kết hợp cơ chế tự động Rollback khi phát hiện cấu hình lỗi qua `nginx -t`, đảm bảo thời gian hoạt động liên tục 100%."

---

## SLIDE 13: CÔNG CỤ C GIÁM SÁT TÀI NGUYÊN CPU & RAM (`src/resource_monitor.c`)
### Nội dung đặt lên Slide:
- **1. Phương pháp Tính `% CPU Usage` bằng Lấy mẫu 2 Thời điểm (Two-Point Sampling):**
  - Trong `/proc/<PID>/stat`, `utime` (trường 14 – User mode) và `stime` (trường 15 – Kernel mode) là **bộ đếm xung nhịp tích lũy** (*jiffies*, $\text{CLK\_TCK} = 100\text{ Hz}$), không phải phần trăm tức thời.
  - Công cụ đọc mẫu tại $t_1$, ngủ `nanosleep(500ms)`, đọc mẫu tại $t_2$ cùng `/proc/stat` và tính:
    $$\text{CPU}_p(\%) = \frac{(\text{utime}_2 - \text{utime}_1) + (\text{stime}_2 - \text{stime}_1)}{T_{\text{sys}}(t_2) - T_{\text{sys}}(t_1)} \times N_{\text{cpus}} \times 100\%$$
- **2. Phân biệt Bộ nhớ Vật lý (`VmRSS`) và Bộ nhớ Ảo (`VmSize`) từ `/proc/<PID>/status`:**
  - **RSS (`VmRSS`):** Dung lượng **RAM vật lý thực tế** đang nạp trên chip nhớ (`~3.1 MB` cho cả cụm 1 Master + 2 Workers).
  - **Virtual Memory (`VmSize`):** Tổng không gian địa chỉ ảo đã ánh xạ (`~19.1 MB`, bao gồm cả vùng nhớ chia sẻ `mmap` `2 MB + 256 KB` của 2 module C và thư viện động).

### Lời dẫn thuyết trình (Người 2):
> "Ở công cụ C thứ hai là `resource_monitor`, nhóm giải quyết bài toán tính chính xác phần trăm CPU và bộ nhớ từ `/proc`. Vì nhân Linux chỉ lưu tổng số xung nhịp CPU cộng dồn từ lúc tiến trình khởi chạy, công cụ thực hiện lấy mẫu tại 2 thời điểm cách nhau 500ms để tính đạo hàm tốc độ tiêu thụ CPU, đồng thời bóc tách rõ sự khác biệt giữa RAM vật lý `VmRSS` và không gian địa chỉ ảo `VmSize`."

---

## SLIDE 14: KẾT QUẢ KIỂM THỬ TỰ ĐỘNG & BENCHMARK HIỆU NĂNG
### Nội dung đặt lên Slide:
- **1. Bộ Kiểm thử Tổng hợp (`./tests/run_all_tests.sh`): Đạt tuyệt đối `10/10 SUITES PASS` (36 phép kiểm chứng)**
  - Environment • Build & ELF Symbols • HTTP 200 • Custom Server Header • Security Rate Limit (429) • Monitoring JSON & ACL (403) • Process Monitor • Resource Monitor • Signal Handling • systemd Lifecycle.
- **2. Kết quả Benchmark Thực tế (`5,000 requests`, `Concurrency = 50` trên `127.0.0.1:8080`):**

| Chỉ số Đo lường (Metric) | Original Nginx (`1.26.2`) | Custom Nginx (`CustomWebServer`) | Đánh giá Kỹ thuật |
| :--- | :---: | :---: | :--- |
| **Requests per second (RPS)** | **`33,837.25 req/s`** | **`25,112.52 req/s`** | Đạt **>25,100 req/s** khi chạy đầy đủ cả 2 module C |
| **Average Latency (Mean)** | **`1.466 ms`** | **`1.980 ms`** | Độ trễ trung bình chỉ tăng **`+0.514 ms`** |
| **CPU Usage (Dưới tải)** | `19.18%` | `27.40%` | Tăng `+8.22%` cho RBTree lookup + Spinlock |
| **Physical RAM (`VmRSS`)** | **`3.27 MB`** (`3,352 KB`) | **`3.07 MB`** (`3,148 KB`) | Cực kỳ tiết kiệm RAM vật lý (`0.08%` hệ thống) |
| **Virtual Memory (`VmSize`)** | `12.41 MB` | `19.18 MB` | Tăng đúng `+2.25 MB/process` cho 2 vùng Shared Memory |
| **Error Rate (Failed TCP)** | **`0.00%`** | **`0.00%`** | Hoạt động ổn định tuyệt đối |

### Lời dẫn thuyết trình (Người 2):
> "Trên bảng là số liệu đo kiểm thực tế giữa bản Nginx 1.26.2 gốc và bản Custom Nginx của nhóm với 5.000 request đồng thời mức 50. Ngay cả khi mỗi request đều đi qua cây đỏ-đen kiểm tra bảo mật và bộ đếm nguyên tử giám sát, Custom Nginx vẫn đạt tốc độ hơn 25.100 request/giây, độ trễ trung bình chỉ chênh lệch nửa mili-giây (1.98 ms so với 1.46 ms) và chỉ chiếm hơn 3 MB RAM vật lý."

---

## SLIDE 15: DEMO TRỰC TIẾP HỆ THỐNG (LIVE DEMONSTRATION)
### Nội dung đặt lên Slide:
- **Kịch bản Demo 2 phút (Phối hợp 2 người):**
  1. **Trên Trình duyệt (`http://127.0.0.1:8080/`):**
     - Quan sát Dashboard tự động cập nhật JSON từ `/custom_status`.
     - Bấm nút **`⚡ Bắn Burst 30 Requests`** $\to$ Quan sát 20 request đầu nhận `HTTP 200 OK`, 10 request sau bị chặn với **`HTTP 429 Too Many Requests`**, bộ đếm **Blocked by Security** tăng ngay lập tức.
     - Bấm nút **`🔍 Test Trang Lỗi 404`** & **`🔒 Test Chặn ACL 403`**.
  2. **Trên Terminal Ubuntu:**
     - Chạy `./build/bin/process_monitor` & `./build/bin/resource_monitor -i 500`.
     - Chạy `make test` (`10/10 PASS`).

### Lời dẫn thuyết trình (Người 2 thao tác máy, Người 1 thuyết minh kết quả trên màn hình):
> "Bây giờ nhóm xin phép demo trực tiếp trên máy ảo Ubuntu. Đầu tiên trên giao diện Dashboard tại cổng 8080, khi chúng em bấm bắn thử 30 request liên tiếp trong chưa đầy 1 giây, thầy/cô có thể thấy 20 request đầu được cho qua và từ request thứ 21 trở đi bị module C chặn ngay với mã HTTP 429. Đồng thời trên Terminal, hai công cụ C `process_monitor` và `resource_monitor` hiển thị trực tiếp cây tiến trình Master–Worker và mức tiêu thụ CPU/RAM từ `/proc`."

---

## SLIDE 16: KẾT LUẬN & HƯỚNG PHÁT TRIỂN
### Nội dung đặt lên Slide:
- **Tổng kết Kết quả Đạt được:**
  - Hoàn thành 100% quy trình tùy biến mã nguồn C, phát triển 2 module HTTP C (`Security` & `Monitoring`) chạy đa tiến trình với Shared Memory.
  - Xây dựng trọn bộ công cụ quản trị hệ thống Linux (`systemd`, POSIX Signals, C `/proc` Process & Resource Monitors, Automated Build Pipeline).
  - Mã nguồn sạch (`-Wall -Wextra -Wpedantic -Werror`), vượt qua 10/10 bộ test tự động.
- **Hướng phát triển tiếp theo:**
  - Nâng cấp thuật toán Rate Limiting sang *Sliding Window Log* / *Token Bucket*.
  - Hỗ trợ xuất chuẩn *Prometheus Metrics* (`/metrics`) song song với JSON.
  - Kết hợp **Linux eBPF / XDP** để chặn gói tin vi phạm ngay tại tầng card mạng trước khi vào TCP stack.
- **Cảm ơn thầy/cô và các bạn đã lắng nghe! Nhóm xin sẵn sàng nhận câu hỏi phản biện.**

---

# PHẦN III – BỘ CÂU HỎI PHẢN BIỆN DỰ KIẾN & CÂU TRẢ LỜI MẪU (Q&A)

Để hai bạn tự tin trả lời ngay khi giảng viên hỏi xoáy vào kỹ thuật:

### Câu hỏi 1 (Dành cho Người 1): *"Tại sao nhóm dùng Shared Memory (`ngx_shm_zone_t`) mà không dùng biến toàn cục (`global variable`) trong C cho Module Security và Monitoring?"*
- **Trả lời:** Vì Nginx sử dụng kiến trúc đa tiến trình (**Multi-process Master–Worker**) chứ không phải đa luồng trong cùng một tiến trình. Sau khi Master gọi `fork()`, mỗi Worker có không gian địa chỉ bộ nhớ riêng biệt (*Copy-on-Write*). Nếu dùng biến toàn cục C thông thường, Worker 1 tăng biến đếm thì Worker 2 không nhìn thấy được. Do đó bắt buộc phải dùng vùng nhớ chia sẻ (`mmap` với cờ `MAP_SHARED`) thông qua API `ngx_shared_memory_add` của Nginx.

### Câu hỏi 2 (Dành cho Người 1): *"Nếu có hàng triệu IP khác nhau gửi request tới thì vùng nhớ chia sẻ 2 MB của Module Security có bị tràn (Memory Leak / Out of Memory) không?"*
- **Trả lời:** Nhóm đã thiết kế hàng đợi **LRU (`Least Recently Used` – `ngx_queue_t`)** song song với Cây Đỏ-Đen. Mỗi khi thêm IP mới, hàm `ngx_http_custom_security_expire()` tự động kiểm tra và thu hồi các nút IP đã hết hạn ở cuối hàng đợi bằng `ngx_slab_free_locked()`. Trong trường hợp bộ nhớ đầy đột ngột, module cưỡng bức thu hồi nút cũ nhất (`force_oldest = 1`), và nếu vẫn không đủ bộ nhớ thì áp dụng cơ chế *fail-open* an toàn (nhả khóa mutex, ghi log `ALERT` và không làm sập tiến trình Worker).

### Câu hỏi 3 (Dành cho Người 2): *"Công cụ `process_monitor.c` làm cách nào để biết tiến trình Nginx đang lắng nghe ở cổng 8080 mà không cần gọi lệnh `netstat` hay `ss`?"*
- **Trả lời:** Trong nhân Linux, mọi socket đều là một file descriptor. Công cụ C của nhóm duyệt thư mục `/proc/<Master_PID>/fd/`, dùng `readlink()` để lấy mã số `inode` của các liên kết có dạng `socket:[inode]`. Sau đó chương trình mở tệp `/proc/net/tcp` và `/proc/net/tcp6`, tìm dòng có cột trạng thái bằng `0A` (`TCP_LISTEN`) và khớp mã `inode`, rồi chuyển đổi cổng từ hệ thập lục phân (Hex) sang hệ thập phân (`0x1F90` = `8080`).

### Câu hỏi 4 (Dành cho Người 2): *"Tại sao trong kết quả Benchmark, `Virtual Memory (VmSize)` của Custom Nginx tăng thêm khoảng 6.77 MB so với Original Nginx, nhưng `RSS Memory (VmRSS)` lại chỉ khoảng 3.1 MB?"*
- **Trả lời:** Vì Custom Nginx đăng ký thêm 2 vùng nhớ chia sẻ (`2 MB` cho Security Module và `256 KB` cho Monitoring Module, tổng cộng `~2.25 MB`). Khi 3 tiến trình (1 Master + 2 Workers) cùng ánh xạ vùng nhớ này vào không gian địa chỉ ảo của mình, tổng `VmSize` cộng dồn của 3 tiến trình sẽ tăng thêm $3 \times 2.25\text{ MB} \approx 6.75\text{ MB}$. Tuy nhiên, nhờ cơ chế *Demand Paging* của nhân Linux, `VmRSS` chỉ tính các trang bộ nhớ vật lý thực sự đã được ghi dữ liệu, nên mức tiêu thụ RAM thực tế vẫn chỉ hơn 3 MB.
