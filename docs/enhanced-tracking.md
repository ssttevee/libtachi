# Enhanced tracking

Komga (6), Kavita (8), and Suwayomi (9) use dummy tracker credentials (`user` / `pass`) to enable tracking. Their server credentials come from the extension's typed JSON preferences under `<host_dir>/prefs/source_<id>.json`. Tracker login never authenticates to a server.

Apps can submit `engine.Request.track_match = .{ .manga_id = ... }` to match and bind an enabled enhanced tracker for a title. Existing bindings are skipped. This request uses the native tracker driver and does not start extensions. The existing enhanced sync updates the server before changing local read state, preserving the continuous-prefix rule. Direct `tracking.Operation.search` calls for these services accept a title's server URL (or a bare numeric Tachidesk manga ID); textual search returns `UnsupportedSearch`. Bind is a no-op, and remote track deletion is unsupported. `Tracker Delete` deletes Suwayomi chapter downloads during progress updates, not manga or track records.

## Source identity and migration

Acceptance compares the remembered `Library.sources[].pkg` exactly with:

- `eu.kanade.tachiyomi.extension.all.komga`
- `eu.kanade.tachiyomi.extension.all.kavita`
- `eu.kanade.tachiyomi.extension.all.tachidesk`

Mihon compares qualified Android classes. libtachi retains extension packages, so it accepts the corresponding package rather than inspecting classes. Missing package metadata is not accepted. `track.enhanced` exports acceptance, identity, and migration helpers. Engine migration keeps enhanced tracks only when their old URL equals the old title URL and both source packages are accepted; it replaces the URL and updates Suwayomi's numeric remote ID. Exact URL equality follows Mihon's `isTrackFrom`; a bare Tachidesk title ID and a full tracker URL are not treated as interchangeable during migration.

## Server settings and authentication

Komga uses `Address`, `Username`, `Password`, and `API key`. A nonempty API key takes precedence (`X-API-Key`); otherwise requests carry HTTP Basic authentication. This replaces Mihon's shared Android OkHttp cookie jar, which is unavailable to the native engine. Series use the v2 progress endpoint and fractional chapter numbers; readlists use the legacy endpoint and integer indices.

Kavita uses `APIURL` and `APIKEY`. The tracker finds the preference file whose API URL matches the track's server base, authenticates at `/Plugin/authenticate`, and uses the JWT for that operation. Unlike Mihon's three hardcoded MD5-derived source IDs, this supports any configured source ID with the matching API URL. The standard IDs are 7266875667263635239, 3764816291200082561, and 778637366235559582. Volumes made from chapter zero count as chapters; other chapter numbers determine the truncated maximum. A 204 latest-chapter response means zero, and comma decimal separators are accepted.

Suwayomi uses `Server URL Address`, `Login (Basic Auth)`, `Password (Basic Auth)`, `Login Mode`, `Custom HTTP headers`, and `Tracker Delete`. Supported modes are `NONE`, `BASIC_AUTH`, `SIMPLE_LOGIN` (form/cookie), and `UI_LOGIN` (GraphQL/JWT). When the mode is absent, nonempty username/password enable Basic authentication, matching the extension's legacy fallback. Bare manga IDs use the extension's retained MD5(`tachidesk/en/1`) source ID 3100117499901280806. Full URLs select settings by server base. Unread positive-numbered chapters up to requested progress are marked read, optionally their downloads are deleted, and server tracking progress is updated before refetching.

Full-URL preference selection checks the complete base path. Multiple preference files matching the same server are rejected as `AmbiguousSourceSettings`, because persisted tracks have no source ID with which to choose an account. This avoids silently applying another account's credentials. Tokens and cookies are obtained per operation rather than cached or persisted; a later operation therefore observes changed extension settings. Errors are returned to the app rather than hidden as a null match, providing configuration and authentication diagnostics. Cancellation propagates.

Enhanced tracker requests do not follow redirects, keeping credentials on the configured server. Configure the canonical server URL. Other trackers retain their existing HTTP behavior. Simple-login redirects are not followed; only cookie name/value pairs are sent on subsequent API requests.

## Research sources

Mihon behavior is ported from the local mihonapp/mihon 487c313 snapshot, including the Suwayomi GraphQL documents.

- [Komga extension source and preference keys](https://github.com/keiyoushi/extensions-source/blob/main/src/all/komga/src/eu/kanade/tachiyomi/extension/all/komga/Komga.kt)
- [Official Tachidesk extension and preference keys](https://github.com/Suwayomi/tachiyomi-extension/blob/main/src/all/tachidesk/src/eu/kanade/tachiyomi/extension/all/tachidesk/Tachidesk.kt)
- [Tachidesk authentication modes](https://github.com/Suwayomi/tachiyomi-extension/blob/main/src/all/tachidesk/src/eu/kanade/tachiyomi/extension/all/tachidesk/TokenManager.kt)

The Tachidesk source is maintained separately from the Keiyoushi extension tree. Settings were verified against these upstream sources on 2026-10-20.

## Tests

All network operations use the local `testing_http.Fixture`; tests read real typed preference files in temporary host directories. Assertions cover request methods, endpoints, authentication headers and payloads, both Komga progress formats, Kavita volume mapping and 204/comma handling, Suwayomi download-deletion branches and all login modes, authentication failures, source acceptance/migration, and engine binding order. No test uses a real server or external network.
