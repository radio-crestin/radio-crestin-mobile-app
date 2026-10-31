import Foundation

/// One entry in the song history for a station.
struct SongEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let artist: String
    let timestamp: Date
    let thumbnailUrl: String?

    init(
        title: String,
        artist: String,
        timestamp: Date,
        thumbnailUrl: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.timestamp = timestamp
        self.thumbnailUrl = thumbnailUrl
    }
}

/// Per-station song history kept entirely in memory. The Apple TV app
/// doesn't persist this across launches (the iPhone / Android apps don't
/// either) — it's a "what just played" affordance for the active session.
///
/// Each entry is one play: a song and the moment it started on the
/// broadcast timeline. The same play reaches the app three ways — the
/// API history (`seed(_:for:)`), the live metadata and the audio-aligned
/// metadata (`record(...)`) — all carrying that start time, so they are
/// kept in start order and a song never shows twice in a row; a song
/// that really played again later keeps its own row.
///
/// HLS audio runs ~18–30 s behind live while the history and the live
/// payloads are at live, so a play the listener has not reached yet can
/// already be known. `record(..., isAudioAligned: true)` marks the song
/// being heard, and later plays stay hidden until the audio gets there.
@MainActor
final class SongHistoryStore: ObservableObject {
    /// What "Melodii recente" shows, per station slug: newest first, one
    /// row per play, nothing the listener has not heard yet.
    @Published private(set) var entries: [String: [SongEntry]] = [:]

    /// Every known play per station, newest first — including plays still
    /// ahead of an HLS listener.
    private var timelines: [String: [SongEntry]] = [:]

    /// Per station, the start of the song an HLS listener hears; plays
    /// that started after it are hidden. No value means the audio is live
    /// (or not playing), so nothing is ahead of it.
    private var audibleHorizons: [String: Date] = [:]

    /// Records the song a station shows now.
    ///
    /// - Parameters:
    ///   - startedAt: when the song started (`now_playing.timestamp`),
    ///     the same instant the API history uses for this play. Falls
    ///     back to now when the payload has none.
    ///   - isAudioAligned: true when the station's song follows its HLS
    ///     audio (the merge shows only songs the audio has reached), i.e.
    ///     it is what the listener hears.
    func record(
        songTitle: String,
        artist: String,
        startedAt: Date? = nil,
        thumbnailUrl: String? = nil,
        isAudioAligned: Bool = false,
        for stationSlug: String
    ) {
        let title = songTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let entry = SongEntry(
            title: title,
            artist: artist,
            timestamp: startedAt ?? Date(),
            thumbnailUrl: thumbnailUrl
        )
        timelines[stationSlug] = SongTimeline.inserting(
            entry, into: timelines[stationSlug] ?? []
        )
        audibleHorizons[stationSlug] = isAudioAligned ? entry.timestamp : nil
        publish(stationSlug)
    }

    /// Merges API-supplied history (newest first) into the station's
    /// plays. Locally recorded plays newer than the API's newest stay on
    /// top: the API may lag the live metadata by a few seconds.
    func seed(_ newEntries: [SongEntry], for stationSlug: String) {
        guard !newEntries.isEmpty else { return }
        timelines[stationSlug] = SongTimeline.seeding(
            newEntries, into: timelines[stationSlug] ?? []
        )
        publish(stationSlug)
    }

    func entries(for stationSlug: String) -> [SongEntry] {
        entries[stationSlug] ?? []
    }

    /// True once any play is known for the station, including plays
    /// still hidden ahead of the audio, so reopening it does not fetch
    /// the history again.
    func hasHistory(for stationSlug: String) -> Bool {
        !(timelines[stationSlug] ?? []).isEmpty
    }

    /// Publishes the station's visible rows, only when they changed:
    /// the metadata sync records the shown song on every merge, and an
    /// unchanged list must not redraw Now Playing.
    private func publish(_ stationSlug: String) {
        let visible = SongTimeline.audible(
            timelines[stationSlug] ?? [],
            horizon: audibleHorizons[stationSlug]
        )
        let shown = entries[stationSlug] ?? []
        guard shown.map(\.id) != visible.map(\.id) else { return }
        entries[stationSlug] = visible
    }
}

/// Pure operations on a newest-first list of plays.
enum SongTimeline {
    /// Plays kept per station. Three rows show; the rest absorbs the API
    /// history and plays hidden ahead of an HLS listener.
    static let capacity = 20

    /// `entry` placed by start time (a tie goes above, as the newest
    /// report), then repeats collapsed and the list capped.
    static func inserting(
        _ entry: SongEntry,
        into timeline: [SongEntry]
    ) -> [SongEntry] {
        var result = timeline
        let index = result.firstIndex { $0.timestamp <= entry.timestamp }
            ?? result.endIndex
        result.insert(entry, at: index)
        return Array(collapsingRepeats(result).prefix(capacity))
    }

    /// `seeded` (newest first) replaces what it covers: only existing
    /// plays newer than its newest one are kept, above it.
    static func seeding(
        _ seeded: [SongEntry],
        into existing: [SongEntry]
    ) -> [SongEntry] {
        guard let head = seeded.first else { return existing }
        let newer = existing.filter { $0.timestamp > head.timestamp }
        return Array(collapsingRepeats(newer + seeded).prefix(capacity))
    }

    /// Merges each run of the same song (title and artist, ignoring case)
    /// into one play. The run's earliest start is kept — that is when the
    /// song began; a later one is a re-report — with the first artwork
    /// found. The kept entry is reused when possible so its id, and the
    /// rows built from it, stay stable.
    static func collapsingRepeats(_ entries: [SongEntry]) -> [SongEntry] {
        var result: [SongEntry] = []
        for entry in entries {
            guard let newer = result.last, isSameSong(newer, entry) else {
                result.append(entry)
                continue
            }
            result[result.count - 1] = mergedPlay(newer: newer, older: entry)
        }
        return result
    }

    /// The plays the listener has heard: those that started no later
    /// than `horizon`, the start of the song in their ears. All of them
    /// when there is no horizon (live audio).
    static func audible(_ entries: [SongEntry], horizon: Date?) -> [SongEntry] {
        guard let horizon else { return entries }
        return entries.filter { $0.timestamp <= horizon }
    }

    private static func isSameSong(_ a: SongEntry, _ b: SongEntry) -> Bool {
        a.title.caseInsensitiveCompare(b.title) == .orderedSame
            && a.artist.caseInsensitiveCompare(b.artist) == .orderedSame
    }

    private static func mergedPlay(
        newer: SongEntry,
        older: SongEntry
    ) -> SongEntry {
        guard older.thumbnailUrl == nil, newer.thumbnailUrl != nil else {
            return older
        }
        return SongEntry(
            title: older.title,
            artist: older.artist,
            timestamp: older.timestamp,
            thumbnailUrl: newer.thumbnailUrl
        )
    }
}

extension Station {
    /// When the current song started on the broadcast timeline
    /// (`now_playing.timestamp`): the same instant the API history uses
    /// for that play, which lets the history recognise it. Nil when the
    /// station reports no start, or one too old to be a song (see
    /// `SongTimestamp.songStart(_:seenAt:)`); the history then dates the
    /// play from when it was first seen.
    var songStartDate: Date? {
        nowPlaying?.timestamp
            .flatMap(SongTimestamp.date(from:))
            .flatMap { SongTimestamp.songStart($0, seenAt: Date()) }
    }
}

/// Parses the API's ISO-8601 song timestamps, which carry microseconds
/// (`2026-10-30T21:34:46.041615+00:00`) but may come without a fraction.
enum SongTimestamp {
    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }

    /// Longest a play can have been running and still be a song. Stations
    /// that report no songs keep one fixed label whose timestamp is when
    /// it was set: 13 of 64 stations on 2026-10-31, 19 to 200 days old,
    /// which "Melodii recente" showed as "acum 180z". No song or programme
    /// runs a whole day, and a day is where the row's label turns to days.
    static let longestPlay: TimeInterval = 24 * 60 * 60

    /// `start` as the start of a play seen at `now`, or nil when it is
    /// older than `longestPlay`: then it dates a fixed label, not a song.
    static func songStart(_ start: Date, seenAt now: Date) -> Date? {
        now.timeIntervalSince(start) < longestPlay ? start : nil
    }

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction = ISO8601DateFormatter()
}
