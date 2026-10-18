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
| `uninstall(pkg)` | package name | `true`/`false` |
| `listExtensions()` | | `ExtensionInfo[]` |

```json
ExtensionInfo {
  "pkg": "eu.kanade.tachiyomi.extension.en.weebcentral",
  "name": "Weeb Central", "versionName": "1.6.25", "versionCode": 106025,
  "libVersion": "1.6", "nsfw": true, "lang": "en", "path": "/…/x.jar",
  "sources": [ SourceInfo ]
}
SourceInfo {
  "id": "2131019126180322627", "name": "Weeb Central", "lang": "en",
  "baseUrl": "https://weebcentral.com", "supportsLatest": true,
  "isConfigurable": false, "supportsRelatedMangas": true,
  "className": "keiyoushi.source.Generated", "extensionPkg": "…"
}
```

Loaded extensions are not persisted; reload them when your process starts.

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
when you want details and chapters in one round trip.

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
| `cacheDir` | `<dataDir>/cache` | OkHttp cache, dex2jar output |
| `userAgent` | Chrome on Android | `NetworkHelper.defaultUserAgentProvider()` |
| `appVersionName` / `appVersionCode` | `0.20.1` / `137` | `eu.kanade.tachiyomi.AppInfo` |
| `packageName` | `app.mihon` | `Context.getPackageName()` |
| `verbose` | false | debug logs + HTTP header logging |

## Logging

`android.util.Log` → `dev.tachi.host.TachiLog` → (if a `log_fn` was given)
the native callback, called from whatever JVM thread logged. Levels follow
Android: 2 verbose … 7 assert.
