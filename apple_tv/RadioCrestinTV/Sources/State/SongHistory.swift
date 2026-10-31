import Foundation
import os

/// One entry in the song history for a station.
struct SongEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let artist: String
    /// The API's id of the song; 0 when unknown. A play of the history
    /// can stand as the station's song (`NowPlaying(play:)`), and a like
    /// of it must name the song, not the station.
    let songId: Int
    let timestamp: Date
    let thumbnailUrl: String?

    init(
        title: String,
        artist: String,
        songId: Int = 0,
        timestamp: Date,
        thumbnailUrl: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.songId = songId
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
/// API history (`seed(_:for:at:)`), the live metadata and the
/// audio-aligned metadata (`record(...)`) — all carrying that start time,
/// so they are kept in start order and a song never shows twice in a row;
/// a song that really played again later keeps its own row.
///
/// HLS audio runs 18 s to 5 minutes behind live while the history and the
/// live payloads are at live, so a play the listener has not reached yet
/// can already be known. `record(..., heardAt:)` marks where the audio is,
/// and later plays stay hidden until the audio gets there.
@MainActor
final class SongHistoryStore: ObservableObject {
    /// What "Melodii recente" shows, per station slug: newest first, one
    /// row per play, nothing the listener has not heard yet.
    @Published private(set) var entries: [String: [SongEntry]] = [:]

    /// Every known play per station, newest first — including plays still
    /// ahead of an HLS listener.
    private var timelines: [String: [SongEntry]] = [:]

    /// Per station, the start of the song an HLS listener hears, or where
    /// the audio is while no song is known to be heard; plays that started
    /// after it are hidden. No value means the audio is live (or not
    /// playing), so nothing is ahead of it.
    private var audibleHorizons: [String: Date] = [:]

    /// When the API last sent each station's history, an empty one
    /// included.
    private var loadedAt: [String: Date] = [:]

    /// How long the API's history of a station stays current. While the
    /// station plays, the songs it shows keep its plays up to date, but
    /// one opened again later has missed the songs since: tvOS keeps the
    /// app alive for days, and its rows read "acum 5 ore" over a gap.
    static let historyLifetime: TimeInterval = 10 * 60

    /// Records the song a station shows now; an empty title records none.
    ///
    /// - Parameters:
    ///   - startedAt: when the song started (`now_playing.timestamp`),
    ///     the same instant the API history uses for this play. Falls
    ///     back to now when the payload has none.
    ///   - heardAt: where the station's HLS audio is when its song follows
    ///     it (the merge shows only songs the audio has reached), i.e. the
    ///     song is what the listener hears. Plays after it stay hidden, or
    ///     with no song shown, plays after this moment. Nil when the song
    ///     follows the live timeline, which nothing is ahead of.
    func record(
        songTitle: String,
        artist: String,
        songId: Int = 0,
        startedAt: Date? = nil,
        thumbnailUrl: String? = nil,
        heardAt: Date? = nil,
        for stationSlug: String
    ) {
        let title = songTitle.trimmingCharacters(in: .whitespaces)
        var shown: SongEntry?
        if !title.isEmpty {
            let entry = SongEntry(
                title: title,
                artist: artist,
                songId: songId,
                timestamp: startedAt ?? Date(),
                thumbnailUrl: thumbnailUrl
            )
            timelines[stationSlug] = SongTimeline.inserting(
                entry, into: timelines[stationSlug] ?? []
            )
            shown = entry
        }
        audibleHorizons[stationSlug] = heardAt.map { shown?.timestamp ?? $0 }
        publish(stationSlug)
    }

    /// The play a listener whose audio is at `moment`, or up to
    /// `uncertainty` after it, hears, as far as the station's history
    /// knows (see `SongTimeline.play(heardAt:uncertainty:in:)`).
    func play(
        heardAt moment: Date,
        uncertainty: TimeInterval = 0,
        for stationSlug: String
    ) -> SongEntry? {
        SongTimeline.play(
            heardAt: moment,
            uncertainty: uncertainty,
            in: timelines[stationSlug] ?? []
        )
    }

    /// Merges API-supplied history (newest first), sent at `now`, into the
    /// station's plays. Locally recorded plays newer than the API's newest
    /// stay on top: the API may lag the live metadata by a few seconds.
    func seed(
        _ newEntries: [SongEntry],
        for stationSlug: String,
        at now: Date = Date()
    ) {
        loadedAt[stationSlug] = now
        guard !newEntries.isEmpty else { return }
        timelines[stationSlug] = SongTimeline.seeding(
            newEntries, into: timelines[stationSlug] ?? []
        )
        publish(stationSlug)
    }

    func entries(for stationSlug: String) -> [SongEntry] {
        entries[stationSlug] ?? []
    }

    /// True while the API's history of the station, an empty one included,
    /// is younger than `historyLifetime`, so reopening the station does not
    /// fetch it again. The plays recorded from the screen do not count: the
    /// song a tune-in shows says nothing of the songs before it, and
    /// counting it left "Melodii recente" empty all session.
    func hasCurrentHistory(
        for stationSlug: String,
        at now: Date = Date()
    ) -> Bool {
        loadedAt[stationSlug].map {
            now.timeIntervalSince($0) < Self.historyLifetime
        } ?? false
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

    /// Shortest a play between two plays of one song lasts as a play of
    /// its own; a shorter one is a blip in the station's metadata. Radio
    /// Gosen sent Maranatha, 2 s later the song before it and 13 s later
    /// Maranatha again, and "Melodii recente" listed Maranatha under the
    /// title as a second play.
    static let shortestInterruption: TimeInterval = 30

    /// `entry` placed by start time (a tie goes above, as the newest
    /// report), then blips dropped, repeats collapsed and the list capped.
    static func inserting(
        _ entry: SongEntry,
        into timeline: [SongEntry]
    ) -> [SongEntry] {
        var result = timeline
        let index = result.firstIndex { $0.timestamp <= entry.timestamp }
            ?? result.endIndex
        result.insert(entry, at: index)
        return Array(
            collapsingRepeats(droppingBlips(result)).prefix(capacity)
        )
    }

    /// `seeded` (newest first) replaces what it covers: only existing
    /// plays newer than its newest one are kept, above it.
    static func seeding(
        _ seeded: [SongEntry],
        into existing: [SongEntry]
    ) -> [SongEntry] {
        guard let head = seeded.first else { return existing }
        let newer = existing.filter { $0.timestamp > head.timestamp }
        return Array(
            collapsingRepeats(droppingBlips(newer + seeded)).prefix(capacity)
        )
    }

    /// `entries` (newest first) without the plays shorter than
    /// `shortestInterruption` between two plays of one song, which then
    /// make one play (`collapsingRepeats`).
    static func droppingBlips(_ entries: [SongEntry]) -> [SongEntry] {
        var result = entries
        var index = 1
        while index < result.count - 1 {
            let newer = result[index - 1]
            let lasted = newer.timestamp.timeIntervalSince(result[index].timestamp)
            if lasted < shortestInterruption,
               isSameSong(newer, result[index + 1]) {
                result.remove(at: index)
            } else {
                index += 1
            }
        }
        return result
    }

    /// Merges each run of the same song (title and artist, ignoring case)
    /// into one play. The run's earliest start is kept — that is when the
    /// song began; a later one is a re-report — with the first artwork
    /// and song id found. The kept entry is reused when possible so its
    /// id, and the rows built from it, stay stable.
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

    /// The play in the ears of a listener whose audio is at `moment`, or
    /// anywhere up to `uncertainty` after it: the newest that started by
    /// then, the same play all along. Only when the timeline also knows a
    /// later play, i.e. reaches past that time: otherwise plays it has not
    /// seen since its newest one may have started in between.
    ///
    /// A song change between the two ends leaves it unknown: either song
    /// may be in the ears, and taking the older one showed it at a tune-in
    /// for a moment before the one heard.
    static func play(
        heardAt moment: Date,
        uncertainty: TimeInterval = 0,
        in timeline: [SongEntry]
    ) -> SongEntry? {
        let latest = moment.addingTimeInterval(uncertainty)
        guard let newest = timeline.first, newest.timestamp > latest,
              let play = timeline.first(where: { $0.timestamp <= latest }),
              play.timestamp <= moment
        else { return nil }
        return play
    }

    /// `entries` without the song shown above them, `title` by `artist`:
    /// once the history has that song it is the newest entry, and "Melodii
    /// recente" lists what played before it, as on Android TV and macOS.
    static func before(
        shownTitle title: String,
        artist: String,
        in entries: [SongEntry]
    ) -> [SongEntry] {
        guard let newest = entries.first,
              isSameSong(
                  newest,
                  title: title.trimmingCharacters(in: .whitespaces),
                  artist: artist
              )
        else { return entries }
        return Array(entries.dropFirst())
    }

    private static func isSameSong(_ a: SongEntry, _ b: SongEntry) -> Bool {
        isSameSong(a, title: b.title, artist: b.artist)
    }

    private static func isSameSong(
        _ entry: SongEntry,
        title: String,
        artist: String
    ) -> Bool {
        entry.title.caseInsensitiveCompare(title) == .orderedSame
            && entry.artist.caseInsensitiveCompare(artist) == .orderedSame
    }

    private static func mergedPlay(
        newer: SongEntry,
        older: SongEntry
    ) -> SongEntry {
        let thumbnailUrl = older.thumbnailUrl ?? newer.thumbnailUrl
        let songId = older.songId > 0 ? older.songId : newer.songId
        guard thumbnailUrl != older.thumbnailUrl || songId != older.songId
        else { return older }
        return SongEntry(
            title: older.title,
            artist: older.artist,
            songId: songId,
            timestamp: older.timestamp,
            thumbnailUrl: thumbnailUrl
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
    /// Each string is parsed once: every merge reads the song start of
    /// every station, two or three times, and the formatter took 4 to 7 ms
    /// a merge for the same strings on the main actor (measured on an M3
    /// Max; an Apple TV is slower).
    static func date(from string: String) -> Date? {
        if let known = parsed.withLock({ $0[string] }) { return known }
        let date = withFraction.date(from: string)
            ?? withoutFraction.date(from: string)
        parsed.withLock { cache in
            // A station's start changes with each song: a full cache
            // holds mostly songs long gone.
            if cache.count >= cacheCapacity { cache.removeAll() }
            cache[string] = date
        }
        return date
    }

    /// `date` as the API writes it, for a play of the history standing as
    /// a station's song.
    static func string(from date: Date) -> String {
        withFraction.string(from: date)
    }

    /// Longest a play can have been running and still be a song. Stations
    /// that report no songs keep one fixed label whose timestamp is when
    /// it was set: 13 of 64 stations on 2026-10-31, 19 to 200 days old,
    /// which "Melodii recente" showed as "acum 180z". A station whose
    /// metadata stopped keeps its last song: RVE Oradea Muzică showed
    /// "Aștept la ușa mea" 10.7 hours on (2026-10-31). Sermons and live
    /// services run a few hours at most; the playing songs and programmes
    /// that day were at most an hour old.
    static let longestPlay: TimeInterval = 6 * 60 * 60

    /// `start` as the start of a play seen at `now`, or nil when it is
    /// older than `longestPlay`: then it dates a fixed label, not a song.
    static func songStart(_ start: Date, seenAt now: Date) -> Date? {
        now.timeIntervalSince(start) < longestPlay ? start : nil
    }

    /// Enough for every station's song and its last plays.
    private static let cacheCapacity = 512

    private static let parsed = OSAllocatedUnfairLock(
        initialState: [String: Date?]()
    )

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction = ISO8601DateFormatter()
}
