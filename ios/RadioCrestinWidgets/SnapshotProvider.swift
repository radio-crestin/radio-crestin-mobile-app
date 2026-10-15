import Foundation
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has saved anything for the widgets.
    let snapshot: WidgetSnapshot?
}

/// Gives the widgets what the app last saved.
///
/// While a station plays the app reloads the widgets on every change, so
/// iOS needn't refresh them; should the app quit unseen, they show it
/// stopped once its save expires. Otherwise only the listener count
/// changes: iOS may refresh every half hour, and it is fetched again then.
struct SnapshotProvider: TimelineProvider {
    /// Whether the widget shows the listener count, worth fetching.
    var showsListeners = false

    private static let idleRefresh: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (SnapshotEntry) -> Void
    ) {
        completion(
            SnapshotEntry(date: Date(), snapshot: WidgetStorage.loadSnapshot())
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SnapshotEntry>) -> Void
    ) {
        Task {
            let now = Date()
            var snapshot = WidgetStorage.loadSnapshot()
            if var saved = snapshot, saved.isPlaying, now >= saved.playingExpiresAt {
                saved.isPlaying = false
                snapshot = saved
            }
            if showsListeners, let saved = snapshot, !saved.isPlaying {
                snapshot = await ListenerCounts.refreshed(saved)
            }
            var entries = [SnapshotEntry(date: now, snapshot: snapshot)]
            let policy: TimelineReloadPolicy
            if let playing = snapshot, playing.isPlaying {
                var stopped = playing
                stopped.isPlaying = false
                entries.append(
                    SnapshotEntry(date: playing.playingExpiresAt, snapshot: stopped)
                )
                policy = .atEnd
            } else {
                policy = .after(now.addingTimeInterval(Self.idleRefresh))
            }
            completion(Timeline(entries: entries, policy: policy))
        }
    }
}

/// The listener count of the station shown while it isn't playing; the
/// app counts them itself while it runs.
enum ListenerCounts {
    /// A count this old is fetched again.
    private static let refreshAfter: TimeInterval = 10 * 60
    /// A count this old isn't shown when a new one can't be fetched.
    private static let shownFor: TimeInterval = 60 * 60

    private static let metadataURL =
        "https://api.radiocrestin.ro/api/v1/stations-metadata"

    static func refreshed(_ snapshot: WidgetSnapshot) async -> WidgetSnapshot {
        guard let station = snapshot.station else { return snapshot }
        let age = Date().timeIntervalSince(snapshot.listenersAt ?? .distantPast)
        guard age >= refreshAfter else { return snapshot }
        var refreshed = snapshot
        if let count = await fetchCount(slug: station.slug) {
            refreshed.listeners = count
            refreshed.listenersAt = Date()
        } else if age >= shownFor {
            refreshed.listeners = nil
        }
        return refreshed
    }

    private static func fetchCount(slug: String) async -> Int? {
        // Floored to 10 s like the app's requests, so the CDN answers
        // from the copy it keeps for everyone.
        let timestamp = Int(Date().timeIntervalSince1970) / 10 * 10
        guard var components = URLComponents(string: metadataURL) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "timestamp", value: String(timestamp)),
        ]
        guard let url = components.url else { return nil }
        do {
            let request = URLRequest(url: url, timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let metadata = try decoder.decode(MetadataResponse.self, from: data)
            return metadata.data.stationsMetadata
                .first { $0.slug == slug }?
                .nowPlaying?
                .listeners
        } catch {
            return nil
        }
    }
}

/// The part of `/stations-metadata` the widgets read.
private struct MetadataResponse: Decodable {
    struct Payload: Decodable {
        let stationsMetadata: [Row]
    }

    struct Row: Decodable {
        let slug: String
        let nowPlaying: NowPlaying?
    }

    struct NowPlaying: Decodable {
        let listeners: Int?
    }

    let data: Payload
}
