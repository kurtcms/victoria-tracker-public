import Foundation

public struct SleepSession: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let childID: UUID
  public let startedAt: Date
  public let endedAt: Date?
  public let recordedBy: UUID
  public let inputSource: String
  public let createdAt: Date
  public let revision: Int
  enum CodingKeys: String, CodingKey {
    case id, revision
    case childID = "child_id"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case recordedBy = "recorded_by"
    case inputSource = "input_source"
    case createdAt = "created_at"
  }
  public func duration(asOf now: Date = Date()) -> TimeInterval {
    max(0, min(endedAt ?? now, now).timeIntervalSince(startedAt))
  }
  public func overlap(with day: LocalDay, asOf now: Date = Date()) -> TimeInterval {
    max(
      0,
      min(endedAt ?? now, min(now, day.interval.end)).timeIntervalSince(
        max(startedAt, day.interval.start)))
  }
}
public struct SleepDaySummary: Equatable, Sendable {
  public let total: TimeInterval
  public let completedTotal: TimeInterval
  public let openElapsed: TimeInterval
  public let sessionCount: Int
  public let includesOngoing: Bool
  public init(sessions: [SleepSession], day: LocalDay, asOf now: Date = Date()) {
    let relevant = sessions.filter { $0.overlap(with: day, asOf: now) > 0 }
    completedTotal = relevant.filter { $0.endedAt != nil && $0.endedAt! <= now }
      .reduce(0) { $0 + $1.overlap(with: day, asOf: now) }
    openElapsed = relevant.filter { $0.endedAt == nil || $0.endedAt! > now }
      .reduce(0) { $0 + $1.overlap(with: day, asOf: now) }
    total = relevant.reduce(0) { $0 + $1.overlap(with: day, asOf: now) }
    sessionCount = relevant.count
    includesOngoing = relevant.contains { $0.endedAt == nil }
  }
}
public struct Milestone: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let childID: UUID
  public let title: String
  public let note: String?
  public let occurredOn: String
  public let datePrecision: String
  public let isFirst: Bool
  public let recordedBy: UUID
  public let inputSource: String
  public let createdAt: Date
  public let revision: Int
  public var guideID: String? = nil
  enum CodingKeys: String, CodingKey {
    case id, title, note, revision
    case childID = "child_id"
    case occurredOn = "occurred_on"
    case datePrecision = "date_precision"
    case isFirst = "is_first"
    case recordedBy = "recorded_by"
    case inputSource = "input_source"
    case createdAt = "created_at"
    case guideID = "guide_id"
  }
  public var dateLabel: String {
    guard let date = CalendarDate.parse(occurredOn) else { return occurredOn }
    let f = DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = datePrecision == "month" ? "MMM yyyy" : "MMM d, yyyy"
    return f.string(from: date)
  }
}
public enum CalendarDate {
  public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }
  public static func parse(_ value: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd"
    f.isLenient = false
    guard let d = f.date(from: value), string(d, timeZone: TimeZone(secondsFromGMT: 0)!) == value
    else { return nil }
    return d
  }
  public static func dayAnchor(_ date: Date, timeZone: TimeZone = .current) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.startOfDay(for: date)
  }
  public static func localDate(_ value: String, timeZone: TimeZone = .current) -> Date? {
    guard parse(value) != nil else { return nil }
    let parts = value.split(separator: "-").compactMap { Int($0) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(
      from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }
  public static func ageLabel(birth: String, on date: String) -> String? {
    guard let b = parse(birth), let d = parse(date), d >= b else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let age = calendar.dateComponents([.year, .month, .day], from: b, to: d)
    var values: [String] = []
    if let y = age.year, y > 0 { values.append("\(y) \(y==1 ? "year":"years")") }
    if let m = age.month, m > 0 { values.append("\(m) \(m==1 ? "month":"months")") }
    if values.isEmpty, let d = age.day { values.append("\(d) \(d==1 ? "day":"days")") }
    return values.joined(separator: ", ") + " old"
  }
  public static func ageLabel(
    birth: String, on date: String, precision: String,
    through today: String = CalendarDate.string(Date())
  ) -> String? {
    if precision == "day" { return ageLabel(birth: birth, on: date) }
    guard precision == "month", let birthday = parse(birth), let recordedMonth = parse(date),
      let latest = parse(today)
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let month = calendar.dateInterval(of: .month, for: recordedMonth),
      let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end)
    else { return nil }
    // A month-only memory can fall anywhere in that month, but cannot precede
    // birth or extend into the future. Never treat its day-01 anchor as exact.
    let first = max(month.start, birthday)
    let last = min(lastDay, latest)
    guard first <= last else { return nil }
    let lowerMonths = calendar.dateComponents([.month], from: birthday, to: first).month ?? 0
    let upperMonths = calendar.dateComponents([.month], from: birthday, to: last).month ?? 0
    if lowerMonths == 0 {
      let lower = calendar.dateComponents([.day], from: birthday, to: first).day ?? 0
      let upper = calendar.dateComponents([.day], from: birthday, to: last).day ?? 0
      return
        "About \(lower == upper ? String(lower) : "\(lower)–\(upper)") \(lower == upper && upper == 1 ? "day" : "days") old"
    }
    return
      "About \(lowerMonths == upperMonths ? String(lowerMonths) : "\(lowerMonths)–\(upperMonths)") \(upperMonths == 1 ? "month" : "months") old"
  }
  public static func days(from birth: String, to date: String) -> Int? {
    guard let b = parse(birth), let d = parse(date), d >= b else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.dateComponents([.day], from: b, to: d).day
  }
}
public struct CarePayload: Codable, Equatable, Sendable {
  public var guideID: String?
  public var occurredAt: Date?
  public var endedAt: Date?
  public var eventType: String?
  public var volumeML: Double?
  public var diaperKind: String?
  public var weightKG: Double?
  public var measurementDate: String?
  public var title: String?
  public var note: String?
  public var occurredOn: String?
  public var datePrecision: String?
  public var isFirst: Bool?
  public var correctionKind: String?
  public var amountML: Double?
  public var targetID: UUID?
  public var targetType: String?
  public var expectedRevision: Int?
  public var void: Bool?
  public init() {}
  enum CodingKeys: String, CodingKey {
    case guideID = "guide_id"
    case title, note, void
    case occurredAt = "occurred_at"
    case endedAt = "ended_at"
    case eventType = "event_type"
    case volumeML = "volume_ml"
    case diaperKind = "diaper_kind"
    case weightKG = "weight_kg"
    case measurementDate = "measurement_date"
    case occurredOn = "occurred_on"
    case datePrecision = "date_precision"
    case isFirst = "is_first"
    case correctionKind = "correction_kind"
    case amountML = "amount_ml"
    case targetID = "target_id"
    case targetType = "target_type"
    case expectedRevision = "expected_revision"
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(guideID, forKey: .guideID)
    try c.encodeIfPresent(occurredAt, forKey: .occurredAt)
    try c.encodeIfPresent(endedAt, forKey: .endedAt)
    try c.encodeIfPresent(eventType, forKey: .eventType)
    if eventType != nil {
      try c.encode(volumeML, forKey: .volumeML)
      try c.encode(diaperKind, forKey: .diaperKind)
      try c.encode(weightKG, forKey: .weightKG)
    }
    if eventType == nil {
      try c.encodeIfPresent(weightKG, forKey: .weightKG)
      try c.encodeIfPresent(diaperKind, forKey: .diaperKind)
    }
    try c.encodeIfPresent(measurementDate, forKey: .measurementDate)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(note, forKey: .note)
    try c.encodeIfPresent(occurredOn, forKey: .occurredOn)
    try c.encodeIfPresent(datePrecision, forKey: .datePrecision)
    try c.encodeIfPresent(isFirst, forKey: .isFirst)
    try c.encodeIfPresent(correctionKind, forKey: .correctionKind)
    try c.encodeIfPresent(amountML, forKey: .amountML)
    try c.encodeIfPresent(targetID, forKey: .targetID)
    try c.encodeIfPresent(targetType, forKey: .targetType)
    try c.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
    try c.encodeIfPresent(void, forKey: .void)
  }
  public static func == (a: Self, b: Self) -> Bool {
    let encoder = APIJSON.encoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(a)) == (try? encoder.encode(b))
  }
  public static func event(_ event: EventPayload, timeZone: TimeZone = .current) -> Self {
    var p = Self()
    p.eventType = event.eventType.rawValue
    p.occurredAt = event.occurredAt
    p.volumeML = event.volumeML
    p.diaperKind = event.diaperKind?.rawValue
    p.weightKG = event.weightKG
    if event.eventType == .weight {
      p.measurementDate = CalendarDate.string(event.occurredAt, timeZone: timeZone)
    }
    return p
  }
}
public struct PhoneZoneOffset: Codable, Equatable, Sendable {
  public let from: Date
  public let seconds: Int
  public static func == (a: Self, b: Self) -> Bool {
    a.seconds == b.seconds && APIJSON.string(a.from) == APIJSON.string(b.from)
  }
  public static func capture(reference: Date, zone: TimeZone) -> [Self] {
    var cursor = reference.addingTimeInterval(-366 * 86400)
    var values = [Self(from: cursor, seconds: zone.secondsFromGMT(for: cursor))]
    while values.count < 16, let next = zone.nextDaylightSavingTimeTransition(after: cursor),
      next <= reference
    {
      values.append(Self(from: next, seconds: zone.secondsFromGMT(for: next.addingTimeInterval(1))))
      cursor = next.addingTimeInterval(1)
    }
    return values
  }
}
public struct CareQueryContext: Codable, Equatable, Sendable {
  public enum Domain: String, Codable, Sendable {
    case feeding, diaper, sleep, weight, milestone, care
  }
  public let childID: UUID
  public let domain: Domain
  public let recordID: UUID?
  public let at: Date
  public init(childID: UUID, domain: Domain, recordID: UUID? = nil, at: Date) {
    self.childID = childID
    self.domain = domain
    self.recordID = recordID
    self.at = at
  }
  enum CodingKeys: String, CodingKey {
    case domain, at
    case childID = "child_id"
    case recordID = "record_id"
  }
  public static func == (a: Self, b: Self) -> Bool {
    a.childID == b.childID && a.domain == b.domain && a.recordID == b.recordID
      && APIJSON.string(a.at) == APIJSON.string(b.at)
  }
}
public struct CareQueryPresentation: Codable, Equatable, Sendable {
  public enum Milk: String, Codable, Sendable { case ml, oz }
  public enum Weight: String, Codable, Sendable { case kg, lb }
  public enum Surface: String, Codable, Sendable { case spoken, visual }
  public let milk: Milk
  public let weight: Weight
  public let surface: Surface
  public init(milk: Milk = .ml, weight: Weight = .kg, surface: Surface) {
    self.milk = milk
    self.weight = weight
    self.surface = surface
  }
}
// Ephemeral read context; never grants mutation authority or changes a queued request.
struct CareQueryMemory {
  private var userID: UUID?
  private var value: CareQueryContext?
  mutating func clear() {
    userID = nil
    value = nil
  }
  func context(userID: UUID, at: Date) -> CareQueryContext? {
    guard self.userID == userID, let value,
      (0...600).contains(at.timeIntervalSince(value.at))
    else { return nil }
    return value
  }
  mutating func receive(_ response: CareResponse, userID: UUID) {
    guard response.isAnswered, let context = response.queryContext,
      context.childID == response.childID
    else {
      clear()
      return
    }
    self.userID = userID
    value = context
  }
}
public struct CareCommand: Codable, Equatable, Identifiable, Sendable {
  public let requestID: UUID
  public var id: UUID { requestID }
  public let referenceAt: Date
  public let timeZone: String
  public let utcOffsetSeconds: Int
  public let zoneOffsets: [PhoneZoneOffset]
  public let source: String
  public let mode: String
  public let childID: UUID?
  public let text: String?
  public let action: String?
  public let payload: CarePayload?
  public let proposalID: UUID?
  public let confirmed: Bool?
  public let language: String?
  public private(set) var queryContext: CareQueryContext? = nil
  public private(set) var presentation: CareQueryPresentation? = nil
  public init(
    text: String, childID: UUID? = nil, source: String = "siri", referenceAt: Date = Date(),
    timeZone: TimeZone = .current, requestID: UUID = UUID()
  ) {
    self.requestID = requestID
    self.referenceAt = referenceAt
    self.timeZone = timeZone.identifier
    self.utcOffsetSeconds = timeZone.secondsFromGMT(for: referenceAt)
    self.zoneOffsets = PhoneZoneOffset.capture(reference: referenceAt, zone: timeZone)
    self.source = source
    mode = "text"
    self.childID = childID
    self.text = text
    action = nil
    payload = nil
    proposalID = nil
    confirmed = nil
    language = nil
  }
  public init(
    action: String, childID: UUID, payload: CarePayload, referenceAt: Date = Date(),
    timeZone: TimeZone = .current, requestID: UUID = UUID()
  ) {
    self.requestID = requestID
    self.referenceAt = referenceAt
    self.timeZone = timeZone.identifier
    self.utcOffsetSeconds = timeZone.secondsFromGMT(for: referenceAt)
    self.zoneOffsets = PhoneZoneOffset.capture(reference: referenceAt, zone: timeZone)
    source = "manual"
    mode = "action"
    self.childID = childID
    text = nil
    self.action = action
    self.payload = payload
    proposalID = nil
    confirmed = nil
    language = nil
  }
  public init(
    proposalID: UUID, childID: UUID, confirmed: Bool, source: String = "manual",
    language: String? = nil,
    referenceAt: Date = Date(), timeZone: TimeZone = .current, requestID: UUID = UUID()
  ) {
    self.requestID = requestID
    self.referenceAt = referenceAt
    self.timeZone = timeZone.identifier
    self.utcOffsetSeconds = timeZone.secondsFromGMT(for: referenceAt)
    self.zoneOffsets = PhoneZoneOffset.capture(reference: referenceAt, zone: timeZone)
    self.source = source
    mode = "confirm"
    self.childID = childID
    text = nil
    action = nil
    payload = nil
    self.proposalID = proposalID
    self.confirmed = confirmed
    self.language = language
  }
  enum CodingKeys: String, CodingKey {
    case source, mode, text, action, payload, confirmed, language, presentation
    case queryContext = "query_context"
    case requestID = "request_id"
    case referenceAt = "reference_at"
    case timeZone = "time_zone"
    case childID = "child_id"
    case proposalID = "proposal_id"
    case utcOffsetSeconds = "utc_offset_seconds"
    case zoneOffsets = "zone_offsets"
  }
  public func attaching(queryContext: CareQueryContext?, presentation: CareQueryPresentation?)
    -> Self
  {
    guard mode == "text", source != "manual" else { return self }
    var copy = self
    copy.queryContext = queryContext
    copy.presentation = presentation
    return copy
  }
  public static func == (a: Self, b: Self) -> Bool {
    a.requestID == b.requestID && APIJSON.string(a.referenceAt) == APIJSON.string(b.referenceAt)
      && a.timeZone == b.timeZone && a.utcOffsetSeconds == b.utcOffsetSeconds
      && a.zoneOffsets == b.zoneOffsets && a.source == b.source && a.mode == b.mode
      && a.childID == b.childID && a.text == b.text && a.action == b.action
      && a.payload == b.payload && a.proposalID == b.proposalID && a.confirmed == b.confirmed
      && a.language == b.language && a.queryContext == b.queryContext
      && a.presentation == b.presentation
  }
}
public struct CareResponse: Codable, Identifiable, Sendable {
  public var id: String { proposalID?.uuidString ?? eventID?.uuidString ?? status + message }
  public let status: String
  public let message: String
  public let eventID: UUID?
  public let childID: UUID?
  public let proposalID: UUID?
  public var eventIDs: [UUID]? = nil
  public var language: String? = nil
  public var isDeletion: Bool? = nil
  public var queryContext: CareQueryContext? = nil
  public var isPersisted: Bool {
    guard status == "recorded", childID != nil else { return false }
    if let eventIDs {
      return !eventIDs.isEmpty && eventIDs.count <= 5 && Set(eventIDs).count == eventIDs.count
    }
    return eventID != nil
  }
  public var isAnswered: Bool { status == "answered" }
  public var needsConfirmation: Bool {
    status == "needs_confirmation" && proposalID != nil && childID != nil
  }
  enum CodingKeys: String, CodingKey {
    case status, message, language
    case queryContext = "query_context"
    case eventIDs = "event_ids"
    case isDeletion = "is_deletion"
    case eventID = "event_id"
    case childID = "child_id"
    case proposalID = "proposal_id"
  }
}
public struct PendingCareCommand: Codable, Identifiable, Sendable {
  public let userID: UUID
  public let command: CareCommand
  public var id: UUID { command.id }
}

struct FeedingCorrectionDraft {
  enum Mode: String, CaseIterable {
    case total, leftover
    var title: String {
      self == .total ? "Change amount drunk" : "Subtract milk left in bottle"
    }
  }
  let currentML: Double
  let basisML: Double
  private(set) var mode: Mode = .total
  var input: String
  init(currentML: Double, basisML: Double) {
    self.currentML = currentML
    self.basisML = basisML
    input = currentML.formatted(.number.grouping(.never))
  }
  mutating func select(_ value: Mode) {
    guard mode != value else { return }
    mode = value
    input = ""
  }
  var amountML: Double? {
    let decimal = Locale.current.decimalSeparator ?? "."
    guard !input.isEmpty, input.allSatisfy({ $0.isNumber || String($0) == decimal }),
      input.components(separatedBy: decimal).count <= 2,
      let value = Double(input.replacingOccurrences(of: decimal, with: ".")),
      value.isFinite, value >= 0, value <= 2000,
      abs(value * 100 - (value * 100).rounded()) < 1e-7,
      mode == .total || (basisML.isFinite && basisML > value && basisML <= 2000)
    else { return nil }
    return value
  }
  var resultML: Double? {
    guard let amountML else { return nil }
    return mode == .leftover ? basisML - amountML : amountML
  }
}
public struct RevisionValue: Codable, Sendable {
  public let volumeML: Double?
  public let weightKG: Double?
  public let diaperKind: String?
  public let startedAt: Date?
  public let endedAt: Date?
  public let title: String?
  public let name: String?
  public let voidedAt: Date?
  enum CodingKeys: String, CodingKey {
    case title, name
    case volumeML = "volume_ml"
    case weightKG = "weight_kg"
    case diaperKind = "diaper_kind"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case voidedAt = "voided_at"
  }
  public var label: String {
    if voidedAt != nil { return "Removed from totals" }
    if let volumeML { return "\(volumeML.formatted()) mL" }
    if let weightKG { return "\(weightKG.formatted()) kg" }
    if let diaperKind {
      return diaperKind == "mixed" ? "Wet and dirty diaper" : "\(diaperKind.capitalized) diaper"
    }
    if let title { return title }
    if let name { return name }
    if let startedAt {
      return
        "\(startedAt.formatted(date:.abbreviated,time:.shortened)) → \(endedAt?.formatted(date:.abbreviated,time:.shortened) ?? "ongoing")"
    }
    return "Record updated"
  }
}
public struct RecordRevision: Codable, Identifiable, Sendable {
  public let id: UUID
  public let targetType: String
  public let targetID: UUID
  public let changedBy: UUID
  public let createdAt: Date
  public let beforeValue: RevisionValue
  public let afterValue: RevisionValue
  enum CodingKeys: String, CodingKey {
    case id
    case targetType = "target_type"
    case targetID = "target_id"
    case changedBy = "changed_by"
    case createdAt = "created_at"
    case beforeValue = "before_value"
    case afterValue = "after_value"
  }
}
