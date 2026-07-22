import Foundation
import OSLog
import Security

/// Minimal Keychain wrapper for storing and retrieving API key strings.
///
/// Each key is stored as a generic password under the app's service name,
/// identified by an account string that matches the settings key.
enum KeychainHelper {

    private static let service = "com.callcapture.app"
    private static let logger = Logger(
        subsystem: "com.callcapture.app",
        category: "Keychain"
    )

    /// Saves a string value to the Keychain for the given account.
    ///
    /// - Parameters:
    ///   - value: The secret string to store.
    ///   - account: The account identifier (e.g. "remote_api_key").
    static func save(_ value: String, for account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                logger.error("Keychain delete failed for \(account): \(status)")
            }
            return
        }

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            logger.error("Keychain update failed for \(account): \(updateStatus)")
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        // Another writer may have inserted the item after our update lookup.
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        if status != errSecSuccess {
            logger.error("Keychain save failed for \(account): \(status)")
        }
    }

    /// Retrieves a string value from the Keychain for the given account.
    ///
    /// - Parameter account: The account identifier.
    /// - Returns: The stored string, or an empty string if not found.
    static func load(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.error("Keychain load failed for \(account): \(status)")
            }
            return ""
        }
        return string
    }
}
