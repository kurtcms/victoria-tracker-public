import Foundation
import Security

enum SecureStorage {
  private static var service: String {
    (Bundle.main.bundleIdentifier ?? "VictoriaTracker") + ".secure"
  }
  static func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw TrackerError.message(
        "Unlock your iPhone and open Victoria Tracker to access your saved sign-in.")
    }
    return try APIJSON.decoder().decode(type, from: data)
  }
  static func write<T: Encodable>(_ value: T, account: String) throws {
    let data = try APIJSON.encoder().encode(value)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
    let attrs: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    if status == errSecItemNotFound {
      var insert = query
      attrs.forEach { insert[$0.key] = $0.value }
      guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
        throw TrackerError.message("Could not securely save this operation.")
      }
    } else if status != errSecSuccess {
      throw TrackerError.message("Could not update secure storage.")
    }
  }
  static func delete(account: String) throws {
    let status = SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account,
      ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TrackerError.message("Could not remove the saved sign-in.")
    }
  }
}
