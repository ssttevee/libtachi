/*
 * zig-tachi — run Mihon/Tachiyomi extensions in-process.
 *
 * All functions return 0 on success or a tachi_error code. On failure,
 * tachi_last_error() returns a thread-local, NUL-terminated description.
 * Strings returned through out-parameters are UTF-8 JSON documents owned by
 * the caller; release them with tachi_free().
 *
 * Thread safety: a tachi_runtime may be used from any thread. The JVM attaches
 * threads lazily; call tachi_thread_detach() from a thread before it exits.
 */
#ifndef TACHI_H
#define TACHI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tachi_runtime tachi_runtime;

typedef enum tachi_error {
    TACHI_OK = 0,
    TACHI_E_INVALID_ARGUMENT = 1,
    TACHI_E_JVM_NOT_FOUND = 2,
    TACHI_E_JVM_CREATE_FAILED = 3,
    TACHI_E_HOST_JAR_NOT_FOUND = 4,
    TACHI_E_BRIDGE_MISSING = 5,
    TACHI_E_JAVA_EXCEPTION = 6,
    /* The extension (or the host runtime) reported an error; see tachi_last_error(). */
    TACHI_E_EXTENSION_ERROR = 7,
    TACHI_E_INVALID_RESPONSE = 8,
    TACHI_E_OUT_OF_MEMORY = 9,
    TACHI_E_NETWORK_ERROR = 10,          /* index/package download failed or non-2xx */
    TACHI_E_INVALID_INDEX = 11,          /* index.pb could not be decoded */
    TACHI_E_FILE_SYSTEM_ERROR = 12,
    TACHI_E_EXTENSION_NOT_IN_REPO = 13,
    TACHI_E_SIGNATURE_MISMATCH = 14,     /* package not signed with the repository's key */
    TACHI_E_UNSUPPORTED_EXTENSION = 15,  /* extensions-lib version the host does not implement */
} tachi_error;

/* Levels follow android.util.Log. */
typedef enum tachi_log_level {
    TACHI_LOG_VERBOSE = 2,
    TACHI_LOG_DEBUG = 3,
    TACHI_LOG_INFO = 4,
    TACHI_LOG_WARN = 5,
    TACHI_LOG_ERROR = 6,
    TACHI_LOG_ASSERT = 7,
} tachi_log_level;

typedef void (*tachi_log_fn)(int level, const char *tag, const char *message, void *user_data);

/* Zero-initialise, then set what you need. Only data_dir is required. */
typedef struct tachi_config {
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
    tachi_log_fn log_fn;           /* receives android.util.Log output; may be called from any thread */
    void *log_user_data;
    void *existing_jvm;            /* JavaVM* to adopt instead of creating one (Android) */
    int app_version_code;          /* default 137 */
    int verbose;                   /* enables debug logging and HTTP header logging */
    int no_class_data_sharing;     /* skip the JVM class-data-sharing archive kept in cache_dir (JDK 19+;
                                      written on first exit, roughly halves JVM start-up afterwards) */
    int native_transport;          /* send extension HTTP through Zig sockets and TLS (for JVMs
                                      without a JIT); see docs/API.md */
} tachi_config;

int tachi_runtime_new(const tachi_config *config, tachi_runtime **out);
void tachi_runtime_free(tachi_runtime *rt);
void tachi_thread_detach(tachi_runtime *rt);
const char *tachi_last_error(void);
void tachi_free(void *p);

/*
 * Install a .jar or .apk extension from a file. The package is loaded now and
 * remembered in <data_dir>/extensions/installed.json so tachi_restore() can
 * reload it in a later process. *out_json receives an ExtensionInfo document.
 */
int tachi_install(tachi_runtime *rt, const char *path, char **out_json);
/* Unload and forget a package; deletes its file if it was downloaded by tachi_repo_install(). */
int tachi_uninstall(tachi_runtime *rt, const char *package_name);
/* *out_json receives a JSON array of ExtensionInfo (what is loaded right now). */
int tachi_list_extensions(tachi_runtime *rt, char **out_json);
/*
 * Reload every remembered package. Call once after tachi_runtime_new().
 * *out_json receives {"loaded": n, "failed": [{"pkg", "error"}]}; a failure
 * keeps the package remembered so a later update can repair it.
 */
int tachi_restore(tachi_runtime *rt, char **out_json);

/*
 * Repositories. index_url is a Mihon-style index.pb (NULL = keiyoushi).
 * The index is cached under <data_dir>/repo for an hour; refresh != 0 bypasses
 * the cache. Downloads are checked against the repository's signing key.
 *
 * tachi_repo_list:    *out_json receives a JSON array of RepoEntry (see docs/API.md).
 * tachi_repo_install: downloads, verifies and installs one package; ExtensionInfo out.
 * tachi_repo_update:  upgrades every package installed from index_url;
 *                     {"updated": [ExtensionInfo], "failed": [...], "missing": [pkg]} out.
 */
int tachi_repo_list(tachi_runtime *rt, const char *index_url, int refresh, char **out_json);
int tachi_repo_install(tachi_runtime *rt, const char *index_url, const char *package_name, char **out_json);
int tachi_repo_update(tachi_runtime *rt, const char *index_url, char **out_json);

/*
 * Invoke a method on a loaded source. `method` is one of:
 *   info, popular, latest, search, update, details, chapters, pages, imageUrl,
 *   related, filters, mangaUrl, chapterUrl, preferences, setPreference
 * `args_json` is a JSON object (may be NULL or "{}"); see docs/API.md.
 */
int tachi_call(tachi_runtime *rt, int64_t source_id, const char *method, const char *args_json, char **out_json);

/*
 * Download a page image through the source's HTTP client (headers, cookies,
 * interceptors). `page_json` is a Page object {"index","url","imageUrl"}.
 * out_bytes and out_len receive the image (free with tachi_free); out_mime the
 * Content-Type or NULL (free with tachi_free).
 */
int tachi_fetch_image(tachi_runtime *rt, int64_t source_id, const char *page_json,
                      uint8_t **out_bytes, size_t *out_len, char **out_mime);

#ifdef __cplusplus
}
#endif

#endif /* TACHI_H */
