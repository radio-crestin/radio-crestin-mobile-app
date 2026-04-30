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
/// Entries can come from two sources, in priority order:
///   1. `seed(_:)` — bulk-loaded from `/stations-metadata-history` when
///      NowPlayingView opens, so the list is populated instantly with
///      real timestamps and thumbnails.
///   2. `record(_:)` — appended live as the metadata poll surfaces a
///      new song. Deduped by (title, artist) against the most recent
///      entry so a poll repeating the same song is a no-op.
@MainActor
final class SongHistoryStore: ObservableObject {
    @Published private(set) var entries: [String: [SongEntry]] = [:]

    /// Append the now-playing song to the station's history if it's
    /// different from the last one we recorded.
    func record(songTitle: String, artist: String, for stationSlug: String) {
        let trimmed = songTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        var stationEntries = entries[stationSlug] ?? []
        if let last = stationEntries.first,
           last.title.caseInsensitiveCompare(trimmed) == .orderedSame,
           last.artist.caseInsensitiveCompare(artist) == .orderedSame {
            return
        }
        stationEntries.insert(
            SongEntry(title: trimmed, artist: artist, timestamp: Date()),
            at: 0
        )
        if stationEntries.count > 20 {
            stationEntries.removeLast(stationEntries.count - 20)
        }
        entries[stationSlug] = stationEntries
    }

    /// Bulk-replace a station's history with API-supplied entries.
    /// Called when NowPlayingView opens. Newest-first input.
    func seed(_ newEntries: [SongEntry], for stationSlug: String) {
        guard !newEntries.isEmpty else { return }
        let merged = mergePreservingNewest(
            seeded: newEntries,
            existing: entries[stationSlug] ?? []
        )
        entries[stationSlug] = Array(merged.prefix(20))
    }

    func entries(for stationSlug: String) -> [SongEntry] {
        entries[stationSlug] ?? []
    }

    /// Merge so any locally-recorded entries that are newer than the
    /// API-supplied head stay at the top. The API may lag the live
    /// metadata poll by a few seconds.
    private func mergePreservingNewest(
        seeded: [SongEntry],
        existing: [SongEntry]
    ) -> [SongEntry] {
        guard let seedHead = seeded.first else { return existing }
        let newer = existing.filter { $0.timestamp > seedHead.timestamp }
        return newer + seeded
    }
}
