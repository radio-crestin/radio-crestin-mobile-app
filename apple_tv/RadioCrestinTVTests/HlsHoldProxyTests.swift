import AVFoundation
import XCTest
@testable import RadioCrestinTV

/// The HLS hold proxy against a fake origin on the loopback interface:
/// what it relays, what it holds through an outage and how a hold ends,
/// with timings short enough for a unit test. Ported from the iPhone app's
/// `test/hls_hold_proxy_test.dart`.
@MainActor
final class HlsHoldProxyTests: XCTestCase {

    /// A started proxy for a fake origin, and a player in front of it.
    private struct Rig {
        let origin: FakeOrigin
        let player: TestPlayer
        let proxy: HlsHoldProxy
        let log: EventLog

        /// The proxy's URL for `pathAndQuery` of the origin in `session`.
        func wrap(_ pathAndQuery: String, session: Int) throws -> URL {
            try XCTUnwrap(
                proxy.wrap(origin.url(pathAndQuery), session: session)
            )
        }

        /// The proxy's URL for `pathAndQuery` of the origin in a new
        /// session.
        func wrapInNewSession(_ pathAndQuery: String) throws -> URL {
            try wrap(pathAndQuery, session: proxy.beginSession())
        }

        /// A request the player starts now and the test awaits later.
        func request(
            _ url: URL,
            method: String = "GET"
        ) -> Task<PlayerResponse, Error> {
            Task { try await player.get(url, method: method) }
        }
    }

    /// Retries ten times a second; a stuck request fails within seconds.
    private nonisolated static let fast = HlsHoldProxy.Timings(
        retryInterval: 0.1,
        maxHold: 20,
        connectTimeout: 1,
        responseTimeout: 1,
        bodyIdleTimeout: 2
    )

    /// Retries only twice a minute: within a test, only the network signal
    /// (`networkRestored`, `networkChanged`) can make it retry.
    private nonisolated static let slowRetry = HlsHoldProxy.Timings(
        retryInterval: 30,
        maxHold: 60,
        connectTimeout: 1,
        responseTimeout: 1,
        bodyIdleTimeout: 2
    )

    private func makeRig(
        timings: HlsHoldProxy.Timings = fast,
        onEvent: ((HlsHoldProxy.Event) -> Void)? = nil
    ) async throws -> Rig {
        let origin = try await FakeOrigin.start()
        let player = TestPlayer()
        let log = EventLog()
        let proxy = HlsHoldProxy(
            allowedHosts: ["127.0.0.1"],
            timings: timings,
            onEvent: { event in
                log.record(event)
                onEvent?(event)
            }
        )
        addTeardownBlock {
            player.close()
            proxy.stop()
            origin.close()
        }
        let started = await proxy.start()
        XCTAssertTrue(started)
        return Rig(origin: origin, player: player, proxy: proxy, log: log)
    }

    /// A proxied playlist URL in a new session, loaded once so that the
    /// session is established.
    private func establishedPlaylist(_ rig: Rig) async throws -> URL {
        let url = try rig.wrap(
            "/hls/rve/index-5m.m3u8?ref=app&s=d1",
            session: rig.proxy.beginSession()
        )
        let got = try await rig.player.get(url)
        XCTAssertEqual(got.status, 200)
        return url
    }

    /// A GET of the proxy `url` from a bare TCP client, which neither
    /// sends it again when it fails nor closes its connection by itself.
    private func rawRequest(_ url: URL, to rig: Rig) throws -> RawClient {
        let components = try XCTUnwrap(URLComponents(
            url: url, resolvingAgainstBaseURL: false
        ))
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let client = RawClient(port: try XCTUnwrap(rig.proxy.port))
        client.send(
            "GET \(components.percentEncodedPath)\(query) HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n\r\n"
        )
        return client
    }

    private func relative(_ path: String, to url: URL) throws -> URL {
        try XCTUnwrap(URL(string: path, relativeTo: url)?.absoluteURL)
    }

    /// Whether `task` is still waiting after `wait`.
    private func isStillPending(
        _ task: Task<PlayerResponse, Error>,
        after wait: Duration = .milliseconds(400)
    ) async -> Bool {
        let finished = Locked(false)
        Task {
            _ = await task.result
            finished.withValue { $0 = true }
        }
        try? await Task.sleep(for: wait)
        return !finished.current
    }

    /// Asserts that `task`'s request was closed without a response.
    private func assertClosedWithoutResponse(
        _ task: Task<PlayerResponse, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let got = try await task.value
            XCTFail("expected no response, got \(got.status)", file: file, line: line)
        } catch {
            XCTAssertTrue(error is URLError, "\(error)", file: file, line: line)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let met = await eventually(timeout: timeout, condition)
        XCTAssertTrue(met, "not met in \(timeout) s: \(what)", file: file, line: line)
    }

    private func secondsSince(_ start: Date) -> TimeInterval {
        Date().timeIntervalSince(start)
    }

    // MARK: Relaying

    func test_relays_the_origins_status_headers_and_body_keeps_the_query_and_forwards_the_players_headers() async throws {
        let rig = try await makeRig()
        let url = try rig.wrap(
            "/hls/rve/index-5m.m3u8?ref=radio-crestin-ios&s=d1",
            session: rig.proxy.beginSession()
        )
        let port = try XCTUnwrap(rig.proxy.port)
        XCTAssertTrue(url.absoluteString.hasPrefix(
            "http://127.0.0.1:\(port)/1/http/127.0.0.1:\(rig.origin.port)/"
        ), url.absoluteString)

        let got = try await rig.player.get(url, headers: [
            "User-Agent": "AppleCoreMedia/1.0.0",
            "X-Playback-Session-Id": "ABC-123",
        ])

        let playlist = FakeOrigin.playlist(version: 1)
        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(got.body, playlist)
        XCTAssertEqual(got.header("Content-Type"), "application/vnd.apple.mpegurl")
        XCTAssertEqual(got.header("Cache-Control"), "no-store")
        XCTAssertEqual(got.header("ETag"), "W/\"v1\"")
        XCTAssertEqual(got.header("Last-Modified"), "Sat, 17 Oct 2026 08:44:00 GMT")
        XCTAssertEqual(got.header("Content-Length"), "\(playlist.utf8.count)")
        XCTAssertEqual(rig.origin.requests.count, 1)
        let seen = try XCTUnwrap(rig.origin.requests.first)
        XCTAssertEqual(seen.path, "/hls/rve/index-5m.m3u8")
        XCTAssertEqual(
            seen.query, "ref=radio-crestin-ios&s=d1",
            "listeners are counted from these"
        )
        XCTAssertEqual(seen.headers["user-agent"], "AppleCoreMedia/1.0.0")
        XCTAssertEqual(seen.headers["x-playback-session-id"], "ABC-123")
        await letQueuedWorkRun()
        XCTAssertTrue(
            rig.log.requestEvents.isEmpty,
            "no log line per normal request: \(rig.log.requestEvents)"
        )
    }

    func test_a_response_closes_its_connection() async throws {
        let rig = try await makeRig()
        let path = try XCTUnwrap(HlsHoldProxy.proxyPath(
            for: rig.origin.url("/hls/rve/index.m3u8"),
            session: rig.proxy.beginSession()
        ))
        let client = RawClient(port: try XCTUnwrap(rig.proxy.port))

        client.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

        await waitUntil("the proxy closes") { client.answer.isClosed }
        let text = client.answer.text
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"), text)
        XCTAssertTrue(text.contains("\r\nConnection: close\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n" + FakeOrigin.playlist(version: 1)), text)
    }

    func test_a_segment_uri_relative_to_the_playlist_resolves_to_the_origins_path_through_the_proxy() async throws {
        let rig = try await makeRig()
        let playlistURL = try await establishedPlaylist(rig)

        let got = try await rig.player.get(try relative("seg-1.ts", to: playlistURL))

        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(got.body, "segment /hls/rve/seg-1.ts")
        XCTAssertEqual(rig.origin.requests.last?.path, "/hls/rve/seg-1.ts")
    }

    func test_a_gzip_answer_is_decompressed_the_player_gets_the_plain_body_and_its_length() async throws {
        let rig = try await makeRig()
        let plain = Data(FakeOrigin.playlist(version: 7).utf8)
        let compressed = try gzipped(plain)
        rig.origin.handler = { _ in
            FakeOrigin.Response(
                headers: [
                    ("Content-Type", "application/vnd.apple.mpegurl"),
                    ("Content-Encoding", "gzip"),
                ],
                body: compressed
            )
        }
        let url = try rig.wrapInNewSession("/hls/rve/index.m3u8")

        let got = try await rig.player.get(url)

        XCTAssertEqual(got.data, plain)
        XCTAssertNil(got.header("Content-Encoding"))
        XCTAssertEqual(got.header("Content-Length"), "\(plain.count)")
        let acceptEncoding = rig.origin.requests.first?.headers["accept-encoding"]
        XCTAssertTrue(
            acceptEncoding?.contains("gzip") == true,
            "compressed upstream, where it costs: \(String(describing: acceptEncoding))"
        )
    }

    func test_head_and_range_requests_get_the_lengths_and_ranges_as_stored() async throws {
        let rig = try await makeRig()
        let url = try rig.wrapInNewSession("/hls/rve/seg-1.ts")
        let length = "segment /hls/rve/seg-1.ts".utf8.count

        let head = try await rig.player.get(url, method: "HEAD")
        XCTAssertEqual(head.status, 200)
        XCTAssertTrue(head.data.isEmpty)
        XCTAssertEqual(head.header("Content-Length"), "\(length)")
        XCTAssertEqual(rig.origin.requests.last?.method, "HEAD")
        XCTAssertEqual(rig.origin.requests.last?.headers["accept-encoding"], "identity")

        let range = try await rig.player.get(url, headers: ["Range": "bytes=0-6"])
        XCTAssertEqual(range.status, 206)
        XCTAssertEqual(range.body, "segment")
        XCTAssertEqual(range.header("Content-Range"), "bytes 0-6/\(length)")
        XCTAssertEqual(range.header("Accept-Ranges"), "bytes")
        XCTAssertEqual(rig.origin.requests.last?.headers["range"], "bytes=0-6")
        XCTAssertEqual(rig.origin.requests.last?.headers["accept-encoding"], "identity")
    }

    func test_a_redirect_to_an_allowed_host_is_relayed_and_stays_on_the_proxy() async throws {
        let rig = try await makeRig()
        let location = rig.origin.url("/hls/other/index.m3u8?x=1").absoluteString
        rig.origin.handler = { _ in
            FakeOrigin.Response(status: 302, headers: [("Location", location)])
        }
        let session = rig.proxy.beginSession()
        let url = try rig.wrap("/hls/rve/index.m3u8", session: session)

        let got = try await rig.player.get(url)

        XCTAssertEqual(got.status, 302)
        XCTAssertEqual(
            got.header("Location"),
            "/\(session)/http/127.0.0.1:\(rig.origin.port)/hls/other/index.m3u8?x=1"
        )
        XCTAssertEqual(rig.origin.requests.count, 1, "not followed upstream")
    }

    func test_an_unknown_path_gets_a_404_another_method_a_405_and_another_host_is_not_fetched() async throws {
        let rig = try await makeRig()
        let base = "http://127.0.0.1:\(try XCTUnwrap(rig.proxy.port))"

        let unknown = try await rig.player.get(
            try XCTUnwrap(URL(string: "\(base)/hls/rve/index.m3u8"))
        )
        let otherHost = try await rig.player.get(
            try XCTUnwrap(URL(string: "\(base)/1/https/example.com/index.m3u8"))
        )
        let url = try rig.wrapInNewSession("/hls/rve/index.m3u8")
        let post = try await rig.player.get(url, method: "POST")

        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(otherHost.status, 404)
        XCTAssertEqual(post.status, 405)
        XCTAssertEqual(post.header("Allow"), "GET, HEAD")
        XCTAssertTrue(rig.origin.requests.isEmpty)
    }

    func test_a_body_that_fails_part_way_is_retried_unseen() async throws {
        let rig = try await makeRig()
        let playlistURL = try await establishedPlaylist(rig)
        let segment = Data((0..<50_000).map { UInt8($0 % 251) })
        let cutsLeft = Locked(1)
        rig.origin.handler = { _ in
            let cut = cutsLeft.withValue { left -> Bool in
                defer { left = max(left - 1, 0) }
                return left > 0
            }
            return FakeOrigin.Response(
                headers: [("Content-Type", "video/mp2t")],
                body: segment,
                cutAfter: cut ? 20_000 : nil
            )
        }

        let got = try await rig.player.get(try relative("seg-1.ts", to: playlistURL))

        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(got.data, segment)
        XCTAssertEqual(rig.origin.requests.count, 3, "the playlist, the cut try, its retry")
        await letQueuedWorkRun()
        XCTAssertTrue(rig.log.requestEvents.isEmpty, "\(rig.log.requestEvents)")
    }

    // MARK: HTTP errors

    func test_an_error_status_is_the_origin_answering_relayed_at_once_never_held() async throws {
        let rig = try await makeRig()
        let playlistURL = try await establishedPlaylist(rig)
        rig.origin.handler = { request in
            FakeOrigin.Response(
                status: request.path.hasSuffix("missing.ts") ? 404 : 503,
                body: Data("nope".utf8)
            )
        }

        let missing = try await rig.player.get(try relative("missing.ts", to: playlistURL))
        let busy = try await rig.player.get(try relative("busy.m3u8", to: playlistURL))

        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(missing.body, "nope")
        XCTAssertEqual(busy.status, 503)
        await letQueuedWorkRun()
        XCTAssertTrue(rig.log.holdStarts.isEmpty)
    }

    // MARK: Holding through an outage

    func test_holds_a_request_of_the_established_session_and_answers_it_with_the_fresh_response_the_moment_the_network_is_back() async throws {
        let rig = try await makeRig(timings: Self.slowRetry)
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections
        rig.origin.version = 2

        let held = rig.request(url)
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)
        XCTAssertEqual(rig.log.holdStarts.map(\.resource), ["index-5m.m3u8"])

        let restoredAt = Date()
        rig.origin.mode = .answering
        rig.proxy.networkRestored()
        let got = try await held.value

        XCTAssertLessThan(secondsSince(restoredAt), 2)
        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(
            got.body, FakeOrigin.playlist(version: 2),
            "a fresh answer, not a replay"
        )
        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        let end = try XCTUnwrap(rig.log.holdEnds.first)
        XCTAssertEqual(end.end, .answered)
        XCTAssertEqual(end.status, 200)
        XCTAssertGreaterThan(end.held, 0.3)
    }

    func test_without_a_network_signal_a_held_request_retries_on_its_interval() async throws {
        let rig = try await makeRig()
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections

        let held = rig.request(url)
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)
        let triesWhileOffline = rig.origin.requests.count
        rig.origin.mode = .answering
        let got = try await held.value

        XCTAssertEqual(got.status, 200)
        XCTAssertGreaterThan(triesWhileOffline, 3, "retried every 100 ms")
        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        XCTAssertEqual(rig.log.holdEnds.first?.end, .answered)
    }

    func test_a_held_segment_loads_once_the_network_is_back() async throws {
        let rig = try await makeRig(timings: Self.slowRetry)
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections

        let held = rig.request(try relative("seg-1.ts", to: url))
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)
        rig.origin.mode = .answering
        rig.proxy.networkRestored()

        let got = try await held.value
        XCTAssertEqual(got.body, "segment /hls/rve/seg-1.ts")
    }

    func test_a_request_held_while_the_listening_socket_closes_is_still_answered() async throws {
        let rig = try await makeRig(timings: Self.slowRetry)
        let url = try await establishedPlaylist(rig)
        let port = rig.proxy.port
        rig.origin.mode = .droppingConnections
        let held = rig.request(url)
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)

        rig.proxy.debugCloseListener()
        XCTAssertNil(rig.proxy.port)
        await waitUntil("serverClosed") { rig.log.serverCloses == 1 }
        rig.origin.mode = .answering
        rig.proxy.networkRestored()

        let got = try await held.value
        XCTAssertEqual(got.status, 200)
        let restarted = await rig.proxy.ensureRunning()
        XCTAssertTrue(restarted)
        XCTAssertEqual(rig.proxy.port, port, "restarted on its own port")
        XCTAssertTrue(rig.proxy.serves(url))
    }

    // MARK: Failing fast

    func test_a_new_load_while_offline_fails_at_once_as_without_the_proxy() async throws {
        let rig = try await makeRig()
        rig.origin.mode = .droppingConnections
        let url = try rig.wrapInNewSession("/hls/rve/index.m3u8")

        let startedAt = Date()
        await assertClosedWithoutResponse(rig.request(url))

        XCTAssertLessThan(secondsSince(startedAt), 1)
        await waitUntil("failedFast") { !rig.log.failedFastSessions.isEmpty }
        XCTAssertTrue(rig.log.holdStarts.isEmpty)
    }

    func test_a_request_of_a_replaced_session_fails_at_once() async throws {
        let rig = try await makeRig()
        let oldURL = try await establishedPlaylist(rig)
        rig.proxy.beginSession()
        rig.origin.mode = .droppingConnections

        await assertClosedWithoutResponse(rig.request(oldURL))

        await waitUntil("failedFast") { !rig.log.failedFastSessions.isEmpty }
        XCTAssertEqual(Set(rig.log.failedFastSessions), [1])
        XCTAssertTrue(rig.log.holdStarts.isEmpty)
    }

    func test_a_connection_that_died_is_retried_at_once_on_a_new_one_a_new_load_does_not_fail_for_it() async throws {
        let rig = try await makeRig()
        rig.origin.dropNext = 1
        let url = try rig.wrapInNewSession("/hls/rve/index.m3u8")

        let got = try await rig.player.get(url)

        XCTAssertEqual(got.status, 200)
        XCTAssertEqual(rig.origin.requests.count, 2)
        await letQueuedWorkRun()
        XCTAssertTrue(rig.log.requestEvents.isEmpty, "\(rig.log.requestEvents)")
    }

    // MARK: Ending a hold

    func test_a_new_session_releases_the_requests_held_for_the_old_one() async throws {
        let rig = try await makeRig()
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections
        let held = rig.request(url)
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)

        rig.proxy.beginSession()

        await assertClosedWithoutResponse(held)
        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        XCTAssertEqual(rig.log.holdEnds.first?.end, .released)
    }

    func test_a_hold_ends_after_the_longest_hold() async throws {
        var timings = Self.fast
        timings.maxHold = 0.7
        let rig = try await makeRig(timings: timings)
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections

        // A raw client: URLSession would send the request again on a new
        // connection, which the proxy holds again (see the next test).
        let startedAt = Date()
        let client = try rawRequest(url, to: rig)
        await waitUntil("closed") { client.answer.isClosed }

        XCTAssertGreaterThan(secondsSince(startedAt), 0.6)
        XCTAssertLessThan(secondsSince(startedAt), 2)
        XCTAssertEqual(client.answer.text, "", "closed without a response")
        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        XCTAssertEqual(rig.log.holdEnds.first?.end, .maxHold)
    }

    func test_a_player_that_sends_a_request_again_after_the_longest_hold_is_held_again() async throws {
        // CFNetwork, which AVPlayer's loads go through, sends a request
        // closed without a response again on a new connection (measured
        // on the tvOS 27 simulator: twice). For the established session
        // each one is held anew, as in the iPhone app.
        var timings = Self.fast
        timings.maxHold = 0.5
        let rig = try await makeRig(timings: timings)
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections

        await assertClosedWithoutResponse(rig.request(url))

        await waitUntil("the holds end") { rig.log.holdEnds.count >= 2 }
        XCTAssertTrue(rig.log.holdEnds.allSatisfy { $0.end == .maxHold })
    }

    func test_the_origin_out_of_reach_while_the_internet_works_is_held_too() async throws {
        // Failing it would only make the player give up.
        let rig = try await makeRig()
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections // the origin alone

        let held = rig.request(url)
        let pending = await isStillPending(held, after: .seconds(1))
        XCTAssertTrue(pending)
        XCTAssertGreaterThan(rig.log.holdRetryFailures.count, 3)
        rig.origin.mode = .answering

        let got = try await held.value
        XCTAssertEqual(got.status, 200)
        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        XCTAssertEqual(rig.log.holdEnds.first?.end, .answered)
    }

    func test_a_client_that_leaves_ends_its_hold_and_the_retries_stop() async throws {
        let rig = try await makeRig()
        let playlistURL = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections
        let client = try rawRequest(playlistURL, to: rig)
        await waitUntil("the hold starts") { !rig.log.holdStarts.isEmpty }

        client.leave()

        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        XCTAssertEqual(rig.log.holdEnds.first?.end, .clientGone)
        let tries = rig.origin.requests.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(rig.origin.requests.count, tries, "no more retries")
    }

    func test_stopping_the_proxy_fails_the_held_requests() async throws {
        let rig = try await makeRig()
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections
        let held = rig.request(url)
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)

        rig.proxy.stop()

        XCTAssertNil(rig.proxy.port)
        await assertClosedWithoutResponse(held)
        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        XCTAssertEqual(rig.log.holdEnds.first?.end, .stopped)
    }

    // MARK: A network whose packets vanish

    /// A try left hanging times out after 1.5 s (connect + response).
    private nonisolated static let hanging = HlsHoldProxy.Timings(
        retryInterval: 0.1,
        maxHold: 20,
        connectTimeout: 0.5,
        responseTimeout: 1,
        bodyIdleTimeout: 2
    )

    func test_a_retry_left_hanging_is_abandoned_for_a_new_one_the_moment_the_network_is_back() async throws {
        let rig = try await makeRig(timings: Self.hanging)
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .hanging

        let held = rig.request(url)
        // The first try and its immediate retry time out: then it is held.
        await waitUntil(timeout: 6, "the hold starts") {
            !rig.log.holdStarts.isEmpty
        }
        // A held retry is now hanging, for up to 1.5 s.
        try await Task.sleep(for: .milliseconds(300))
        rig.origin.mode = .answering
        let restoredAt = Date()
        rig.proxy.networkRestored()

        let got = try await held.value
        XCTAssertEqual(got.status, 200)
        XCTAssertLessThan(secondsSince(restoredAt), 0.7)
        let error = rig.log.holdStarts.first?.error as? URLError
        XCTAssertEqual(error?.code, .timedOut)
    }

    func test_without_a_network_signal_a_retry_left_hanging_ends_at_its_timeout_and_the_next_gets_through() async throws {
        let rig = try await makeRig(timings: Self.hanging)
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .hanging

        let held = rig.request(url)
        await waitUntil(timeout: 6, "the hold starts") {
            !rig.log.holdStarts.isEmpty
        }
        try await Task.sleep(for: .milliseconds(300))
        rig.origin.mode = .answering
        let answeringAt = Date()

        let got = try await held.value
        XCTAssertEqual(got.status, 200)
        XCTAssertLessThan(secondsSince(answeringAt), 2)
        XCTAssertTrue(rig.log.holdRetryFailures.contains {
            ($0 as? URLError)?.code == .timedOut
        })
    }

    // MARK: A network change

    func test_a_network_change_cuts_a_request_in_flight_and_sends_it_again_at_once_on_a_new_connection() async throws {
        var timings = Self.fast
        timings.responseTimeout = 10
        let rig = try await makeRig(timings: timings)
        let answered = Locked(0)
        rig.origin.handler = { request in
            // The first is lost with the network it went out on.
            let first = answered.withValue { count -> Bool in
                defer { count += 1 }
                return count == 0
            }
            if first { return nil }
            return FakeOrigin.Response(body: Data("segment \(request.path)".utf8))
        }
        let url = try rig.wrapInNewSession("/hls/rve/seg-1.ts")

        let request = rig.request(url)
        await waitUntil("the origin got it") { !rig.origin.requests.isEmpty }
        let changedAt = Date()
        rig.proxy.networkChanged()

        let got = try await request.value
        XCTAssertEqual(got.body, "segment /hls/rve/seg-1.ts")
        XCTAssertLessThan(secondsSince(changedAt), 1)
        XCTAssertEqual(rig.origin.requests.count, 2)
    }

    func test_a_network_change_retries_a_held_request_at_once() async throws {
        let rig = try await makeRig(timings: Self.slowRetry)
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections
        let held = rig.request(url)
        await waitUntil("the hold starts") { !rig.log.holdStarts.isEmpty }
        rig.origin.mode = .answering

        let changedAt = Date()
        rig.proxy.networkChanged()

        let got = try await held.value
        XCTAssertEqual(got.status, 200)
        XCTAssertLessThan(
            secondsSince(changedAt), 1, "not after the 30 s retry interval"
        )
    }

    // MARK: Whether the origin answered

    func test_a_session_is_answered_once_a_request_of_it_got_any_response() async throws {
        let rig = try await makeRig()
        let session = rig.proxy.beginSession()
        XCTAssertFalse(rig.proxy.originAnswered(session: session))

        rig.origin.mode = .droppingConnections
        let url = try rig.wrap("/hls/rve/index.m3u8", session: session)
        await assertClosedWithoutResponse(rig.request(url))
        XCTAssertFalse(
            rig.proxy.originAnswered(session: session), "failed before any answer"
        )

        rig.origin.mode = .answering
        rig.origin.handler = { _ in FakeOrigin.Response(status: 404) }
        let got = try await rig.player.get(url)
        XCTAssertEqual(got.status, 404)
        XCTAssertTrue(
            rig.proxy.originAnswered(session: session), "a status is an answer"
        )

        let next = rig.proxy.beginSession()
        XCTAssertFalse(rig.proxy.originAnswered(session: next))
        XCTAssertFalse(
            rig.proxy.originAnswered(session: session),
            "only the current session is followed"
        )
    }

    // MARK: Playlist URIs

    func test_rewrites_the_uri_lines_and_uri_attributes_it_is_told_to_keeping_everything_else() {
        let playlist = "#EXTM3U\r\n"
            + "#EXT-X-MAP:URI=\"/init.mp4\"\r\n"
            + "#EXT-X-DATERANGE:ID=\"a\",X-TITLE=\"Cântec https://x\"\r\n"
            + "#EXTINF:6.0,\r\n"
            + "https://hls.radiocrestin.ro/hls/a/seg-1.ts\r\n"
            + "#EXTINF:6.0,\r\n"
            + "seg-2.ts\r\n"

        let rewritten = HlsHoldProxy.rewritePlaylistURIs(playlist) { uri in
            uri.hasPrefix("seg") ? nil : "P[\(uri)]"
        }

        XCTAssertEqual(
            rewritten,
            "#EXTM3U\r\n"
                + "#EXT-X-MAP:URI=\"P[/init.mp4]\"\r\n"
                + "#EXT-X-DATERANGE:ID=\"a\",X-TITLE=\"Cântec https://x\"\r\n"
                + "#EXTINF:6.0,\r\n"
                + "P[https://hls.radiocrestin.ro/hls/a/seg-1.ts]\r\n"
                + "#EXTINF:6.0,\r\n"
                + "seg-2.ts\r\n"
        )
    }

    func test_a_playlist_with_nothing_to_rewrite_is_relayed_byte_for_byte() throws {
        let target = try XCTUnwrap(HlsHoldProxy.target(
            ofRequestTarget: "/3/https/hls.radiocrestin.ro/hls/rve/index.m3u8",
            allowedHosts: ["hls.radiocrestin.ro"]
        ))
        // As our origin writes them: relative segment URIs, UTF-8 titles.
        let body = Data((
            "#EXTM3U\n"
                + "#EXT-X-PROGRAM-DATE-TIME:2026-10-31T08:00:00.000Z\n"
                + "#EXT-X-DATERANGE:ID=\"1\",X-TITLE=\"Isus e Domnul — Ștefan\"\n"
                + "#EXTINF:6.0,\n"
                + "radio-gosen-1793342519-1793352996.ts\n"
        ).utf8)

        let rewritten = HlsHoldProxy.rewritePlaylist(
            body, of: target, allowedHosts: ["hls.radiocrestin.ro"]
        )

        XCTAssertEqual(rewritten, body)
    }

    func test_absolute_and_root_relative_uris_of_an_allowed_host_are_sent_back_through_the_proxy() async throws {
        let rig = try await makeRig()
        let title = "#EXT-X-DATERANGE:X-TITLE=\"Bucurie în Domnul\"\n"
        let body = "#EXTM3U\n"
            + title
            + "#EXTINF:6.0,\n"
            + rig.origin.url("/hls/rve/seg-1.ts?t=1").absoluteString + "\n"
            + "#EXTINF:6.0,\n"
            + "/hls/rve/seg-2.ts\n"
            + "#EXTINF:6.0,\n"
            + "seg-3.ts\n"
            + "#EXTINF:6.0,\n"
            + "https://cdn.example.com/seg-4.ts\n"
        rig.origin.handler = { request in
            if request.path.hasSuffix(".m3u8") {
                return FakeOrigin.Response(
                    headers: [("Content-Type", "application/vnd.apple.mpegurl")],
                    body: Data(body.utf8)
                )
            }
            return FakeOrigin.Response(body: Data("segment \(request.path)".utf8))
        }
        let session = rig.proxy.beginSession()
        let url = try rig.wrap("/hls/rve/index.m3u8", session: session)

        let got = try await rig.player.get(url)

        let prefix = "/\(session)/http/127.0.0.1:\(rig.origin.port)"
        XCTAssertEqual(
            got.body,
            "#EXTM3U\n"
                + title
                + "#EXTINF:6.0,\n"
                + "\(prefix)/hls/rve/seg-1.ts?t=1\n"
                + "#EXTINF:6.0,\n"
                + "\(prefix)/hls/rve/seg-2.ts\n"
                + "#EXTINF:6.0,\n"
                + "seg-3.ts\n"
                + "#EXTINF:6.0,\n"
                + "https://cdn.example.com/seg-4.ts\n"
        )
        XCTAssertEqual(got.header("Content-Length"), "\(got.data.count)")
        let segment = try await rig.player.get(
            try relative("\(prefix)/hls/rve/seg-2.ts", to: url)
        )
        XCTAssertEqual(segment.body, "segment /hls/rve/seg-2.ts")
    }

    func test_proxied_uris_scheme_relative_root_relative_absolute_and_relative() throws {
        let hosts: Set<String> = ["hls.radiocrestin.ro"]
        let target = try XCTUnwrap(HlsHoldProxy.target(
            ofRequestTarget: "/4/https/hls.radiocrestin.ro:8443/hls/a/index.m3u8",
            allowedHosts: hosts
        ))
        func proxied(_ uri: String) -> String? {
            HlsHoldProxy.proxiedURI(uri, of: target, allowedHosts: hosts)
        }

        XCTAssertEqual(
            proxied("//hls.radiocrestin.ro/hls/b/seg.ts"),
            "/4/https/hls.radiocrestin.ro/hls/b/seg.ts"
        )
        XCTAssertEqual(
            proxied("//cdn.example.com/seg.ts"),
            "https://cdn.example.com/seg.ts",
            "another host gets the playlist's scheme, not the proxy's http"
        )
        XCTAssertEqual(
            proxied("/hls/b/seg.ts?x=1"),
            "/4/https/hls.radiocrestin.ro:8443/hls/b/seg.ts?x=1"
        )
        XCTAssertEqual(
            proxied("http://HLS.radiocrestin.ro/a.ts"),
            "/4/http/hls.radiocrestin.ro/a.ts"
        )
        XCTAssertNil(proxied("https://cdn.example.com/seg.ts"))
        XCTAssertNil(proxied("seg-1.ts"))
        XCTAssertNil(proxied("../b/seg-1.ts"))
    }

    func test_takes_a_proxy_request_target_apart() throws {
        let hosts: Set<String> = ["hls.radiocrestin.ro"]
        let target = try XCTUnwrap(HlsHoldProxy.target(
            ofRequestTarget: "/12/https/hls.radiocrestin.ro/hls/a/index.m3u8?ref=x&s=y",
            allowedHosts: hosts
        ))
        XCTAssertEqual(target.session, 12)
        XCTAssertEqual(
            target.upstream.absoluteString,
            "https://hls.radiocrestin.ro/hls/a/index.m3u8?ref=x&s=y"
        )
        XCTAssertEqual(target.resource, "index.m3u8")

        for invalid in [
            "/hls/a/index.m3u8",
            "/x/https/hls.radiocrestin.ro/a.m3u8",
            "/1/ftp/hls.radiocrestin.ro/a.m3u8",
            "/1/https/example.com/a.m3u8",
            "/1/https/hls.radiocrestin.ro",
            "*",
        ] {
            XCTAssertNil(
                HlsHoldProxy.target(ofRequestTarget: invalid, allowedHosts: hosts),
                invalid
            )
        }
    }

    func test_parses_a_request_head_as_it_arrives() {
        let head = "GET /1/https/h/a.m3u8?x=1 HTTP/1.1\r\n"
            + "Host: 127.0.0.1:5000\r\n"
            + "User-Agent: AppleCoreMedia/1.0.0\r\n"
            + "X-Playback-Session-Id:ABC\r\n\r\n"
        let bytes = Data(head.utf8)

        XCTAssertEqual(HlsHoldProxy.RequestHead.parse(bytes.prefix(20)), .incomplete)
        XCTAssertEqual(
            HlsHoldProxy.RequestHead.parse(bytes),
            .complete(HlsHoldProxy.RequestHead(
                method: "GET",
                target: "/1/https/h/a.m3u8?x=1",
                headers: [
                    .init(name: "host", value: "127.0.0.1:5000"),
                    .init(name: "user-agent", value: "AppleCoreMedia/1.0.0"),
                    .init(name: "x-playback-session-id", value: "ABC"),
                ]
            ))
        )
        XCTAssertEqual(
            HlsHoldProxy.RequestHead.parse(Data("HELLO\r\n\r\n".utf8)), .malformed
        )
        XCTAssertEqual(
            HlsHoldProxy.RequestHead.parse(Data(repeating: 0x41, count: 20_000)),
            .malformed
        )
    }

    // MARK: Lifecycle

    func test_wraps_only_http_urls_of_an_allowed_host_keeping_the_query_and_the_port() async throws {
        let proxy = HlsHoldProxy(allowedHosts: ["hls.radiocrestin.ro"])
        addTeardownBlock { proxy.stop() }
        func wrapped(_ upstream: String, session: Int) throws -> String? {
            let url = try XCTUnwrap(URL(string: upstream))
            return proxy.wrap(url, session: session)?.absoluteString
        }
        let upstream = "https://hls.radiocrestin.ro/hls/a/index.m3u8?ref=x&s=y"
        XCTAssertNil(try wrapped(upstream, session: 1), "not listening yet")
        let started = await proxy.start()
        XCTAssertTrue(started)
        let port = try XCTUnwrap(proxy.port)

        XCTAssertEqual(
            try wrapped(upstream, session: 3),
            "http://127.0.0.1:\(port)/3/https/hls.radiocrestin.ro/hls/a/"
                + "index.m3u8?ref=x&s=y"
        )
        XCTAssertEqual(
            try wrapped("https://HLS.radiocrestin.ro:8443/hls/a.m3u8", session: 4),
            "http://127.0.0.1:\(port)/4/https/hls.radiocrestin.ro:8443/hls/a.m3u8"
        )
        XCTAssertNil(try wrapped("https://stream.example.com/a.mp3", session: 1))
        XCTAssertNil(try wrapped("ftp://hls.radiocrestin.ro/a.m3u8", session: 1))
        let allowed = try XCTUnwrap(URL(string: "https://hls.radiocrestin.ro/x"))
        let other = try XCTUnwrap(URL(string: "https://other.ro/x"))
        XCTAssertTrue(proxy.allows(allowed))
        XCTAssertFalse(proxy.allows(other))
    }

    func test_restarts_on_its_previous_port_and_tells_when_it_could_not() async throws {
        let rig = try await makeRig()
        let url = try rig.wrapInNewSession("/hls/rve/index.m3u8")
        // A request, so that its connection lingers on the port.
        _ = try await rig.player.get(url)
        let port = try XCTUnwrap(rig.proxy.port)

        rig.proxy.stop()
        XCTAssertNil(rig.proxy.port)
        XCTAssertFalse(rig.proxy.serves(url))
        let restarted = await rig.proxy.start()
        XCTAssertTrue(restarted)
        XCTAssertEqual(rig.proxy.port, port)
        XCTAssertTrue(rig.proxy.serves(url))

        rig.proxy.stop()
        let squatter = try await PortSquatter.take(port: port)
        let running = await rig.proxy.ensureRunning()
        XCTAssertTrue(running)
        XCTAssertNotEqual(rig.proxy.port, port)
        XCTAssertFalse(
            rig.proxy.serves(url),
            "what was loaded through the old port must be loaded again"
        )
        withExtendedLifetime(squatter) {}
    }

    func test_keeps_its_port_across_quick_closes_and_restarts_of_its_socket() async throws {
        let rig = try await makeRig()
        let port = rig.proxy.port
        for round in 0..<30 {
            rig.proxy.debugCloseListener()
            let restarted = await rig.proxy.ensureRunning()
            XCTAssertTrue(restarted, "round \(round)")
            let running = await rig.proxy.ensureRunning()
            XCTAssertTrue(running, "round \(round)")
            XCTAssertEqual(rig.proxy.port, port, "round \(round)")
        }
    }

    func test_ensure_running_leaves_a_listener_that_accepts_alone() async throws {
        let rig = try await makeRig()
        let port = rig.proxy.port

        let running = await rig.proxy.ensureRunning()

        XCTAssertTrue(running)
        XCTAssertEqual(rig.proxy.port, port)
        await letQueuedWorkRun()
        XCTAssertEqual(rig.log.serverStarts, 1)
        XCTAssertEqual(rig.log.serverCloses, 0)
    }

    func test_a_session_keeps_holding_across_a_restart_on_the_same_port() async throws {
        let rig = try await makeRig(timings: Self.slowRetry)
        let url = try await establishedPlaylist(rig)
        rig.proxy.debugCloseListener()
        let restarted = await rig.proxy.ensureRunning()
        XCTAssertTrue(restarted)
        rig.origin.mode = .droppingConnections

        let held = rig.request(url)
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)
        rig.origin.mode = .answering
        rig.proxy.networkRestored()

        let got = try await held.value
        XCTAssertEqual(got.status, 200)
    }

    func test_an_event_listener_may_call_the_proxy_back() async throws {
        let proxyBox = Locked<HlsHoldProxy?>(nil)
        let rig = try await makeRig(onEvent: { _ in
            // On the event queue: must not deadlock with the proxy's.
            _ = proxyBox.current?.port
            _ = proxyBox.current?.originAnswered(session: 1)
        })
        proxyBox.withValue { $0 = rig.proxy }
        let url = try await establishedPlaylist(rig)
        rig.origin.mode = .droppingConnections
        let held = rig.request(url)
        let pending = await isStillPending(held)
        XCTAssertTrue(pending)
        rig.origin.mode = .answering

        let got = try await held.value
        XCTAssertEqual(got.status, 200)
        await waitUntil("the hold ends") { rig.log.holdEnds.count == 1 }
        proxyBox.withValue { $0 = nil }
    }

    // MARK: AVPlayer

    func test_avplayer_loads_an_hls_playlist_through_the_proxy() async throws {
        let rig = try await makeRig(timings: HlsHoldProxy.Timings())
        rig.origin.handler = { request in
            switch request.path {
            case "/vod/index.m3u8":
                return FakeOrigin.Response(
                    headers: [("Content-Type", "application/vnd.apple.mpegurl")],
                    body: Data(Self.vodPlaylist.utf8)
                )
            case "/vod/seg-0.mp3":
                return FakeOrigin.Response(
                    headers: [("Content-Type", "audio/mpeg")],
                    body: Self.silentMP3Segment(timestamp: 0)
                )
            case "/vod/seg-1.mp3":
                return FakeOrigin.Response(
                    headers: [("Content-Type", "audio/mpeg")],
                    body: Self.silentMP3Segment(timestamp: 89_370)
                )
            default:
                return FakeOrigin.Response(status: 404)
            }
        }
        let url = try rig.wrapInNewSession("/vod/index.m3u8")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)

        await waitUntil(timeout: 15, "the item is ready or failed") {
            item.status != .unknown
        }

        XCTAssertEqual(
            item.status, .readyToPlay, String(describing: item.error)
        )
        let paths = rig.origin.requests.map(\.path)
        XCTAssertEqual(paths.first, "/vod/index.m3u8")
        XCTAssertTrue(paths.contains("/vod/seg-0.mp3"), "\(paths)")
        XCTAssertTrue(
            rig.origin.requests.first?.headers["user-agent"]?
                .contains("AppleCoreMedia") == true,
            "AVPlayer's own requests, through the proxy"
        )
        player.replaceCurrentItem(with: nil)
    }

    /// Two segments of packed MP3 audio, ~1 s each.
    private nonisolated static let vodPlaylist = "#EXTM3U\n"
        + "#EXT-X-VERSION:3\n"
        + "#EXT-X-TARGETDURATION:1\n"
        + "#EXT-X-MEDIA-SEQUENCE:0\n"
        + "#EXT-X-PLAYLIST-TYPE:VOD\n"
        + "#EXTINF:0.993,\n"
        + "seg-0.mp3\n"
        + "#EXTINF:0.993,\n"
        + "seg-1.mp3\n"
        + "#EXT-X-ENDLIST\n"

    /// ~1 s of silent MPEG-1 Layer III (44.1 kHz, 128 kb/s, stereo): 38
    /// frames whose side information is all zeros, which decodes as
    /// silence. HLS packed audio starts with an ID3 tag carrying the
    /// segment's 90 kHz `timestamp`.
    private nonisolated static func silentMP3Segment(
        timestamp: UInt64
    ) -> Data {
        var payload = Data("com.apple.streaming.transportStreamTimestamp".utf8)
        payload.append(0)
        withUnsafeBytes(of: timestamp.bigEndian) {
            payload.append(contentsOf: $0)
        }
        func syncSafe(_ value: Int) -> [UInt8] {
            [21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) }
        }
        var data = Data("ID3".utf8)
        data.append(contentsOf: [4, 0, 0] + syncSafe(10 + payload.count))
        data.append(contentsOf: Data("PRIV".utf8))
        data.append(contentsOf: syncSafe(payload.count) + [0, 0])
        data.append(payload)
        // MPEG-1 Layer III, no CRC, 128 kb/s, 44.1 kHz, no padding, stereo:
        // 144 * 128000 / 44100 = 417 bytes a frame.
        var frame = Data([0xFF, 0xFB, 0x90, 0x00])
        frame.append(Data(count: 417 - 4))
        for _ in 0..<38 { data.append(frame) }
        return data
    }
}
