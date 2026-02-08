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
}
