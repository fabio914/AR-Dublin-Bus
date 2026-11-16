import Foundation
import Security

/// Stores the NTA developer-portal API key in the Keychain.
///
/// A key baked in at build time (`NTA_API_KEY` in `Config/Secrets.xcconfig`, compiled in by
/// the "Generate BuildSecrets.swift" build script) is used when none has been saved.
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

    static let bundledKey: String? = BuildSecretCoding.decode(BuildSecrets.scrambledNTAAPIKey)

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

/// How the build script stores a secret in the binary: each byte shifted by an amount that
/// depends on its position, so the value isn't readable as plain text in the app.
/// This is obscurity, not security: anyone determined can still recover it.
enum BuildSecretCoding {
    private static func shift(at index: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: index &* 37 &+ 91)
    }

    static func encode(_ secret: String) -> [UInt8] {
        secret.utf8.enumerated().map { $0.element &+ shift(at: $0.offset) }
    }

    /// The secret, or `nil` if there is none.
    static func decode(_ scrambled: [UInt8]) -> String? {
        guard !scrambled.isEmpty else { return nil }
        return String(decoding: scrambled.enumerated().map { $0.element &- shift(at: $0.offset) }, as: UTF8.self)
    }
}
