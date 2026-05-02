import Foundation
import PostHog

/// PostHog wrapper for the Apple TV app. Mirrors the
/// `lib/services/analytics_service.dart` setup: same project key, same
/// host, automatic lifecycle events, error tracking on. Events are
/// fire-and-forget so the UI never waits on the queue.
enum Analytics {
    private static let projectKey = "phc_9lTquHDSyoFxkYq4VPd8cFiQ21VZd627Lv8jSV8S7Fi"
    private static let host = "https://k.radiocrestin.ro"

    static func bootstrap() {
        let config = PostHogConfig(apiKey: projectKey, host: host)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false   // we'll capture our own screen events
        config.flushAt = 20
        config.flushIntervalSeconds = 30
        config.maxQueueSize = 1000
        config.maxBatchSize = 50
        config.personProfiles = .identifiedOnly
        #if DEBUG
        config.debug = true
        #endif
        PostHogSDK.shared.setup(config)
    }

    // MARK: - Event helpers — match the Flutter event names so dashboards
    // built for iPhone / Android keep working with tvOS sessions blended in.

    static func capture(
        _ event: String,
        properties: [String: Any]? = nil
    ) {
        PostHogSDK.shared.capture(event, properties: properties)
    }

    static func screen(_ name: String, properties: [String: Any]? = nil) {
        PostHogSDK.shared.screen(name, properties: properties)
    }

    static func captureError(
        _ error: Error,
        context: String,
        extra: [String: Any] = [:]
    ) {
        var props: [String: Any] = [
            "context": context,
            "error_description": error.localizedDescription,
            "error_type": String(describing: type(of: error))
        ]
        props.merge(extra) { current, _ in current }
        capture("exception_caught", properties: props)
    }

    // MARK: - Domain events

    static func listeningStarted(stationSlug: String, stationTitle: String, stationId: Int) {
        capture("listening_started", properties: [
            "station_slug": stationSlug,
            "station_name": stationTitle,
            "station_id": stationId
        ])
    }

    static func listeningStopped(
        stationSlug: String, stationTitle: String, stationId: Int,
        durationSeconds: Int, reason: String
    ) {
        capture("listening_stopped", properties: [
            "station_slug": stationSlug,
            "station_name": stationTitle,
            "station_id": stationId,
            "duration_seconds": durationSeconds,
            "reason": reason
        ])
    }

    static func favoriteToggled(stationSlug: String, willBeFavorite: Bool) {
        capture(willBeFavorite ? "favorite_added" : "favorite_removed",
                properties: ["station_slug": stationSlug])
    }
}
