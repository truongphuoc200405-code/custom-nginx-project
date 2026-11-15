# SYSTEMD SERVICE INTEGRATION DOCUMENTATION
## Phase: PROMPT 7 – systemd Integration (`custom-nginx.service`)

---

## 1. Overview & Architecture

Custom Nginx is integrated with Ubuntu's `systemd` service manager via [systemd/custom-nginx.service](file:///home/truongphuoc/Desktop/custom-nginx-project/systemd/custom-nginx.service). To strictly honor the project's non-root and no-sudo safety rules while running under genuine `systemd` cgroup supervision:
- The service runs under the user's `systemd` manager (`systemctl --user` at `/home/truongphuoc/.config/systemd/user/custom-nginx.service`, CGroup `/user.slice/user-1000.slice/user@1000.service/custom-nginx.service`) as unprivileged user `truongphuoc` on port `8080`.
- It never overwrites or interferes with any system-wide `/lib/systemd/system/nginx.service` or `/usr/sbin/nginx`.
- The unit file is also 100% compatible with system-wide deployment (`/etc/systemd/system/custom-nginx.service`) if the user explicitly confirms `sudo`.

---

## 2. Unit File Specification (`systemd/custom-nginx.service`)

File location: [systemd/custom-nginx.service](file:///home/truongphuoc/Desktop/custom-nginx-project/systemd/custom-nginx.service)

```ini
[Unit]
Description=Custom Nginx Web Server (Security & Monitoring Modules on Ubuntu)
Documentation=file:///home/truongphuoc/Desktop/custom-nginx-project/docs/systemd_integration.md
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=/home/truongphuoc/Desktop/custom-nginx-project
PIDFile=/home/truongphuoc/Desktop/custom-nginx-project/logs/nginx.pid

# Validate configuration before starting or reloading
ExecStartPre=/home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx -p /home/truongphuoc/Desktop/custom-nginx-project -c /home/truongphuoc/Desktop/custom-nginx-project/config/nginx.conf -t
ExecStart=/home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx -p /home/truongphuoc/Desktop/custom-nginx-project -c /home/truongphuoc/Desktop/custom-nginx-project/config/nginx.conf
ExecReload=/home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx -p /home/truongphuoc/Desktop/custom-nginx-project -c /home/truongphuoc/Desktop/custom-nginx-project/config/nginx.conf -t
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID

# Restart & Timeout Policies
Restart=on-failure
RestartSec=3s
TimeoutStartSec=15s
TimeoutStopSec=15s
KillMode=mixed
KillSignal=SIGQUIT
SendSIGKILL=yes

# Non-root User/Group & Security Hardening
NoNewPrivileges=true
LockPersonality=true
RestrictRealtime=true
SystemCallArchitectures=native
UMask=0027
LimitNOFILE=65535

[Install]
WantedBy=default.target
```

### Key Directives Explained
- **`Type=forking` & `PIDFile`**: Matches Nginx's daemon model where the initial process forks the persistent Master process and writes its PID to `logs/nginx.pid`.
- **`ExecStartPre`**: Runs `nginx -t` before starting; if the config is broken, `systemd` aborts startup cleanly.
- **`ExecReload`**: Runs `nginx -t` first, then sends `SIGHUP` (`/bin/kill -s HUP $MAINPID`) to the Master process for zero-downtime worker replacement. If `nginx -t` fails, the running server is untouched.
- **`ExecStop` & `KillSignal=SIGQUIT`**: Sends `SIGQUIT` to trigger Nginx's graceful shutdown so in-flight HTTP requests finish cleanly.
- **`Restart=on-failure` (`RestartSec=3s`)**: Automatically restarts the Master process if it terminates abnormally.
- **Security Hardening**: `NoNewPrivileges=true`, `LockPersonality=true`, `RestrictRealtime=true`, `SystemCallArchitectures=native`, `UMask=0027`, and `LimitNOFILE=65535`.

---

## 3. Service Management Scripts (`scripts/`)

| Script | Purpose & Safety Checks |
| :--- | :--- |
| [scripts/service_start.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/service_start.sh) | Verifies `logs/nginx.pid` ownership via `/proc/<pid>/exe` (refuses to overwrite/kill foreign processes), checks port `8080` collisions via `ss -tulpn`, syncs `systemd/custom-nginx.service` to `~/.config/systemd/user/`, runs `systemctl --user daemon-reload && systemctl --user start custom-nginx.service`, and extracts security logs into `logs/security.log`. |
| [scripts/service_stop.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/service_stop.sh) | Verifies PID identity, stops `custom-nginx.service` via `systemctl --user stop`, and updates `logs/security.log`. |
| [scripts/service_reload.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/service_reload.sh) | Validates `nginx -t`, invokes `systemctl --user reload custom-nginx.service`, and displays Master PID persistence alongside old vs. new Worker PIDs. |
| [scripts/service_status.sh](file:///home/truongphuoc/Desktop/custom-nginx-project/scripts/service_status.sh) | Displays `systemctl --user status`, CGroup hierarchy, `ps` Master/Worker table, `ss -tulpn` port bindings, line/byte counts of all 4 log files (`access.log`, `error.log`, `security.log`, `build.log`), and live `/custom_status` JSON output. |

---

## 4. Verification Results

### 4.1. `systemd` CGroup & Status Output
```text
● custom-nginx.service - Custom Nginx Web Server (Security & Monitoring Modules on Ubuntu)
     Loaded: loaded (/home/truongphuoc/.config/systemd/user/custom-nginx.service; disabled; vendor preset: enabled)
     Active: active (running) since Sun 2026-11-15 03:03:04 PST; 1s ago
    Process: 36446 ExecStartPre=/home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx -p /home/truongphuoc/Desktop/custom-nginx-project -c /home/truongphuoc/Desktop/custom-nginx-project/config/nginx.conf -t (code=exited, status=0/SUCCESS)
    Process: 36448 ExecStart=/home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx -p /home/truongphuoc/Desktop/custom-nginx-project -c /home/truongphuoc/Desktop/custom-nginx-project/config/nginx.conf (code=exited, status=0/SUCCESS)
   Main PID: 36449 (nginx)
     CGroup: /user.slice/user-1000.slice/user@1000.service/custom-nginx.service
             ├─36449 nginx: master process /home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx ...
             ├─36450 nginx: worker process
             └─36451 nginx: worker process
```

### 4.2. Zero-Downtime Reload Verification (`scripts/service_reload.sh`)
```text
  * Master PID (Unchanged) : 36281
  * Previous Worker PIDs   : 36282 36283 
  * New Worker PIDs        : 36362 36363 
[SUCCESS] custom-nginx.service reloaded zero-downtime via systemd.
```

### 4.3. Centralized Log Management (`logs/`)
- `logs/access.log`: HTTP client requests with `pid=$pid`.
- `logs/error.log`: Nginx lifecycle notices and module diagnostic logs.
- `logs/security.log`: Dedicated security & access-control audit events (`[CUSTOM_SECURITY]`, `[CUSTOM_MONITORING]`).
- `logs/build.log`: Complete configure, compiler, and installation logs.
