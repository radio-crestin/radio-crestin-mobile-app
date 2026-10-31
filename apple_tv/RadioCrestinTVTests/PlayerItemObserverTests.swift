import AVFoundation
import XCTest
@testable import RadioCrestinTV

/// What AVFoundation posts about one item, as the engine hears it. When an
/// HLS origin goes away mid-play, `AVPlayerItemFailedToPlayToEndTime` is
/// the only signal (E2a): the item's `status` stays `readyToPlay`.
///
/// The items belong to no player, so they never load: only the
/// notifications a test posts reach the observer.
@MainActor
final class PlayerItemObserverTests: XCTestCase {

    private final class Recorder {
        var events: [PlayerItemObserver.Event] = []
    }

    private func makeItem() throws -> AVPlayerItem {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9/a.m3u8"))
        return AVPlayerItem(url: url)
    }

    private func observe(
        _ item: AVPlayerItem,
        into recorder: Recorder
    ) -> PlayerItemObserver {
        PlayerItemObserver(item: item) { recorder.events.append($0) }
    }

    private func postFailedToPlayToEnd(_ item: AVPlayerItem, error: Error) {
        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: error]
        )
    }

    func test_failed_to_play_to_end_is_reported_with_its_error() async throws {
        let item = try makeItem()
        let recorder = Recorder()
        let observer = observe(item, into: recorder)
        defer { observer.cancel() }

        postFailedToPlayToEnd(item, error: URLError(.resourceUnavailable))

        let delivered = await eventually { !recorder.events.isEmpty }
        XCTAssertTrue(delivered)
        guard case .failedToPlayToEnd(let error)? = recorder.events.first else {
            return XCTFail("expected failedToPlayToEnd, got \(recorder.events)")
        }
        XCTAssertEqual((error as? URLError)?.code, .resourceUnavailable)
    }

    func test_played_to_end_is_reported() async throws {
        let item = try makeItem()
        let recorder = Recorder()
        let observer = observe(item, into: recorder)
        defer { observer.cancel() }

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime, object: item
        )

        let delivered = await eventually { !recorder.events.isEmpty }
        XCTAssertTrue(delivered)
        guard case .playedToEnd? = recorder.events.first else {
            return XCTFail("expected playedToEnd, got \(recorder.events)")
        }
    }

    func test_notifications_about_another_item_are_ignored() async throws {
        let item = try makeItem()
        let other = try makeItem()
        let recorder = Recorder()
        let observer = observe(item, into: recorder)
        defer { observer.cancel() }

        postFailedToPlayToEnd(other, error: URLError(.timedOut))
        await letQueuedWorkRun()

        XCTAssertTrue(recorder.events.isEmpty)
    }

    /// The engine cancels the observer before it loads the next item; a
    /// delivery already queued for the old item must not reach it.
    func test_a_cancelled_observer_drops_deliveries_already_queued() async throws {
        let item = try makeItem()
        let recorder = Recorder()
        let observer = observe(item, into: recorder)

        postFailedToPlayToEnd(item, error: URLError(.timedOut))
        observer.cancel()
        await letQueuedWorkRun()

        XCTAssertTrue(recorder.events.isEmpty)
    }
}
