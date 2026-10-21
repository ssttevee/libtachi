# Design

## Goal

A portable library that runs Mihon/Tachiyomi extensions inside a host
application's process, exposed through a C ABI (and a Zig module), so that
desktop or server apps written in Zig, C, Swift, Rust, etc. can browse manga
sources without an Android device and without running a separate web server.

## What an extension actually is

An extension is an Android APK compiled against
[extensions-lib](https://github.com/keiyoushi/extensions-lib) (currently
version 1.6). It contains:

- Kotlin classes compiled to Dalvik bytecode (`classes.dex`) implementing
  `eu.kanade.tachiyomi.source.Source` / `HttpSource`.
- An `AndroidManifest.xml` whose `<meta-data>` names the main class
  (`tachiyomi.extension.class`) and the lib version (`tachiyomix.extensionLib`).
- Nothing else of substance: OkHttp, Jsoup, kotlinx.serialization, coroutines
  and the extensions-lib API are all `compileOnly`, provided by the host app.

The extensions-lib artifact is **stubs only** (every method throws
`"Stub!"`). The real implementations live in Mihon. So to host extensions one
needs: a JVM, the third-party libraries at matching versions, an
implementation of the `eu.kanade.tachiyomi.*` API, and enough of `android.*`
for the bytecode to link and the handful of Android calls extensions make.

Since mid-2025 the Keiyoushi repository also publishes a **`.jar`** per
extension (JVM bytecode, plain-text manifest) alongside each `.apk` — field
`501` of `index.pb`. That removes the dex→class conversion from the hot path;
dex2jar is kept as a fallback for APK-only repositories.

## Prior art

| | Suwayomi-Server | PatchBukkit | zig-tachi |
|---|---|---|---|
| Problem | Run Tachiyomi extensions on a desktop JVM, serve a web/GraphQL API | Run Bukkit (Java) plugins inside Pumpkin, a Rust Minecraft server | Run Tachiyomi extensions inside any native app |
| JVM | Is the JVM (Kotlin app) | Embeds HotSpot from Rust via the JNI Invocation API (`jni` crate) | Embeds HotSpot from Zig via the JNI Invocation API (generated bindings) |
| Native↔JVM data | n/a | Protobuf over FFM/JNI | JSON over JNI `byte[]` |
| Android layer | `AndroidCompat` module + stripped `android.jar` | n/a | Same approach, trimmed to what a scan of 79 extensions showed is used |
| dex | dex2jar at install time | n/a | Prefer upstream `.jar`; dex2jar fallback |

Suwayomi proves the android-compat strategy across 1400+ extensions;
PatchBukkit proves embedding a JVM behind a native plugin API is practical.
zig-tachi combines the two.

## Architecture

```
native process
├── libtachi (Zig)
│   ├── jvm.zig    find libjvm, JNI_CreateJavaVM, attach threads (or adopt an existing JavaVM*)
│   ├── jni.zig    JNINativeInterface / JNIInvokeInterface tables generated from jni.h
│   ├── tachi.zig  Runtime: caches jclass/jmethodIDs, marshals JSON <-> byte[], error envelope
│   └── capi.zig   C ABI (tachi.h)
└── JVM (HotSpot via dlopen, or the app's ART on Android)
    └── tachi-host.jar
        ├── dev.tachi.host.Bridge           static entry points, never throw, JSON envelope
        ├── dev.tachi.host.ExtensionLoader  manifest parsing, URLClassLoader per extension, dex2jar
        ├── dev.tachi.host.SourceCalls      method dispatch, filter/preference marshalling, runBlocking
        ├── eu.kanade.tachiyomi.*           extensions-lib 1.6 implementation (from Mihon)
        ├── android.*, androidx.preference.*   compat classes (ours)
        ├── android-stubs.jar               android.jar minus java/javax/org and minus our classes
        └── okhttp 5, jsoup, kotlinx.*, injekt, dex2jar, apk-parser
            └── <extension>.jar             loaded at runtime, one class loader each
```

### Why JSON over JNI (not protobuf, not typed JNI)

The data volume is tiny (a page of 20–50 manga, a chapter list) and the
schema evolves with extensions-lib. JSON keeps the Zig side free of
generated code, lets the C API stay at "strings in, strings out", and the
Kotlin side uses kotlinx.serialization, which is already on the classpath
for extensions. Strings cross as UTF-8 `byte[]` rather than `jstring` to
avoid JNI's modified-UTF-8 (which mangles emoji in titles).

Image bytes are the one large payload; they cross as a raw `byte[]`.

### Why a per-extension `URLClassLoader` with the host as parent

Extensions only contain their own classes (plus keiyoushi's bundled helper
libs under shaded names), so parent-first delegation is correct and simpler
than Suwayomi's child-first loader. Unloading an extension closes its loader.

### Android compatibility layer

A scan of 79 extension jars (constant-pool class/method references) gave the
surface that matters. Classes we implement for real (they replace the stub
versions, which the Gradle build strips from `android-stubs.jar`):

| Class | Used by (of 79) | Notes |
|---|---|---|
| `android.net.Uri` | 79 | lenient parser + Builder, `encode`/`decode` with Android semantics |
| `android.app.Application` / `Context` / `ContextWrapper` | 58 | dirs + `getSharedPreferences` |
| `android.util.Log` | 54 | routed to the native log callback |
| `android.util.Base64` | 31 | Android flag semantics on top of `java.util.Base64` |
| `android.content.SharedPreferences` (impl) | 24 | JSON file per name, typed values, listeners |
| `android.os.SystemClock` | 24 | |
| `androidx.preference.*` | 22 | Preference tree captured for the host app's settings UI |
| `android.os.Build` | 7 | reports API 30 |
| `android.os.Handler` / `Looper` | 7 | single background "main" thread |
| `android.webkit.CookieManager` | 5 | shares the OkHttp cookie jar |
| `android.widget.Toast` | 2 | logged |

Everything else (`Activity`, `Intent`, `Bundle`, `WebView`, `Bitmap`, …)
stays a stub that throws `RuntimeException("Stub!")` if actually called.
Extensions reference `Activity`/`Intent` only from their deep-link
`UrlActivity`, which is never instantiated here.

### extensions-lib 1.6 only

The scan found zero references to RxJava: 1.6 extensions implement the
`suspend` API directly. The Keiyoushi repo ships only 1.6 builds. So the
host implements exactly the 1.6 surface (plus Mihon's harmless extras such as
`HttpSource.getImage`). Supporting 1.4/1.5 would mean adding RxJava and the
`fetch*`/`ParsedHttpSource` helpers; it is straightforward but not needed yet.

### Threading

HotSpot is thread-safe through JNI. `Runtime` accepts the embedder's `std.Io`
and uses `Io.concurrent` to execute JNI bodies, with an `Io.Event` as the
caller's cancellation point. Native execution threads attach as daemons and
detach after each operation. Extension `suspend` functions use `runBlocking`
with `Dispatchers.IO` and a parent coroutine job registered under a unique
operation ID before execution starts.

Canceling the caller's I/O task cancels that operation's coroutine job and
its tracked HTTP calls, including calls whose response headers have already
arrived. The native caller joins execution before returning `error.Canceled`;
borrowed arguments and the runtime remain alive until Java has unwound. A
successful result racing cancellation is released instead of returned.
Image bytes, MIME metadata and diagnostics are collected on their execution
thread and transferred back to the caller together.

This is cooperative in-process cancellation. Java code that does not suspend,
check its coroutine job or unblock when its HTTP call is canceled can delay
completion indefinitely. JVM creation and arbitrary class loading cannot be
forcibly interrupted through `std.Io`. The worker backend provides the stronger
boundary: cancellation of its socket wait terminates the active worker, and
its next call starts another. Canceling a call waiting for the worker lock
leaves the active call alone.

`Runtime.supportsCancellation()` reports whether the host implements the full
operation lifecycle. Older host jars remain usable with synchronous JNI
execution and a warning through the configured log callback. The supplied
I/O implementation must support concurrency for the new bridge;
`error.ConcurrencyUnavailable` reports when it cannot. Runtime destruction
requires all calls to have finished.

### Error model

Normal bridge replies are `{"ok":…}` or
`{"error":{type,message,stack}}`; the Zig layer converts that to
`error.ExtensionError` + `tachi.lastError()`, and the C API to
`TACHI_E_EXTENSION_ERROR` + `tachi_last_error()`. Operation registration returns
a primitive ID so native allocation failure cannot lose an already registered
operation. An exception that does
escape (bridge bug) is caught by `ExceptionCheck`, described via
`Throwable.toString()`, and surfaced as `error.JavaException`.

## Portability

| Target | Status | Notes |
|---|---|---|
| macOS, Linux (x86_64/aarch64) | works | needs a JDK 17+ at runtime; bundle a `jlink` image (~40 MB) for distribution |
| Windows | should work | `jvm.dll` lookup is implemented but untested |
| Android | designed, untested | `Options.existing_vm` adopts the app's `JavaVM*`; the host classes must be in the app's dex, and the compat layer is replaced by the real framework |
| iOS | not possible with this design | no JIT/JVM. The only route is a Dalvik/JVM interpreter in Zig with a class library, which is a separate, much larger project; the C API is designed so such a backend could be swapped in |

## Roadmap

1. **Cloudflare**: `TachiRuntime.cloudflareSolver` is a hook; wire it to a
   native callback so a host app with a real browser/WebView can solve
   challenges, as Mihon does with Android's WebView.
2. **JavaScript engine**: `TachiRuntime.jsEngine` hook; ship an optional
   QuickJS (via Zig, exposed through JNI) or GraalJS jar on `extra_classpath`.
3. **`android.graphics.Bitmap`** on `java.awt.image.BufferedImage` for the
   ~10% of sources that descramble images in an OkHttp interceptor (Suwayomi
   has an implementation to port).
4. **Streaming images** (`fetchImage` currently buffers the whole body).
5. ~~Repo index client~~: done in Zig (`src/repo.zig`, `src/manage.zig`);
   the JVM stays a pure extension interface. Still open: verifying the JAR
   signature over every entry (today only the signer's certificate hash is
   checked, over HTTPS), APK v2/v3 signing-block parsing, and icon download.
6. **Async API**: optional callback-based variants so hosts need not manage
   threads themselves.
7. extensions-lib 1.4/1.5 if a repository that still ships them matters.
8. Slim the host jar (dex2jar + stubs account for most of its 40 MB). It
   is embedded with `-Dembed-host-jar` and extracted to the cache dir once, so
   the size costs disk and binary size, not start-up time; the CDS archive
   keyed by the jar hash (`tachi-host-<hash>.jsa`) is what makes start-up
   fast.

## Testing

- `zig build test` — pure-Zig unit tests (envelope decoding).
- Live checks performed during development: the full
  popular → details → chapters → pages → image → search → filters pipeline on
  Weeb Central, and loading all 79 jars of a random sample of the Keiyoushi
  index (79/79 load and instantiate their sources).
