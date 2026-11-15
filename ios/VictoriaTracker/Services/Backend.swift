import Foundation

struct AuthSession: Codable, Sendable {
  let accessToken: String
  let refreshToken: String
  let expiresAt: Date
  let userID: UUID
}
private struct AuthResult: Decodable {
  struct User: Decodable {
    let id: UUID
    let email: String?
  }
  let accessToken: String?
  let refreshToken: String?
  let expiresIn: Double?
  let user: User?
  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
    case user
  }
  func session() throws -> AuthSession {
    guard let accessToken, let refreshToken, let expiresIn, let user else {
      throw TrackerError.message("Confirm your email using the Supabase email, then sign in.")
    }
    return AuthSession(
      accessToken: accessToken, refreshToken: refreshToken,
      expiresAt: Date().addingTimeInterval(expiresIn), userID: user.id)
  }
}
private struct HTTPFailure: Error {
  let status: Int
  let data: Data
}

// Supabase endpoints do not require redirects. Never forward credentials to a redirect target.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

actor Backend {
  static let shared = Backend()
  private let transport: URLSession
  private var refreshing: Task<AuthSession, Error>?
  private var authGeneration = 0
  private var confirmingEmail = false
  private var inFlight: [UUID: Task<RecordResponse, Error>] = [:]
  private var careInFlight: [UUID: Task<CareResponse, Error>] = [:]

  private init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    transport = URLSession(
      configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
  }

  func savedSession() throws -> AuthSession? {
    try SecureStorage.read(AuthSession.self, account: "session")
  }
  private func send(path: String, method: String = "GET", body: Data? = nil, token: String? = nil)
    async throws -> Data
  {
    let config = try Configuration.load()
    guard let url = URL(string: path, relativeTo: config.url) else {
      throw TrackerError.message("Invalid backend URL.")
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.httpBody = body
    req.timeoutInterval = path.contains("functions/") ? 55 : 20
    req.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await transport.data(for: req)
    guard let response = response as? HTTPURLResponse else {
      throw TrackerError.message("No response from the server.")
    }
    guard (200..<300).contains(response.statusCode) else {
      throw HTTPFailure(status: response.statusCode, data: data)
    }
    return data
  }
  private func data(_ body: [String: String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: body)
  }
  private func readable(_ error: Error) -> Error {
    guard let e = error as? HTTPFailure else { return error }
    if e.status == 401 {
      return TrackerError.message("Your sign-in has expired. Open the app and sign in again.")
    }
    if let body = try? JSONSerialization.jsonObject(with: e.data) as? [String: Any],
      let message = (body["message"] ?? body["msg"] ?? body["error_description"]) as? String
    {
      return TrackerError.message(String(message.prefix(400)))
    }
    return TrackerError.message("The server could not complete this request (\(e.status)).")
  }
  func signIn(email: String, password: String) async throws {
    authGeneration += 1
    let generation = authGeneration
    do {
      let result = try await send(
        path: "/auth/v1/token?grant_type=password", method: "POST",
        body: data(["email": email, "password": password]))
      let session = try APIJSON.decoder().decode(AuthResult.self, from: result).session()
      guard generation == authGeneration else {
        throw TrackerError.message("The sign-in changed. Please try again.")
      }
      try SecureStorage.write(session, account: "session")
      try? SecureStorage.delete(account: "email-confirmation")
    } catch { throw readable(error) }
  }
  func signUp(email: String, password: String) async throws -> String {
    guard password.count >= 12 else {
      throw TrackerError.message("Use a password with at least 12 characters.")
    }
    guard try savedSession() == nil else {
      throw TrackerError.message("Sign out before creating another account.")
    }
    authGeneration += 1
    do {
      let existing = try SecureStorage.read(
        PendingEmailConfirmation.self, account: "email-confirmation")
      let pending: PendingEmailConfirmation
      if let existing, existing.isUsable(for: email) {
        pending = existing
      } else {
        pending = PendingEmailConfirmation(
          email: email, verifier: try EmailConfirmation.newVerifier(), createdAt: Date())
      }
      // Keep the verifier across app restarts and uncertain network responses.
      try SecureStorage.write(pending, account: "email-confirmation")
      _ = try await send(
        path: EmailConfirmation.signupPath, method: "POST",
        body: EmailConfirmation.signupBody(
          email: email, password: password, verifier: pending.verifier))
      return
        "Open the confirmation email on this iPhone to return here. If you confirm on another device, return here and sign in with your password."
    } catch { throw readable(error) }
  }
  func confirmEmail(url: URL) async throws -> String {
    let code = try EmailConfirmation.code(from: url)
    guard try savedSession() == nil else { return "You’re already signed in." }
    guard !confirmingEmail else { return "Email confirmation is already in progress." }
    guard
      let pending = try SecureStorage.read(
        PendingEmailConfirmation.self, account: "email-confirmation"),
      pending.isUsable(for: pending.email)
    else {
      return
        "Return to sign in with your email and password. This iPhone has no pending signup to complete automatically."
    }
    confirmingEmail = true
    let generation = authGeneration
    defer { confirmingEmail = false }
    do {
      let result = try await send(
        path: "/auth/v1/token?grant_type=pkce", method: "POST",
        body: data(["auth_code": code, "code_verifier": pending.verifier]))
      let auth = try APIJSON.decoder().decode(AuthResult.self, from: result)
      let session = try auth.session()
      guard generation == authGeneration,
        auth.user?.email?.caseInsensitiveCompare(pending.email) == .orderedSame,
        try SecureStorage.read(PendingEmailConfirmation.self, account: "email-confirmation")
          == pending
      else {
        throw TrackerError.message("The sign-in changed. Return to sign in with your password.")
      }
      try SecureStorage.write(session, account: "session")
      authGeneration += 1
      try? SecureStorage.delete(account: "email-confirmation")
      return "Email confirmed. You’re signed in."
    } catch {
      // A callback/code/verifier must never appear in a surfaced network error.
      throw TrackerError.message(
        "Could not complete automatic sign-in. Return to sign in with your password; if your email is unconfirmed, request a new confirmation."
      )
    }
  }
  func signOut() async throws {
    let session = try savedSession()
    authGeneration += 1
    refreshing?.cancel()
    refreshing = nil
    try SecureStorage.delete(account: "session")
    try SecureStorage.delete(account: "email-confirmation")
    // Retain pending entries under their original parent's ID; never send them as another parent.
    if let session {
      _ = try? await send(path: "/auth/v1/logout", method: "POST", token: session.accessToken)
    }
  }
  private func session(forceRefresh: Bool = false) async throws -> AuthSession {
    guard let current = try savedSession() else {
      throw TrackerError.message("Open Victoria Tracker and sign in first.")
    }
    if !forceRefresh && current.expiresAt > Date().addingTimeInterval(60) { return current }
    if let refreshing {
      let generation = authGeneration
      let refreshed = try await refreshing.value
      guard generation == authGeneration else {
        throw TrackerError.message("The signed-in parent changed.")
      }
      return refreshed
    }
    let generation = authGeneration
    let task = Task<AuthSession, Error> {
      do {
        let result = try await self.send(
          path: "/auth/v1/token?grant_type=refresh_token", method: "POST",
          body: self.data(["refresh_token": current.refreshToken]))
        return try APIJSON.decoder().decode(AuthResult.self, from: result).session()
      } catch { throw self.readable(error) }
    }
    refreshing = task
    defer { refreshing = nil }
    let refreshed = try await task.value
    guard generation == authGeneration else {
      throw TrackerError.message("The signed-in parent changed. Please try again.")
    }
    try SecureStorage.write(refreshed, account: "session")
    return refreshed
  }
  private func authorized(
    path: String, method: String = "GET", body: Data? = nil, expectedUser: UUID? = nil
  ) async throws -> Data {
    let initial = try await session()
    guard expectedUser == nil || initial.userID == expectedUser else {
      throw TrackerError.message("Sign back in as the parent who made this entry.")
    }
    do {
      return try await send(path: path, method: method, body: body, token: initial.accessToken)
    } catch let e as HTTPFailure where e.status == 401 {
      let renewed = try await session(forceRefresh: true)
      guard renewed.userID == initial.userID else {
        throw TrackerError.message("The signed-in parent changed.")
      }
      do {
        return try await send(path: path, method: method, body: body, token: renewed.accessToken)
      } catch { throw readable(error) }
    } catch { throw readable(error) }
  }
  func children() async throws -> [Child] {
    try await rows(
      table: "children",
      query: [
        URLQueryItem(name: "select", value: "*"),
        URLQueryItem(name: "order", value: "created_at.asc,id.asc"),
      ], as: Child.self)
  }
  func createFamily(name: String = "Victoria") async throws {
    _ = try await authorized(
      path: "/rest/v1/rpc/create_family_v2", method: "POST",
      body: data([
        "p_time_zone": Child.defaultTimeZoneID,
        "p_name": name.trimmingCharacters(in: .whitespacesAndNewlines),
      ]))
  }
  func joinFamily(token: String) async throws {
    _ = try await authorized(
      path: "/rest/v1/rpc/join_family", method: "POST",
      body: data(["p_token": token.trimmingCharacters(in: .whitespacesAndNewlines)]))
  }
  func invite() async throws -> String {
    try APIJSON.decoder().decode(
      String.self,
      from: await authorized(
        path: "/rest/v1/rpc/create_family_invite", method: "POST", body: data([:])))
  }
  func events(child: Child, day: LocalDay) async throws -> [BabyEvent] {
    let interval = day.interval
    // Paginate so a busy day cannot silently truncate totals at PostgREST's row limit.
    var result: [BabyEvent] = []
    var offset = 0
    while true {
      var components = URLComponents()
      components.path = "/rest/v1/events"
      components.queryItems = [
        URLQueryItem(name: "child_id", value: "eq.\(child.id.uuidString)"),
        URLQueryItem(name: "occurred_at", value: "gte.\(APIJSON.string(interval.start))"),
        URLQueryItem(name: "occurred_at", value: "lt.\(APIJSON.string(interval.end))"),
        URLQueryItem(name: "order", value: "occurred_at.desc,id.asc"),
        URLQueryItem(name: "limit", value: "500"),
        URLQueryItem(name: "offset", value: String(offset)),
      ]
      let page = try APIJSON.decoder().decode(
        [BabyEvent].self, from: await authorized(path: components.string!))
      result += page
      if page.count < 500 { return result }
      offset += page.count
    }
  }
  func pending() throws -> [PendingRecord] {
    guard let user = try savedSession()?.userID else { return [] }
    return try allPending().filter { $0.userID == user }
  }
  private func allPending() throws -> [PendingRecord] {
    try SecureStorage.read([PendingRecord].self, account: "pending") ?? []
  }
  private func removePending(_ id: UUID, user: UUID) throws {
    try SecureStorage.write(
      allPending().filter { !($0.id == id && $0.userID == user) }, account: "pending")
  }
  func record(_ command: RecordCommand) async throws -> RecordResponse {
    if let task = inFlight[command.id] { return try await task.value }
    let current = try await session()
    var entries = try allPending()
    if let existing = entries.first(where: { $0.id == command.id }),
      existing.userID != current.userID || existing.command != command
    {
      throw TrackerError.message("This retry belongs to a different parent or command.")
    }
    if !entries.contains(where: { $0.id == command.id }) {
      guard entries.count < 100 else {
        throw TrackerError.message("Please resolve pending entries before recording more.")
      }
      entries.append(PendingRecord(userID: current.userID, command: command))
      try SecureStorage.write(entries, account: "pending")
    }
    let task = Task<RecordResponse, Error> {
      try await self.submit(command, userID: current.userID)
    }
    inFlight[command.id] = task
    defer { inFlight[command.id] = nil }
    return try await task.value
  }
  private func submit(_ command: RecordCommand, userID: UUID) async throws -> RecordResponse {
    let encoded = try APIJSON.encoder().encode(command)
    for attempt in 0..<2 {
      do {
        guard try savedSession()?.userID == userID else {
          throw TrackerError.message("Sign back in as the parent who made this entry.")
        }
        let raw = try await authorized(
          path: "/functions/v1/record-event", method: "POST", body: encoded, expectedUser: userID)
        let response = try APIJSON.decoder().decode(RecordResponse.self, from: raw)
        guard ["recorded", "needs_clarification", "rejected"].contains(response.status),
          response.status != "recorded"
            || (response.event?.requestID == command.id
              && response.event?.childID == command.childID)
        else {
          throw TrackerError.message(
            "The server did not confirm persistence. Retry the pending entry.")
        }
        try removePending(command.id, user: userID)
        return response
      } catch let error as URLError
        where attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code)
      {
        continue  // Same serialized command, reference instant and UUID.
      } catch {
        throw TrackerError.message(
          "Could not confirm recording. Open the app and retry the pending entry. \(readable(error).localizedDescription)"
        )
      }
    }
    throw TrackerError.message("Retry the pending entry in the app.")
  }
  func retry(_ pending: PendingRecord) async throws -> RecordResponse {
    guard try savedSession()?.userID == pending.userID else {
      throw TrackerError.message("Sign in as the parent who recorded this entry.")
    }
    return try await record(pending.command)
  }
  func dismissPending(_ entry: PendingRecord) throws {
    guard try savedSession()?.userID == entry.userID, inFlight[entry.id] == nil else {
      throw TrackerError.message("Wait for this parent's recording attempt to finish.")
    }
    try removePending(entry.id, user: entry.userID)
  }
}

extension Backend {
  private func rows<T: Decodable>(table: String, query: [URLQueryItem], as type: T.Type)
    async throws -> [T]
  {
    var result: [T] = []
    var offset = 0
    while true {
      var u = URLComponents()
      u.path = "/rest/v1/\(table)"
      u.queryItems =
        query + [
          URLQueryItem(name: "limit", value: "500"),
          URLQueryItem(name: "offset", value: String(offset)),
        ]
      let page = try APIJSON.decoder().decode([T].self, from: await authorized(path: u.string!))
      result += page
      if page.count < 500 { return result }
      offset += page.count
    }
  }
  func sleep(child: Child, day: LocalDay) async throws -> [SleepSession] {
    try await rows(
      table: "sleep_sessions",
      query: [
        URLQueryItem(name: "child_id", value: "eq.\(child.id)"),
        URLQueryItem(
          name: "or",
          value:
            "(ended_at.is.null,and(started_at.lt.\(APIJSON.string(day.interval.end)),ended_at.gt.\(APIJSON.string(day.interval.start))))"
        ),
        URLQueryItem(name: "order", value: "started_at.desc,id.asc"),
      ], as: SleepSession.self)
  }
  func milestones(child: Child) async throws -> [Milestone] {
    try await rows(
      table: "milestones",
      query: [
        URLQueryItem(name: "child_id", value: "eq.\(child.id)"),
        URLQueryItem(name: "order", value: "occurred_on.desc,created_at.desc,id.asc"),
      ], as: Milestone.self)
  }
  func weights(child: Child) async throws -> [BabyEvent] {
    try await rows(
      table: "events",
      query: [
        URLQueryItem(name: "child_id", value: "eq.\(child.id)"),
        URLQueryItem(name: "event_type", value: "eq.weight"),
        URLQueryItem(name: "order", value: "occurred_at.asc,created_at.asc,id.asc"),
      ], as: BabyEvent.self)
  }
  func revisions(child: Child) async throws -> [RecordRevision] {
    try await rows(
      table: "care_revisions",
      query: [
        URLQueryItem(name: "child_id", value: "eq.\(child.id)"),
        URLQueryItem(name: "order", value: "created_at.desc,id.asc"),
      ], as: RecordRevision.self)
  }
  func saveChild(
    _ existing: Child?, name: String, birthDate: String?, referenceSex: String?,
    referenceConfirmed: Bool, wasPremature: Bool?, archive: Bool = false
  ) async throws {
    let value: [String: Any] = [
      "p_child_id": existing.map { $0.id.uuidString as Any } ?? NSNull(), "p_name": name,
      "p_birth_date": birthDate.map { $0 as Any } ?? NSNull(),
      "p_reference_sex": referenceSex.map { $0 as Any } ?? NSNull(),
      "p_reference_confirmed": referenceConfirmed,
      "p_was_premature": wasPremature.map { $0 as Any } ?? NSNull(),
      "p_expected_version": existing?.profileVersion.map { $0 as Any } ?? NSNull(),
      "p_archive": archive,
    ]
    _ = try await authorized(
      path: "/rest/v1/rpc/save_child", method: "POST",
      body: JSONSerialization.data(withJSONObject: value))
  }
  func pendingCare() throws -> [PendingCareCommand] {
    guard let user = try savedSession()?.userID else { return [] }
    return try allCarePending().filter { $0.userID == user }
  }
  private func allCarePending() throws -> [PendingCareCommand] {
    try SecureStorage.read([PendingCareCommand].self, account: "care-pending") ?? []
  }
  private func removeCarePending(_ id: UUID, user: UUID) throws {
    try SecureStorage.write(
      allCarePending().filter { !($0.id == id && $0.userID == user) }, account: "care-pending")
  }
  func performCare(_ command: CareCommand) async throws -> CareResponse {
    if let task = careInFlight[command.id] { return try await task.value }
    let current = try await session()
    var entries = try allCarePending()
    if let existing = entries.first(where: { $0.id == command.id }),
      existing.userID != current.userID || existing.command != command
    {
      throw TrackerError.message("This pending attempt belongs to another parent or command.")
    }
    if !entries.contains(where: { $0.id == command.id }) {
      guard entries.count < 100 else {
        throw TrackerError.message("Resolve pending attempts before recording more.")
      }
      entries.append(PendingCareCommand(userID: current.userID, command: command))
      try SecureStorage.write(entries, account: "care-pending")
    }
    let task = Task<CareResponse, Error> {
      try await self.submitCare(command, user: current.userID)
    }
    careInFlight[command.id] = task
    defer { careInFlight[command.id] = nil }
    return try await task.value
  }
  private func submitCare(_ command: CareCommand, user: UUID) async throws -> CareResponse {
    let encoded = try APIJSON.encoder().encode(command)
    for attempt in 0..<2 {
      do {
        let raw = try await authorized(
          path: "/functions/v1/care-command", method: "POST", body: encoded, expectedUser: user)
        let result = try APIJSON.decoder().decode(CareResponse.self, from: raw)
        guard
          ["recorded", "answered", "needs_confirmation", "needs_clarification", "rejected"].contains(
            result.status),
          result.status != "recorded" || result.isPersisted,
          result.status != "answered" || result.childID != nil,
          result.status != "needs_confirmation" || result.needsConfirmation,
          command.childID == nil || result.childID == nil || result.childID == command.childID
        else {
          throw TrackerError.message(
            "The server did not confirm this action. Check the pending attempt.")
        }
        try removeCarePending(command.id, user: user)
        return result
      } catch let error as URLError
        where attempt == 0 && [.timedOut, .networkConnectionLost].contains(error.code)
      { continue } catch {
        throw TrackerError.message(
          "Could not confirm recording. Open the app and retry the pending entry. \(readable(error).localizedDescription)"
        )
      }
    }
    throw TrackerError.message("Retry the pending entry in the app.")
  }
  func retryCare(_ entry: PendingCareCommand) async throws -> CareResponse {
    guard try savedSession()?.userID == entry.userID else {
      throw TrackerError.message("Sign in as the parent who started this action.")
    }
    return try await performCare(entry.command)
  }
  func dismissCare(_ entry: PendingCareCommand) throws {
    guard try savedSession()?.userID == entry.userID, careInFlight[entry.id] == nil else {
      throw TrackerError.message("Wait for the original parent’s recording to finish.")
    }
    try removeCarePending(entry.id, user: entry.userID)
  }
}
