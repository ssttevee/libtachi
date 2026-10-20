# Bridge API

Everything crosses the native/JVM boundary as UTF-8 JSON. The Zig API
(`tachi.Runtime`) and the C API (`tachi.h`) are thin wrappers over the same
five entry points; `tachi.models` mirrors the documents below.

Every reply from the host is an envelope:

```json
{"ok": <result>}
{"error": {"type": "java.io.IOException", "message": "…", "stack": "…"}}
```

The wrappers unwrap it: Zig returns the `ok` payload (or `error.ExtensionError`
with `tachi.lastError()`), C returns the payload through `out_json` (or
`TACHI_E_EXTENSION_ERROR` with `tachi_last_error()`).

Source ids are 63-bit integers. They are **strings** in JSON (`"id": "2131…"`)
so JavaScript consumers do not lose precision, and `int64_t` in the C API.

## Extensions

| Call | Args | Result |
|---|---|---|
| `install(path)` | path to `.jar` or `.apk` | `ExtensionInfo` |
| `register(entry)` | `{"path", "info": ExtensionInfo}` from an earlier `install` | `ExtensionInfo`; loads on first use |
| `uninstall(pkg)` | package name | `true`/`false` |
| `extensionToLoad(sourceId)` | source id | name of its registered, not yet loaded extension; `""` once loaded |
| `loadSource(sourceId)` | source id | `true` after loading its extension, so the load can be reported on its own |
| `listExtensions()` | | `ExtensionInfo[]` |

```json
ExtensionInfo {
  "pkg": "eu.kanade.tachiyomi.extension.en.weebcentral",
  "name": "Weeb Central", "versionName": "1.6.25", "versionCode": 106025,
  "libVersion": "1.6", "nsfw": true, "lang": "en", "path": "/…/x.jar",
  "sources": [ SourceInfo ],
  "sourceClasses": [ "keiyoushi.source.Generated" ]   // as the manifest declares them
}
SourceInfo {
  "id": "2131019126180322627", "name": "Weeb Central", "lang": "en",
  "baseUrl": "https://weebcentral.com", "supportsLatest": true,
  "isConfigurable": false, "supportsRelatedMangas": true,
  "className": "keiyoushi.source.Generated", "extensionPkg": "…"
}
```

`install` and `register` are the only ways a package enters the JVM. The
Zig/C layers wrap them with a registry so installs survive the process; see
below. A registered package is listed with its recorded sources, but its
classes load, and its sources are created, only when one of them is first
called. Classes from a signed jar load from an unsigned copy in
`<cacheDir>/extensions`: the signatures attach no permissions here, and
checking a digest per class is slow on JVMs without a JIT.

## Management (native side)

Everything in this section is implemented in Zig on `std.Io` and never
crosses into the JVM except to call `install`/`uninstall` above. It is
exposed as `Runtime.installExtension/uninstallExtension/restore/repo*` in
Zig and as `tachi_install/tachi_uninstall/tachi_restore/tachi_repo_*` in C.

| Call | Does |
|---|---|
| `installExtension(path)` | `install` + records the package in `<data_dir>/extensions/installed.json` |
| `uninstallExtension(pkg)` | `uninstall` + forgets it; deletes the file if it was downloaded from a repo |
| `restore()` | `register`s every recorded package; `{"loaded": n, "failed": [{"pkg", "error"}]}`. Entries from before `info` was recorded load now, and their info is saved |
| `repoList(url?)` | `RepoEntry[]`: the index joined with the registry |
| `repoInstall(pkg, url?)` | download, verify signer, `install`, record |
| `repoUpdate(url?)` | `{"updated": ExtensionInfo[], "failed": [{"pkg","error"}], "missing": [pkg]}` |

```json
RepoEntry {
  "pkg": "eu.kanade.tachiyomi.extension.en.weebcentral", "name": "Weeb Central",
  "versionName": "1.6.25", "versionCode": 106025, "libVersion": "1.6",
  "nsfw": true, "lang": "en",
  "jarUrl": "https://…/tachiyomi-en.weebcentral-v1.6.25.jar", "apkUrl": "https://…", "iconUrl": "https://…",
  "supported": true,                 // libVersion is one the host implements
  "installed": true, "installedVersionCode": 106025, "hasUpdate": false,
  "sources": [ { "id": "2131019126180322627", "name": "Weeb Central", "lang": "en", "baseUrl": "https://weebcentral.com" } ]
}
```

The index is Mihon's `index.pb` (gzip protobuf; `index.min.json` is no
longer produced by keiyoushi). It is cached under `<data_dir>/repo/` for an
hour. Packages are stored as `<data_dir>/extensions/<pkg>-<versionCode>.jar`;
the jar URL is preferred over the apk so dex2jar is never needed for
keiyoushi. Before a download is loaded, the SHA-256 of the certificate in its
`META-INF/*.RSA` block must equal the index's `signing_key` (the check Mihon
makes on APK signatures). Packages without a v1 signature block are rejected;
keiyoushi APKs are v2/v3-only, which is one more reason to prefer the jar.

## `call(sourceId, method, args)`

| method | args | result |
|---|---|---|
| `info` | | `SourceInfo` |
| `popular` | `{"page": 1}` | `MangasPage` |
| `latest` | `{"page": 1}` | `MangasPage` |
| `search` | `{"page": 1, "query": "…", "filters": Filter[]?}` | `MangasPage` |
| `update` | `{"manga": Manga, "chapters": Chapter[]?, "fetchDetails": true, "fetchChapters": true}` | `{"manga": Manga, "chapters": Chapter[]}` |
| `details` | `{"manga": Manga}` | `Manga` |
| `chapters` | `{"manga": Manga}` | `Chapter[]` |
| `pages` | `{"chapter": Chapter}` | `Page[]` |
| `imageUrl` | `{"page": Page}` | `"https://…"` |
| `related` | `{"manga": Manga}` | `Manga[]` |
| `mangaUrl` | `{"manga": Manga}` | `"https://…"` (browser URL) |
| `chapterUrl` | `{"chapter": Chapter}` | `"https://…"` |
| `filters` | | `Filter[]` (fresh defaults) |
| `preferences` | | `Preference[]` |
| `setPreference` | `{"key": "…", "value": <json>}` | `Preference[]` (after change) |

For `details`/`chapters`/`pages` only the `url` of the input object is
normally needed (plus `title`/`name`, which may be empty), but pass back the
whole object you received: some sources stash state in `memo`.

`update` is the extensions-lib 1.6 primitive the others are built on; use it
when you want details and chapters in one round trip. Sources whose details
and chapters come from the same page then fetch and parse it once.

As in Mihon, `details` and `update` keep the input manga's `url` when the
source's parsed details leave it unset, and its `title` when the parsed one
is blank; many `mangaDetailsParse` implementations rely on this.

The host bundles jsoup with one change: `StringUtil.stripControlChars`, which
runs on every resolved link, is a loop rather than a regex replace that
matches at every position. On JVMs without a JIT it dominated parsing
link-heavy pages. `./gradlew testHostCompat` checks it against the regex.

### Documents

```json
Manga {
  "url": "/series/…", "title": "…", "thumbnailUrl": "…", "artist": "…", "author": "…",
  "status": 1,                      // 0 unknown 1 ongoing 2 completed 3 licensed 4 publishing_finished 5 cancelled 6 on_hiatus
  "description": "…", "genre": "a, b, c",
  "updateStrategy": "ALWAYS_UPDATE" | "ONLY_FETCH_ONCE",
  "initialized": true, "memo": {…}?
}
Chapter { "url": "…", "name": "…", "chapterNumber": 12.5, "scanlator": "…"?, "dateUpload": 1700000000000, "memo": {…}? }
Page    { "index": 0, "url": "…", "imageUrl": "…"? }
MangasPage { "mangas": Manga[], "hasNextPage": true }
```

### Filters

`filters` returns the source's filter tree with default states. To search
with filters, send the same list back (same order) with `state` edited:

```json
{"type": "header",    "name": "…"}
{"type": "separator", "name": ""}
{"type": "select",    "name": "Sort", "values": ["A", "B"], "state": 0}
{"type": "text",      "name": "Author", "state": ""}
{"type": "checkbox",  "name": "Completed", "state": false}
{"type": "tristate",  "name": "Action", "state": 0}          // 0 ignore 1 include 2 exclude
{"type": "sort",      "name": "Order", "values": ["Views"], "state": {"index": 0, "ascending": false} | null}
{"type": "group",     "name": "Genres", "filters": [ … ]}
```

### Preferences

```json
{
  "type": "switch" | "checkbox" | "list" | "multiselect" | "edittext" | "category" | "other",
  "key": "…", "title": "…", "summary": "…",
  "defaultValue": <json>, "value": <json>,          // current persisted value
  "entries": ["Label"], "entryValues": ["value"],   // list / multiselect
  "dialogTitle": "…", "dialogMessage": "…",
  "enabled": true, "visible": true
}
```

`setPreference` runs the preference's change listener first (as Android
does) and only persists if it accepts. Values: boolean for switch/checkbox,
string for list/edittext, string array for multiselect.

## `fetchImage(sourceId, page)`

Downloads `page.imageUrl` (resolving it through the source's `getImageUrl`
first when absent) using the source's own OkHttp client, so Referer headers,
cookies, rate limiters and image-descrambling interceptors apply. Returns raw
bytes plus the `Content-Type`.

## Runtime configuration

`Runtime.init` / `tachi_config` → Kotlin `RuntimeConfig`:

| field | default | notes |
|---|---|---|
| `dataDir` | required | prefs, cookies, converted APKs |
| `cacheDir` | `<dataDir>/cache` | OkHttp cache, dex2jar output, unsigned class jars |
| `userAgent` | Chrome on Android | `NetworkHelper.defaultUserAgentProvider()` |
| `appVersionName` / `appVersionCode` | `0.20.1` / `137` | `eu.kanade.tachiyomi.AppInfo` |
| `packageName` | `app.mihon` | `Context.getPackageName()` |
| `verbose` | false | debug logs + HTTP header logging |
| `nativeTransport` | false | set by the native side when `Options.native_transport` registered `NativeTransport` |

## Logging

`android.util.Log` → `dev.tachi.host.TachiLog` → (if a `log_fn` was given)
the native callback, called from whatever JVM thread logged. Levels follow
Android: 2 verbose … 7 assert.

Every OkHttp call made through the host's clients logs one info line, tag
`http`: `GET host/path dns_ms= connect_ms= tls_ms= headers_ms= total_ms=`,
with ` failed=Exception` when it fails.

## Native transport

`Options.native_transport` (`tachi_config.native_transport` in C) sends the
host clients' sockets through Zig (`src/transport.zig`): OkHttp keeps DNS,
routing, cookies, redirects, interceptors and HTTP/1.1, and only the bytes,
and TLS, are native. `std.crypto.tls` verifies the peer and host name against
`ca_file` (the system roots when null). On JVMs without a JIT, Java's TLS is
interpreted: loading the trust store and one handshake take seconds each.

Handshakes run on a Zig thread with a 1 MiB stack, since a JVM thread may
have little left. Peer certificates stay native, so sessions report none:
the OkHttp disk cache, which records them, is off in this mode, and pinned
hosts (`CertificatePinner`) fail. A client that installs its own
`SSLSocketFactory` still gets Java TLS over the native socket. The 1.3/1.2
suite and protocol names reported to OkHttp are nominal; Zig negotiates.


### Native image planning (PocketManga host bridge)

`call(source, "imageRequests", {"chapter": Chapter})` returns one request per page:
`{page, url, method, headers:[{name,value}], rates:[{key,spacingMs,initialWaitMs}], cookies:[Set-Cookie-string], fallback:null|string}`.
It resolves null imageUrl with getImageUrl and uses the source's virtual imageRequest. Rate limiters are identified structurally, including R8-minified Keiyoushi rule lists and Mihon's legacy host/permit/window/queue/semaphore layout. Their waits are removed from the probe and exported as conservative spacing plus an initial drain window. Unknown locking/queue layouts require fetchImage. All other application interceptors run before a simulated bridge (default User-Agent, URL-matched jar cookies, identity encoding), followed by network interceptors and a synthetic empty 200 response. The captured final request supplies URL, method and ordered headers, including dynamic cookie/signing changes. A replaced response body, exception or terminal bypass/repetition selects fetchImage with the responsible interceptor's name. Custom client transport/authentication/TLS policies, non-GET/body requests and non-identity final encoding also require fetchImage. A native caller must preserve the limits, handle redirects/challenges through the original client, retain partial pages and never forward headers to an unexamined redirect target.

`call(source, "imageCookies", {"url": URL, "cookies": [...]})` restores the exported matching cookies into a restarted source client before JVM fallback; it returns true. `call(source, "cancel", {})` calls the source client's dispatcher.cancelAll and returns true. Process owners must still terminate an unresponsive host; extension code need not cooperate with cancellation.

### Zstd compression compatibility

The host supplies `okhttp3.zstd.Zstd` with the public ABI of okhttp-zstd 5.5.0:
`INSTANCE`, `getEncoding(): String`, and `decompress(BufferedSource): Source`,
implementing `CompressionInterceptor.DecompressionAlgorithm`. Extensions can keep
using `CompressionInterceptor(Zstd, Brotli, Gzip)`. Decoding uses the source-built
libzstd 1.5.7 streaming decoder through `NativeZstdInputStream` and a small JNI
bridge. No Aircompressor, alignment adapter, or ASM bytecode transform remains.
Brotli continues to use its existing Java decoder.

The pinned upstream source, target flags, loader choice and build commands
are documented in [host/native/README.md](../host/native/README.md).
`zig build zstd -Dtarget=...` builds `<prefix>/lib/libpocketmanga-zstd.so`, and
dependent builds can install the `pocketmanga-zstd` named lazy path for their
own target. Package it into `runtime/lib/` beside the bundled JRE's parent.
The worker loads the absolute normalized `java.home/../lib/libpocketmanga-zstd.so`
path with `System.load`; it never extracts native code from jar resources.
Desktop tests can explicitly set
`-Dtachi.zstd.library=/absolute/path/to/the/desktop/library`.

Run `cd host && ./gradlew shadowJar testZstd testImageRequests --offline` for
streaming, single-byte input, concatenated frames, checksum/truncation, closure,
and interceptor/rate-limit fixtures. `testImageRequests` accepts
`-PextensionJars=/path/to/mangadex.jar,/path/to/mangafox.jar` to instantiate and
probe the installed clients. Add `-PliveMangaDex=true` to plan the documented
43-page MangaDex chapter through live metadata requests without image transfers.

`python3 tools/check_zstd_abi.py --native zig-out/lib/libpocketmanga-zstd.so
--reference /path/to/okhttp-zstd-5.5.0.jar /path/to/extension.jar ...` compares the
published public members and actual extension references, rejects obsolete
or extracting decoders, and audits the ARM soft-float ABI, NEEDED entries and
maximum GLIBC version. The BSD zstd license is included in the shadow jar and
next to the built library for device packaging. The app's ARM/firmware fixtures
exercise actual zstd HTTP/TLS metadata and verify the bundled JNI mapping.
