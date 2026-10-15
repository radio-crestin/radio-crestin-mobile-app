import AppIntents
import Foundation

/// A widget button, carried out by the app.
enum WidgetCommand {
    case play(slug: String, fromFavorites: Bool)
    case pause
    case skip(forward: Bool)
}

/// Hands the widgets' buttons to the app.
///
/// The intents below are audio playback intents: iOS performs them in the
/// app's process, launching it in the background when it isn't running,
/// and the app sets `handler` at launch. The widget extension compiles them
/// too, for its buttons, and leaves `handler` unset.
enum WidgetCommandCenter {
    static var handler: ((WidgetCommand) async -> Void)?
}

/// Plays a station: the play button, or a tile of the favorites.
@available(iOS 17.0, *)
struct PlayStationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pornește stația"
    static let isDiscoverable = false

    /// The station's slug; empty plays the current or last station.
    @Parameter(title: "Stația")
    var stationSlug: String

    /// Whether next and previous should then go through the favorites.
    @Parameter(title: "Din favorite", default: false)
    var fromFavorites: Bool

    init() {}

    init(stationSlug: String, fromFavorites: Bool) {
        self.stationSlug = stationSlug
        self.fromFavorites = fromFavorites
    }

    func perform() async throws -> some IntentResult {
        await WidgetCommandCenter.handler?(
            .play(slug: stationSlug, fromFavorites: fromFavorites)
        )
        return .result()
    }
}

@available(iOS 17.0, *)
struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pauză"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await WidgetCommandCenter.handler?(.pause)
        return .result()
    }
}

/// The next or the previous station, as the lock screen's buttons play.
@available(iOS 17.0, *)
struct SkipStationIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Schimbă stația"
    static let isDiscoverable = false

    @Parameter(title: "Următoarea", default: true)
    var forward: Bool

    init() {}

    init(forward: Bool) {
        self.forward = forward
    }

    func perform() async throws -> some IntentResult {
        await WidgetCommandCenter.handler?(.skip(forward: forward))
        return .result()
    }
}
