# ARCHITECTURE & PROJECT RULES SPECIFICATION
## Custom Nginx Web Server on Ubuntu

---

## 1. Kiến trúc tổng thể (System Architecture)

Dự án xây dựng một phiên bản **Custom Nginx Web Server** hoạt động độc lập trong không gian người dùng (hoặc thông qua `systemd` được cấu hình trỏ tới prefix riêng), tích hợp hai module mở rộng viết bằng C và bộ công cụ giám sát cấp hệ điều hành Linux:

```text
+-------------------------------------------------------------------------+
|                        CLIENT / BENCHMARK TOOLS                         |
|                       (curl, ApacheBench - ab)                          |
+------------------------------------+------------------------------------+
                                     | HTTP Requests
                                     v
+-------------------------------------------------------------------------+
|                    CUSTOM NGINX WEB SERVER (build/)                     |
|                                                                         |
|  +-------------------------------------------------------------------+  |
|  | Master Process (Signal Handling: SIGHUP, SIGTERM, SIGUSR1, etc.)  |  |
|  +---------------------------------+---------------------------------+  |
|                                    | Forks & Manages                    |
|                                    v                                    |
|  +-------------------------------------------------------------------+  |
|  | Worker Processes (Event-driven Non-blocking I/O Loop)             |  |
|  |                                                                   |  |
|  |  +-----------------------------+  +----------------------------+  |  |
|  |  | Customized Nginx Core (C)   |  | Custom Security Module (C) |  |  |
|  |  | (Server Headers, Core Mods) |  | (ngx_http_security_module) |  |  |
|  |  +-----------------------------+  +----------------------------+  |  |
|  |                                                                   |  |
|  |  +-------------------------------------------------------------+  |  |
|  |  | Custom Monitoring Module (C) (ngx_http_monitoring_module)   |  |  |
|  |  +------------------------------+------------------------------+  |  |
|  +---------------------------------|---------------------------------+  |
+------------------------------------|------------------------------------+
                                     | System Calls / procfs Reads
                                     v
+-------------------------------------------------------------------------+
|                          UBUNTU LINUX KERNEL                            |
|       procfs (/proc/<pid>/stat, /proc/meminfo, /proc/loadavg)           |
|       POSIX Signals, Epoll, Network Stack, systemd Service Manager      |
+-------------------------------------------------------------------------+
```

---

## 2. Thiết kế phân tách thư mục & Prefix cô lập (Isolation Design)

Để đảm bảo nguyên tắc **không ghi đè Nginx hệ thống** (`/usr/sbin/nginx`), toàn bộ quá trình configure và install của Nginx tùy biến sẽ sử dụng đường dẫn cô lập:

- **Installation Prefix (`--prefix`)**: `/home/truongphuoc/Desktop/custom-nginx-project/build`
- **Binary Path (`--sbin-path`)**: `/home/truongphuoc/Desktop/custom-nginx-project/build/sbin/nginx`
- **Config Path (`--conf-path`)**: `/home/truongphuoc/Desktop/custom-nginx-project/config/nginx.conf`
- **Error Log Path (`--error-log-path`)**: `/home/truongphuoc/Desktop/custom-nginx-project/logs/error.log`
- **HTTP Log Path (`--http-log-path`)**: `/home/truongphuoc/Desktop/custom-nginx-project/logs/access.log`
- **PID Path (`--pid-path`)**: `/home/truongphuoc/Desktop/custom-nginx-project/logs/nginx.pid`

---

## 3. Vai trò chi tiết của từng thư mục

1. **`source/`**: Chứa tarball mã nguồn Nginx chính thức và thư mục giải nén phục vụ phân tích, sửa đổi và biên dịch.
2. **`patches/`**: Lưu các bản vá (`.patch` / `.diff`) được trích xuất từ thay đổi trên mã nguồn C gốc để dễ dàng kiểm toán và tái lập.
3. **`modules/security/`**: Chứa file `config` và mã nguồn C của module bảo mật tùy chỉnh (kiểm tra request, header bảo mật, lọc truy cập...).
4. **`modules/monitoring/`**: Chứa file `config` và mã nguồn C của module giám sát (cung cấp endpoint thống kê trực tiếp từ tiến trình và `/proc`).
5. **`scripts/`**: Chứa các Bash script tự động hóa: tải source, build, quản lý vòng đời tiến trình, gửi tín hiệu, theo dõi CPU/RAM.
6. **`config/`**: Chứa cấu hình Nginx tùy chỉnh và file dịch vụ `systemd` (`custom-nginx.service`).
7. **`web/`**: Chứa các trang tĩnh (`index.html`, trang lỗi tùy chỉnh) để phục vụ kiểm thử.
8. **`tests/`**: Chứa các script kiểm thử tích hợp và benchmark so sánh hiệu năng.
9. **`logs/`**: Lưu toàn bộ log vận hành, PID file và báo cáo thực nghiệm.
10. **`build/`**: Đích cài đặt (`PREFIX`) của bản dựng Custom Nginx.
11. **`docs/`**: Tài liệu kỹ thuật xuyên suốt các giai đoạn từ Prompt 0 đến Prompt 11.

---

## 4. Quy tắc thực thi nghiêm ngặt (Strict Project Rules)

1. **Làm việc trực tiếp trên file thực tế**: Mọi thay đổi được ghi trực tiếp vào workspace.
2. **Không giả lập dữ liệu**: Chỉ báo cáo `PASS` sau khi chạy lệnh thực tế và kiểm tra đầu ra.
3. **Không tự ý chạy `sudo`**: Luôn giải thích rõ mục đích và câu lệnh cần quyền root trước khi yêu cầu người dùng xác nhận.
4. **Bảo toàn tính toàn vẹn qua từng giai đoạn**: Không sửa mã nguồn bằng cách thay thế chuỗi mù quáng; sử dụng công cụ đọc/sửa chính xác và kiểm tra lỗi biên dịch triệt để.
5. **Tuân thủ từng bước (Phase-Gate)**: Hoàn thành đúng phạm vi của Prompt hiện tại, báo cáo đầy đủ theo mẫu 7 mục và dừng lại chờ lệnh tiếp theo.
