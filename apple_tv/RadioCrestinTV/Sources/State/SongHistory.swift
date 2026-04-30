import Foundation

/// One entry in the song history for a station.
struct SongEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let artist: String
    let timestamp: Date
}

/// Per-station song history kept entirely in memory. The Apple TV app
/// doesn't persist this across launches (the iPhone / Android apps don't
/// either) — it's a "what just played" affordance for the active session.
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

    func entries(for stationSlug: String) -> [SongEntry] {
        entries[stationSlug] ?? []
    }
}
