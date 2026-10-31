import Foundation
import PostHog

/// PostHog wrapper for the Apple TV app. Mirrors the
/// `lib/services/analytics_service.dart` setup: same project key, same
/// host, automatic lifecycle events, error tracking on. Events are
/// fire-and-forget so the UI never waits on the queue.
enum Analytics {
    private static let projectKey = "phc_nYXw3QDHsrAMhEGXnvLcMDgyTG3rgKtEK2HaxV97csvy"
    private static let host = "https://k.radiocrestin.ro"

    static func bootstrap() {
        let config = PostHogConfig(projectToken: projectKey, host: host)
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
        HlsHoldProxyFlag.startObserving()
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

    /// Anonymous PostHog identity for this device. Embedded in the WhatsApp
    /// contact message so support can correlate a report with analytics —
    /// mirrors `globals.deviceId` in the Flutter apps.
    static var distinctId: String {
        PostHogSDK.shared.getDistinctId()
    }

    static func captureError(
        _ error: Error,
        context: String,
        extra: [String: Any] = [:]
    ) {
        capture(
            "exception_caught",
            properties: errorProperties(error, context: context, extra: extra)
        )
    }

    /// The properties of an `exception_caught` event. The description is
    /// in the Apple TV's language, so the error's domain and code come
    /// along: dashboards group by them whatever the language.
    static func errorProperties(
        _ error: Error,
        context: String,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        let nsError = error as NSError
        var props: [String: Any] = [
            "context": context,
            "error_description": error.localizedDescription,
            "error_type": String(describing: type(of: error)),
            "error_domain": nsError.domain,
            "error_code": nsError.code
        ]
        props.merge(extra) { current, _ in current }
        return props
    }

    // MARK: - Domain events

    static func listeningStarted(
        stationSlug: String,
        stationTitle: String,
        stationId: Int,
        stationType: String = "radio"
    ) {
        capture("listening_started", properties: [
            "station_slug": stationSlug,
            "station_name": stationTitle,
            "station_id": stationId,
            "station_type": stationType
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
