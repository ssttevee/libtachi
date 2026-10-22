# zig-tachi

zig-tachi lets desktop applications use [Mihon](https://mihon.app) / Tachiyomi
extensions to browse manga sources, search for titles, list chapters, and fetch
page images. You can call it from Zig or any language that can use a C API.
It runs on macOS and Linux without an Android device or a separate web server.

An **extension** is a plugin that knows how to read one or more manga websites.
Each website exposed by an extension is called a **source**. Extensions are
written for Android, so zig-tachi supplies the Android APIs they need and runs
their code in a Java Virtual Machine (JVM).

## Choose a library

The project provides two libraries built on the same extension runtime:

| Library | What it provides | What your application provides |
|---|---|---|
| `libtachicore` | Extension loading, source calls, repository index parsing, and image requests | Package acquisition, installation records, library storage, and download management |
| `libtachi` | The core plus extension installation, a library database, reading progress, download queues, backups, and tracking | The user interface and application integration |

Choose `libtachicore` if you want to build your own storage and download system.
Choose `libtachi` if its library and download management fit your application.

For Zig, import the `tachicore` or `tachi` module. For C and language bindings,
use `tachicore.h` or `tachi.h` and link the corresponding library.

## How it works

The default runtime starts a JVM inside your application's process:

```text
Your application
  └─ libtachicore, directly or through libtachi
       └─ JVM
            └─ tachi-host.jar: extension loader and Android compatibility APIs
                 └─ extension .jar or .apk files
```

The native library talks to Java through JNI, Java's native interface. The C
API passes source requests and results as JSON; the Zig API also offers typed
results. The host uses an extension's own HTTP client when its cookies,
headers, or image interceptors are needed.

`libtachi` can also run extensions in a helper process. This lets an application
stop extension code that does not cooperate with cancellation. See
[engine backends and cancellation](docs/ENGINE.md).

## Build

You need:

- **Zig 0.17.0**. Set `Z` below to that executable if your default `zig` is a
  different version.
- **JDK 17 or newer**, both to build the Java host and to run extensions.
- **An Android API jar (`android.jar`)** to build the host. The build finds it
  through `ANDROID_HOME` or `~/Library/Android/sdk`. If you do not have an
  Android SDK, run `host/scripts/get-android-jar.sh` and add
  `-Dandroid-jar=host/lib/android.jar` to the build command.

From the repository root:

```sh
Z=/path/to/zig-0.17.0/zig
$Z build
```

This builds both libraries and the command-line application:

| Output | Location |
|---|---|
| Static and shared libraries | `zig-out/lib/` |
| C headers | `zig-out/include/` |
| Java host | `zig-out/lib/tachi-host.jar` |
| Command-line application | `zig-out/bin/tachi-cli` |

To build only the independent core, without SQLite or the CLI:

```sh
$Z build core -Dcore-only --prefix zig-out/core
```

The host is built with Gradle and cached between builds. To use a prebuilt host
jar, pass `-Dhost-jar=/path/to/tachi-host.jar`; this skips Gradle and the Android
API jar requirement. To embed the host jar in the native binaries, pass
`-Dembed-host-jar`. Embedding removes the need to ship a separate host jar;
a JDK is required at runtime either way.

## Try the command-line application

The CLI uses `libtachi` to find, install, and call extensions. This example
browses the default Keiyoushi extension repository:

```sh
CLI=./zig-out/bin/tachi-cli

# Find English extensions whose names contain "weeb".
$CLI repo list --lang en --grep weeb

# Install a package using its package name from that list.
$CLI repo install eu.kanade.tachiyomi.extension.en.weebcentral
```

The installation result includes the extension's sources. Each source has a
numeric `id`; use that ID for source commands:

```sh
SOURCE_ID=2131019126180322627 # example: use the ID returned by your installation
$CLI popular "$SOURCE_ID"
$CLI search "$SOURCE_ID" "one piece"
```

Use a title's URL from those results to list its chapters, then a chapter's URL
to list its pages:

```sh
$CLI chapters "$SOURCE_ID" '/series/url-from-search-results'
$CLI pages "$SOURCE_ID" '/chapter/url-from-chapter-results'
```

Installed extensions load automatically on each run. `repo update` updates
them, and `uninstall PACKAGE_NAME` removes one. You can also use `install FILE`
to install a local extension or `--ext FILE` to load one for a single run.

The CLI stores its data in `./.tachi-data` by default. Use `--data-dir` to
choose another directory.

## Use the core from Zig

This example loads a package your application has already acquired and asks
its first source for popular titles. It belongs inside your application's
setup code; `gpa` is your allocator and `init` is the `std.process.Init` passed
to `main`.

```zig
const std = @import("std");
const core = @import("tachicore");

// Inside main or an application setup function:
const rt = try core.Runtime.init(gpa, init.io, .{
    .data_dir = "/path/to/extension-sandbox",
    .host_jar = "/path/to/tachi-host.jar",
    .environ = init.minimal.environ,
});
defer rt.deinit();

const extension = try rt.loadPackageParsed("/path/to/extension.jar");
defer extension.deinit();
if (extension.value().sources.len == 0) return error.NoSources;
const source_id = try extension.value().sources[0].idInt();

const popular = try rt.browse(source_id, 1, .popular);
defer popular.deinit();
for (popular.value().mangas) |manga| {
    std.debug.print("{s}\n", .{manga.title});
}
```

The runtime uses the supplied `std.Io` for native I/O and cancellation. Decoded
results own their memory until `deinit()`. If calls run concurrently, the
allocator and I/O implementation must support concurrency.

The core needs a sandbox directory for extension preferences, cookies, class
loading, and JVM caches. Your application owns package files and decides how
to save library data and downloaded pages.

See [the core guide](docs/CORE.md) for dependency setup, repository parsing,
image retrieval, cancellation, and a C example. For a managed application,
start with [the engine guide](docs/ENGINE.md). C callers use the JSON methods
in [the API reference](docs/API.md); returned allocations must be released
with the matching library's free function.

## Supported extensions and limits

The runtime supports **extensions-lib 1.6** on macOS and Linux with HotSpot
JDK 17 or newer. It loads Keiyoushi `.jar` builds directly and converts `.apk`
builds through dex2jar.

Supported source operations include popular and latest titles, search and
filters, title details, related titles, chapters, pages, image retrieval,
browser URLs, and source preferences. The Android compatibility layer includes
preferences, cookies, URI handling, logging, and other APIs used by extensions.

These features are not supported:

- Sources that require a WebView, including Cloudflare challenges and
  JavaScript-rendered pages. Hooks are available for applications to supply a
  challenge solver or JavaScript engine.
- Image descrambling that depends on `android.graphics.Bitmap`.
- Extensions-lib 1.4/1.5, which use RxJava.
- iOS, where this JVM-based runtime is unavailable.

See [Mihon feature coverage](docs/PARITY.md) and
[the design and roadmap](docs/DESIGN.md) for more detail.

## Data and backups

`libtachi` stores library metadata, reading progress, settings, and download
queue state in `tachi.sqlite3` under `Engine.Options.dir`. SQLite is bundled;
applications do not need a system SQLite library. Images, extension packages,
registries, and host preferences use ordinary files. `libtachicore` does not
create this database or manage a chapter store.

For a filesystem backup, close the engine and copy its data directory,
including any SQLite recovery journal. File operations on other disks are
outside database transactions. The engine also supports Mihon backup
import/export.

When opening data from a JSON-based installation, `libtachi` validates and
imports it into SQLite on first use. Successful imports are recorded so they
do not overwrite later database edits. Original JSON files are kept as
migration backups; they do not receive subsequent database changes. Invalid
imports roll back and report an error. Newer database schema versions are
rejected rather than reset.

## Tests

```sh
$Z build test                       # unit tests and standalone Zig/C core consumers
$Z build test-core -Dcore-only       # core tests without the managed library
$Z build test-core-jvm -Dcore-only   # core integration test with a real JVM
$Z build test-jvm                    # cancellation, concurrency, and worker integration
```

The JVM integration tests need the host jar and a JDK. Unit tests do not build
the host unless `-Dembed-host-jar` is enabled.

## Find your way around

| Start here | For |
|---|---|
| [Core guide](docs/CORE.md) | Building an application with its own storage and downloads |
| [Engine guide](docs/ENGINE.md) | Using `libtachi` jobs, library management, and downloads |
| [API reference](docs/API.md) | Source methods, JSON requests, and result schemas |
| [Feature coverage](docs/PARITY.md) | Comparing the engine with Mihon |
| [Design](docs/DESIGN.md) | Architecture and implementation decisions |
| `src/core.zig`, `include/tachicore.h` | Core Zig and C interfaces |
| `src/tachi.zig`, `include/tachi.h` | Managed Zig and C interfaces |
| `src/engine.zig` | Application jobs and actions |
| `host/` | Java/Kotlin host and Android compatibility layer |

## Licensing of ported code

`host/src/main/kotlin/eu/kanade/tachiyomi/**` is adapted from
[Mihon](https://github.com/mihonapp/mihon) (Apache-2.0). The Android
compatibility classes re-implement AOSP APIs (Apache-2.0). The loader design
follows [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) (MPL-2.0)
and Mihon, but the code is original. See [NOTICE](NOTICE).
