import Foundation
import UIKit

/// Where the app leaves the widgets' data: the App Group container, which
/// the app and the widget extension can both read.
enum WidgetStorage {
    static let appGroup = "group.com.radiocrestinsoftware.radioApp"

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    static var snapshotURL: URL? {
        directory?.appendingPathComponent("snapshot.json")
    }

    static var imagesDirectory: URL? {
        directory?.appendingPathComponent("Images", isDirectory: true)
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Writes [snapshot] in one step, so the extension never reads half.
    @discardableResult
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = snapshotURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("WidgetStorage: saving the snapshot failed: \(error)")
            return false
        }
    }

    static func image(named name: String?) -> UIImage? {
        guard let name, let url = imagesDirectory?.appendingPathComponent(name)
        else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
