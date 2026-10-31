import Foundation

/// The listener's like or dislike of a song; nil when neither. Raw
/// values as the phone keeps them (`SongLikeService`: 1 and -1).
enum SongRating: Int, Codable {
    case liked = 1
    case disliked = -1

    /// The review a rating sends, with the phone's stars and words
    /// (`likeSong` / `dislikeSong` in `appAudioHandler.dart`). None for a
    /// song shown without its id: a review without a song is the
    /// listener's review of the station, which the API keeps one of, and
    /// a like of the song would replace it.
    func review(of song: RatedSong) -> ReviewRequest? {
        guard song.sentSongId != nil || song.titleKey == nil else {
            return nil
        }
        switch self {
        case .liked:
            return .submit(
                stationId: song.stationId, stars: 5,
                message: "I like: \(song.info)", songId: song.sentSongId
            )
        case .disliked:
            return .submit(
                stationId: song.stationId, stars: 1,
                message: "I don't like: \(song.info)", songId: song.sentSongId
            )
        }
    }
}

/// What Now Playing shows the like buttons for: the station's song, or
/// without one the station itself, which the phone then rates.
struct RatedSong: Equatable {
    let stationId: Int
    let stationTitle: String
    /// The API's id of the song; 0 when the song shows without one.
    private(set) var songId: Int
    let title: String
    let artist: String

    init(station: Station) {
        stationId = station.id
        stationTitle = station.title
        songId = station.nowPlaying?.song?.id ?? 0
        title = station.songTitle
        artist = station.songArtist
    }

    /// The phone's `_buildSongInfo`: "Title - Artist", the title alone,
    /// or without a song the station's name.
    var info: String {
        if !artist.isEmpty { return "\(title) - \(artist)" }
        if !title.isEmpty { return title }
        return stationTitle
    }

    /// The `song_id` a review carries: only an id the API knows.
    var sentSongId: Int? { songId > 0 ? songId : nil }

    /// The song as the API knows it, `songId`, for one shown without its
    /// id whose rating was given with it.
    func identified(as songId: Int) -> RatedSong {
        var song = self
        song.songId = songId
        return song
    }

    /// Where the rating is kept: by the song's id, by title and artist for
    /// a song shown without one, by station when there is no song.
    var key: String {
        if songId > 0 { return "song:\(songId)" }
        return titleKey ?? "station:\(stationId)"
    }

    /// Title and artist, ignoring case and outer spaces as the song
    /// history does. Nil without a song.
    var titleKey: String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return "title:\(title.lowercased())\u{1F}\(artist.lowercased())"
    }
}

/// A rating as saved, with the review it was sent as.
struct SongRatingEntry: Codable, Equatable {
    /// `RatedSong.key` of the song rated.
    let key: String
    let rating: SongRating
    /// The station and the song id the review named (0: none).
    let stationId: Int
    let songId: Int
    /// `RatedSong.titleKey` of the song rated, so the song finds its
    /// rating also while it shows without its id. Nil without a song, and
    /// in ratings saved before it was kept.
    var titleKey: String? = nil

    /// Whether a review was sent for it: not for a song rated while it
    /// showed without its id (`SongRating.review(of:)`).
    var wasSent: Bool { songId > 0 || titleKey == nil }

    /// Takes back the review it was sent as, for the station and song that
    /// review named. None for a rating kept on the device only.
    var deletion: ReviewRequest? {
        guard wasSent else { return nil }
        return .delete(stationId: stationId, songId: songId > 0 ? songId : nil)
    }
}

/// Pressing Apreciază or Nu îmi place, as on the phone: the rating that is
/// on is taken back, any other one is given.
struct SongRatingPress: Equatable {
    /// The song's rating afterwards.
    let rating: SongRating?
    /// What the API is told, in order; nothing for a rating kept on the
    /// device only.
    let requests: [ReviewRequest]

    /// - Parameter current: the song's rating before. Taking it back
    ///   deletes the review it was sent as, whether the song shows with its
    ///   id now or not. Switching it where another station plays the song
    ///   deletes that review first: the API keeps one per station and
    ///   song, and the first station's stayed while the device showed only
    ///   the new rating.
    static func pressing(
        _ pressed: SongRating,
        current: SongRatingEntry?,
        song: RatedSong
    ) -> SongRatingPress {
        guard let current, current.rating == pressed else {
            let otherStations = current.flatMap {
                $0.stationId == song.stationId ? nil : $0.deletion
            }
            return SongRatingPress(
                rating: pressed,
                requests: [otherStations, pressed.review(of: song)]
                    .compactMap { $0 }
            )
        }
        return SongRatingPress(
            rating: nil, requests: current.deletion.map { [$0] } ?? []
        )
    }
}

/// The listener's song ratings, kept on the device so a song shows its
/// rating again after Menu and after a relaunch, and sent to the API as
/// reviews (`ReviewService`), fire and forget.
///
/// Kept in UserDefaults, which tvOS caps at about 500 KB per app: only
/// the latest `capacity` ratings stay, a few tens of kilobytes.
@MainActor
final class SongRatings: ObservableObject {
    static let capacity = 500

    /// Oldest first.
    @Published private(set) var entries: [SongRatingEntry]

    private var byKey: [String: SongRatingEntry]
    /// The ratings given with a song id, by title and artist.
    private var byTitle: [String: SongRatingEntry]
    private let defaults: UserDefaults
    private let reviews: ReviewService

    /// The review being sent; the next one waits for it, so a quick second
    /// press, taking the rating back, reaches the API after it.
    private var sending: Task<Void, Never>?

    private static let defaultsKey = "tv.songRatings"

    init(
        defaults: UserDefaults = .standard,
        reviews: ReviewService = ReviewService()
    ) {
        self.defaults = defaults
        self.reviews = reviews
        let saved = defaults.data(forKey: Self.defaultsKey).flatMap {
            try? JSONDecoder().decode([SongRatingEntry].self, from: $0)
        } ?? []
        entries = saved
        byKey = Self.index(saved, by: \.key)
        byTitle = Self.titleIndex(saved)
    }

    /// The rating of the song `station` shows, or of the station without
    /// one.
    func rating(of station: Station) -> SongRating? {
        entry(for: RatedSong(station: station))?.rating
    }

    /// Presses Apreciază (`.liked`) or Nu îmi place (`.disliked`) for the
    /// song `station` shows. The buttons show the outcome at once; the
    /// review is sent meanwhile, after the ones before it.
    ///
    /// - Returns: the sending, for tests to wait on.
    @discardableResult
    func press(
        _ pressed: SongRating,
        for station: Station
    ) -> Task<Void, Never> {
        var song = RatedSong(station: station)
        let current = entry(for: song)
        if song.songId == 0, let current, current.songId > 0 {
            song = song.identified(as: current.songId)
        }
        let outcome = SongRatingPress.pressing(
            pressed, current: current, song: song
        )
        save(outcome.rating, for: song, replacing: current)
        let reviews = reviews
        let requests = outcome.requests
        let previous = sending
        let send = Task {
            await previous?.value
            for request in requests { await reviews.send(request) }
        }
        sending = send
        return send
    }

    /// The song's entry: by its key, else by its title and artist, the
    /// rating it got while it showed without its id or, shown without one
    /// now, the rating it got with it. A song with an id never takes the
    /// rating of another id with the same title: two recordings, or two
    /// programmes called "Live".
    private func entry(for song: RatedSong) -> SongRatingEntry? {
        if let entry = byKey[song.key] { return entry }
        guard let titleKey = song.titleKey else { return nil }
        return song.songId > 0 ? byKey[titleKey] : byTitle[titleKey]
    }

    private func save(
        _ rating: SongRating?,
        for song: RatedSong,
        replacing current: SongRatingEntry?
    ) {
        let replaced = Set([song.key, current?.key].compactMap { $0 })
        var kept = entries.filter { !replaced.contains($0.key) }
        if let rating {
            kept.append(SongRatingEntry(
                key: song.key,
                rating: rating,
                stationId: song.stationId,
                songId: song.songId,
                titleKey: song.titleKey
            ))
        }
        entries = Array(kept.suffix(Self.capacity))
        byKey = Self.index(entries, by: \.key)
        byTitle = Self.titleIndex(entries)
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func index(
        _ entries: [SongRatingEntry],
        by key: (SongRatingEntry) -> String
    ) -> [String: SongRatingEntry] {
        Dictionary(entries.map { (key($0), $0) }) { _, newer in newer }
    }

    private static func titleIndex(
        _ entries: [SongRatingEntry]
    ) -> [String: SongRatingEntry] {
        let withId = entries.filter { $0.songId > 0 && $0.titleKey != nil }
        return index(withId) { $0.titleKey ?? "" }
    }
}
