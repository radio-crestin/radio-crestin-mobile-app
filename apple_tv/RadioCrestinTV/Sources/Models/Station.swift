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

    /// Backend-provided station kind. Optional so older API responses that
    /// predate the field still decode — a missing/null value means radio.
    let stationType: String?

    /// Ordered, enabled playlist entries for `station_type == "playlist"`.
    /// Optional and defensively decoded — radio/TV stations omit it.
    let playlistItems: [PlaylistItem]?

    /// DVR (timeshift) variant of the live HLS stream — a 1-hour sliding
    /// window that carries the same `EXT-X-PROGRAM-DATE-TIME` + `DATERANGE`
    /// tags as the short-window live index. Nullable and often absent
    /// (absent entirely in production today).
    ///
    /// Decoded only to future-proof the model against the backend contract;
    /// **DVR/timeshift playback is intentionally NOT implemented on tvOS
    /// yet**, so nothing currently reads this field. Kept so a later feature
    /// can wire up live rewind without another model migration.
    let hlsDvrStreamUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, slug, title, order
        case thumbnailUrl = "thumbnail_url"
        case totalListeners = "total_listeners"
        case stationStreams = "station_streams"
        case uptime
        case nowPlaying = "now_playing"
        case reviewsStats = "reviews_stats"
        case stationType = "station_type"
        case playlistItems = "playlist_items"
        case hlsDvrStreamUrl = "hls_dvr_stream_url"
    }

    /// Whether the station is currently reachable. A **missing** `uptime`
    /// record — the backend omits it when `check_uptime == false` (private
    /// dev/test stations, and some real TV/playlist stations) — means
    /// *unknown*, not down: it reads as `true` so the station stays playable
    /// and shows no warning. Only an explicit `is_up == false` marks a
    /// station as unavailable.
    var isUp: Bool { uptime?.isUp ?? true }

    /// How this station should be played. Parsed case-insensitively;
    /// anything unrecognized (or absent) falls back to `.radio`.
    var kind: StationKind { StationKind(rawWireValue: stationType) }

    /// Playlist entries the tvOS player can actually render, in **wire
    /// order** — the backend serves them newest-first, and the first
    /// array element must play first / show at the top, so we filter
    /// only and never re-sort. Allowlist-based: only `audio` and `video`
    /// survive — YouTube entries (single clips or whole playlists) and
    /// any unknown future type strings cannot be embedded on tvOS and
    /// would only hand AVPlayer an unplayable URL.
    var playableItems: [PlaylistItem] {
        (playlistItems ?? []).filter(\.isPlayable)
    }

    /// True when this is a playlist station whose entries exist but none
    /// is playable on tvOS (YouTube-only lists, unknown types). The UI
    /// shows a friendly explanation instead of a dead player.
    var hasOnlyUnplayableItems: Bool {
        guard kind == .playlist else { return false }
        let items = playlistItems ?? []
        return !items.isEmpty && !items.contains(where: \.isPlayable)
    }

    /// Value reported to analytics for the station kind ("radio"/"tv"/
    /// "playlist"). Never nil so dashboards can group cleanly.
    var kindAnalyticsValue: String { kind.rawValue }

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

    /// The station without its current song, for a copy saved across
    /// launches: the song was current when the copy was made, and an old
    /// session's song must never show as playing now. The next refresh
    /// brings the song back.
    var withoutSong: Station {
        var copy = self
        copy.nowPlaying = nil
        return copy
    }

    /// The station without a song that started longer ago than any song
    /// runs (`SongTimestamp.longestPlay`). Stations that report no songs
    /// keep one fixed label dated when it was set: RVE Sibiu showed
    /// "Durch die Bibel", 181 days old, as the song playing, picture
    /// included, on its card, in Now Playing and in the system's.
    var withoutStaleSong: Station {
        guard let start = nowPlaying?.timestamp.flatMap(SongTimestamp.date(from:)),
              SongTimestamp.songStart(start, seenAt: Date()) == nil
        else { return self }
        return withoutSong
    }

    var songTitle: String { nowPlaying?.song?.name ?? "" }
    var songArtist: String { nowPlaying?.song?.artist?.name ?? "" }
    var songThumbnailUrl: String? {
        nowPlaying?.song?.thumbnailUrl ?? nowPlaying?.song?.artist?.thumbnailUrl
    }

    /// Secondary line shown under the station title in the grid. Radio
    /// stations surface the current song and fall back to an empty string
    /// when nothing is playing (the grid then shows only the title).
    /// Playlist and TV stations never carry a `now_playing` song, so
    /// rather than render an empty line they get a typed descriptor: a
    /// playlist summary (playable-item count, or a plain label when there's
    /// nothing to count) or a live-TV label.
    var cardSubtitle: String {
        switch kind {
        case .radio:
            return songTitle
        case .tv:
            return "Transmisiune live"
        case .playlist:
            let count = playableItems.count
            guard count > 0 else { return "Listă de redare" }
            return count == 1
                ? "Listă de redare · o piesă"
                : "Listă de redare · \(count) piese"
        }
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

/// The three playback experiences a station can offer.
enum StationKind: String, Hashable {
    case radio
    case tv
    case playlist

    /// Maps the raw `station_type` wire string (any casing) to a kind.
    /// Unknown / missing / null all collapse to `.radio`.
    init(rawWireValue: String?) {
        switch rawWireValue?.lowercased() {
        case "tv": self = .tv
        case "playlist": self = .playlist
        default: self = .radio
        }
    }
}

/// One entry in a playlist station. The wire delivers entries
/// newest-first (descending `playlist_item_order`) and enabled-only;
/// apps must preserve that order exactly, so nothing re-sorts by
/// `order`. `type` is `audio`, `video`, `youtube`, or
/// `youtube_playlist` (the YouTube kinds — and any future type
/// strings — are unplayable on tvOS).
struct PlaylistItem: Codable, Hashable, Identifiable {
    let id: Int
    let order: Int
    let type: String
    let url: String
    let title: String
    let thumbnailUrl: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id, order, type, url, title
        case thumbnailUrl = "thumbnail_url"
        case durationSeconds = "duration_seconds"
    }

    var isVideo: Bool { type.lowercased() == "video" }
    var isAudio: Bool { type.lowercased() == "audio" }

    /// True when tvOS can render this item natively. Allowlist — only
    /// `audio` and `video` qualify, so `youtube`, `youtube_playlist`,
    /// and any unknown future type degrade to "not playable" instead of
    /// handing AVPlayer a URL it cannot open.
    var isPlayable: Bool { isAudio || isVideo }
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

extension Song {
    /// Decodes the song with its name as the listener reads it
    /// (`displayName(of:)`), wherever it comes from: the catalog, the
    /// metadata, the history, so they keep naming the same song.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(Int.self, forKey: .id),
            name: Self.displayName(
                of: try container.decode(String.self, forKey: .name)
            ),
            thumbnailUrl: try container.decodeIfPresent(
                String.self, forKey: .thumbnailUrl
            ),
            artist: try container.decodeIfPresent(Artist.self, forKey: .artist)
        )
    }

    /// `name` without what some stations' metadata leaves on it, shown on
    /// the card, in Now Playing and in the system's: an audio file
    /// extension (Calea Spre Cer Popular: "Lasa-L sa te-atinga.mp3"), a
    /// lone % or # after the last word (Old Christian Radio: "My Very Best
    /// Friend %"), and spaces around it. A % after a number, as in
    /// "100 %", stays.
    ///
    /// Taken off until none is left, so a name read again, from the saved
    /// catalog, comes out the same and keeps naming the same song.
    static func displayName(of name: String) -> String {
        var shown = name
        while true {
            let trimmed = shown.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = withoutAudioExtension(withoutMarker(trimmed))
            if cleaned == shown { return shown }
            shown = cleaned
        }
    }

    private static func withoutAudioExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex,
              audioExtensions.contains(
                  name[name.index(after: dot)...].lowercased()
              )
        else { return name }
        return String(name[..<dot])
    }

    private static func withoutMarker(_ name: String) -> String {
        guard let marker = name.last, marker == "%" || marker == "#" else {
            return name
        }
        let words = name.dropLast()
        guard words.last?.isWhitespace == true,
              let lastWord = words.split(whereSeparator: \.isWhitespace).last
        else { return name }
        // A percentage, as in "100 %"; "mp3 %" is no number.
        let isNumber = lastWord.contains(where: \.isNumber)
            && lastWord.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
        guard marker == "#" || !isNumber else { return name }
        return String(words)
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "wma",
    ]
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
