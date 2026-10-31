import Foundation

/// How far behind live the listener hears radio: the "Încărcare în avans"
/// setting, with the same choices, labels and default as the phone app
/// (`SeekModeManager`).
///
/// Playing behind live is what lets the player hold that much audio ahead
/// of the playhead: an HLS player can only buffer audio that already
/// exists. With the hold proxy (`HlsHoldProxy`) keeping AVPlayer from
/// giving up during an outage, a network break shorter than the offset is
/// not heard at all; live, only ~18–24 s are.
enum SeekMode: String, CaseIterable, Identifiable {
    case instant
    case twoMinutes
    case fiveMinutes

    /// The phone's default: a 2-minute buffer rides out most Wi-Fi breaks
    /// and the listener barely notices a 2-minute delay on radio.
    static let `default` = SeekMode.twoMinutes

    var id: String { rawValue }

    /// How far behind live playback starts, in seconds. Live starts at the
    /// playlist's own `EXT-X-START` (18 s behind the live edge), counted
    /// here as no offset.
    var offset: TimeInterval {
        switch self {
        case .instant: return 0
        case .twoMinutes: return 2 * 60
        case .fiveMinutes: return 5 * 60
        }
    }

    var label: String {
        switch self {
        case .instant: return "Live"
        case .twoMinutes: return "2 minute"
        case .fiveMinutes: return "5 minute"
        }
    }

    /// What the choice means for the listener, under its label.
    var explanation: String {
        switch self {
        case .instant:
            return "Asculți live, cu un mic decalaj de câteva secunde."
        case .twoMinutes:
            return "Decalaj de 2 minute față de live. O cădere a internetului mai scurtă de atât nu se aude."
        case .fiveMinutes:
            return "Decalaj de 5 minute față de live. Pentru o conexiune instabilă."
        }
    }
}

/// The origin's start variants of a live HLS playlist: `index-2m.m3u8` and
/// `index-5m.m3u8` are `index.m3u8` with an `EXT-X-START` 2 or 5 minutes
/// behind live, over the same 11-minute window. AVPlayer starts where the
/// playlist says, so a variant begins behind live with no seek after the
/// load. Mirrors the phone's `HlsStartVariant`.
enum HlsStartVariant {
    /// The origin's hosts, the only ones that publish the variants.
    static let hosts: Set<String> = ["hls.radiocrestin.ro", "live.radiocrestin.ro"]

    private static let livePlaylist = "index.m3u8"

    /// The variant of `url` that starts `mode`'s offset behind live, with
    /// its query kept; nil for live, another host or another playlist.
    static func url(for url: URL, mode: SeekMode) -> URL? {
        guard let playlist = playlist(for: mode),
              let host = url.host?.lowercased(), hosts.contains(host),
              url.lastPathComponent == livePlaylist,
              var components = URLComponents(
                  url: url, resolvingAgainstBaseURL: false
              )
        else { return nil }
        components.path = String(components.path.dropLast(livePlaylist.count))
            + playlist
        return components.url
    }

    private static func playlist(for mode: SeekMode) -> String? {
        switch mode {
        case .instant: return nil
        case .twoMinutes: return "index-2m.m3u8"
        case .fiveMinutes: return "index-5m.m3u8"
        }
    }
}
