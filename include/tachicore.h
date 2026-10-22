/* libtachicore: extension execution and repository decoding.
 * The integrator owns package acquisition, installation records, library storage,
 * download scheduling and saved pages. This API does not create those stores.
 * A host sandbox is still required for extension preferences, cookies and JVM caches.
 *
 * Functions return 0 or a tachicore_error unless documented otherwise.
 * Output JSON/bytes are caller-owned; release them with tachicore_free().
 * On error tachicore_last_error() returns a borrowed thread-local description.
 * Join all calls before freeing a runtime; detach native caller threads before exit.
 */
#ifndef TACHICORE_H
#define TACHICORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct tachicore_runtime tachicore_runtime;

typedef enum tachicore_error {
    TACHICORE_OK = 0,
    TACHICORE_E_INVALID_ARGUMENT = 1,
    TACHICORE_E_JVM_NOT_FOUND = 2,
    TACHICORE_E_JVM_CREATE_FAILED = 3,
    TACHICORE_E_HOST_JAR_NOT_FOUND = 4,
    TACHICORE_E_BRIDGE_MISSING = 5,
    TACHICORE_E_JAVA_EXCEPTION = 6,
    /* The extension (or the host runtime) reported an error; see tachicore_last_error(). */
    TACHICORE_E_EXTENSION_ERROR = 7,
    TACHICORE_E_INVALID_RESPONSE = 8,
    TACHICORE_E_OUT_OF_MEMORY = 9,
    TACHICORE_E_NETWORK_ERROR = 10,          /* reserved for transport errors */
    TACHICORE_E_INVALID_INDEX = 11,          /* index.pb could not be decoded */
    TACHICORE_E_FILE_SYSTEM_ERROR = 12,
    TACHICORE_E_CANCELED = 16,
    TACHICORE_E_CONCURRENCY_UNAVAILABLE = 17,
    TACHICORE_E_BROWSER_VERIFICATION_REQUIRED = 18, /* source needs an unsupported browser check */
} tachicore_error;

/* Levels follow android.util.Log. */
typedef enum tachicore_log_level {
    TACHICORE_LOG_VERBOSE = 2,
    TACHICORE_LOG_DEBUG = 3,
    TACHICORE_LOG_INFO = 4,
    TACHICORE_LOG_WARN = 5,
    TACHICORE_LOG_ERROR = 6,
    TACHICORE_LOG_ASSERT = 7,
} tachicore_log_level;

typedef void (*tachicore_log_fn)(int level, const char *tag, const char *message, void *user_data);

/* Zero-initialise, then set what you need. Only data_dir is required. */
typedef struct tachicore_config {
    const char *data_dir;          /* preferences, cookies, converted APKs */
    const char *cache_dir;         /* default: <data_dir>/cache */
    const char *host_jar;          /* default: $TACHI_HOST_JAR, the copy embedded at build time (extracted
                                      into cache_dir), tachi-host.jar beside the executable or in ../lib,
                                      ./tachi-host.jar, ./host/build/libs/tachi-host.jar */
    const char *java_home;         /* default: $TACHI_JAVA_HOME, $JAVA_HOME, well-known install dirs */
    const char *libjvm_path;       /* overrides java_home */
    const char *user_agent;
    const char *app_version_name;  /* what eu.kanade.tachiyomi.AppInfo reports; default "0.20.1" */
    const char *package_name;      /* Context.getPackageName(); default "app.mihon" */
    const char *const *extra_classpath; /* NULL-terminated; extra jars (e.g. a JS engine) */
    const char *const *jvm_options;     /* NULL-terminated; raw JVM flags such as "-Xmx512m" */
    tachicore_log_fn log_fn;           /* receives android.util.Log output; may be called from any thread */
    void *log_user_data;
    void *existing_jvm;            /* JavaVM* to adopt instead of creating one (Android) */
    int app_version_code;          /* default 137 */
    int verbose;                   /* enables debug logging and HTTP header logging */
    int no_class_data_sharing;     /* skip the JVM class-data-sharing archive kept in cache_dir (JDK 19+;
                                      written on first exit, roughly halves JVM start-up afterwards) */
    int native_transport;          /* send extension HTTP through Zig sockets and TLS (for JVMs
                                      without a JIT); see docs/API.md */
} tachicore_config;

int tachicore_runtime_new(const tachicore_config *config, tachicore_runtime **out);
void tachicore_runtime_free(tachicore_runtime *rt);
void tachicore_thread_detach(tachicore_runtime *rt);
const char *tachicore_last_error(void);
void tachicore_free(void *p);
const char *tachicore_default_index_url(void); /* borrowed static URL */

/* Load an integrator-owned .jar/.apk; ExtensionInfo JSON out. No registry entry
 * is written and the package file is neither copied nor deleted. Keep registered
 * package paths available until unloading them. */
int tachicore_load(tachicore_runtime *rt, const char *path, char **out_json);
/* Register a package for lazy loading using previously obtained ExtensionInfo. */
int tachicore_register(tachicore_runtime *rt, const char *path, const char *info_json, char **out_json);
int tachicore_unload(tachicore_runtime *rt, const char *package_name, int *out_removed);
int tachicore_list_extensions(tachicore_runtime *rt, char **out_json);

/* Source methods and JSON schemas are documented in docs/API.md. imageRequests
 * plans pages for the integrator's HTTP client. fetch_image executes the source's
 * client/interceptors when needed and returns bytes without saving a page. */
int tachicore_call(tachicore_runtime *rt, int64_t source_id, const char *method,
                   const char *args_json, char **out_json);
int tachicore_fetch_image(tachicore_runtime *rt, int64_t source_id, const char *page_json,
                          uint8_t **out_bytes, size_t *out_len, char **out_mime);
int tachicore_cancel_requests(tachicore_runtime *rt, int64_t source_id);
/* Returns 1 when the host supports operation cancellation, 0 otherwise.
 * Zig callers cancel individual Io futures; the C hook above is source-wide HTTP cancellation. */
int tachicore_supports_cancellation(const tachicore_runtime *rt);

/* Decode caller-supplied bytes; these functions perform no network or file I/O.
 * parse_index accepts protobuf or JSON v2 indexes (including gzip). A returned
 * extension_list_url needs another integrator fetch and parse_extension_list.
 * Legacy repo metadata may return index_v2; otherwise fetch its legacy list and
 * supply the repository base URL to parse_legacy_list. */
int tachicore_parse_index(const uint8_t *bytes, size_t len, char **out_json);
int tachicore_parse_extension_list(const uint8_t *bytes, size_t len, char **out_json);
int tachicore_parse_legacy_repo(const uint8_t *bytes, size_t len, char **out_json);
int tachicore_parse_legacy_list(const uint8_t *bytes, size_t len, const char *base_url, char **out_json);
/* PKCS#7 DER signature block in; JSON array of lowercase certificate SHA-256
 * fingerprints out. The integrator extracts signature blocks and applies trust policy. */
int tachicore_certificate_fingerprints(const uint8_t *bytes, size_t len, char **out_json);

#ifdef __cplusplus
}
#endif
#endif
