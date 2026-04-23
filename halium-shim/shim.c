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
 *   - ioctl(2)                         — all kernel driver calls
 *   - open(2) / openat(2)              — device node opens
 *   - hw_get_module()                  — HIDL HAL module loads
 *   - AServiceManager_getService()     — AIDL service lookups (by name)
 *   - AServiceManager_checkService()   — AIDL service existence check
 *   - AServiceManager_waitForService() — AIDL blocking service lookup
 *   - binder_write_read ioctl          — Binder IPC transactions (BC_TRANSACTION)
 *
 * Known-name tables (compiled in):
 *   - AIDL interface descriptors from VINTF manifests
 *   - Audio product strategy IDs (AOSP + vendor vx_1000..vx_1039)
 *   Used to annotate every intercepted call with the hardware category
 *   and to scan ioctl/binder payloads for known component names.
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

/* ── Known-name tables ──────────────────────────────────── */
/*
 * These tables map component names discovered from:
 *   - VINTF manifest XML files  (HAL interface descriptors)
 *   - ComponentTypeSet XML      (audio product strategy IDs)
 * to human-readable hardware categories.
 *
 * When a known name appears in any intercepted call — a service
 * lookup, an ioctl payload, or a Binder transaction buffer — the
 * shim annotates the JSON-lines record with "category" and "known"
 * so downstream analysis can group events by hardware block.
 */

typedef struct { const char *prefix; const char *category; } aidl_entry_t;

/* AIDL interface descriptor prefixes → hardware category.
 * Derived from vendor/etc/vintf/manifest/ (all <name> elements). */
static const aidl_entry_t g_aidl_table[] = {
    { "android.hardware.audio",                     "audio"        },
    { "android.hardware.biometrics",                "biometrics"   },
    { "android.hardware.bluetooth",                 "bluetooth"    },
    { "android.hardware.boot",                      "boot"         },
    { "android.hardware.camera",                    "camera"       },
    { "android.hardware.contexthub",                "contexthub"   },
    { "android.hardware.drm",                       "drm"          },
    { "android.hardware.dumpstate",                 "dumpstate"    },
    { "android.hardware.gatekeeper",                "gatekeeper"   },
    { "android.hardware.gnss",                      "gps"          },
    { "android.hardware.graphics",                  "display"      },
    { "android.hardware.health",                    "health"       },
    { "android.hardware.input",                     "input"        },
    { "android.hardware.keymaster",                 "keymaster"    },
    { "android.hardware.light",                     "lights"       },
    { "android.hardware.media",                     "codec"        },
    { "android.hardware.memtrack",                  "memtrack"     },
    { "android.hardware.nfc",                       "nfc"          },
    { "android.hardware.neuralnetworks",            "nnapi"        },
    { "android.hardware.oemlock",                   "oemlock"      },
    { "android.hardware.power",                     "power"        },
    { "android.hardware.radio",                     "modem"        },
    { "android.hardware.secure_element",            "se"           },
    { "android.hardware.security",                  "security"     },
    { "android.hardware.sensors",                   "sensors"      },
    { "android.hardware.thermal",                   "thermal"      },
    { "android.hardware.usb",                       "usb"          },
    { "android.hardware.vibrator",                  "vibrator"     },
    { "android.hardware.weaver",                    "weaver"       },
    { "android.hardware.wifi",                      "wifi"         },
    { "android.system",                             "system"       },
    { "com.google.input",                           "touchscreen"  },
    { "hardware.google",                            "google_hw"    },
    { "vendor.google.battery",                      "battery"      },
    { "vendor.google.bluetooth_ext",                "bluetooth"    },
    { "vendor.google.camera",                       "camera"       },
    { "vendor.google.edgetpu",                      "tpu"          },
    { "vendor.google.wireless_charger",             "charger"      },
    { "vendor.samsung_slsi.telephony",              "modem"        },
    { "vendor.dolby",                               "audio"        },
    { NULL, NULL }
};

/* Resolve an AIDL service name to a hardware category.
 * Returns NULL when no prefix matches. */
static const char *aidl_category(const char *name) {
    if (!name) return NULL;
    for (int i = 0; g_aidl_table[i].prefix; i++)
        if (strncmp(name, g_aidl_table[i].prefix,
                    strlen(g_aidl_table[i].prefix)) == 0)
            return g_aidl_table[i].category;
    return NULL;
}

/* ── Audio product strategy table ──────────────────────── */
/*
 * Standard AOSP strategies (no numeric identifier in the XML).
 * Vendor strategies carry Identifier values starting at 1000.
 * Source: audio_policy_engine_product_strategies.xml (ComponentTypeSet).
 */
typedef struct { int id; const char *name; } strat_entry_t;

#define STRAT_ID_NONE   (-1)   /* standard AOSP — no numeric ID */
#define STRAT_VENDOR_LO 1000
#define STRAT_VENDOR_HI 1039

static const strat_entry_t g_strategies[] = {
    /* Standard AOSP strategies */
    { STRAT_ID_NONE, "STRATEGY_PHONE"                       },
    { STRAT_ID_NONE, "STRATEGY_SONIFICATION"                },
    { STRAT_ID_NONE, "STRATEGY_ENFORCED_AUDIBLE"            },
    { STRAT_ID_NONE, "STRATEGY_ACCESSIBILITY"               },
    { STRAT_ID_NONE, "STRATEGY_SONIFICATION_RESPECTFUL"     },
    { STRAT_ID_NONE, "STRATEGY_ASSISTANT"                   },
    { STRAT_ID_NONE, "STRATEGY_MEDIA"                       },
    { STRAT_ID_NONE, "STRATEGY_DTMF"                        },
    { STRAT_ID_NONE, "STRATEGY_CALL_ASSISTANT"              },
    { STRAT_ID_NONE, "STRATEGY_TRANSMITTED_THROUGH_SPEAKER" },
    /* Vendor strategies: vx_1000 .. vx_1039 */
    { 1000, "vx_1000" }, { 1001, "vx_1001" }, { 1002, "vx_1002" },
    { 1003, "vx_1003" }, { 1004, "vx_1004" }, { 1005, "vx_1005" },
    { 1006, "vx_1006" }, { 1007, "vx_1007" }, { 1008, "vx_1008" },
    { 1009, "vx_1009" }, { 1010, "vx_1010" }, { 1011, "vx_1011" },
    { 1012, "vx_1012" }, { 1013, "vx_1013" }, { 1014, "vx_1014" },
    { 1015, "vx_1015" }, { 1016, "vx_1016" }, { 1017, "vx_1017" },
    { 1018, "vx_1018" }, { 1019, "vx_1019" }, { 1020, "vx_1020" },
    { 1021, "vx_1021" }, { 1022, "vx_1022" }, { 1023, "vx_1023" },
    { 1024, "vx_1024" }, { 1025, "vx_1025" }, { 1026, "vx_1026" },
    { 1027, "vx_1027" }, { 1028, "vx_1028" }, { 1029, "vx_1029" },
    { 1030, "vx_1030" }, { 1031, "vx_1031" }, { 1032, "vx_1032" },
    { 1033, "vx_1033" }, { 1034, "vx_1034" }, { 1035, "vx_1035" },
    { 1036, "vx_1036" }, { 1037, "vx_1037" }, { 1038, "vx_1038" },
    { 1039, "vx_1039" },
    { -2, NULL }  /* sentinel */
};

/* Resolve a numeric strategy ID → name.  Returns NULL if not found. */
static const char *strategy_name(int id) {
    for (int i = 0; g_strategies[i].id != -2; i++)
        if (g_strategies[i].id == id) return g_strategies[i].name;
    return NULL;
}

/*
 * Scan up to scan_len bytes of buf for:
 *   (a) a known AIDL interface descriptor (C-string match)
 *   (b) a vendor strategy ID (1000-1039) as a 32-bit LE integer
 *
 * Writes a short annotation into out (up to out_len bytes).
 * Returns 1 if anything was found, 0 otherwise.
 */
static int scan_known_names(const void *buf, size_t scan_len,
                            char *out, size_t out_len) {
    if (!buf || scan_len == 0 || !out || out_len == 0) return 0;
    const char *cbuf = (const char *)buf;
    out[0] = '\0';

    /* (a) AIDL descriptor string search */
    for (int i = 0; g_aidl_table[i].prefix; i++) {
        size_t plen = strlen(g_aidl_table[i].prefix);
        if (plen > scan_len) continue;
        if (memmem(cbuf, scan_len, g_aidl_table[i].prefix, plen)) {
            snprintf(out, out_len, "aidl:%s", g_aidl_table[i].category);
            return 1;
        }
    }

    /* (b) Vendor strategy ID as 4-byte LE word */
    const uint8_t *b = (const uint8_t *)buf;
    for (size_t i = 0; i + 3 < scan_len; i++) {
        uint32_t v = (uint32_t)b[i]
                   | ((uint32_t)b[i+1] << 8)
                   | ((uint32_t)b[i+2] << 16)
                   | ((uint32_t)b[i+3] << 24);
        if (v >= (uint32_t)STRAT_VENDOR_LO && v <= (uint32_t)STRAT_VENDOR_HI) {
            snprintf(out, out_len, "audio_strategy:%s",
                     strategy_name((int)v));
            return 1;
        }
    }
    return 0;
}

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

/* Emit an ioctl event with hex buffer dump and known-name annotation.
 *
 * For Binder BINDER_WRITE_READ ioctls (type='b', nr=1) the write buffer
 * is followed in memory by the transaction data; we scan up to 512 bytes
 * starting from the write_buffer pointer for known AIDL descriptors and
 * audio strategy IDs.  Any other ioctl has its iocsz-byte arg scanned
 * directly.
 *
 * Binder write_read struct (64-bit layout, 6 × uint64 = 48 bytes):
 *   [0] write_size   [1] write_consumed   [2] write_buffer (ptr)
 *   [3] read_size    [4] read_consumed    [5] read_buffer  (ptr)
 */
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

    /* Known-name annotation ------------------------------------------ */
    char known[64] = "";

    /* BINDER_WRITE_READ: type=0x62('b'), nr=1 */
    if (type == 0x62 && nr == 1 && buf) {
        /* Dereference write_buffer pointer from binder_write_read.
         * Layout (64-bit): uint64[0]=write_size, uint64[2]=write_buffer. */
        const uint64_t *bwr = (const uint64_t *)buf;
        uint64_t write_size = bwr[0];
        uint64_t write_ptr  = bwr[2];
        if (write_size > 0 && write_ptr != 0) {
            const void *wbuf = (const void *)(uintptr_t)write_ptr;
            size_t scan = write_size < 512 ? (size_t)write_size : 512;
            scan_known_names(wbuf, scan, known, sizeof(known));
        }
    } else if (buf && buf_len > 0) {
        scan_known_names(buf, buf_len, known, sizeof(known));
    }

    char code_hex[32];
    snprintf(code_hex, sizeof(code_hex), "0x%08lx", (unsigned long)request);

    char detail[512];
    snprintf(detail, sizeof(detail),
        "dir=%s size=%u type=0x%02x nr=%u fd_path=%s buf=%s",
        dir_str, size, type, nr, fd_path, hexbuf);

    emit("linux", "ioctl", "code", code_hex, "detail", detail,
         "known", known[0] ? known : NULL, ret);
}

/* ── Real function pointers ─────────────────────────────── */

typedef int   (*real_ioctl_t)(int, unsigned long, ...);
typedef int   (*real_open_t)(const char *, int, ...);
typedef int   (*real_openat_t)(int, const char *, int, ...);
typedef int   (*real_hw_get_module_t)(const char *, const hw_module_t **);

/* AIDL service manager (libbinder_ndk / libandroid) */
typedef void *(*real_SM_getService_t)(const char *);
typedef void *(*real_SM_checkService_t)(const char *);
typedef void *(*real_SM_waitForService_t)(const char *);

static real_ioctl_t            real_ioctl            = NULL;
static real_open_t             real_open             = NULL;
static real_openat_t           real_openat           = NULL;
static real_hw_get_module_t    real_hw_get_module    = NULL;
static real_SM_getService_t    real_SM_getService    = NULL;
static real_SM_checkService_t  real_SM_checkService  = NULL;
static real_SM_waitForService_t real_SM_waitForService = NULL;

static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;

static void shim_init_once(void) {
    real_ioctl             = (real_ioctl_t)           dlsym(RTLD_NEXT, "ioctl");
    real_open              = (real_open_t)             dlsym(RTLD_NEXT, "open");
    real_openat            = (real_openat_t)           dlsym(RTLD_NEXT, "openat");
    real_hw_get_module     = (real_hw_get_module_t)    dlsym(RTLD_NEXT, "hw_get_module");
    real_SM_getService     = (real_SM_getService_t)    dlsym(RTLD_NEXT, "AServiceManager_getService");
    real_SM_checkService   = (real_SM_checkService_t)  dlsym(RTLD_NEXT, "AServiceManager_checkService");
    real_SM_waitForService = (real_SM_waitForService_t)dlsym(RTLD_NEXT, "AServiceManager_waitForService");
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

/* open — log device node opens (/dev/ prefix) */
int open(const char *path, int flags, ...) {
    ensure_init();

    va_list ap;
    va_start(ap, flags);
    mode_t mode = (mode_t)va_arg(ap, unsigned int);
    va_end(ap);

    int ret = real_open ? real_open(path, flags, mode) : -1;

    if (strncmp(path, "/dev/", 5) == 0) {
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

    if (strncmp(path, "/dev/", 5) == 0) {
        char ret_str[16];
        snprintf(ret_str, sizeof(ret_str), "%d", ret);
        emit("linux", "openat", "path", path, "fd", ret_str, NULL, NULL, ret);
    }

    return ret;
}

/* hw_get_module — HIDL HAL module load.
 * Annotated with the hardware category from the known AIDL table
 * (id strings are shared between HIDL and AIDL for the same subsystem). */
int hw_get_module(const char *id, const hw_module_t **module) {
    ensure_init();

    int ret = real_hw_get_module ? real_hw_get_module(id, module) : -ENOENT;

    const char *mod_name = (ret == 0 && module && *module) ? (*module)->name : "(null)";
    const char *category = aidl_category(id);
    emit("android", "hw_get_module",
         "id",       id ? id : "(null)",
         "name",     mod_name,
         "category", category ? category : "unknown",
         (long)ret);

    return ret;
}

/* ── AIDL service manager interception ──────────────────── */
/*
 * AServiceManager_getService / checkService / waitForService are the
 * NDK entry points for looking up AIDL services by their fully-qualified
 * descriptor (e.g. "android.hardware.bluetooth.IBluetoothHci/default").
 * By intercepting them we can trace exactly which named component is
 * requested, from where (call sequence index), and whether the lookup
 * succeeded — giving the "where they go and to where" data flow.
 */

void *AServiceManager_getService(const char *name) {
    ensure_init();
    void *ret = real_SM_getService ? real_SM_getService(name) : NULL;
    const char *cat = aidl_category(name);
    emit("android", "SM_getService",
         "name",     name ? name : "(null)",
         "category", cat ? cat : "unknown",
         "result",   ret ? "ok" : "null",
         ret ? 0L : -1L);
    return ret;
}

void *AServiceManager_checkService(const char *name) {
    ensure_init();
    void *ret = real_SM_checkService ? real_SM_checkService(name) : NULL;
    const char *cat = aidl_category(name);
    emit("android", "SM_checkService",
         "name",     name ? name : "(null)",
         "category", cat ? cat : "unknown",
         "result",   ret ? "ok" : "null",
         ret ? 0L : -1L);
    return ret;
}

void *AServiceManager_waitForService(const char *name) {
    ensure_init();
    void *ret = real_SM_waitForService ? real_SM_waitForService(name) : NULL;
    const char *cat = aidl_category(name);
    emit("android", "SM_waitForService",
         "name",     name ? name : "(null)",
         "category", cat ? cat : "unknown",
         "result",   ret ? "ok" : "null",
         ret ? 0L : -1L);
    return ret;
}
