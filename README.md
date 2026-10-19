# zig-tachi

Run [Mihon](https://mihon.app) / Tachiyomi extensions **in-process**, from any
language with a C ABI, without an Android device and without a web server.

```
┌──────────────────────────┐      JNI       ┌──────────────────────────────┐
│ your app (Zig / C / ...) │ ─────────────▶ │ embedded JVM (HotSpot / ART) │
│   libtachi  · tachi.h    │ ◀───────────── │   tachi-host.jar             │
│   JSON in / JSON out     │   byte[] JSON  │   ├ extensions-lib 1.6 impl  │
└──────────────────────────┘                │   ├ android.* compat layer   │
                                            │   └ extension .jar / .apk    │
                                            └──────────────────────────────┘
```

Extensions are ordinary Android APKs written against
[extensions-lib](https://github.com/keiyoushi/extensions-lib). The same trick
that lets [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) run
them on a desktop JVM is used here, but packaged as an embeddable library in
the spirit of [PatchBukkit](https://github.com/Pumpkin-MC/PatchBukkit): the
JVM lives inside your process and you talk to it through a small, stable C API.

See [docs/DESIGN.md](docs/DESIGN.md) for the architecture and the reasoning
behind it, and [docs/API.md](docs/API.md) for the JSON wire format.

## Status

Working today (macOS/Linux, HotSpot JDK 17+):

- Loads keiyoushi `.jar` builds directly, and `.apk` builds via dex2jar.
- Full source API for extensions-lib **1.6**: popular, latest, search with
  filters, manga details, chapter list, page list, image download through the
  source's own OkHttp client (cookies, headers, interceptors), related titles,
  browser URLs, and source preferences.
- Android compatibility layer covering what extensions actually touch:
  `Context`/`Application`, `SharedPreferences`, `androidx.preference.*`,
  `Uri`, `Base64`, `Log`, `SystemClock`, `Build`, `Handler`/`Looper`,
  `webkit.CookieManager` (shared with OkHttp), `Toast`.
- Extension repositories: lists Mihon-style `index.pb` repos (keiyoushi by
  default), downloads packages, checks them against the repo's signing key,
  and remembers installs across runs. All of it in Zig on `std.Io`; the JVM
  only ever loads files.
- Log output and errors flow back to the native side; JVM threads attach lazily.

Not yet: WebView-dependent sources (Cloudflare challenges, JS-rendered pages),
`android.graphics.Bitmap` image descrambling, extensions-lib 1.4/1.5 (RxJava),
iOS (no JVM). Hooks exist for the host app to plug in a Cloudflare solver and a
JavaScript engine. See the roadmap in `docs/DESIGN.md`.

## Build

Requirements: Zig 0.17, a JDK 17+ (to build and to run), and an `android.jar`
(only to build the host jar). The Gradle build finds one under `ANDROID_HOME`
/ `~/Library/Android/sdk`; without an SDK, run `host/scripts/get-android-jar.sh`
and pass `-Ptachi.androidJar=host/lib/android.jar`.

```sh
zig build host        # host/build/libs/tachi-host.jar, copied to zig-out/lib  (Gradle, ~1 min first time)
zig build             # zig-out/lib/libtachi.{a,dylib|so}, zig-out/lib/tachi-host.jar,
                      # zig-out/include/tachi.h, zig-out/bin/tachi-cli
zig build test

# For distribution: bake the jar into the library and CLI so they are the only
# files to ship (plus a JDK). It is written to the cache dir on first run.
zig build -Dembed-host-jar
```

`-Dhost-jar=PATH` picks a jar other than `host/build/libs/tachi-host.jar`
for both modes. Without embedding, `zig build` copies an already built jar to
`zig-out/lib`, and the runtime looks for it beside the executable and in
`../lib`, so `zig-out/bin/tachi-cli` works from any directory.

Start-up: the runtime keeps a JVM class-data-sharing archive of the host in
the cache dir (JDK 19+, created on the first exit). With it a full
`tachi-cli` run that starts the JVM, loads the host and lists extensions
takes about 70 ms on an M-series Mac, against 170 ms without. Disable with
`class_data_sharing = false` / `no_class_data_sharing` / `--no-cds`.

## Try it

```sh
CLI=./zig-out/bin/tachi-cli

$CLI repo list --lang en --grep weeb          # browse the keiyoushi index (cached for an hour)
#     eu.kanade.tachiyomi.extension.en.weebcentral   1.6.25   en   [18+] Weeb Central
$CLI repo install eu.kanade.tachiyomi.extension.en.weebcentral
#   { "pkg": "eu.kanade.tachiyomi.extension.en.weebcentral", ..., "sources": [ { "id": "2131019126180322627", ... } ] }
# Installed extensions are reloaded on every run; `repo update` upgrades them,
# `uninstall PKG` removes them. A local file works too: `install FILE`, or
# `--ext FILE` for just this run.

$CLI popular  2131019126180322627
$CLI search   2131019126180322627 "one piece"
$CLI chapters 2131019126180322627 /series/01J76XYCT4YVNM26WW8RAKWEV5/One-Piece
$CLI pages    2131019126180322627 /chapters/01J76XYZPZ0WKZQ4N3VH3M7M6E
$CLI image    2131019126180322627 "https://.../001-001.png" page.png
```

Data (installed packages and their registry, cached indexes, preferences,
cookies, converted APKs) lives in `--data-dir` (default `./.tachi-data`).

## Use from Zig

```zig
const tachi = @import("tachi");

// `io` and `environ` come from `std.process.Init` in `main`; the library does
// all file-system and environment access through them (no hidden libc calls).
var rt = try tachi.Runtime.init(gpa, init.io, .{
    .data_dir = "/path/to/data",
    .log_fn = myLog,
    .environ = init.minimal.environ, // enables $TACHI_HOST_JAR / $JAVA_HOME lookup
});
defer rt.deinit();

const restored = try rt.restore(); // reload what earlier runs installed
defer gpa.free(restored);
const ext_json = try rt.repoInstall("eu.kanade.tachiyomi.extension.en.weebcentral", .{});
defer gpa.free(ext_json);
// or from a file: rt.installExtensionParsed("tachiyomi-en.weebcentral-v1.6.25.jar")
const id: i64 = 2131019126180322627;

const popular = try rt.callParsed(tachi.models.MangasPage, id, "popular", "{\"page\":1}");
defer popular.deinit();
for (popular.value().mangas) |m| std.debug.print("{s}\n", .{m.title});

const img = try rt.fetchImage(id, "{\"index\":0,\"imageUrl\":\"https://...\"}");
defer img.deinit(gpa);
```

Add it as a dependency with `zig fetch --save <url>` and
`exe.root_module.addImport("tachi", dep.module("tachi"))`.

## Use from C

```c
#include <tachi.h>

tachi_config cfg = { .data_dir = "/path/to/data" };   /* .host_jar = "..." unless embedded or beside the executable */
tachi_runtime *rt;
if (tachi_runtime_new(&cfg, &rt) != 0) { fprintf(stderr, "%s\n", tachi_last_error()); return 1; }

char *info;
tachi_restore(rt, &info);                                            /* reload earlier installs */
tachi_free(info);
tachi_repo_install(rt, NULL, "eu.kanade.tachiyomi.extension.en.weebcentral", &info); /* ExtensionInfo JSON */
tachi_free(info);

char *page;
tachi_call(rt, 2131019126180322627LL, "popular", "{\"page\":1}", &page);  /* MangasPage JSON */
tachi_free(page);

tachi_runtime_free(rt);
```

Link against `zig-out/lib/libtachi.a` (or the shared library) plus `libc`;
`libjvm` is loaded at runtime from `$JAVA_HOME` or a well-known install dir.

## Layout

| Path | What |
|---|---|
| `src/tachi.zig` | Public Zig API (`Runtime`, typed results) |
| `src/repo.zig` | repository index client: `index.pb` decoding, HTTP, signer check |
| `src/manage.zig` | install registry, `restore`, repo install/update |
| `src/jvm.zig` | libjvm discovery, JVM creation/adoption, thread attach |
| `src/jni.zig` | JNI function tables, generated from `jni.h` by `tools/gen_jni.py` |
| `src/capi.zig`, `include/tachi.h` | C ABI |
| `src/main.zig` | `tachi-cli` |
| `host/` | Kotlin host runtime (Gradle project) → `tachi-host.jar` |
| `host/src/main/kotlin/eu/kanade/tachiyomi/` | extensions-lib 1.6 implementation (ported from Mihon, Apache-2.0) |
| `host/src/main/java/android*`  | Android compatibility classes |
| `host/src/main/kotlin/dev/tachi/host/` | loader, JSON bridge, DI wiring |

## Licensing of ported code

`host/src/main/kotlin/eu/kanade/tachiyomi/**` is adapted from
[Mihon](https://github.com/mihonapp/mihon) (Apache-2.0). The Android
compatibility classes re-implement AOSP APIs (Apache-2.0). The loader design
follows Suwayomi-Server (MPL-2.0) and Mihon, but the code is original. See
`NOTICE`.
