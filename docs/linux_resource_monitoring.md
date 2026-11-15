# Linux Resource Monitoring (`CPU` & `RAM`) cho Custom Nginx

## 1. Tổng quan Kiến trúc Quản lý Tài nguyên Linux (`procfs`)

Công cụ **Custom Nginx Resource Monitor** ([src/resource_monitor.c](file:///home/truongphuoc/Desktop/custom-nginx-project/src/resource_monitor.c) và [include/resource_monitor.h](file:///home/truongphuoc/Desktop/custom-nginx-project/include/resource_monitor.h)) thu thập số liệu CPU và bộ nhớ trực tiếp từ nhân Linux thông qua hệ thống tệp ảo `/proc` (`procfs`) và các lời gọi hệ thống POSIX (`sysconf()`, `clock_gettime()`, `nanosleep()`, `readlink()`).

Không giống các script vỏ bọc gọi `top` hay `ps`, công cụ C này thực hiện định danh chính xác nhị phân thực thi của Custom Nginx qua `/proc/<PID>/exe` (trỏ tới `build/custom/sbin/nginx`) và tổng hợp số liệu của toàn bộ cụm tiến trình **Master + Workers**.

---

## 2. Nguồn Dữ liệu Hạt nhân (`Data Sources` trong `/proc`)

| Nguồn `/proc` / Syscall | Dữ liệu trích xuất | Ý nghĩa Kỹ thuật |
| :--- | :--- | :--- |
| `/proc/<PID>/exe` | Đường dẫn tuyệt đối tới binary thực thi | Xác thực chính xác tiến trình thuộc `build/custom/sbin/nginx`, loại trừ Nginx hệ thống (`/usr/sbin/nginx`). |
| `/proc/<PID>/stat` | Trường `3` (`state`), `4` (`ppid`), `14` (`utime`), `15` (`stime`), `16` (`cutime`), `17` (`cstime`), `20` (`num_threads`), `23` (`vsize`), `24` (`rss`) | Cung cấp bộ đếm thời gian CPU nguyên bản tính bằng xung nhịp hạt nhân (*clock ticks* / *jiffies*) và thông tin bộ nhớ cấp trang. |
| `/proc/<PID>/status` | `State`, `Threads`, `VmSize`, `VmRSS`, `VmPeak`, `VmHWM` | Cung cấp kích thước bộ nhớ ảo (`VmSize`) và bộ nhớ vật lý thường trú (`VmRSS`) theo đơn vị KiB (`kB`). |
| `/proc/stat` | Dòng tổng hợp `cpu user nice system idle iowait irq softirq steal` | Tổng thời gian CPU toàn hệ thống (tính bằng *jiffies*) trên tất cả các nhân xử lý. |
| `/proc/meminfo` | `MemTotal`, `MemFree`, `MemAvailable`, `Buffers`, `Cached` | Dung lượng RAM vật lý toàn hệ thống để tính tỷ lệ phần trăm bộ nhớ (`Memory Usage %`). |
| `/proc/uptime` | `uptime_seconds`, `idle_seconds` | Thời gian hoạt động liên tục của hệ thống Ubuntu kể từ lần khởi động gần nhất. |
| `sysconf()` | `_SC_CLK_TCK` (`100 Hz`), `_SC_NPROCESSORS_ONLN`, `_SC_PAGESIZE` (`4096 B`) | Hằng số cấu hình nhân Linux tại runtime. |

---

## 3. Phương pháp Tính toán CPU Usage (Two-Point Sampling)

### 3.1. Tại sao không được hiển thị trực tiếp `utime + stime` như phần trăm CPU?
Trong `/proc/<PID>/stat`, hai trường `utime` (trường 14) và `stime` (trường 15) là **bộ đếm tích lũy** (*cumulative counters*) tính từ lúc tiến trình được khởi tạo (`fork()`), đo bằng đơn vị *clock ticks* ($\text{CLK\_TCK} = 100\text{ ticks/giây}$ trên x86_64 Linux). Để tính **tốc độ sử dụng CPU tức thời (`CPU Usage %`)**, bắt buộc phải lấy mẫu tại hai thời điểm $t_1$ và $t_2$ cách nhau một khoảng thời gian lấy mẫu $\Delta t$ (*sampling interval*).

### 3.2. Giải thích các thành phần thời gian CPU
1. **User Time (`utime` – Trường 14 của `/proc/<PID>/stat`)**:
   - Số xung nhịp (*clock ticks*) mà tiến trình thực thi mã lệnh ở chế độ người dùng (**User Mode / Ring 3**), ví dụ: phân tích cú pháp HTTP header, chạy logic module bảo mật `ngx_http_custom_security_module`, định dạng chuỗi JSON trong `ngx_http_custom_monitoring_module`.
2. **System Time (`stime` – Trường 15 của `/proc/<PID>/stat`)**:
   - Số xung nhịp mà nhân Linux thực thi ở chế độ đặc quyền (**Kernel Mode / Ring 0**) thay mặt cho tiến trình khi gọi system call, ví dụ: `epoll_wait()`, `accept4()`, `recv()`, `send()`, `write()` log.
3. **Total Process CPU Time (`proc_ticks`)**:
   $$T_{\text{proc}}(t) = \text{utime}(t) + \text{stime}(t)$$
4. **Total System CPU Time (`sys_jiffies` từ `/proc/stat`)**:
   $$T_{\text{sys}}(t) = \text{user} + \text{nice} + \text{system} + \text{idle} + \text{iowait} + \text{irq} + \text{softirq} + \text{steal}$$
5. **Sampling Interval ($\Delta t$)**:
   - Khoảng thời gian nghỉ giữa hai lần đọc $t_1$ và $t_2$ (mặc định `500 ms`, có thể tùy chỉnh bằng cờ `-i <ms>`), được thực hiện bằng syscall `nanosleep()` có xử lý tiếp tục khi gặp ngắt `EINTR`.

### 3.3. Công thức tính CPU Usage (%)
Sau khoảng lấy mẫu $\Delta t = t_2 - t_1$:
- Độ tăng xung nhịp của từng tiến trình Nginx $p$:
  $$\Delta T_{\text{proc}, p} = \left(\text{utime}_p(t_2) - \text{utime}_p(t_1)\right) + \left(\text{stime}_p(t_2) - \text{stime}_p(t_1)\right)$$
- Độ tăng xung nhịp của toàn bộ hệ thống:
  $$\Delta T_{\text{sys}} = T_{\text{sys}}(t_2) - T_{\text{sys}}(t_1)$$
- Tỷ lệ sử dụng CPU của tiến trình $p$ (chuẩn hóa theo số nhân trực tuyến $N_{\text{cpus}}$ giống quy ước của `top` và `ps`, trong đó `100%` tương ứng với 1 nhân CPU hoạt động toàn tải):
  $$\text{CPU}_p(\%) = \frac{\Delta T_{\text{proc}, p}}{\Delta T_{\text{sys}}} \times N_{\text{cpus}} \times 100\%$$
- Tổng CPU Usage của Custom Nginx (Master + tất cả Workers):
  $$\text{CPU}_{\text{CustomNginx}}(\%) = \sum_{p \in \{\text{Master}, \text{Workers}\}} \text{CPU}_p(\%)$$

---

## 4. Phân biệt Bộ nhớ `RSS` (`VmRSS`) và `Virtual Memory` (`VmSize`)

Trong [src/resource_monitor.c](file:///home/truongphuoc/Desktop/custom-nginx-project/src/resource_monitor.c), cả hai chỉ số bộ nhớ được đọc từ `/proc/<PID>/status` (và đối chiếu dự phòng với trường 23, 24 của `/proc/<PID>/stat`):

| Chỉ số | Nguồn trong `/proc/<PID>/status` | Bản chất trong Nhân Linux |
| :--- | :--- | :--- |
| **RSS (`Resident Set Size`)** | `VmRSS` (KiB) | Dung lượng **RAM vật lý thực tế** đang được ánh xạ trong bảng trang (*page tables*) của tiến trình và nằm trực tiếp trên bộ nhớ RAM (bao gồm heap/stack đang sử dụng và các trang thư viện dùng chung đã nạp vào RAM). |
| **Virtual Memory (`Virtual Address Space`)** | `VmSize` (KiB) | Tổng **không gian địa chỉ ảo** mà tiến trình đã yêu cầu nhân cấp phát (`mmap()`, `brk()`, toàn bộ vùng mã/dữ liệu của `libc`, `libcrypt`, vùng nhớ dùng chung `ngx_shm_zone_t` 1 MB cho module Security và 256 KB cho module Monitoring), bao gồm cả các trang chưa từng được chạm tới (*lazy allocation / demand paging*) hoặc đã swap. |
| **Peak Memory** | `VmHWM` / `VmPeak` | Đỉnh bộ nhớ vật lý (`High Water Mark`) và đỉnh bộ nhớ ảo từng đạt tới của tiến trình. |

Công thức tính tỷ lệ phần trăm bộ nhớ vật lý (`Memory Usage %`):
$$\text{Memory Usage (\%)} = \frac{\sum_{p \in \{\text{Master}, \text{Workers}\}} \text{VmRSS}_p}{\text{MemTotal}_{\text{system}}} \times 100\%$$

---

## 5. Hướng dẫn Biên dịch, Sử dụng và Kiểm thử

### 5.1. Biên dịch
```bash
make monitors
# Hoặc biên dịch trực tiếp bằng GCC:
gcc -Wall -Wextra -Werror -O2 -Iinclude src/resource_monitor.c -o build/bin/resource_monitor
```

### 5.2. Chạy công cụ giám sát
```bash
# Chạy với khoảng lấy mẫu mặc định 500ms:
./build/bin/resource_monitor

# Chạy với khoảng lấy mẫu tùy chỉnh (ví dụ 700ms):
./build/bin/resource_monitor -i 700
```

### 5.3. Kết quả chạy thực tế (`./tests/test_resource_monitor.sh`)
- **TEST 1 (Running Nginx Telemetry)**: Xác nhận `Nginx Process State: RUNNING`, `Process Count: 3 (1 Master + 2 Workers)`, `Workers: 2`, `System Uptime`. (**PASS**)
- **TEST 2 (Memory Calculation Verification)**: Kiểm chứng tổng `RSS Memory` (`3240 KB` = `352 + 1444 + 1444 KB`) và `Virtual Memory` (`19604 KB` = `6252 + 6676 + 6676 KB`), đảm bảo `Virtual Memory > RSS Memory`. (**PASS**)
- **TEST 3 (CPU Usage under Load)**: Tạo tải HTTP đồng thời vào `/custom_status`, ghi nhận `Delta = 2 ticks` trong `700 ms` (`CPU Usage = 2.96%`). (**PASS**)
- **TEST 4 (Multi-Worker Scaling)**: Nâng `worker_processes` lên `4`, reload không gián đoạn qua `SIGHUP`, xác nhận `Process Count: 5 (1 Master + 4 Workers)`, sau đó khôi phục về `2` Workers. (**PASS**)
- **TEST 5 (Process Termination)**: Khi dừng dịch vụ, báo cáo chính xác `Nginx Process State: STOPPED`, `Process Count: 0`, `RSS Memory: 0.00 MB`. (**PASS**)
- **TEST 6 (Error Handling)**: Từ chối khoảng lấy mẫu không hợp lệ (`-i 10`) với mã thoát khác `0` và xử lý an toàn khi đường dẫn binary không tồn tại. (**PASS**)
