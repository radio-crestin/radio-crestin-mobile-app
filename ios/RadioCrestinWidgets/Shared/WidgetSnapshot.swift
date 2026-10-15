import Foundation

/// What the Radio Crestin widgets show, as the app last saved it.
///
/// The app saves it whenever something the widgets show changes (the
/// station, the song heard, play or pause, the favorites) and reloads them;
/// the widget extension only reads it. Images are file names in
/// `WidgetStorage.imagesDirectory`.
struct WidgetSnapshot: Codable, Equatable {
    struct Station: Codable, Equatable {
        let slug: String
        let title: String
        let logo: String?
    }

    struct Song: Codable, Equatable {
        let title: String
        let artist: String?
    }

    /// Whether the listener wants audio playing, also while it connects.
    var isPlaying: Bool
    /// The station playing, or else the last one listened to.
    var station: Station?
    /// The song heard now, the listening delay included; only while playing.
    var song: Song?
    /// The song's artwork. Nil without one and in the data-saving modes,
    /// where the station logo stands in, as in the app.
    var cover: String?
    /// How many listen to `station`, and when the app counted them.
    var listeners: Int?
    var listenersAt: Date?
    /// The stations next/previous would play, for the links that stand in
    /// for buttons before iOS 17.
    var previousSlug: String?
    var nextSlug: String?
    /// The favorites in the listener's order, topped up with the stations
    /// they play most when there are fewer than a widget shows.
    var favorites: [Station]
    /// How many of `favorites` the listener chose.
    var favoriteCount: Int
    var savedAt: Date

    /// While a station plays the app saves at least every 5 minutes, so
    /// one not saved for this long is from an app that quit without saying
    /// so (a crash, an update): it shows as stopped from then on.
    static let playingExpiry: TimeInterval = 12 * 60

    var playingExpiresAt: Date { savedAt.addingTimeInterval(Self.playingExpiry) }

    /// Whether the widgets would show the same as with [other]: the dates
    /// only say when it was saved and counted.
    func showsSame(as other: WidgetSnapshot) -> Bool {
        var mine = self
        var theirs = other
        mine.savedAt = .distantPast
        theirs.savedAt = .distantPast
        mine.listenersAt = nil
        theirs.listenersAt = nil
        return mine == theirs
    }
}

/// The widgets' kinds, as WidgetKit names them.
enum WidgetKind {
    static let nowPlaying = "NowPlaying"
    static let favorites = "Favorites"
}
