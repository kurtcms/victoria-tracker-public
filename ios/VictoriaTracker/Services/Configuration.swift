import Foundation

struct Configuration: Sendable {
  let url: URL
  let publishableKey: String
  static func load() throws -> Configuration {
    guard let rawURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
      let url = URL(string: rawURL), url.scheme == "https", url.host != nil,
      !rawURL.contains("example"), !rawURL.contains("$("),
      let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String,
      !key.isEmpty, !key.contains("$("), !key.contains("replace"), !key.hasPrefix("sb_secret_")
    else {
      throw TrackerError.message(
        "Add your Supabase URL and publishable key to Config.local.xcconfig, then rebuild. See docs/SETUP.md."
      )
    }
    // Legacy anon JWTs are also public client keys. Never accept a service-role JWT.
    if !key.hasPrefix("sb_publishable_") {
      let parts = key.split(separator: ".")
      guard parts.count == 3 else {
        throw TrackerError.message("Use a Supabase publishable key or legacy anon key.")
      }
      var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
      payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
      guard let data = Data(base64Encoded: payload),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        json["role"] as? String == "anon"
      else { throw TrackerError.message("Privileged keys must never be put in the app.") }
    }
    return Configuration(url: url, publishableKey: key)
  }
}
