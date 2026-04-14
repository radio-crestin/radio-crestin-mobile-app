import UIKit
import Flutter
import CarPlay
import MediaPlayer

@available(iOS 14.0, *)
class NowPlayingButtonsHandler: NSObject, FlutterPlugin, CPNowPlayingTemplateObserver {
    private static var channel: FlutterMethodChannel?
    private static var isFavorite: Bool = false
    private static var likeStatus: Int = 0 // -1 = dislike, 0 = neutral, 1 = like

    // Keep strong references to buttons to prevent deallocation
    private static var currentButtons: [CPNowPlayingButton] = []

    static func register(with registrar: FlutterPluginRegistrar) {
        channel = FlutterMethodChannel(
            name: "com.radiocrestin.nowplaying_buttons",
            binaryMessenger: registrar.messenger()
        )

        let instance = NowPlayingButtonsHandler()
        registrar.addMethodCallDelegate(instance, channel: channel!)

        // Setup buttons on registration
        setupNowPlayingButtons()

        // Set observer for Up Next button
        CPNowPlayingTemplate.shared.add(instance)

        // Observe scene activation to ensure buttons are configured when CarPlay connects
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { _ in
            setupNowPlayingButtons()
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setFavoriteState":
            if let args = call.arguments as? [String: Any],
               let isFavorite = args["isFavorite"] as? Bool {
                NowPlayingButtonsHandler.isFavorite = isFavorite
                NowPlayingButtonsHandler.setupNowPlayingButtons()
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing isFavorite argument", details: nil))
            }
        case "setLikeDislikeState":
            if let args = call.arguments as? [String: Any],
               let status = args["likeStatus"] as? Int {
                NowPlayingButtonsHandler.likeStatus = status
                NowPlayingButtonsHandler.setupNowPlayingButtons()
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing likeStatus argument", details: nil))
            }
        case "syncPlaybackState":
            // Explicitly update MPNowPlayingInfoCenter playback rate so
            // CPNowPlayingTemplate.shared reflects the correct play/pause state.
            // audio_service updates this via its own bridge, but the CarPlay scene
            // may not pick up those updates in a multi-scene setup.
            if let args = call.arguments as? [String: Any],
               let isPlaying = args["isPlaying"] as? Bool {
                let rate: Double = isPlaying ? 1.0 : 0.0
                NSLog("NowPlayingButtonsHandler: syncPlaybackState isPlaying=\(isPlaying) rate=\(rate)")
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                let oldRate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? -1
                NSLog("NowPlayingButtonsHandler: old playbackRate=\(oldRate), setting to \(rate)")
                info[MPNowPlayingInfoPropertyPlaybackRate] = rate
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                result(true)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing isPlaying argument", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    static func setupNowPlayingButtons() {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared

        // Enable Up Next (recently played) button
        nowPlayingTemplate.isUpNextButtonEnabled = true
        nowPlayingTemplate.isAlbumArtistButtonEnabled = false

        // Create all buttons: like, favorite, dislike
        let likeButton = createLikeButton()
        let favoriteButton = createFavoriteButton()
        let dislikeButton = createDislikeButton()

        // Store strong reference and update template
        currentButtons = [likeButton, favoriteButton, dislikeButton]
        nowPlayingTemplate.updateNowPlayingButtons(currentButtons)
    }

    static func createFavoriteButton() -> CPNowPlayingButton {
        let imageName = isFavorite ? "heart.fill" : "heart"
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        var image = UIImage(systemName: imageName, withConfiguration: config) ?? UIImage()
        image = image.withRenderingMode(.alwaysTemplate)

        let button = CPNowPlayingImageButton(image: image) { _ in
            // Toggle favorite state
            isFavorite = !isFavorite

            // Update button appearance
            setupNowPlayingButtons()

            // Notify Flutter
            channel?.invokeMethod("onFavoriteButtonPressed", arguments: ["isFavorite": isFavorite])
        }

        return button
    }

    static func createLikeButton() -> CPNowPlayingButton {
        let imageName = likeStatus == 1 ? "hand.thumbsup.fill" : "hand.thumbsup"
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        var image = UIImage(systemName: imageName, withConfiguration: config) ?? UIImage()
        image = image.withRenderingMode(.alwaysTemplate)

        let button = CPNowPlayingImageButton(image: image) { _ in
            // Toggle: if already liked, reset to neutral; otherwise set to liked
            let newStatus = likeStatus == 1 ? 0 : 1
            likeStatus = newStatus

            // Update button appearance
            setupNowPlayingButtons()

            // Notify Flutter
            channel?.invokeMethod("onLikeButtonPressed", arguments: ["likeStatus": newStatus])
        }

        return button
    }

    static func createDislikeButton() -> CPNowPlayingButton {
        let imageName = likeStatus == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown"
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        var image = UIImage(systemName: imageName, withConfiguration: config) ?? UIImage()
        image = image.withRenderingMode(.alwaysTemplate)

        let button = CPNowPlayingImageButton(image: image) { _ in
            // Toggle: if already disliked, reset to neutral; otherwise set to disliked
            let newStatus = likeStatus == -1 ? 0 : -1
            likeStatus = newStatus

            // Update button appearance
            setupNowPlayingButtons()

            // Notify Flutter
            channel?.invokeMethod("onDislikeButtonPressed", arguments: ["likeStatus": newStatus])
        }

        return button
    }

    // MARK: - CPNowPlayingTemplateObserver

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        NSLog("NowPlayingButtonsHandler: Up Next button tapped")
        NowPlayingButtonsHandler.channel?.invokeMethod("onUpNextButtonTapped", arguments: nil)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // Not used
    }
}
