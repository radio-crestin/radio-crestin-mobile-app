import Flutter
import Intents

/// Answers Siri's requests to play a station (`INPlayMediaIntent`): "Hey
/// Siri, play RVE Constanța on Radio Creștin", also from the car's voice
/// button. Flutter finds the station and plays it (`SiriMediaService`),
/// and sends the station names Siri learns.
///
/// iOS hands the request to the app itself, launching it in the background
/// if needed, so a request can arrive before Flutter runs: it waits until
/// Flutter says it is `ready`.
final class SiriMediaHandler: NSObject, INPlayMediaIntentHandling {
    static let shared = SiriMediaHandler()

    private static let channelName = "com.radiocrestin.siri"
    /// How long a request waits for Flutter after a launch; Siri gives up
    /// on an answer after about 10 seconds.
    private static let readyTimeout: TimeInterval = 8

    // Main thread only, as the channel.
    private var channel: FlutterMethodChannel?
    private var flutterReady = false
    private var readyWaiters: [UUID: (Bool) -> Void] = [:]

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "ready":
                self?.flutterBecameReady()
                result(nil)
            case "vocabulary":
                Self.learn(call.arguments as? [[String: String]] ?? [])
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        self.channel = channel
    }

    // MARK: - INPlayMediaIntentHandling

    /// Which station the request names; without a name, the one playing
    /// or the last one played. Siri may give the slug of a name it learned
    /// as the identifier.
    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let query = intent.mediaSearch?.mediaName ?? ""
        let id = intent.mediaSearch?.mediaIdentifier ?? ""
        NSLog("SiriMediaHandler: find \"\(query)\" (\(id))")
        invoke("find", ["query": query, "id": id]) { reply in
            guard let station = reply as? [String: String],
                  let id = station["id"],
                  let title = station["title"] else {
                completion([.unsupported()])
                return
            }
            let item = INMediaItem(
                identifier: id,
                title: title,
                type: .radioStation,
                artwork: nil
            )
            completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
        }
    }

    func handle(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        guard let id = intent.mediaItems?.first?.identifier else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        NSLog("SiriMediaHandler: play \(id)")
        invoke("play", ["id": id]) { reply in
            let code: INPlayMediaIntentResponseCode =
                (reply as? Bool) == true ? .success : .failure
            completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    // MARK: - Names

    /// Teaches Siri the station names as radio show titles, so it hears a
    /// Romanian name said in a request in another language. Each name
    /// carries its station's slug.
    private static func learn(_ names: [[String: String]]) {
        let vocabulary = NSOrderedSet(array: names.compactMap { name -> INSpeakableString? in
            guard let id = name["id"], let phrase = name["phrase"] else { return nil }
            return INSpeakableString(
                vocabularyIdentifier: id,
                spokenPhrase: phrase,
                pronunciationHint: nil
            )
        })
        NSLog("SiriMediaHandler: \(vocabulary.count) station names for Siri "
            + "(Siri access \(INPreferences.siriAuthorizationStatus().rawValue))")
        // Saving them can take a while.
        DispatchQueue.global(qos: .utility).async {
            INVocabulary.shared().setVocabulary(vocabulary, of: .mediaShowTitle)
        }
    }

    // MARK: - Flutter

    /// Calls [method] in Flutter once it runs; replies nil when it doesn't
    /// start in time or fails.
    private func invoke(
        _ method: String,
        _ arguments: [String: Any],
        reply: @escaping (Any?) -> Void
    ) {
        DispatchQueue.main.async {
            self.whenFlutterReady { ready in
                guard ready, let channel = self.channel else {
                    NSLog("SiriMediaHandler: Flutter didn't start, dropped \(method)")
                    reply(nil)
                    return
                }
                channel.invokeMethod(method, arguments: arguments) { result in
                    reply(result is FlutterError ? nil : result)
                }
            }
        }
    }

    private func whenFlutterReady(_ action: @escaping (Bool) -> Void) {
        if flutterReady {
            action(true)
            return
        }
        let id = UUID()
        readyWaiters[id] = action
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout) {
            self.readyWaiters.removeValue(forKey: id)?(false)
        }
    }

    private func flutterBecameReady() {
        flutterReady = true
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        waiters.forEach { $0(true) }
    }
}
