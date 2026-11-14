import CryptoKit
import Foundation
import Security

/// Only a PKCE authorization code may arrive through the app's custom URL scheme.
enum EmailConfirmation {
  static let redirect = "com.victoriatracker.app://auth/confirm"

  static func newVerifier() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw TrackerError.message("Could not securely start signup. Please try again.")
    }
    return base64URL(Data(bytes))
  }

  static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  static var signupPath: String {
    var components = URLComponents()
    components.path = "/auth/v1/signup"
    components.queryItems = [URLQueryItem(name: "redirect_to", value: redirect)]
    return components.string!
  }

  static func signupBody(email: String, password: String, verifier: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "email": email, "password": password,
      "code_challenge": challenge(for: verifier), "code_challenge_method": "s256",
    ])
  }

  static func code(from url: URL) throws -> String {
    let invalid = TrackerError.message("This confirmation link is invalid. Return to sign in.")
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme == "com.victoriatracker.app", c.host == "auth", c.path == "/confirm",
      c.user == nil, c.password == nil, c.port == nil
    else { throw invalid }
    let items = c.queryItems ?? []
    // Do not echo server errors, URLs or tokens into the interface or diagnostics.
    if items.contains(where: { $0.name == "error" || $0.name == "error_code" })
      || c.fragment?.contains("error=") == true
    {
      throw TrackerError.message("The confirmation link expired or was already used. Try signing in; if your email is unconfirmed, request a new confirmation.")
    }
    guard c.fragment == nil, items.allSatisfy({ $0.name == "code" }), items.count == 1,
      let code = items.first?.value, !code.isEmpty, code.utf8.count <= 1024,
      code.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~").contains($0) })
    else { throw invalid }
    return code
  }
}

struct PendingEmailConfirmation: Codable, Equatable, Sendable {
  let email: String
  let verifier: String
  let createdAt: Date

  func isUsable(for email: String, now: Date = Date()) -> Bool {
    self.email.caseInsensitiveCompare(email) == .orderedSame
      && (0..<86400).contains(now.timeIntervalSince(createdAt))
  }
}
