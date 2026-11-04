import Flutter
import Security

/// Keeps the app's device ID in the Keychain, where it outlives the app.
///
/// Deleting the app clears its preferences but not its Keychain items, so a
/// reinstall finds the same ID and analytics sees a returning person rather
/// than a new one. `ThisDeviceOnly` keeps the item out of backups, so a
/// restored or new iPhone gets its own ID instead of a copy.
enum DeviceIdKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.radiocrestin.device-id",
        kSecAttrAccount as String: "device_id",
    ]

    static func register(with messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(
            name: "com.radiocrestin.device_id",
            binaryMessenger: messenger
        ).setMethodCallHandler { call, result in
            switch call.method {
            case "read":
                result(read())
            case "write":
                guard let id = call.arguments as? String else {
                    result(false)
                    return
                }
                result(write(id))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ id: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(id.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        let item = query.merging(attributes) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
