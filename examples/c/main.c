/* Minimal C consumer of libtachi: load an extension and print popular titles.
 *
 *   zig build
 *   zig cc -o popular examples/c/main.c -Izig-out/include zig-out/lib/libtachi.a
 *   TACHI_HOST_JAR=host/build/libs/tachi-host.jar ./popular ext.jar
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tachi.h>

static void on_log(int level, const char *tag, const char *msg, void *ud) {
    (void)ud;
    if (level >= TACHI_LOG_WARN) fprintf(stderr, "[%d] %s: %s\n", level, tag, msg);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s extension.jar\n", argv[0]);
        return 2;
    }
    tachi_config cfg = {0};
    cfg.data_dir = ".tachi-data";
    cfg.log_fn = on_log;

    tachi_runtime *rt = NULL;
    if (tachi_runtime_new(&cfg, &rt) != TACHI_OK) {
        fprintf(stderr, "runtime: %s\n", tachi_last_error());
        return 1;
    }

    char *info = NULL;
    if (tachi_install(rt, argv[1], &info) != TACHI_OK) {
        fprintf(stderr, "install: %s\n", tachi_last_error());
        tachi_runtime_free(rt);
        return 1;
    }
    /* Pull the first source id out of the ExtensionInfo JSON ("id":"123..."). */
    const char *p = strstr(info, "\"id\":\"");
    long long id = p ? strtoll(p + 6, NULL, 10) : 0;
    printf("loaded %s, first source id %lld\n", argv[1], id);
    tachi_free(info);

    char *page = NULL;
    int rc = tachi_call(rt, id, "popular", "{\"page\":1}", &page);
    if (rc != TACHI_OK) {
        fprintf(stderr, "popular: %s\n", tachi_last_error());
    } else {
        printf("%.*s...\n", 300, page);
        tachi_free(page);
    }
    tachi_runtime_free(rt);
    return rc == TACHI_OK ? 0 : 1;
}
