/*
 * halium-shim/shim.c
 * ============================================================
 * Hands-on-metal — Mode C: LD_PRELOAD HAL / ioctl Interceptor
 *
 * Build (aarch64 Android NDK cross-compile):
 *   See Makefile
 *
 * Usage:
 *   LD_PRELOAD=/path/to/libhom_shim.so <halium-process>
 *
 * What is intercepted:
 *   - ioctl(2)                   — all kernel driver calls
 *   - open(2) / openat(2)        — device node opens
 *   - hw_get_module()            — HAL module loads
 *   - binder_write_read ioctl    — Binder IPC transactions
 *
 * Output:
 *   JSON-lines written to $HOM_SHIM_LOG (default: $HOME/tmp/hom_shim.jsonl)
 *   Each line is one intercepted event, ordered by monotonic clock.
 *
 * Decoding ioctl command codes (Linux _IOC macros):
 *   bits 31-30: direction  00=NONE 10=READ 01=WRITE 11=READWRITE
 *   bits 29-16: size       (payload size in bytes)
 *   bits 15-8:  type       (driver magic)
 *   bits  7-0:  number     (command index within driver)
 * ============================================================
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <errno.h>
#include <stdint.h>

/* ── Android hardware abstraction layer header (minimal) ── */
typedef struct hw_module_t {
    uint32_t    tag;
    uint16_t    module_api_version;
    uint16_t    hal_api_version;
    const char *id;
    const char *name;
    const char *author;
    /* ... remaining fields not needed for interception */
    void       *dso;
    uint32_t    reserved[32 - 7];
} hw_module_t;

/* ── Logging ────────────────────────────────────────────── */

static FILE        *g_log         = NULL;
static pthread_mutex_t g_log_mtx  = PTHREAD_MUTEX_INITIALIZER;
static uint64_t     g_call_idx    = 0;

static void shim_log_init(void) {
    if (g_log) return;
    const char *path = getenv("HOM_SHIM_LOG");
    static char default_path[1024];
    if (!path || !*path) {
        const char *home = getenv("HOME");
        if (home && *home) {
            int path_len = snprintf(default_path, sizeof(default_path), "%s/tmp/hom_shim.jsonl", home);
            if (path_len < 0 || (size_t)path_len >= sizeof(default_path)) {
                fprintf(stderr, "hom_shim: HOME path too long, falling back to ./tmp/hom_shim.jsonl\n");
                snprintf(default_path, sizeof(default_path), "./tmp/hom_shim.jsonl");
            }
        } else {
            snprintf(default_path, sizeof(default_path), "./tmp/hom_shim.jsonl");
        }
        path = default_path;
    }
    g_log = fopen(path, "a");
    if (!g_log) g_log = stderr;
}

static uint64_t mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* Emit a JSON-lines record (no heap allocation, fixed-size buffer). */
#define LOG_BUF 4096
static void emit(const char *layer, const char *event,
                 const char *key1, const char *val1,
                 const char *key2, const char *val2,
                 const char *key3, const char *val3,
                 long ret)
{
    char buf[LOG_BUF];
    int  n = 0;

    pthread_mutex_lock(&g_log_mtx);
    shim_log_init();
    uint64_t idx = ++g_call_idx;
    uint64_t ts  = mono_ns();
    pthread_mutex_unlock(&g_log_mtx);

    n += snprintf(buf + n, LOG_BUF - n,
        "{\"idx\":%llu,\"ts_ns\":%llu,\"layer\":\"%s\",\"event\":\"%s\"",
        (unsigned long long)idx, (unsigned long long)ts, layer, event);

    if (key1 && val1)
        n += snprintf(buf + n, LOG_BUF - n, ",\"%s\":\"%s\"", key1, val1);
    if (key2 && val2)
        n += snprintf(buf + n, LOG_BUF - n, ",\"%s\":\"%s\"", key2, val2);
    if (key3 && val3)
        n += snprintf(buf + n, LOG_BUF - n, ",\"%s\":\"%s\"", key3, val3);

    n += snprintf(buf + n, LOG_BUF - n, ",\"ret\":%ld}\n", ret);

    pthread_mutex_lock(&g_log_mtx);
    if (g_log) {
        fwrite(buf, 1, n, g_log);
        fflush(g_log);
    }
    pthread_mutex_unlock(&g_log_mtx);
}

/* Emit an ioctl event with hex buffer dump. */
static void emit_ioctl(int fd, unsigned long request,
                       const void *buf, size_t buf_len, long ret)
{
    /* Decode _IOC fields */
    unsigned int dir  = (unsigned int)((request >> 30) & 0x3);
    unsigned int size = (unsigned int)((request >> 16) & 0x3FFF);
    unsigned int type = (unsigned int)((request >>  8) & 0xFF);
    unsigned int nr   = (unsigned int)( request        & 0xFF);

    const char *dir_str;
    switch (dir) {
        case 0:  dir_str = "NONE";      break;
        case 1:  dir_str = "WRITE";     break;
        case 2:  dir_str = "READ";      break;
        default: dir_str = "READWRITE"; break;
    }

    /* Resolve fd → path via /proc/self/fd */
    char fd_path[256] = "";
    char fd_link[64];
    snprintf(fd_link, sizeof(fd_link), "/proc/self/fd/%d", fd);
    ssize_t lr = readlink(fd_link, fd_path, sizeof(fd_path) - 1);
    if (lr > 0) fd_path[lr] = '\0';

    /* Hex dump of first 64 bytes of buffer */
    char hexbuf[256] = "";
    if (buf && buf_len > 0) {
        const unsigned char *b = (const unsigned char *)buf;
        size_t dumplen = buf_len < 64 ? buf_len : 64;
        int hpos = 0;
        for (size_t i = 0; i < dumplen && hpos < (int)sizeof(hexbuf) - 3; i++)
            hpos += snprintf(hexbuf + hpos, sizeof(hexbuf) - hpos, "%02x", b[i]);
    }

    char code_hex[32];
    snprintf(code_hex, sizeof(code_hex), "0x%08lx", (unsigned long)request);

    char detail[512];
    snprintf(detail, sizeof(detail),
        "dir=%s size=%u type=0x%02x nr=%u fd_path=%s buf=%s",
        dir_str, size, type, nr, fd_path, hexbuf);

    emit("linux", "ioctl", "code", code_hex, "detail", detail, NULL, NULL, ret);
}

/* ── Real function pointers ─────────────────────────────── */

typedef int  (*real_ioctl_t)(int, unsigned long, ...);
typedef int  (*real_open_t)(const char *, int, ...);
typedef int  (*real_openat_t)(int, const char *, int, ...);
typedef int  (*real_hw_get_module_t)(const char *, const hw_module_t **);

static real_ioctl_t        real_ioctl        = NULL;
static real_open_t         real_open         = NULL;
static real_openat_t       real_openat       = NULL;
static real_hw_get_module_t real_hw_get_module = NULL;

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;

static void shim_init_once(void) {
    real_ioctl         = (real_ioctl_t)        dlsym(RTLD_NEXT, "ioctl");
    real_open          = (real_open_t)          dlsym(RTLD_NEXT, "open");
    real_openat        = (real_openat_t)        dlsym(RTLD_NEXT, "openat");
    real_hw_get_module = (real_hw_get_module_t) dlsym(RTLD_NEXT, "hw_get_module");
    shim_log_init();
}

static void ensure_init(void) {
    pthread_once(&g_init_once, shim_init_once);
}

/* ── Intercepted functions ──────────────────────────────── */

/* ioctl — every kernel driver call passes through here */
int ioctl(int fd, unsigned long request, ...) {
    ensure_init();

    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    long ret = real_ioctl ? (long)real_ioctl(fd, request, arg) : -1;

    /* Determine buffer length from _IOC_SIZE */
    unsigned int iocsz = (unsigned int)((request >> 16) & 0x3FFF);
    emit_ioctl(fd, request, arg, (size_t)iocsz, ret);

    return (int)ret;
}

/* open — log device node opens (/dev/*) */
int open(const char *path, int flags, ...) {
    ensure_init();

    va_list ap;
    va_start(ap, flags);
    mode_t mode = (mode_t)va_arg(ap, unsigned int);
    va_end(ap);

    int ret = real_open ? real_open(path, flags, mode) : -1;

    if (path && strncmp(path, "/dev/", 5) == 0) {
        char ret_str[16];
        snprintf(ret_str, sizeof(ret_str), "%d", ret);
        emit("linux", "open", "path", path, "fd", ret_str, NULL, NULL, ret);
    }

    return ret;
}

/* openat — same as open but relative to dirfd */
int openat(int dirfd, const char *path, int flags, ...) {
    ensure_init();

    va_list ap;
    va_start(ap, flags);
    mode_t mode = (mode_t)va_arg(ap, unsigned int);
    va_end(ap);

    int ret = real_openat ? real_openat(dirfd, path, flags, mode) : -1;

    if (path && strncmp(path, "/dev/", 5) == 0) {
        char ret_str[16];
        snprintf(ret_str, sizeof(ret_str), "%d", ret);
        emit("linux", "openat", "path", path, "fd", ret_str, NULL, NULL, ret);
    }

    return ret;
}

/* hw_get_module — Android HAL module load */
int hw_get_module(const char *id, const hw_module_t **module) {
    ensure_init();

    int ret = real_hw_get_module ? real_hw_get_module(id, module) : -ENOENT;

    const char *name = (ret == 0 && module && *module) ? (*module)->name : "(null)";
    emit("android", "hw_get_module", "id", id ? id : "(null)",
         "name", name, NULL, NULL, (long)ret);

    return ret;
}
