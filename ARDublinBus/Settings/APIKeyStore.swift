import Foundation
import Security

/// Stores the NTA developer-portal API key in the Keychain.
///
/// A key baked in at build time (`NTA_API_KEY` in `Config/Secrets.xcconfig`, exposed
/// through the `NTAAPIKey` Info.plist entry) is used when none has been saved.
final class APIKeyStore: @unchecked Sendable {
    static let shared = APIKeyStore()

    private let service = "ARDublinBus.NTA"
    private let account = "gtfsr-api-key"
    private let lock = NSLock()
    private var cachedKey: String??

    /// The key in effect: the saved one, else the build-time one.
    var apiKey: String? {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey { return cachedKey ?? Self.bundledKey }
        let stored = readKeychain()
        cachedKey = .some(stored)
        return stored ?? Self.bundledKey
    }

    var hasSavedKey: Bool { (readKeychain() ?? "").isEmpty == false }

    static var bundledKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NTAAPIKey") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    /// Saves `key`, or deletes the saved key when `key` is empty.
    func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        if !trimmed.isEmpty {
            var attributes = query
            attributes[kSecValueData as String] = Data(trimmed.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        }
        cachedKey = .some(trimmed.isEmpty ? nil : trimmed)
    }

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
