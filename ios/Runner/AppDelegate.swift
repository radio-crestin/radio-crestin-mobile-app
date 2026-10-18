import UIKit
import Flutter
import FirebaseCore

let flutterEngine = FlutterEngine(name: "SharedEngine", project: nil, allowHeadlessExecution: true)

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        FirebaseApp.configure()

        // Start the shared Flutter engine
        flutterEngine.run()
        GeneratedPluginRegistrant.register(with: flutterEngine)

        // Register Now Playing buttons handler for CarPlay
        if #available(iOS 14.0, *) {
            if let registrar = flutterEngine.registrar(forPlugin: "NowPlayingButtonsHandler") {
                NSLog("AppDelegate: Registering NowPlayingButtonsHandler")
                NowPlayingButtonsHandler.register(with: registrar)
            } else {
                NSLog("AppDelegate: Failed to get registrar for NowPlayingButtonsHandler")
            }
        }

        // Lets the device sheet tell a blocked Local Network permission
        // apart from a network with no Chromecast.
        LocalNetworkAccessHandler.register(with: flutterEngine.binaryMessenger)

        // Keeps a paused live stream's buffer while iOS would suspend the
        // app (see IosBackgroundTask in Dart).
        BackgroundTaskHandler.register(with: flutterEngine.binaryMessenger)

        // Before a Home Screen widget's button, which may be what launched
        // the app, reaches it.
        HomeWidgetBridge.shared.register(with: flutterEngine.binaryMessenger)

        // Mirror Android's "com.radiocrestin.app" channel so Flutter has a
        // single cross-platform interface. iOS cannot distinguish "launched
        // from icon" vs "launched from app switcher card" (a fresh process
        // is identical in both cases, and a suspended-app resume isn't a
        // launch event), so we report "launcher" for every cold start.
        let appChannel = FlutterMethodChannel(
            name: "com.radiocrestin.app",
            binaryMessenger: flutterEngine.binaryMessenger
        )
        appChannel.setMethodCallHandler { call, result in
            switch call.method {
            case "getLaunchSource":
                result("launcher")
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Push Notification
        UNUserNotificationCenter.current().delegate = self

        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions,
            completionHandler: { _, _ in }
        )

        application.registerForRemoteNotifications()

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func applicationWillTerminate(_ application: UIApplication) {
        HomeWidgetBridge.shared.appWillTerminate()
        super.applicationWillTerminate(application)
    }
}
