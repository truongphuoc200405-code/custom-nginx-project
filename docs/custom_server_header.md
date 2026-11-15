# CUSTOMIZING NGINX C SOURCE CODE – SERVER HEADER & IDENTITY
## Phase: PROMPT 3 – Modify Nginx C Source (`CustomWebServer`)

---

## 1. Source Code Analysis

### 1.1. Files Handling Server Header & Version Disclosure
1. **[source/nginx/src/http/ngx_http_header_filter_module.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_header_filter_module.c#L49-L51)**:
   - Defines the three static byte arrays (`u_char[]`) emitted in the HTTP `Server` response header depending on the `server_tokens` directive (`on`, `off`, or `build`).
   - Function `ngx_http_header_filter(ngx_http_request_t *r)`:
     - **Lines 286–296**: Calculates exact buffer size using `sizeof(...) - 1` at compile time.
     - **Lines 455–470**: Selects the pointer `p` and length `len` using `sizeof(...) - 1` and copies the string into the outgoing header buffer `b->last` via `ngx_cpymem(b->last, p, len)`.
2. **[source/nginx/src/http/ngx_http_special_response.c](file:///home/truongphuoc/Desktop/custom-nginx-project/source/nginx/src/http/ngx_http_special_response.c#L21-L39)**:
   - Defines the three HTML footer tails (`ngx_http_error_full_tail`, `ngx_http_error_build_tail`, `ngx_http_error_tail`) appended to built-in HTTP error pages (`3xx`, `4xx`, `5xx`).
   - Function `ngx_http_send_special_response(ngx_http_request_t *r, ngx_http_core_loc_conf_t *clcf, ngx_uint_t err)` uses `sizeof(...) - 1` on these static arrays to set `Content-Length` and construct the response body buffer chain.

### 1.2. Why Modifying Static Arrays in C Source Is Safe & Preserves ABI
- In `ngx_http_header_filter_module.c` and `ngx_http_special_response.c`, Nginx computes buffer lengths using the C compile-time operator `sizeof(array) - 1` rather than hardcoding integer lengths.
- Furthermore, by keeping `nginx_version` (`1026002`) intact in `src/core/nginx.h`, `NGX_MODULE_V1` binary module signatures remain 100% compatible with all built-in and custom HTTP modules, and the HTTP protocol version (`HTTP/1.1`), status codes, response bodies, and header filter chain (`ngx_http_top_header_filter`) are completely unaffected.

---

## 2. Source Code Before vs. After Modification

### 2.1. `src/http/ngx_http_header_filter_module.c` (Lines 49–51)

**Before (Original Nginx 1.26.2):**
```c
static u_char ngx_http_server_string[] = "Server: nginx" CRLF;
static u_char ngx_http_server_full_string[] = "Server: " NGINX_VER CRLF;
static u_char ngx_http_server_build_string[] = "Server: " NGINX_VER_BUILD CRLF;
```

**After (Customized C Source):**
```c
static u_char ngx_http_server_string[] = "Server: CustomWebServer" CRLF;
static u_char ngx_http_server_full_string[] = "Server: CustomWebServer" CRLF;
static u_char ngx_http_server_build_string[] = "Server: CustomWebServer" CRLF;
```

### 2.2. `src/http/ngx_http_special_response.c` (Lines 21–39)

**Before (Original Nginx 1.26.2):**
```c
static u_char ngx_http_error_full_tail[] =
"<hr><center>" NGINX_VER "</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;


static u_char ngx_http_error_build_tail[] =
"<hr><center>" NGINX_VER_BUILD "</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;


static u_char ngx_http_error_tail[] =
"<hr><center>nginx</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;
```

**After (Customized C Source):**
```c
static u_char ngx_http_error_full_tail[] =
"<hr><center>CustomWebServer</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;


static u_char ngx_http_error_build_tail[] =
"<hr><center>CustomWebServer</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;


static u_char ngx_http_error_tail[] =
"<hr><center>CustomWebServer</center>" CRLF
"</body>" CRLF
"</html>" CRLF
;
```

---

## 3. Unified Diff Patch (`patches/custom_server_header.patch`)

File location: [patches/custom_server_header.patch](file:///home/truongphuoc/Desktop/custom-nginx-project/patches/custom_server_header.patch)

```diff
--- a/src/http/ngx_http_header_filter_module.c
+++ b/src/http/ngx_http_header_filter_module.c
@@ -46,9 +46,9 @@
 };
 
 
-static u_char ngx_http_server_string[] = "Server: nginx" CRLF;
-static u_char ngx_http_server_full_string[] = "Server: " NGINX_VER CRLF;
-static u_char ngx_http_server_build_string[] = "Server: " NGINX_VER_BUILD CRLF;
+static u_char ngx_http_server_string[] = "Server: CustomWebServer" CRLF;
+static u_char ngx_http_server_full_string[] = "Server: CustomWebServer" CRLF;
+static u_char ngx_http_server_build_string[] = "Server: CustomWebServer" CRLF;
 
 
 static ngx_str_t ngx_http_status_lines[] = {
--- a/src/http/ngx_http_special_response.c
+++ b/src/http/ngx_http_special_response.c
@@ -19,21 +19,21 @@
 
 
 static u_char ngx_http_error_full_tail[] =
-"<hr><center>" NGINX_VER "</center>" CRLF
+"<hr><center>CustomWebServer</center>" CRLF
 "</body>" CRLF
 "</html>" CRLF
 ;
 
 
 static u_char ngx_http_error_build_tail[] =
-"<hr><center>" NGINX_VER_BUILD "</center>" CRLF
+"<hr><center>CustomWebServer</center>" CRLF
 "</body>" CRLF
 "</html>" CRLF
 ;
 
 
 static u_char ngx_http_error_tail[] =
-"<hr><center>nginx</center>" CRLF
+"<hr><center>CustomWebServer</center>" CRLF
 "</body>" CRLF
 "</html>" CRLF
 ;
```

### Patch Operations Verification
- **Apply patch**: `patch -p1 -N -d source/nginx < patches/custom_server_header.patch`
- **Revert patch**: `patch -p1 -R -d source/nginx < patches/custom_server_header.patch`

---

## 4. Build Commands & Binary Verification

### 4.1. Configure & Compile Commands
```bash
cd source/nginx && bash ./configure \
  --prefix=/home/truongphuoc/Desktop/custom-nginx-project/build/custom \
  --sbin-path=/home/truongphuoc/Desktop/custom-nginx-project/build/custom/sbin/nginx \
  --conf-path=/home/truongphuoc/Desktop/custom-nginx-project/config/nginx.conf \
  --error-log-path=/home/truongphuoc/Desktop/custom-nginx-project/logs/error.log \
  --http-log-path=/home/truongphuoc/Desktop/custom-nginx-project/logs/access.log \
  --pid-path=/home/truongphuoc/Desktop/custom-nginx-project/logs/nginx.pid \
  --lock-path=/home/truongphuoc/Desktop/custom-nginx-project/logs/nginx.lock \
  --with-http_stub_status_module \
  --without-http_rewrite_module \
  --without-http_gzip_module

make -j$(nproc)
make install
```

### 4.2. Cryptographic & ELF Binary Proof (Original vs. Custom)
```text
$ sha256sum build/original/sbin/nginx build/custom/sbin/nginx
f3b56135c7887419042a7a25bab91ec9e1943163a9a9c0ba2f4aaf083050b54e  build/original/sbin/nginx
319585ebf5a02258ca46902cd607b1668135d51b92d6ec0087a841686adc0f75  build/custom/sbin/nginx

$ strings build/original/sbin/nginx | grep -E "^Server: |<hr><center>"
<hr><center>nginx</center>
<hr><center>nginx/1.26.2</center>
<hr><center>nginx/1.26.2</center>
Server: nginx/1.26.2
Server: nginx/1.26.2
Server: nginx

$ strings build/custom/sbin/nginx | grep -E "^Server: |<hr><center>"
<hr><center>CustomWebServer</center>
<hr><center>CustomWebServer</center>
<hr><center>CustomWebServer</center>
Server: CustomWebServer
Server: CustomWebServer
Server: CustomWebServer
```

---

## 5. Runtime Test Results & Comparison

| Check Metric | Original Nginx (`build/original/sbin/nginx`) | Custom Nginx (`build/custom/sbin/nginx`) |
| :--- | :--- | :--- |
| **HTTP Status (`GET /`)** | `HTTP/1.1 200 OK` | `HTTP/1.1 200 OK` |
| **Server Header** | `Server: nginx/1.26.2` | `Server: CustomWebServer` |
| **Version Disclosed?** | Yes (`1.26.2`) | **No** (Hidden across all `server_tokens` modes) |
| **Content-Type** | `text/html` | `text/html` |
| **Content-Length (`index.html`)** | `3080` bytes | `3080` bytes |
| **404 Error Page Footer** | `<hr><center>nginx/1.26.2</center>` | `<hr><center>CustomWebServer</center>` |
| **Error Log Status** | Clean startup & graceful shutdown | Clean startup & graceful shutdown |

### Raw HTTP Response Header (`http://127.0.0.1:8080/`)
```http
HTTP/1.1 200 OK
Server: CustomWebServer
Date: Sun, 15 Nov 2026 09:32:32 GMT
Content-Type: text/html
Content-Length: 3080
Last-Modified: Sun, 15 Nov 2026 08:43:35 GMT
Connection: keep-alive
ETag: "6af970b7-c08"
Accept-Ranges: bytes
```
