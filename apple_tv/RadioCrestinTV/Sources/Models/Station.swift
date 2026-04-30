import Foundation

/// Pared-down model — only the fields the tvOS UI actually consumes.
/// Mirrors the Flutter `Query$GetStations$stations` shape so the same
/// API responses parse without server-side changes.
struct Station: Codable, Identifiable, Hashable {
    let id: Int
    let slug: String
    let title: String
    let order: Int
    let thumbnailUrl: String?
    let totalListeners: Int?

    let stationStreams: [StationStream]
    let uptime: Uptime?
    let nowPlaying: NowPlaying?

    enum CodingKeys: String, CodingKey {
        case id, slug, title, order
        case thumbnailUrl = "thumbnail_url"
        case totalListeners = "total_listeners"
        case stationStreams = "station_streams"
        case uptime
        case nowPlaying = "now_playing"
    }

    var isUp: Bool { uptime?.isUp ?? true }

    /// Streams in API order (the audio handler tries them sequentially on
    /// playback failure — the same fallback contract Android implements).
    var orderedStreams: [StationStream] {
        stationStreams.sorted { $0.order < $1.order }
    }

    var songTitle: String { nowPlaying?.song?.name ?? "" }
    var songArtist: String { nowPlaying?.song?.artist?.name ?? "" }
}

struct StationStream: Codable, Hashable {
    let order: Int
    let type: String
    let streamUrl: String

    enum CodingKeys: String, CodingKey {
        case order, type
        case streamUrl = "stream_url"
    }

    var isHls: Bool { type == "HLS" }
}

struct Uptime: Codable, Hashable {
    let isUp: Bool
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case isUp = "is_up"
        case timestamp
    }
}

struct NowPlaying: Codable, Hashable {
    let id: Int
    let timestamp: String?
    let song: Song?
}

struct Song: Codable, Hashable {
    let id: Int
    let name: String
    let thumbnailUrl: String?
    let artist: Artist?

    enum CodingKeys: String, CodingKey {
        case id, name, artist
        case thumbnailUrl = "thumbnail_url"
    }
}

struct Artist: Codable, Hashable {
    let id: Int
    let name: String
    let thumbnailUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case thumbnailUrl = "thumbnail_url"
    }
}
