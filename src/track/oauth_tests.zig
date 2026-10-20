//! Deterministic wire tests for the three OAuth-backed manga services.
const std = @import("std");
const tracking = @import("../tracking.zig");
const driver = @import("driver.zig");
const Http = @import("http.zig").Http;
const Fixture = @import("../testing_http.zig").Fixture;
const c = @import("oauth_common.zig");
const al = @import("anilist.zig");
const mal = @import("myanimelist.zig");
const kitsu = @import("kitsu.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const Test = struct {
    arena: std.heap.ArenaAllocator,
    fixture: Fixture,
    http: Http,
    ctx: driver.Context,
    fn init(self: *Test, id: i32, bodies: []const []const u8, expected: []const []const []const u8) !void {
        self.arena = .init(std.testing.allocator);
        const a = self.arena.allocator();
        const responses = try a.alloc([]const u8, bodies.len);
        for (bodies, responses) |body, *response| response.* = if (std.mem.startsWith(u8, body, "HTTP/")) body else try std.fmt.allocPrint(a, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
        self.fixture = try Fixture.init(responses);
        self.fixture.expected_requests = expected;
        try self.fixture.start();
        self.http = .{ .gpa = std.testing.allocator, .io = std.testing.io };
        self.ctx = .{ .arena = a, .io = std.testing.io, .http = &self.http, .base_url = try self.fixture.url(a, ""), .tracker_id = id, .credential = .{ .tracker_id = id, .username = "77", .password = "tok", .token = if (id == 2) "{\"access_token\":\"tok\",\"expires\":4000000000000}" else "{\"access_token\":\"tok\",\"refresh_token\":\"refresh\",\"created_at\":4000000000,\"expires_in\":10000}" }, .formats = .{}, .host_dir = null };
    }
    fn deinit(self: *Test) void {
        self.http.deinit();
        self.fixture.deinit();
        self.arena.deinit();
    }
};
const al_manga = "{\"id\":5,\"title\":{\"userPreferred\":\"Title\"},\"chapters\":12,\"coverImage\":{\"large\":\"cover\"},\"format\":\"MANGA\",\"countryOfOrigin\":\"KR\",\"status\":\"FINISHED\",\"description\":\"A &amp; B\",\"averageScore\":83,\"startDate\":{\"year\":2020,\"month\":2,\"day\":3},\"staff\":{\"edges\":[{\"role\":\"Story & Art\",\"node\":{\"name\":{\"userPreferred\":\"Creator\"}}}]}}";
const al_entry = "{\"data\":{\"Page\":{\"mediaList\":[{\"id\":9,\"status\":\"REPEATING\",\"scoreRaw\":85,\"progress\":3,\"private\":true,\"startedAt\":{\"year\":2020,\"month\":2,\"day\":3},\"completedAt\":null,\"media\":" ++ al_manga ++ "}]}}}";
const al_write = "{\"data\":{\"SaveMediaListEntry\":{\"id\":9}}}";

test "AniList covers login URL, token login, title/id searches, add/existing bind, update, refresh and delete" {
    var t: Test = undefined;
    try t.init(2, &.{
        "{\"data\":{\"Viewer\":{\"id\":77,\"name\":\"Reader\",\"mediaListOptions\":{\"scoreFormat\":\"POINT_5\"}}}}",
        "{\"data\":{\"Page\":{\"media\":[" ++ al_manga ++ "]}}}",
        "{\"data\":{\"Page\":{\"media\":[" ++ al_manga ++ "]}}}",
        "{\"data\":{\"Page\":{\"mediaList\":[]}}}",
        al_write,
        al_entry,
        al_write,
        al_write,
        al_entry,
        "{\"data\":{\"DeleteMediaListEntry\":{\"deleted\":true}}}",
    }, &.{
        &.{ "POST / ", "AniListGetCurrentUser", "Bearer tok" },
        &.{ "AniListSearchManga", "\"search\":\"title\"", "format_not_in" },
        &.{ "AniListGetMangaDetails", "\"manga_id\":5" },
        &.{ "AniListGetLibManga", "\"user_id\":77" },
        &.{ "AniListAddManga", "\"status\":\"PLANNING\"", "\"private\":false" },
        &.{"AniListGetLibManga"},
        &.{ "AniListUpdateManga", "\"status\":\"REPEATING\"", "\"score\":85", "\"private\":false" },
        &.{ "AniListUpdateManga", "\"status\":\"COMPLETED\"", "\"progress\":12" },
        &.{"AniListGetLibManga"},
        &.{ "AniListDeleteManga", "\"library_id\":9" },
    });
    defer t.deinit();
    const url = (try al.call(&t.ctx, .{ .login_url = .{ .redirect_uri = "", .state = "" } })).login_url.?;
    try strings("https://anilist.co/api/v2/oauth/authorize?client_id=16329&response_type=token", url);
    const login = try al.call(&t.ctx, .{ .login = .{ .username = "", .password = "tok" } });
    try equal(tracking.AnilistScore.POINT_5, login.anilist_score_type.?);
    try strings("77", login.credential.?.username);
    try strings("Reader", login.credential.?.display_name);
    t.ctx.credential = login.credential.?;
    const result = (try al.call(&t.ctx, .{ .search = "title" })).matches[0];
    try strings("Title", result.track.title);
    try strings("Manhwa", result.publishing_type);
    try strings("2020-2-3", result.start_date);
    try strings("A & B", result.summary);
    try strings("Creator", result.authors[0]);
    try strings("Creator", result.artists[0]);
    try equal(83, result.score);
    try equal(5, (try al.call(&t.ctx, .{ .search = "id: 5" })).matches[0].track.remote_id);
    const bound = (try al.call(&t.ctx, .{ .bind = .{ .track = result.track, .has_read_chapters = false } })).track.?;
    try equal(9, bound.library_id);
    try equal(5, bound.status);
    const existing = (try al.call(&t.ctx, .{ .bind = .{ .track = result.track, .has_read_chapters = true } })).track.?;
    try equal(6, existing.status);
    try equal(85, existing.score);
    try expect(!existing.private);
    var progress = bound;
    progress.last_chapter_read = 12.9;
    const updated = (try al.call(&t.ctx, .{ .update = .{ .track = progress, .did_read_chapter = true } })).track.?;
    try equal(2, updated.status);
    try expect(updated.finished > 0);
    const fresh = (try al.call(&t.ctx, .{ .refresh = bound })).track.?;
    try equal(6, fresh.status);
    try equal(3, fresh.last_chapter_read);
    try expect(fresh.private);
    try equal(try c.dateMs("2020-02-03"), fresh.started);
    _ = try al.call(&t.ctx, .{ .delete = bound });
    try t.fixture.finish();
}

const mal_manga = "{\"id\":5,\"title\":\"Title\",\"synopsis\":\"Summary\",\"num_chapters\":12,\"mean\":8.3,\"main_picture\":{\"large\":\"cover\"},\"status\":\"finished_publishing\",\"media_type\":\"one_shot\",\"start_date\":\"2020-02\",\"authors\":[{\"node\":{\"first_name\":\"First\",\"last_name\":\"Last\"},\"role\":\"Story & Art\"},{\"node\":{\"first_name\":\"Art\",\"last_name\":\"\"},\"role\":\"Art\"}]}";
const mal_status = "{\"is_rereading\":true,\"status\":\"reading\",\"num_chapters_read\":3,\"score\":8,\"start_date\":\"2020\",\"finish_date\":null}";
const mal_complete = "{\"is_rereading\":false,\"status\":\"completed\",\"num_chapters_read\":12,\"score\":8,\"start_date\":\"2020\",\"finish_date\":\"2021-02-03\"}";

test "MAL covers PKCE, login, search filters/id/list pagination, bind, update, refresh and delete" {
    var t: Test = undefined;
    try t.init(1, &.{
        "{\"access_token\":\"tok\",\"refresh_token\":\"r\",\"expires_in\":10000}",
        "{\"name\":\"Reader\"}",
        "{\"data\":[{\"node\":" ++ mal_manga ++ "},{\"node\":{\"id\":6,\"media_type\":\"light_novel\"}}],\"paging\":{}}",
        mal_manga,
        "{\"data\":[{\"node\":" ++ mal_manga ++ "}],\"paging\":{\"next\":\"next\"}}",
        "{\"data\":[],\"paging\":{}}",
        "{\"num_chapters\":12,\"my_list_status\":null}",
        "{\"is_rereading\":false,\"status\":\"plan_to_read\",\"num_chapters_read\":0,\"score\":0}",
        "{\"num_chapters\":12,\"my_list_status\":" ++ mal_status ++ "}",
        mal_status,
        mal_complete,
        "{\"num_chapters\":12,\"my_list_status\":" ++ mal_status ++ "}",
        "{}",
    }, &.{
        &.{ "POST /v1/oauth2/token ", "client_id=" ++ c.mal_client, "code=code", "code_verifier=verifier", "grant_type=authorization_code" },
        &.{ "GET /users/@me ", "Bearer tok" },
        &.{ "GET /manga?q=title&nsfw=true", "fields=" },
        &.{"GET /manga/5?fields="},
        &.{ "GET /users/@me/mangalist?", "limit=250" },
        &.{"offset=250"},
        &.{ "GET /manga/5?fields=", "my_list_status" },
        &.{ "PUT /manga/5/my_list_status ", "status=plan_to_read", "score=0.0", "start_date=&finish_date=" },
        &.{"GET /manga/5?fields="},
        &.{ "status=reading&is_rereading=true", "score=8.0", "num_chapters_read=3" },
        &.{ "status=completed&is_rereading=false", "num_chapters_read=12" },
        &.{"GET /manga/5?fields="},
        &.{"DELETE /manga/5/my_list_status "},
    });
    defer t.deinit();
    const auth = try mal.call(&t.ctx, .{ .login_url = .{ .redirect_uri = "app://callback", .state = "state" } });
    try expect(auth.verifier.?.len >= 43);
    try expect(std.mem.indexOf(u8, auth.login_url.?, auth.verifier.?) != null);
    try expect(std.mem.indexOf(u8, auth.login_url.?, "state=state") != null);
    const login = try mal.call(&t.ctx, .{ .login = .{ .username = "", .password = "code", .verifier = "verifier" } });
    try strings("Reader", login.credential.?.username);
    t.ctx.credential = login.credential.?;
    const results = (try mal.call(&t.ctx, .{ .search = "title" })).matches;
    try equal(1, results.len);
    const result = results[0];
    try strings("finished publishing", result.publishing_status);
    try strings("one shot", result.publishing_type);
    try strings("First Last", result.authors[0]);
    try strings("Art", result.artists[0]);
    try equal(8.3, result.score);
    try equal(5, (try mal.call(&t.ctx, .{ .search = "id: 5" })).matches[0].track.remote_id);
    try equal(1, (try mal.call(&t.ctx, .{ .search = "my:tItLe" })).matches.len);
    const bound = (try mal.call(&t.ctx, .{ .bind = .{ .track = result.track, .has_read_chapters = false } })).track.?;
    try equal(6, bound.status);
    const existing = (try mal.call(&t.ctx, .{ .bind = .{ .track = result.track, .has_read_chapters = true } })).track.?;
    try equal(7, existing.status);
    var progress = existing;
    progress.last_chapter_read = 12.9;
    try equal(2, (try mal.call(&t.ctx, .{ .update = .{ .track = progress, .did_read_chapter = true } })).track.?.status);
    const fresh = (try mal.call(&t.ctx, .{ .refresh = bound })).track.?;
    try equal(7, fresh.status);
    try equal(try c.dateMs("2020-01-01"), fresh.started);
    _ = try mal.call(&t.ctx, .{ .delete = fresh });
    try t.fixture.finish();
}

const kitsu_manga = "{\"id\":\"5\",\"titles\":{\"preferred\":\"Title\"},\"chapterCount\":12,\"posterImage\":{\"views\":[{\"url\":\"small\"}],\"original\":{\"url\":\"original\"}},\"description\":{\"en\":\"Summary\"},\"status\":\"FINISHED\",\"subtype\":\"OEL\",\"startDate\":\"2020-02-03\",\"slug\":\"title\",\"averageRating\":83.5,\"staff\":{\"nodes\":[{\"role\":\"Story & Art\",\"person\":{\"name\":\"Creator\"}}]}}";
const kitsu_entry = "{\"data\":{\"findMangaById\":{\"id\":\"5\",\"titles\":{\"preferred\":\"Remote\"},\"chapterCount\":12,\"slug\":\"title\",\"myLibraryEntry\":{\"id\":\"9\",\"status\":\"ON_HOLD\",\"rating\":14,\"progress\":3,\"private\":true,\"startedAt\":\"2020-02-03T12:30:00+01:00\",\"finishedAt\":null}}}}";
const kitsu_add = "{\"data\":{\"libraryEntry\":{\"create\":{\"libraryEntry\":{\"id\":\"9\"}}}}}";
const kitsu_update = "{\"data\":{\"libraryEntry\":{\"update\":{\"libraryEntry\":{\"id\":\"9\"}}}}}";

test "Kitsu covers password login, title/id/slug search, binding, updates, refresh and deletion" {
    var t: Test = undefined;
    try t.init(3, &.{
        "{\"access_token\":\"tok\",\"refresh_token\":\"r\",\"expires_in\":10000,\"created_at\":4000000000}",
        "{\"data\":{\"currentAccount\":{\"id\":\"77\",\"ratingSystem\":\"REGULAR\",\"profile\":{\"name\":\"Reader\"}}}}",
        "{\"data\":{\"searchMangaByTitle\":{\"nodes\":[" ++ kitsu_manga ++ ",{\"subtype\":\"NOVEL\"},null]}}}",
        "{\"data\":{\"findMangaById\":" ++ kitsu_manga ++ "}}",
        "{\"data\":{\"findMangaBySlug\":" ++ kitsu_manga ++ "}}",
        "{\"data\":{\"findMangaById\":{\"myLibraryEntry\":null}}}",
        kitsu_add,
        kitsu_entry,
        kitsu_update,
        kitsu_update,
        kitsu_entry,
        "{\"data\":{\"libraryEntry\":{\"delete\":{\"libraryEntry\":{\"id\":\"9\"}}}}}",
    }, &.{
        &.{ "POST /api/oauth/token ", "username=user&password=pass", "grant_type=password", "client_id=" ++ c.kitsu_client, "client_secret=" ++ c.kitsu_secret },
        &.{ "POST /api/graphql ", "KitsuGetCurrentAccount", "Bearer tok", "Accept: application/vnd.api+json", "Content-Type: application/vnd.api+json" },
        &.{ "KitsuSearchMangaByTitle", "\"query\":\"title\"" },
        &.{ "KitsuGetMangaDetailsById", "\"id\":\"5\"" },
        &.{ "KitsuGetMangaDetailsBySlug", "\"slug\":\"title\"" },
        &.{"KitsuFindLibManga"},
        &.{ "KitsuAddLibManga", "\"status\":\"PLANNED\"", "\"rating\":null" },
        &.{"KitsuFindLibManga"},
        &.{ "KitsuUpdateLibManga", "\"status\":\"CURRENT\"", "\"rating\":14", "\"private\":false", "\"startedAt\":\"2020-02-03T11:30:00.000Z\"" },
        &.{ "KitsuUpdateLibManga", "\"status\":\"COMPLETED\"", "\"progress\":12" },
        &.{"KitsuFindLibManga"},
        &.{ "KitsuDeleteLibEntry", "\"library_id\":\"9\"" },
    });
    defer t.deinit();
    try std.testing.expectError(error.PasswordLogin, kitsu.call(&t.ctx, .{ .login_url = .{ .redirect_uri = "", .state = "" } }));
    const login = try kitsu.call(&t.ctx, .{ .login = .{ .username = "user", .password = "pass" } });
    try equal(tracking.KitsuScore.regular, login.kitsu_score_type.?);
    try strings("77", login.credential.?.username);
    try strings("Reader", login.credential.?.display_name);
    t.ctx.credential = login.credential.?;
    const results = (try kitsu.call(&t.ctx, .{ .search = "title" })).matches;
    try equal(1, results.len);
    const result = results[0];
    try strings("OEL", result.publishing_type);
    try strings("Finished", result.publishing_status);
    try strings("small", result.cover_url);
    try strings("Creator", result.authors[0]);
    try strings("Creator", result.artists[0]);
    try equal(83.5, result.score);
    try equal(5, (try kitsu.call(&t.ctx, .{ .search = "id: 5" })).matches[0].track.remote_id);
    try equal(5, (try kitsu.call(&t.ctx, .{ .search = "id: title" })).matches[0].track.remote_id);
    const bound = (try kitsu.call(&t.ctx, .{ .bind = .{ .track = result.track, .has_read_chapters = false } })).track.?;
    try equal(9, bound.library_id);
    try equal(5, bound.status);
    const existing = (try kitsu.call(&t.ctx, .{ .bind = .{ .track = result.track, .has_read_chapters = true } })).track.?;
    try equal(1, existing.status);
    try expect(!existing.private);
    var progress = existing;
    progress.last_chapter_read = 12.9;
    const updated = (try kitsu.call(&t.ctx, .{ .update = .{ .track = progress, .did_read_chapter = true } })).track.?;
    try equal(2, updated.status);
    try expect(updated.finished > 0);
    const fresh = (try kitsu.call(&t.ctx, .{ .refresh = bound })).track.?;
    try equal(3, fresh.status);
    try strings("Title", fresh.title);
    try expect(fresh.private);
    try equal(14, fresh.score);
    _ = try kitsu.call(&t.ctx, .{ .delete = fresh });
    try t.fixture.finish();
}

test "MAL and Kitsu refresh expired tokens and return the replacement credential" {
    inline for (.{ .{ @as(i32, 1), mal }, .{ @as(i32, 3), kitsu } }) |service| {
        var t: Test = undefined;
        try t.init(service[0], &.{ "{\"access_token\":\"new\",\"refresh_token\":\"new-refresh\",\"expires_in\":10000,\"created_at\":4000000000}", if (service[0] == 1) "{\"data\":[],\"paging\":{}}" else "{\"data\":{\"searchMangaByTitle\":{\"nodes\":[]}}}" }, &.{ &.{ "grant_type=refresh_token", "refresh_token=refresh" }, &.{"Bearer new"} });
        defer t.deinit();
        t.ctx.credential.token = "{\"access_token\":\"tok\",\"refresh_token\":\"refresh\",\"created_at\":1,\"expires_in\":1}";
        const reply = try service[1].call(&t.ctx, .{ .search = "title" });
        try strings("new", reply.credential.?.password);
        try expect(std.mem.indexOf(u8, reply.credential.?.token, "new-refresh") != null);
        try t.fixture.finish();
    }
}

test "expired AniList credentials fail locally and partial dates and instants map correctly" {
    var t: Test = undefined;
    try t.init(2, &.{}, &.{});
    defer t.deinit();
    t.ctx.credential.token = "{\"expires\":1}";
    try std.testing.expectError(error.AuthenticationExpired, al.call(&t.ctx, .{ .search = "title" }));
    try equal(try c.dateMs("2020-01-01"), try c.dateMs("2020"));
    try equal(try c.dateMs("2020-02-01"), try c.dateMs("2020-02"));
    try equal(try c.instantMs("2020-02-03T11:30:00Z"), try c.instantMs("2020-02-03T12:30:00+01:00"));
    try strings("2020-02-03T11:30:00.123Z", (try c.instant(&t.ctx, try c.instantMs("2020-02-03T11:30:00.123Z"))).?);
    try strings("A & B\nC © é\n\n", try c.html(&t.ctx, "<p>A &amp; B<br>C &#169; &eacute;</p>"));
    try t.fixture.finish();
}

test "AniList resolves legacy library ids and falls back on invalid id searches" {
    var t: Test = undefined;
    try t.init(2, &.{ al_entry, al_write, al_entry, "{\"data\":{\"DeleteMediaListEntry\":{\"deleted\":true}}}", "{\"data\":{\"Page\":{\"mediaList\":[]}}}", "{\"data\":{\"Page\":{\"media\":[]}}}", "{\"errors\":[{\"message\":\"bad query\"}]}" }, &.{ &.{"AniListGetLibManga"}, &.{ "AniListUpdateManga", "\"library_id\":9", "\"status\":\"REPEATING\"", "\"startedAt\":{\"year\":null,\"month\":null,\"day\":null}" }, &.{"AniListGetLibManga"}, &.{ "AniListDeleteManga", "\"library_id\":9" }, &.{"AniListGetLibManga"}, &.{ "AniListSearchManga", "\"search\":\"id: invalid\"" }, &.{"AniListSearchManga"} });
    defer t.deinit();
    const track: tracking.Track = .{ .tracker_id = 2, .remote_id = 5, .status = 6, .last_chapter_read = 1 };
    const updated = (try al.call(&t.ctx, .{ .update = .{ .track = track, .did_read_chapter = true } })).track.?;
    try equal(9, updated.library_id);
    try equal(0, updated.started);
    _ = try al.call(&t.ctx, .{ .delete = track });
    _ = try al.call(&t.ctx, .{ .delete = track });
    try equal(0, (try al.call(&t.ctx, .{ .search = "id: invalid" })).matches.len);
    try equal(0, (try al.call(&t.ctx, .{ .search = "query" })).matches.len);
    try t.fixture.finish();
}

test "MAL refresh adds missing entries and reports unapproved titles" {
    var t: Test = undefined;
    try t.init(1, &.{ "{\"num_chapters\":12,\"my_list_status\":null}", mal_status, "HTTP/1.1 400 Bad Request\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{\"error\":\"invalid_content\"}" }, &.{ &.{"GET /manga/5?"}, &.{ "PUT /manga/5/my_list_status ", "status=reading&is_rereading=true", "num_chapters_read=1", "start_date=&finish_date=" }, &.{"PUT /manga/5/my_list_status "} });
    defer t.deinit();
    const track: tracking.Track = .{ .tracker_id = 1, .remote_id = 5, .status = 7, .last_chapter_read = 1 };
    const fresh = (try mal.call(&t.ctx, .{ .refresh = track })).track.?;
    try equal(12, fresh.total_chapters);
    try std.testing.expectError(error.MALTitleNotApproved, mal.call(&t.ctx, .{ .update = .{ .track = track, .did_read_chapter = true } }));
    try t.fixture.finish();
}

test "Kitsu keeps an old token after a failed refresh, clears dates/ratings and ignores missing deletes" {
    var t: Test = undefined;
    try t.init(3, &.{ "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", "{\"data\":{\"searchMangaByTitle\":{\"nodes\":[]}}}", kitsu_update, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 38\r\nConnection: close\r\n\r\nCouldn't find LibraryEntry with 'id'=9", "{\"errors\":[{\"message\":\"bad query\"}]}" }, &.{ &.{"grant_type=refresh_token"}, &.{"Bearer tok"}, &.{ "KitsuUpdateLibManga", "\"rating\":null", "\"startedAt\":null", "\"finishedAt\":null" }, &.{"KitsuDeleteLibEntry"}, &.{"KitsuSearchMangaByTitle"} });
    defer t.deinit();
    const original = t.ctx.credential.token;
    t.ctx.credential.token = "{\"access_token\":\"tok\",\"refresh_token\":\"refresh\",\"created_at\":1,\"expires_in\":1}";
    try expect((try kitsu.call(&t.ctx, .{ .search = "title" })).credential == null);
    t.ctx.credential.token = original;
    const track: tracking.Track = .{ .tracker_id = 3, .remote_id = 5, .library_id = 9, .status = 1 };
    _ = try kitsu.call(&t.ctx, .{ .update = .{ .track = track } });
    _ = try kitsu.call(&t.ctx, .{ .delete = track });
    try equal(0, (try kitsu.call(&t.ctx, .{ .search = "title" })).matches.len);
    try t.fixture.finish();
}

test "each provider propagates HTTP authentication expiry" {
    inline for (.{ .{ @as(i32, 1), mal }, .{ @as(i32, 2), al }, .{ @as(i32, 3), kitsu } }) |service| {
        var t: Test = undefined;
        try t.init(service[0], &.{"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"}, &.{&.{"Bearer tok"}});
        defer t.deinit();
        try std.testing.expectError(error.AuthenticationExpired, service[1].call(&t.ctx, .{ .search = "title" }));
        try t.fixture.finish();
    }
}
