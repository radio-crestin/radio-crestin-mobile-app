import Foundation

/// The song changes a live HLS item's playlist announced, and which of
/// them the audio has reached since it started.
///
/// The origin writes a song's `EXT-X-DATERANGE` once the song has ended
/// live, with its START-DATE and END-DATE. The end is the start of the
/// song now on air, which a listener behind live (18 s to 5 minutes) has
/// yet to hear. Every date is a boundary, as on the phone
/// (`SongBoundaryQueue`), and a song's END-DATE and the next song's
/// START-DATE are one change.
///
/// The changes before the audio's start were heard before the listener
/// tuned in: the fetch at the start covers them, and they are never
/// reached. Every later one is reached once, when the audio gets there,
/// however late the playlist announced it.
///
/// A pure value type: the engine feeds it the announced dates and the
/// playhead's `EXT-X-PROGRAM-DATE-TIME`.
struct SongBoundaries {
    /// Dates this close are one song change: a song's END-DATE and the
    /// next one's START-DATE, written from the same moment.
    static let sameChange: TimeInterval = 2

    /// Boundaries remembered. The playlist's 11-minute window announces a
    /// few, some tens only for a run of short items, and never one that
    /// left it again.
    static let capacity = 64

    /// Every boundary announced, earliest first.
    private var known: [Date] = []
    /// Boundaries the audio has yet to reach, earliest first.
    private var ahead: [Date] = []
    /// Where the audio started; nil until the first `reach`.
    private var start: Date?

    /// Adds announced boundaries, ignoring those already known.
    mutating func add(_ dates: [Date]) {
        for date in dates where !isKnown(date) {
            known.append(date)
            if start.map({ date > $0 }) ?? true {
                ahead.append(date)
            }
        }
        known.sort()
        ahead.sort()
        if known.count > Self.capacity {
            known.removeFirst(known.count - Self.capacity)
        }
    }

    /// Notes that the audio is at `heard`, and returns whether it reached
    /// a song change since the last call. The first call is the audio's
    /// start: the changes up to it count as heard.
    mutating func reach(_ heard: Date) -> Bool {
        let reached = ahead.prefix { $0 <= heard }.count
        ahead.removeFirst(reached)
        guard start != nil else {
            start = heard
            return false
        }
        return reached > 0
    }

    /// The newest boundary at or before `heard`.
    func latest(atOrBefore heard: Date) -> Date? {
        known.last { $0 <= heard }
    }

    private func isKnown(_ date: Date) -> Bool {
        known.contains { abs($0.timeIntervalSince(date)) <= Self.sameChange }
    }
}
