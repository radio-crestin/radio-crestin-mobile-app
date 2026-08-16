import Foundation

/// Turns a YouTube watch/live URL into a URL `AVPlayer` can open.
///
/// tvOS ships no WebKit, so the IFrame embed the phone apps use is
/// impossible here. Instead we ask YouTube's **innertube** player
/// endpoint — the private JSON API the official first-party clients
/// (TVHTML5 on Apple TV / Cobalt, the iOS app, …) talk to — for the
/// video's streaming manifest, and hand the resulting URL to the normal
/// AVPlayer pipeline. Live broadcasts return an `hlsManifestUrl`, which
/// is exactly what AVPlayer wants; VODs may instead expose a
/// self-contained progressive MP4.
///
/// ## Stability warning
///
/// Innertube is **unofficial and unversioned**. Google changes client
/// version strings, tightens bot checks (`LOGIN_REQUIRED`), and migrates
/// formats (the ongoing SABR rollout is removing progressive MP4s) with
/// no notice. Everything that knows about the wire format lives in this
/// one file so schema churn is a single-file fix, and **every failure
/// path is non-fatal**: `resolve` throws, `AudioPlayer` treats the item
/// as unplayable, and the UI falls back to the existing skip-card. A
/// broken resolver degrades the experience; it never hangs or crashes it.
actor YoutubeStreamResolver {

    // MARK: - Public surface

    enum ResolveError: Error, LocalizedError {
        case notAYoutubeURL
        case unplayable(reason: String)
        case noCompatibleStream
        case transport(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .notAYoutubeURL: return "Not a YouTube URL"
            case .unplayable(let reason): return "YouTube: \(reason)"
            case .noCompatibleStream:
                return "No AVPlayer-compatible YouTube stream"
            case .transport(let error): return error.localizedDescription
            }
        }
    }

    /// A resolved, directly playable stream.
    struct Resolved: Equatable {
        let url: URL
        /// True when the source is an HLS manifest (live or VOD). Lets the
        /// player apply its live-stream buffering rules.
        let isHLS: Bool
        /// True when YouTube reports an in-progress live broadcast.
        let isLive: Bool
        let title: String
        /// Seconds until YouTube's signed URLs expire; drives cache TTL.
        let expiresIn: TimeInterval
    }

    static let shared = YoutubeStreamResolver()

    private let session: URLSession
    private var cache: [String: (value: Resolved, expires: Date)] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolves a YouTube page URL to a playable stream URL.
    ///
    /// Cached per video id until YouTube's own expiry (capped), because a
    /// playlist of 25 clips would otherwise re-resolve on every skip.
    func resolve(pageURL: String) async throws -> Resolved {
        guard let videoId = Self.videoId(from: pageURL) else {
            throw ResolveError.notAYoutubeURL
        }
        if let hit = cache[videoId], hit.expires > Date() {
            return hit.value
        }
        var lastError: Error = ResolveError.noCompatibleStream
        // Clients are tried in order of how useful their answer is to
        // AVPlayer. The TV client is first because this *is* a TV app and
        // it is the client most likely to be served an HLS manifest.
        for client in Self.clients {
            do {
                let resolved = try await request(videoId: videoId, client: client)
                cache[videoId] = (
                    resolved,
                    Date().addingTimeInterval(
                        min(resolved.expiresIn, Self.maxCacheTTL)
                    )
                )
                return resolved
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Drops cached entries. Used when a station is re-tuned after an
    /// error so a stale/expired URL isn't retried.
    func invalidate() { cache.removeAll() }

    // MARK: - Video id extraction

    /// Pulls the 11-character video id out of any of YouTube's URL shapes:
    /// `watch?v=`, `youtu.be/`, `/live/`, `/embed/`, `/shorts/`.
    /// Returns nil for playlist-only URLs (no single video to play).
    nonisolated static func videoId(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return nil }
        let host = (components.host ?? "").lowercased()
        guard host.contains("youtube.com") || host.contains("youtu.be") else {
            // A bare id is also accepted so callers can pass one directly.
            return isPlausibleId(trimmed) ? trimmed : nil
        }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
           isPlausibleId(v) {
            return v
        }
        // Path-based forms. `youtu.be/<id>` has the id as the only segment.
        let segments = components.path.split(separator: "/").map(String.init)
        if host.contains("youtu.be"), let first = segments.first,
           isPlausibleId(first) {
            return first
        }
        for marker in ["live", "embed", "shorts", "v"] {
            if let idx = segments.firstIndex(of: marker),
               idx + 1 < segments.count,
               isPlausibleId(segments[idx + 1]) {
                return segments[idx + 1]
            }
        }
        return nil
    }

    /// Playlist id from a `list=` query parameter, when present.
    nonisolated static func playlistId(from raw: String) -> String? {
        guard let components = URLComponents(string: raw) else { return nil }
        return components.queryItems?
            .first(where: { $0.name == "list" })?.value
    }

    /// YouTube ids are 11 chars of the URL-safe base64 alphabet.
    nonisolated static func isPlausibleId(_ candidate: String) -> Bool {
        guard candidate.count == 11 else { return false }
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        return candidate.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - Innertube request

    private struct Client {
        let name: String
        let version: String
        let userAgent: String
        let clientNameHeader: String
        let extraContext: [String: Any]
    }

    /// Public innertube key. Shipped in YouTube's own web bundle — this is
    /// not a credential and grants nothing beyond the anonymous player
    /// endpoint.
    private static let innertubeKey =
        "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8" // gitleaks:allow

    private static let endpoint =
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&key="
        + innertubeKey

    /// Cap on how long a resolved URL is reused, regardless of what
    /// YouTube advertises.
    private static let maxCacheTTL: TimeInterval = 60 * 30

    private static let clients: [Client] = [
        // TV client: what an Apple TV / Cobalt device would send. Most
        // likely to be handed a plain HLS manifest for live content.
        Client(
            name: "TVHTML5",
            version: "7.20250101.10.00",
            userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.1",
            clientNameHeader: "7",
            extraContext: [:]
        ),
        // iOS client: returns unsigned (non-ciphered) URLs, and
        // `hlsManifestUrl` for live broadcasts.
        Client(
            name: "IOS",
            version: "20.03.02",
            userAgent:
                "com.google.ios.youtube/20.03.02 (iPhone16,2; U; CPU iOS 18_2_1 like Mac OS X)",
            clientNameHeader: "5",
            extraContext: [
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.2.1.22C161"
            ]
        ),
        // Embedded-player client: sometimes playable when the others are
        // age/bot gated.
        Client(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            version: "2.0",
            userAgent:
                "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15",
            clientNameHeader: "85",
            extraContext: ["clientScreen": "EMBED"]
        )
    ]

    private func request(videoId: String, client: Client) async throws -> Resolved {
        guard let url = URL(string: Self.endpoint) else {
            throw ResolveError.noCompatibleStream
        }
        var context: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "gl": "US"
        ]
        context.merge(client.extraContext) { current, _ in current }

        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": context],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(client.clientNameHeader,
                     forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.version,
                     forHTTPHeaderField: "X-YouTube-Client-Version")
        // Keep well inside the player's own connect budget so a slow
        // resolve can never be the thing that hangs playback.
        req.timeoutInterval = Self.requestTimeout
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: req)
        } catch {
            throw ResolveError.transport(underlying: error)
        }
        return try Self.parse(data)
    }

    /// Resolution must finish well inside `PlaybackTimeoutPolicy`'s
    /// budget, since it happens before AVPlayer is even handed a URL.
    static let requestTimeout: TimeInterval = 6

    // MARK: - Response parsing (the churn-prone part)

    /// Extracts the best AVPlayer-compatible stream from an innertube
    /// player response.
    ///
    /// Preference order:
    /// 1. `streamingData.hlsManifestUrl` — adaptive, native to AVPlayer,
    ///    present for live broadcasts.
    /// 2. A progressive entry in `streamingData.formats` that carries BOTH
    ///    audio and video in one file (an unsigned `url`).
    ///
    /// `adaptiveFormats` are deliberately NOT used: they split audio and
    /// video into separate files, which AVPlayer cannot recombine without
    /// a manifest.
    static func parse(_ data: Data) throws -> Resolved {
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw ResolveError.noCompatibleStream
        }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw ResolveError.unplayable(reason: message)
        }

        let playability = root["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "UNKNOWN"
        if status != "OK" {
            let reason = (playability?["reason"] as? String)
                ?? (playability?["messages"] as? [String])?.first
                ?? status
            throw ResolveError.unplayable(reason: reason)
        }

        let details = root["videoDetails"] as? [String: Any]
        let title = details?["title"] as? String ?? ""
        let isLive = (details?["isLive"] as? Bool) ?? false

        guard let streaming = root["streamingData"] as? [String: Any] else {
            throw ResolveError.noCompatibleStream
        }
        let expiresIn = Double(
            (streaming["expiresInSeconds"] as? String) ?? ""
        ) ?? 300

        if let hls = streaming["hlsManifestUrl"] as? String,
           let url = URL(string: hls) {
            return Resolved(url: url, isHLS: true, isLive: isLive,
                            title: title, expiresIn: expiresIn)
        }

        if let best = bestProgressive(streaming["formats"] as? [[String: Any]]),
           let url = URL(string: best) {
            return Resolved(url: url, isHLS: false, isLive: isLive,
                            title: title, expiresIn: expiresIn)
        }

        throw ResolveError.noCompatibleStream
    }

    /// Highest-quality muxed MP4 with a plain (non-ciphered) URL.
    ///
    /// Entries carrying `signatureCipher` are skipped: unscrambling them
    /// needs YouTube's player JavaScript, which tvOS has no engine to run.
    private static func bestProgressive(_ formats: [[String: Any]]?) -> String? {
        guard let formats else { return nil }
        let usable = formats.filter { format in
            guard let url = format["url"] as? String, !url.isEmpty else {
                return false
            }
            let mime = (format["mimeType"] as? String ?? "").lowercased()
            // Muxed entries declare two codecs; audio-only/video-only
            // progressive entries are not useful on their own.
            guard mime.hasPrefix("video/mp4") else { return false }
            return mime.contains(",")
        }
        let ranked = usable.sorted {
            ($0["height"] as? Int ?? 0) > ($1["height"] as? Int ?? 0)
        }
        return ranked.first?["url"] as? String
    }
}
