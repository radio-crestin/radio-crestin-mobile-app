import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the WhatsApp deep link the TV renders as a QR code.
///
/// Apple TV can't run WhatsApp, so contact happens by scanning a QR with a
/// phone. The link carries a prefilled Romanian message that already
/// contains the diagnostics support would otherwise have to ask for.
///
/// The message assembly is a pure function so it can be unit-tested
/// without a device, a bundle, or a network.
enum ContactLinks {
    /// Radio Crestin's support WhatsApp number, in international format
    /// without `+`. Same number the iPhone and Android TV apps use
    /// (`lib/tv/pages/tv_settings.dart`).
    static let whatsAppNumber = "40766338046"
    static let whatsAppDisplayNumber = "+40 766 338 046"

    /// Diagnostics attached to a support message. Every field is optional
    /// because the contact affordance is reachable from screens that know
    /// different amounts about what broke.
    struct Diagnostics: Equatable {
        var stationTitle: String?
        var stationSlug: String?
        /// The stream URL or playlist-item title that failed, when known.
        var failingSource: String?
        var deviceId: String
        var appVersion: String
        var systemVersion: String

        init(
            stationTitle: String? = nil,
            stationSlug: String? = nil,
            failingSource: String? = nil,
            deviceId: String = DeviceIdentity.deviceId,
            appVersion: String = ContactLinks.currentAppVersion,
            systemVersion: String = ContactLinks.currentSystemVersion
        ) {
            self.stationTitle = stationTitle
            self.stationSlug = stationSlug
            self.failingSource = failingSource
            self.deviceId = deviceId
            self.appVersion = appVersion
            self.systemVersion = systemVersion
        }
    }

    /// Longest source string we embed. A QR has to stay readable across a
    /// living room, and payload length drives module density — so a long
    /// stream URL is truncated rather than allowed to blur the code.
    static let maxSourceLength = 40

    /// The prefilled message body, in Romanian.
    ///
    /// Kept deliberately terse: a greeting, the problem statement, then a
    /// compact diagnostics block. Anything longer costs QR readability.
    static func supportMessage(_ diagnostics: Diagnostics) -> String {
        var lines = [
            "Bună ziua,",
            "am o problemă cu redarea pe Apple TV."
        ]
        if let title = diagnostics.stationTitle, !title.isEmpty {
            let slug = diagnostics.stationSlug.map { " (\($0))" } ?? ""
            lines.append("Post: \(title)\(slug)")
        } else if let slug = diagnostics.stationSlug, !slug.isEmpty {
            lines.append("Post: \(slug)")
        }
        if let source = diagnostics.failingSource, !source.isEmpty {
            lines.append("Sursă: \(truncate(source))")
        }
        lines.append(
            "App \(diagnostics.appVersion) · tvOS \(diagnostics.systemVersion)"
        )
        lines.append("ID: \(diagnostics.deviceId)")
        return lines.joined(separator: "\n")
    }

    /// Full `https://wa.me/<number>?text=<encoded>` link.
    static func whatsAppURL(_ diagnostics: Diagnostics) -> URL? {
        let encoded = percentEncoded(supportMessage(diagnostics))
        return URL(string: "https://wa.me/\(whatsAppNumber)?text=\(encoded)")
    }

    /// Mirrors Dart's `Uri.encodeComponent` / JS `encodeURIComponent` so
    /// the link matches what the phone apps generate: spaces become `%20`
    /// and newlines `%0A`.
    static func percentEncoded(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func truncate(_ value: String) -> String {
        guard value.count > maxSourceLength else { return value }
        return String(value.prefix(maxSourceLength - 1)) + "…"
    }

    // MARK: - Environment

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)(\(build))"
    }

    static var currentSystemVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return "?"
        #endif
    }
}
