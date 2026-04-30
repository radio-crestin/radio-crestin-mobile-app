import Foundation

/// Two-endpoint REST repository, contract identical to the Flutter app:
///
/// * `GET /api/v1/stations?timestamp=<live>` — full station list (logos,
///   streams, descriptions, reviews stats). Heavy. Refreshed on app
///   foreground + every 30 minutes.
/// * `GET /api/v1/stations-metadata?timestamp=<sync>[&changes_from_timestamp=<live>]`
///   — lightweight `now_playing` + `uptime` + listener count. Polled
///   every 10 seconds. The `timestamp` query param is the *audio* time
///   the metadata should align with: live wall-clock for direct streams,
///   PROGRAM-DATE-TIME for HLS so the song shown matches the song the
///   user is hearing (HLS has a 6–30s buffer).
///
/// Both endpoints accept a `timestamp` query parameter and the responses
/// are cached server-side keyed by it; reusing 10s-aligned values keeps
/// the hit rate high.
final class StationRepository {
    private let client: RestClient

    init(client: RestClient = RestClient()) {
        self.client = client
    }

    // MARK: - Full station list

    /// Fetches the full station catalog. The `timestamp` defaults to the
    /// live (wall-clock) rounded second.
    func fetchStations(timestamp: Int? = nil) async throws -> [Station] {
        let ts = timestamp ?? roundedTimestamp()
        guard var components = URLComponents(string: API.stationsURL) else {
            throw APIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "timestamp", value: "\(ts)")]
        guard let url = components.url else { throw APIError.invalidURL }
        let envelope = try await client.get(url, as: StationsEnvelope.self)
        return envelope.data.stations
    }

    // MARK: - Lightweight metadata

    /// Fetches `now_playing` + `uptime` for every station.
    /// - Parameters:
    ///   - timestamp: 10s-aligned audio time. For an HLS station this is
    ///     the PROGRAM-DATE-TIME of the audio currently playing; for
    ///     direct MP3 this is the live wall-clock time.
    ///   - changesFromTimestamp: if set, the server only returns stations
    ///     whose metadata changed since that timestamp — saves bandwidth
    ///     on every poll except the first.
    /// - Returns: keyed by station id.
    func fetchMetadata(
        timestamp: Int,
        changesFromTimestamp: Int? = nil
    ) async throws -> [Int: StationMetadata] {
        guard var components = URLComponents(string: API.stationsMetadataURL) else {
            throw APIError.invalidURL
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "timestamp", value: "\(timestamp)")
        ]
        if let from = changesFromTimestamp, from > 0 {
            items.append(URLQueryItem(
                name: "changes_from_timestamp", value: "\(from)"
            ))
        }
        components.queryItems = items
        guard let url = components.url else { throw APIError.invalidURL }
        let envelope = try await client.get(url, as: MetadataEnvelope.self)
        var map: [Int: StationMetadata] = [:]
        for entry in envelope.data.stations_metadata {
            map[entry.id] = entry
        }
        return map
    }
}

// MARK: - Wire types

private struct StationsEnvelope: Decodable {
    let data: StationsPayload
    struct StationsPayload: Decodable {
        let stations: [Station]
    }
}

private struct MetadataEnvelope: Decodable {
    let data: MetadataPayload
    // swiftlint:disable:next nesting
    struct MetadataPayload: Decodable {
        let stations_metadata: [StationMetadata]
    }
}

/// Lightweight counterpart to `Station` returned by `/stations-metadata`.
/// Only carries the fields that change between full refreshes.
struct StationMetadata: Decodable {
    let id: Int
    let uptime: Uptime?
    let now_playing: NowPlayingMetadata?

    /// Listeners are reported under `now_playing.listeners` on the
    /// metadata endpoint (the full `/stations` endpoint puts the same
    /// number under `total_listeners`). We surface it directly here so
    /// merge code can prefer the live count over an offset count.
    var listeners: Int? { now_playing?.listeners }
}

struct NowPlayingMetadata: Decodable {
    let timestamp: String?
    let listeners: Int?
    let song: Song?
}
