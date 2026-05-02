import Foundation

/// Pared-down model — only the fields the tvOS UI actually consumes.
/// Mirrors the shape returned by `GET /api/v1/stations` so the same
/// REST responses parse without server-side changes. Extra keys present
/// on the wire (description, posts, facebook_page_id, …) are ignored.
struct Station: Codable, Identifiable, Hashable {
    let id: Int
    let slug: String
    let title: String
    let order: Int
    let thumbnailUrl: String?
    var totalListeners: Int?

    let stationStreams: [StationStream]
    var uptime: Uptime?
    var nowPlaying: NowPlaying?
    let reviewsStats: ReviewsStats?

    enum CodingKeys: String, CodingKey {
        case id, slug, title, order
        case thumbnailUrl = "thumbnail_url"
        case totalListeners = "total_listeners"
        case stationStreams = "station_streams"
        case uptime
        case nowPlaying = "now_playing"
        case reviewsStats = "reviews_stats"
    }

    var isUp: Bool { uptime?.isUp ?? true }

    /// Streams in API order (the audio handler tries them sequentially on
    /// playback failure — the same fallback contract Android implements).
    var orderedStreams: [StationStream] {
        stationStreams.sorted { $0.order < $1.order }
    }

    /// True when the primary (lowest-order) stream is HLS. Used by the
    /// metadata sync to decide whether an offset timestamp is needed.
    var primaryStreamIsHls: Bool {
        orderedStreams.first?.type == "HLS"
    }

    var songTitle: String { nowPlaying?.song?.name ?? "" }
    var songArtist: String { nowPlaying?.song?.artist?.name ?? "" }
    var songThumbnailUrl: String? {
        nowPlaying?.song?.thumbnailUrl ?? nowPlaying?.song?.artist?.thumbnailUrl
    }

    /// URL list to try in order: song / artist art first (so the user
    /// sees the actual album cover when available), then station logo.
    /// Mirrors Station.displayThumbnail in the Flutter app.
    var displayThumbnailURLs: [URL] {
        [songThumbnailUrl, thumbnailUrl]
            .compactMap { $0 }
            .compactMap { URL(string: $0) }
    }

    /// Server-computed average rating (0..5). 0 when no reviews.
    var averageRating: Double {
        reviewsStats?.averageRating ?? 0
    }

    var reviewCount: Int {
        reviewsStats?.numberOfReviews ?? 0
    }

    /// Review-based score used by the recommended sort: average × count.
    /// Stations with many high reviews float to the top.
    var reviewScore: Double {
        averageRating * Double(reviewCount)
    }

    /// Returns a copy with `now_playing`, `uptime`, and listener count
    /// replaced from the `/stations-metadata` payload. Mirrors the Flutter
    /// `_mergeStationWithMetadata` logic — `liveListeners` (when supplied)
    /// always wins over the offset metadata's listener count so the
    /// audience number reflects what's actually listening *now* rather
    /// than what was listening at the HLS playback timestamp.
    func merging(_ metadata: StationMetadata, liveListeners: Int?) -> Station {
        var copy = self
        if let m = metadata.uptime {
            copy.uptime = m
        }
        if let np = metadata.now_playing {
            copy.nowPlaying = NowPlaying(
                id: nowPlaying?.id ?? 0,
                timestamp: np.timestamp,
                song: np.song
            )
            copy.totalListeners = liveListeners ?? np.listeners ?? totalListeners
        }
        return copy
    }
}

struct ReviewsStats: Codable, Hashable {
    let averageRating: Double
    let numberOfReviews: Int

    enum CodingKeys: String, CodingKey {
        case averageRating = "average_rating"
        case numberOfReviews = "number_of_reviews"
    }
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
