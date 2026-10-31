import AVFoundation
import XCTest
@testable import RadioCrestinTV

@MainActor
final class SystemPlaybackEventsTests: XCTestCase {

    private func event(
        _ name: Notification.Name, _ info: [AnyHashable: Any]?
    ) -> SystemPlaybackEvents.Event? {
        SystemPlaybackEvents.event(
            from: Notification(name: name, object: nil, userInfo: info)
        )
    }

    // MARK: - Interruptions

    func test_interruption_began() {
        XCTAssertEqual(
            event(AVAudioSession.interruptionNotification, [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ]),
            .interruptionBegan
        )
    }

    func test_interruption_ended_with_should_resume() {
        XCTAssertEqual(
            event(AVAudioSession.interruptionNotification, [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]),
            .interruptionEnded(shouldResume: true)
        )
    }

    func test_interruption_ended_without_options_does_not_resume() {
        XCTAssertEqual(
            event(AVAudioSession.interruptionNotification, [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue
            ]),
            .interruptionEnded(shouldResume: false)
        )
    }

    func test_interruption_without_a_type_is_ignored() {
        XCTAssertNil(event(AVAudioSession.interruptionNotification, nil))
    }

    // MARK: - Route changes

    func test_losing_the_output_device_is_reported() {
        XCTAssertEqual(
            event(AVAudioSession.routeChangeNotification, [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason
                        .oldDeviceUnavailable.rawValue
            ]),
            .outputLost
        )
    }

    func test_other_route_changes_are_ignored() {
        XCTAssertNil(event(AVAudioSession.routeChangeNotification, [
            AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
        ]))
    }

    // MARK: - Rate changes

    func test_a_background_pause_is_reported() {
        XCTAssertEqual(
            event(AVPlayer.rateDidChangeNotification, [
                AVPlayer.rateDidChangeReasonKey:
                    AVPlayer.RateDidChangeReason.appBackgrounded.rawValue
            ]),
            .pausedInBackground
        )
    }

    func test_rate_changes_the_app_made_are_ignored() {
        XCTAssertNil(event(AVPlayer.rateDidChangeNotification, [
            AVPlayer.rateDidChangeReasonKey:
                AVPlayer.RateDidChangeReason.setRateCalled.rawValue
        ]))
    }

    func test_unrelated_notifications_are_ignored() {
        XCTAssertNil(event(.AVPlayerItemDidPlayToEndTime, nil))
    }
}
