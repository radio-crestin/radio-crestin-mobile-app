import Foundation

/// Sort strategies that can be applied to the station list.
/// Mirrors `lib/services/station_sort_service.dart` so the same four
/// "Pentru tine / Cele mai ascultate / După ascultători / Alfabetic"
/// labels render across phone, Android TV, and Apple TV.
enum StationSort: String, CaseIterable, Identifiable {
    case recommended
    case mostPlayed
    case listeners
    case alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recommended: return "Pentru tine"
        case .mostPlayed:  return "Cele mai ascultate"
        case .listeners:   return "După ascultători"
        case .alphabetical: return "Alfabetic"
        }
    }

    var systemIcon: String {
        switch self {
        case .recommended:  return "sparkles"
        case .mostPlayed:   return "music.note"
        case .listeners:    return "person.2"
        case .alphabetical: return "textformat.abc"
        }
    }
}

/// Pure sort helpers. Inputs are the station list + per-user signals
/// (play counts, favorites). Output is a deterministic ordering.
enum StationSortService {
    static func sort(
        _ stations: [Station],
        by option: StationSort,
        playCounts: [String: Int],
        favoriteSlugs: Set<String>
    ) -> [Station] {
        let scores = scoreSnapshot(for: stations)
        switch option {
        case .recommended:
            return recommended(stations,
                               playCounts: playCounts,
                               favorites: favoriteSlugs,
                               scores: scores)
        case .mostPlayed:
            return mostPlayed(stations, playCounts: playCounts, scores: scores)
        case .listeners:
            return stations.sorted {
                ($0.totalListeners ?? 0) > ($1.totalListeners ?? 0)
            }
        case .alphabetical:
            return stations.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    // MARK: - Recommended ("Pentru tine")

    /// 1. Station of the day (deterministic daily rotation, alphabetical by slug)
    /// 2-4. Top 3 most-played by user (excluding favorites + station of day);
    ///      backfilled by score if user has fewer than 3 plays
    /// 5+. Remaining sorted by score (50% reviews + 50% listeners)
    private static func recommended(
        _ stations: [Station],
        playCounts: [String: Int],
        favorites: Set<String>,
        scores: [String: StationScore]
    ) -> [Station] {
        guard !stations.isEmpty else { return [] }

        let bySlug = Dictionary(uniqueKeysWithValues: stations.map { ($0.slug, $0) })

        let stationOfDay = stationOfTheDaySlug(stations)
        var placed: Set<String> = stationOfDay.map { [$0] } ?? []

        // Top 3 most-played, excluding favorites + station of day.
        let stationSlugs = Set(stations.map(\.slug))
        let mostPlayed = playCounts
            .filter { stationSlugs.contains($0.key)
                && !placed.contains($0.key)
                && !favorites.contains($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)

        var topThree = Array(mostPlayed)

        // Backfill by score until we have 3 (or run out of candidates).
        if topThree.count < 3 {
            let alreadyPlaced = placed.union(topThree)
            let candidates = stations
                .filter { !alreadyPlaced.contains($0.slug)
                    && !favorites.contains($0.slug) }
            for s in sortByScore(candidates, scores: scores) {
                if topThree.count >= 3 { break }
                topThree.append(s.slug)
            }
        }
        placed.formUnion(topThree)

        let remaining = sortByScore(
            stations.filter { !placed.contains($0.slug) },
            scores: scores
        )

        var result: [Station] = []
        if let sod = stationOfDay, let s = bySlug[sod] {
            result.append(s)
        }
        result.append(contentsOf: topThree.compactMap { bySlug[$0] })
        result.append(contentsOf: remaining)
        return result
    }

    // MARK: - Most played

    private static func mostPlayed(
        _ stations: [Station],
        playCounts: [String: Int],
        scores: [String: StationScore]
    ) -> [Station] {
        return stations.sorted { a, b in
            let pa = playCounts[a.slug] ?? 0
            let pb = playCounts[b.slug] ?? 0
            if pa != pb { return pa > pb }
            // Tie-break by score so stations with no plays at all still
            // get a sensible secondary order rather than random.
            return (scores[a.slug]?.score ?? 0) > (scores[b.slug]?.score ?? 0)
        }
    }

    // MARK: - Score snapshot (50% reviews + 50% listeners, normalized)

    struct StationScore: Equatable {
        let score: Double
        let listeners: Int
        let rating: Double
    }

    static func scoreSnapshot(for stations: [Station]) -> [String: StationScore] {
        guard !stations.isEmpty else { return [:] }
        let maxReviewRaw = stations.map(\.reviewScore).max() ?? 0
        let maxListenersRaw = Double(stations.map { $0.totalListeners ?? 0 }.max() ?? 0)
        let maxReview = max(maxReviewRaw, 1)
        let maxListeners = max(maxListenersRaw, 1)

        var snapshot: [String: StationScore] = [:]
        for s in stations {
            let listeners = Double(s.totalListeners ?? 0)
            let reviewScore = s.reviewScore
            snapshot[s.slug] = StationScore(
                score: (reviewScore / maxReview) * 0.5
                    + (listeners / maxListeners) * 0.5,
                listeners: s.totalListeners ?? 0,
                rating: reviewScore
            )
        }
        return snapshot
    }

    private static func sortByScore(
        _ stations: [Station],
        scores: [String: StationScore]
    ) -> [Station] {
        return stations.sorted {
            (scores[$0.slug]?.score ?? 0) > (scores[$1.slug]?.score ?? 0)
        }
    }

    /// Station of the day — deterministic daily rotation through the
    /// alphabetical-by-slug list. Matches the Flutter / web algorithm.
    private static func stationOfTheDaySlug(_ stations: [Station]) -> String? {
        guard !stations.isEmpty else { return nil }
        let stable = stations.sorted { $0.slug < $1.slug }
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        // Match the Flutter computation: difference in days from Dec 31 of
        // the previous year (so Jan 1 → day 1, not day 0).
        let yearStart = cal.date(from: DateComponents(
            year: cal.component(.year, from: now), month: 1, day: 0
        )) ?? now
        let dayOfYear = cal.dateComponents(
            [.day], from: yearStart, to: now
        ).day ?? 0
        let index = ((dayOfYear % stable.count) + stable.count) % stable.count
        return stable[index].slug
    }
}
