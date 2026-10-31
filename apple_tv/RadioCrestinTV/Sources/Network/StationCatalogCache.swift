import Foundation

/// The last public catalog the API sent, kept for the next launch. The
/// tabs then show at once, and the app stays usable while the API is down:
/// the streams are served from other hosts. The startup refresh replaces
/// it as soon as the API answers. Mirrors the phone's startup cache
/// (`StationDataService._cacheStationsData`).
///
/// It lives in the Caches directory: tvOS keeps only about 500 KB of
/// UserDefaults for an app. tvOS may purge Caches; a launch without the
/// file starts as it always did, on the loading screen.
///
/// Songs are left out. A song describes the moment of the save, and a
/// launch must never show an old session's song as playing now.
struct StationCatalogCache {
    /// Where the catalog is kept. Nil keeps nothing.
    let fileURL: URL?

    init(fileURL: URL? = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    static let defaultFileURL: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("station-catalog.json")

    /// The saved catalog. Nil when there is none: a first launch, a purged
    /// cache, or a save that no longer decodes into `Station`.
    func load() -> [Station]? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let stations = try? JSONDecoder().decode(
                  [Station].self, from: data
              ),
              !stations.isEmpty
        else { return nil }
        return stations
    }

    /// Replaces the saved catalog with `stations`, without their songs.
    /// `@concurrent` so the encoding and the write never run on the
    /// caller's actor (the main one), whatever the module's concurrency
    /// settings make of a plain `nonisolated async` function.
    @concurrent
    func save(_ stations: [Station]) async {
        guard let fileURL, !stations.isEmpty,
              let data = try? JSONEncoder().encode(
                  stations.map(\.withoutSong)
              )
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
