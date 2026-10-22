# Independent extension core

`libtachicore` is the extension interface for applications that provide their own
library, storage and download management. Its Zig module is `tachicore`; its C
header is `tachicore.h`. `libtachi` consumes this same module and adds the turnkey
engine, SQLite persistence, package registry, repository acquisition, workers,
download queues, backups and tracking.

## Build

Use the project's Zig 0.17 toolchain:

```sh
Z=/path/to/zig-0.17/zig
$Z build core -Dcore-only --prefix zig-out/core
$Z build test-core -Dcore-only
$Z build test-core-jvm -Dcore-only
```

The installation contains `lib/libtachicore.a`, the shared library
(`libtachicore.so` or `libtachicore.dylib`), `include/tachicore.h`, and
`lib/tachi-host.jar`. `-Dcore-only` excludes the turnkey module, CLI and SQLite
from build configuration and dependency resolution. A normal `zig build`
installs both libraries. `-Dhost-jar=PATH` uses a prebuilt host jar;
`-Dembed-host-jar` embeds it instead of installing a sidecar. Building the host
requires the same JDK and Android API jar as the turnkey build; using a prebuilt
host avoids that Gradle build. Running extension code requires a JVM.

A separate Zig package can consume only the core:

```zig
const dep = b.dependency("zig_tachi", .{
    .target = target,
    .optimize = optimize,
    .@"core-only" = true,
});
exe.root_module.addImport("tachicore", dep.module("tachicore"));
```

No SQLite, worker shim or database API is attached to that module. Deploy the
host jar and pass its path to `Runtime.init`, or enable host embedding on the
dependency. The standalone consumer tests exercise both the Zig module and the
C library without linking `libtachi`.

## Responsibilities

The core provides:

- JVM/host initialization, caller-supplied `std.Io`, logging, diagnostics and
  cooperative operation cancellation.
- Loading and unloading integrator-owned extension files, lazy registration
  from saved `ExtensionInfo`, and enumeration of registered extensions/sources.
- Source calls, filters/preferences, related titles, chapter/page lists and
  image request plans. When a source must execute its HTTP client or image
  interceptor, `fetchImage` returns bytes and MIME metadata to the caller.
- Decoding protobuf/JSON repository indexes, external extension lists, legacy
  repository metadata/lists, and certificate fingerprints from supplied bytes.

The integrator chooses repository acquisition, redirects and cache policy;
package downloading, signature trust and file placement; installation records
and startup registration; library/database layout; download scheduling,
retries, rate limiting, progress and saved page storage. Discovery parsers do
no network or filesystem I/O. Follow `extension_list_url`/`index_v2` using the
integrator's HTTP client, then supply the resulting bytes to the appropriate
parser. `parseLegacyList` takes the repository base URL for package/icon URLs.

`Runtime.Options.data_dir` is required as a host sandbox: extensions use
Android preferences, cookies and file APIs, and APK conversion/class loading
and optional JVM caches need files. The integrator selects and owns this
location. The core creates no installation registry, SQLite database, chapter
store or download queue. `loadPackage` does not copy/delete the supplied package
or remember it across processes; the JVM may create a class-loading copy or
convert an APK inside its sandbox. Keep package files available for lazy loads
and let the runtime finish all calls before unloading/destroying it.

## Zig interface

```zig
const core = @import("tachicore");

// Acquisition and storage of these bytes are the application's responsibility.
const index = try core.discovery.parseIndex(arena, supplied_index_bytes);
for (index.extensions) |extension| {
    // Present/filter entries, choose a package, and acquire/verify its file.
    _ = extension;
}

const rt = try core.Runtime.init(gpa, io, .{
    .data_dir = extension_sandbox,
    .host_jar = host_jar_path,
    .environ = environ,
});
defer rt.deinit();
const extension = try rt.loadPackageParsed(owned_package_path);
defer extension.deinit();
const source = try extension.value().sources[0].idInt();
const result = try rt.browse(source, 1, .{ .search = .{ .query = "Example" } });
defer result.deinit();
```

The core and `libtachi` share model types and JSON schemas; see [API.md](API.md).
Decoded runtime results own their arenas until `deinit`; discovery results
belong to the allocator passed to the parser. Raw JSON buffers belong to
`rt.gpa`. `Image.deinit(gpa)` releases its image bytes and optional MIME string.
The allocator must support concurrent allocations when calls overlap.

For chapter pages, obtain `rt.imageRequests(source, chapter)`. The integrator
handles eligible native requests, headers, cookies, rate rules, redirects,
retries and persistence. Requests marked for fallback require the source's
client/interceptors; use `rt.fetchImage` and save its returned bytes yourself.
`Runtime.restoreImageCookies` restores planned cookies when starting a new
host. These operations neither enqueue a chapter nor mark one downloaded.

Calls use the supplied `std.Io` just as in the turnkey runtime. Cancel an
individual `Io.concurrent` future and join it before releasing borrowed
inputs. In-process cancellation requires foreign code to cooperate. The core
does not choose a worker-process or task scheduling policy for the application.

## C interface

Include `tachicore.h` and link only `libtachicore`. The `tachicore_*` symbols
are independent of the `tachi_*` API; both headers can be included
together. Their runtime handles are distinct types and must not be cast between
frontends. Use one runtime frontend to own a JVM.

```c
#include <tachicore.h>

char *index_json = NULL;
int status = tachicore_parse_index(bytes, len, &index_json);
if (status == TACHICORE_OK) {
    /* Present entries and acquire a package using application policy. */
    tachicore_free(index_json);
}

tachicore_config config = {0};
config.data_dir = extension_sandbox;
config.host_jar = host_jar_path;
tachicore_runtime *runtime = NULL;
status = tachicore_runtime_new(&config, &runtime);
if (status == TACHICORE_OK) {
    char *extension_json = NULL;
    status = tachicore_load(runtime, owned_package_path, &extension_json);
    if (status == TACHICORE_OK) tachicore_free(extension_json);
    tachicore_runtime_free(runtime);
}
```

`tachicore_call` uses the source method/JSON schemas in [API.md](API.md),
including `imageRequests`. `tachicore_fetch_image` returns image bytes without
saving a page. Free all returned JSON, image and MIME allocations with
`tachicore_free`. `tachicore_last_error` is borrowed and thread-local.
`tachicore_cancel_requests` is source-wide HTTP cancellation; per-operation
`std.Io` cancellation is exposed by the Zig API.

## Managed integration with libtachi

`libtachi` provides package installation, persistent registration, library
storage and download management through `tachi.Runtime`, `tachi.Engine`, the
CLI and `tachi.h`. Runtime source methods delegate to `tachicore.Runtime`.
`installExtension`, `restore`, `repoInstall` and `repoUpdate` belong to the
managed adapter, which owns the registry mutex and package policy.

Zig integrations can access the underlying core runtime through
`tachi.Runtime.core` and its JVM through `rt.core.vm`.

Choose `tachicore` when the integrator owns its data model and download system.
Choose `tachi` when its engine and management policies fit.
