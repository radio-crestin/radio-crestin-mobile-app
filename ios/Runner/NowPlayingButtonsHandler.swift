import UIKit
import Flutter
import CarPlay

@available(iOS 14.0, *)
class NowPlayingButtonsHandler: NSObject, FlutterPlugin {
    private static var channel: FlutterMethodChannel?
    private static var isFavorite: Bool = false

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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    static func setupNowPlayingButtons() {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared

        // Enable template features
        nowPlayingTemplate.isUpNextButtonEnabled = false
        nowPlayingTemplate.isAlbumArtistButtonEnabled = false

        // Create favorite button
        let favoriteButton = createFavoriteButton()

        // Store strong reference and update template
        currentButtons = [favoriteButton]
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
}
