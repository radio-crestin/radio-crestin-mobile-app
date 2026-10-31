import Foundation
import PostHog

/// Remote kill switch for the hold proxy that live radio HLS loads go
/// through (`HlsHoldProxy`): the PostHog flag `hls_hold_proxy`, the one the
/// iPhone app reads, on unless defined and off.
///
/// Every live HLS load of the origin goes through the proxy, so a fault in
/// it would cost every Apple TV its HLS streams: it must be switchable
/// without a release. Turned off, loads go straight to the origin again
/// from the next one on. The last value seen is kept in UserDefaults, so it
/// applies from launch, before PostHog has loaded its flags.
enum HlsHoldProxyFlag {
    static let flagKey = "hls_hold_proxy"

    private static let cacheKey = "tv.hlsHoldProxyEnabled"
    private static var observer: NSObjectProtocol?

    /// Whether live HLS loads may go through the proxy.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: cacheKey) as? Bool ?? true
    }

    /// Caches the flag each time PostHog loads flags. Called once, after
    /// PostHog is set up.
    static func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: PostHogSDK.didReceiveFeatureFlags,
            object: nil,
            queue: .main
        ) { _ in
            let value = PostHogSDK.shared.getFeatureFlag(
                flagKey, sendFeatureFlagEvent: false
            )
            UserDefaults.standard.set(isEnabled(flagValue: value), forKey: cacheKey)
        }
    }

    /// Pure: an undefined flag keeps the proxy on; a boolean decides; a
    /// multivariate value means the flag is on.
    static func isEnabled(flagValue: Any?) -> Bool {
        guard let flagValue else { return true }
        return flagValue as? Bool ?? true
    }
}
