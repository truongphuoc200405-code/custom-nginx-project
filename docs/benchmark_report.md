# Báo cáo Đánh giá Hiệu năng (Benchmark Report): Original Nginx vs Custom Nginx

## 1. Môi trường và Phương pháp Đo kiểm (Benchmark Methodology)

- **Hệ điều hành**: Ubuntu 20.04.4 LTS (`Linux 5.15.0-139-generic x86_64`, 2 vCPU, 3875.94 MB RAM)
- **Trình biên dịch**: `GCC 9.4.0` (`-O -pipe -Wall -Wextra -Werror`) và `GNU Make 4.2.1`
- **Cấu hình Worker**: `worker_processes 2;`, `worker_connections 1024;`, `sendfile on;`
- **Công cụ Benchmark**:
  - Do gói `apache2-utils` (`/usr/bin/ab`) chưa được cài đặt sẵn trên máy chủ và tuân thủ nguyên tắc không tự ý chạy `sudo apt`, dự án đã xây dựng công cụ tương thích chuẩn CLI ApacheBench bằng ngôn ngữ C sử dụng `epoll` non-blocking socket ([src/ab_bench.c](file:///home/truongphuoc/Desktop/custom-nginx-project/src/ab_bench.c) -> [build/bin/ab](file:///home/truongphuoc/Desktop/custom-nginx-project/build/bin/ab)) kết hợp script tự động hóa [scripts/run_benchmark.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/run_benchmark.sh). Nếu hệ thống có `/usr/bin/ab`, script tự động ưu tiên gọi `/usr/bin/ab`.
  - Trong suốt quá trình tải, công cụ [build/bin/resource_monitor](file:///home/truongphuoc/Desktop/custom-nginx-project/build/bin/resource_monitor) lấy mẫu trực tiếp từ `/proc/stat`, `/proc/<PID>/stat` và `/proc/<PID>/status` với cửa sổ lấy mẫu `400 ms` để đo chính xác `CPU Usage (%)`, `RSS Memory` và `Virtual Memory`.
- **Đối tượng so sánh (chỉ chạy nội bộ trên `127.0.0.1:8080`)**:
  1. **Original Nginx**: [build/original/sbin/nginx](file:///home/truongphuoc/Desktop/custom-nginx-project/build/original/sbin/nginx) (Nginx 1.26.2 nguyên bản, `Server: nginx/1.26.2`).
  2. **Custom Nginx**: [build/custom/sbin/nginx](file:///home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx) (Đã vá `Server: CustomWebServer`, tích hợp đồng thời `ngx_http_custom_security_module` với Red-Black Tree + Spinlock/Mutex trong `NGX_HTTP_PREACCESS_PHASE` và `ngx_http_custom_monitoring_module` với bộ đếm nguyên tử trong `NGX_HTTP_LOG_PHASE`).

---

## 2. Bảng So sánh Tổng hợp: Original Nginx vs Custom Nginx

Kịch bản chuẩn: **`5,000` HTTP requests, độ đồng thời `Concurrency = 50` (`-n 5000 -c 50`)** truy xuất tệp tĩnh `/index.html`:

| Chỉ số Đo lường (Metric) | Original Nginx (`1.26.2`) | Custom Nginx (`CustomWebServer`) | Chênh lệch / Đánh giá Kỹ thuật |
| :--- | :--- | :--- | :--- |
| **Server Header phản hồi** | `nginx/1.26.2` | `CustomWebServer` (+ `X-RateLimit-Limit`) | Đã ẩn hoàn toàn tên và phiên bản Nginx |
| **Tổng số Requests hoàn tất** | `5,000` | `5,000` | Hoàn tất 100% |
| **Failed Requests (Error Rate)** | `0 (0.00%)` | `0 (0.00%)` | Không có lỗi kết nối hay rớt gói |
| **Tổng thời gian thực thi** | `0.1478 seconds` | `0.1991 seconds` | `+0.0513 seconds` |
| **Requests per second (RPS)** | **`33,837.25 req/sec`** | **`25,112.52 req/sec`** | Chi phí bảo mật + giám sát chỉ làm giảm ~25.7% RPS nhưng vẫn đạt **>25,000 req/s** |
| **Average Latency (Mean / req)** | **`1.466 ms`** | **`1.980 ms`** | Độ trễ trung bình chỉ tăng **`+0.514 ms`** (nửa mili-giây) |
| **Mean Latency (Across concurrent)** | `0.030 ms` | `0.040 ms` | `+0.010 ms` |
| **Latency Percentile `p50` (Median)** | `1.279 ms` | `1.691 ms` | `+0.412 ms` |
| **Latency Percentile `p90`** | `1.890 ms` | `2.809 ms` | `+0.919 ms` |
| **Latency Percentile `p99`** | `6.107 ms` | `7.102 ms` | `+0.995 ms` |
| **Transfer Rate** | `109,508.43 KB/sec` | `82,008.08 KB/sec` | Băng thông loopback rất cao |
| **CPU Usage khi tải (`400 ms` window)** | **`19.18%`** (`7 ticks`) | **`27.40%`** (`10 ticks`) | Tăng `+8.22%` CPU do tra cứu cây đỏ-đen + khóa `ngx_shmtx_lock` + chèn header động |
| **RSS Memory (RAM vật lý)** | **`3.27 MB` (`3,352 KB`)** | **`3.07 MB` (`3,148 KB`)** | Tương đương (~3.1–3.3 MB cho 1 Master + 2 Workers) |
| **Virtual Memory (`VmSize`)** | **`12.41 MB` (`12,708 KB`)** | **`19.18 MB` (`19,644 KB`)** | Tăng **`+6.77 MB` (`+6,936 KB`)** tổng cộng cho 3 tiến trình (`~2.25 MB/process` ánh xạ 2 vùng Shared Memory `2 MB + 256 KB`) |
| **Memory Usage (% System RAM)** | `0.08%` | `0.08%` | Rất nhẹ trên tổng 3,875.94 MB RAM |

---

## 3. Phân tích Chi tiết theo Từng Tiến trình (Per-Process Breakdown)

### 3.1. Original Nginx dưới tải (`5,000` requests, `c = 50`)
| PID | Role | State | `utime` (ticks) | `stime` (ticks) | $\Delta$ Ticks | CPU (%) | RSS (KB) | VSize (KB) | Mem (%) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `49564` | `MASTER` | `S` | `0` | `0` | `0` | `0.00%` | `352` | `3,940` | `0.01%` |
| `49566` | `WORKER` | `S` | `0` | `3` | `3` | `8.22%` | `1,500` | `4,384` | `0.04%` |
| `49567` | `WORKER` | `S` | `0` | `4` | `4` | `10.96%` | `1,500` | `4,384` | `0.04%` |

### 3.2. Custom Nginx dưới tải (`5,000` requests, `c = 50`)
| PID | Role | State | `utime` (ticks) | `stime` (ticks) | $\Delta$ Ticks | CPU (%) | RSS (KB) | VSize (KB) | Mem (%) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `49594` | `MASTER` | `S` | `0` | `0` | `0` | `0.00%` | `364` | `6,252` | `0.01%` |
| `49596` | `WORKER` | `S` | `0` | `6` | `6` | `16.44%` | `1,392` | `6,696` | `0.04%` |
| `49597` | `WORKER` | `S` | `1` | `3` | `4` | `10.96%` | `1,392` | `6,696` | `0.04%` |

> **Nhận xét Kỹ thuật về Bộ nhớ**:
> Mỗi tiến trình của Original Nginx có `VmSize` khoảng `3,940 – 4,384 KB`, trong khi mỗi tiến trình của Custom Nginx có `VmSize` khoảng `6,252 – 6,696 KB`. Độ chênh lệch mỗi tiến trình đúng bằng **`2,312 KB` (`~2.25 MB`)**, phản ánh chính xác kích thước hai vùng nhớ chia sẻ (`custom_security_shm_zone = 2048 KB` + `custom_monitoring_shm_zone = 256 KB`) được ánh xạ (`mmap(MAP_SHARED|MAP_ANON)`) vào không gian địa chỉ ảo của Master và từng Worker. Tuy nhiên, dung lượng RAM vật lý thực tế (`VmRSS`) chỉ tiêu thụ các trang thực sự chạm tới (`~3.07 MB` tổng cộng).

---

## 4. Benchmark Chuyên biệt các Tính năng Tùy biến trên Custom Nginx

### 4.1. Kịch bản Chống Tấn công Flood (`GET /flood_test`, `-n 1000 -c 25`, giới hạn `20 req/1s`)
- **Complete requests**: `1,000` (`Failed TCP requests: 0`)
- **Requests per second**: **`24,708.25 req/sec`**
- **Average Latency**: **`0.996 ms`** (`p50 = 0.686 ms`, `p99 = 9.108 ms`)
- **Kết quả bảo mật**: Module `ngx_http_custom_security_module` chặn tức thời các request vượt ngưỡng với mã `HTTP 429 Too Many Requests` ở pha `NGX_HTTP_PREACCESS_PHASE` trước khi chạm tới ổ đĩa, giúp độ trễ phản hồi trung bình giảm xuống dưới `1 ms`.

### 4.2. Kịch bản Truy xuất Endpoint Giám sát (`GET /custom_status`, `-n 2000 -c 25`)
- **Complete requests**: `2,000` (`Failed requests: 0`)
- **Requests per second**: **`21,836.57 req/sec`**
- **Average Latency**: **`1.135 ms`** (`p50 = 0.657 ms`, `p90 = 1.410 ms`, `p99 = 8.519 ms`)
- **Đánh giá**: Nhờ sử dụng các phép toán nguyên tử không khóa (`ngx_atomic_fetch_add`) và cấp phát bộ đệm từ `r->pool`, endpoint `/custom_status` tạo phản hồi JSON động với thông lượng trên **21,800 req/giây** mà không gây nghẽn cổ chai giữa các Worker.

---

## 5. Hướng dẫn Chạy lại Benchmark
```bash
# Chạy toàn bộ kịch bản benchmark tự động và xuất log ra logs/benchmark_raw.log:
make benchmark
# Hoặc gọi trực tiếp script:
./scripts/run_benchmark.sh
```
