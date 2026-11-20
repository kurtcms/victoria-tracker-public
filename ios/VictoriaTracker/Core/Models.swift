import Foundation

enum TrackerError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let value): value
    }
  }
}

public enum EventType: String, Codable, CaseIterable, Sendable {
  case feeding, diaper, weight
  public var title: String {
    switch self {
    case .feeding: "Milk"
    case .diaper: "Diaper"
    case .weight: "Weight"
    }
  }
  public var symbol: String {
    switch self {
    case .feeding: "waterbottle.fill"
    case .diaper: "drop.fill"
    case .weight: "scalemass.fill"
    }
  }
}
public enum DiaperKind: String, Codable, CaseIterable, Sendable {
  case wet, dirty, mixed
  public var title: String { self == .mixed ? "Wet and dirty" : rawValue.capitalized }
}
public struct Child: Codable, Identifiable, Equatable, Sendable {
  public static let defaultTimeZoneID = "America/Vancouver"
  public let id: UUID
  public let familyID: UUID
  public let name: String
  public let timeZone: String
  public var dateOfBirth: String? = nil
  public var voicePronoun: String? = nil
  public var growthReferenceSex: String? = nil
  public var growthReferenceConfirmed: Bool? = nil
  public var wasPremature: Bool? = nil
  public var profileVersion: Int? = nil
  public var archivedAt: Date? = nil
  enum CodingKeys: String, CodingKey {
    case id
    case familyID = "family_id"
    case name
    case timeZone = "time_zone"
    case dateOfBirth = "date_of_birth"
    case voicePronoun = "voice_pronoun"
    case growthReferenceSex = "growth_reference_sex"
    case growthReferenceConfirmed = "growth_reference_confirmed"
    case wasPremature = "was_premature"
    case profileVersion = "profile_version"
    case archivedAt = "archived_at"
  }
}
public struct BabyEvent: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let childID: UUID
  public let eventType: EventType
  public let occurredAt: Date
  public let recordedBy: UUID
  public let inputSource: String
  public let createdAt: Date
  public let volumeML: Double?
  public let diaperKind: DiaperKind?
  public let weightKG: Double?
  public let requestID: UUID
  public var revision: Int? = nil
  public var measurementDate: String? = nil
  public var feedingBasisML: Double? = nil
  public var detail: String {
    switch eventType {
    case .feeding:
      "\((volumeML ?? 0).formatted(.number.precision(.fractionLength(0...2)))) mL of milk"
    case .diaper: "\(diaperKind?.title ?? "Unknown") diaper"
    case .weight: "\((weightKG ?? 0).formatted(.number.precision(.fractionLength(0...3)))) kg"
    }
  }
  enum CodingKeys: String, CodingKey {
    case id
    case childID = "child_id"
    case eventType = "event_type"
    case occurredAt = "occurred_at"
    case recordedBy = "recorded_by"
    case inputSource = "input_source"
    case createdAt = "created_at"
    case volumeML = "volume_ml"
    case diaperKind = "diaper_kind"
    case weightKG = "weight_kg"
    case requestID = "request_id"
    case revision
    case measurementDate = "measurement_date"
    case feedingBasisML = "feeding_basis_ml"
  }
}
public struct EventPayload: Codable, Equatable, Sendable {
  public var eventType: EventType
  public var occurredAt: Date
  public var volumeML: Double?
  public var diaperKind: DiaperKind?
  public var weightKG: Double?
  public init(
    eventType: EventType, occurredAt: Date, volumeML: Double? = nil, diaperKind: DiaperKind? = nil,
    weightKG: Double? = nil
  ) {
    self.eventType = eventType
    self.occurredAt = occurredAt
    self.volumeML = volumeML
    self.diaperKind = diaperKind
    self.weightKG = weightKG
  }
  public var isValid: Bool {
    switch eventType {
    case .feeding:
      volumeML.map { $0.isFinite && $0 > 0 && $0 <= 2000 && Self.hasPrecision($0, scale: 100) }
        == true && diaperKind == nil && weightKG == nil
    case .diaper: diaperKind != nil && volumeML == nil && weightKG == nil
    case .weight:
      weightKG.map { $0.isFinite && $0 > 0 && $0 <= 100 && Self.hasPrecision($0, scale: 1000) }
        == true && volumeML == nil && diaperKind == nil
    }
  }
  private static func hasPrecision(_ value: Double, scale: Double) -> Bool {
    abs(value * scale - (value * scale).rounded()) < 1e-7
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.eventType == rhs.eventType
      && APIJSON.string(lhs.occurredAt) == APIJSON.string(rhs.occurredAt)
      && lhs.volumeML == rhs.volumeML && lhs.diaperKind == rhs.diaperKind
      && lhs.weightKG == rhs.weightKG
  }
  enum CodingKeys: String, CodingKey {
    case eventType = "event_type"
    case occurredAt = "occurred_at"
    case volumeML = "volume_ml"
    case diaperKind = "diaper_kind"
    case weightKG = "weight_kg"
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(eventType, forKey: .eventType)
    try c.encode(occurredAt, forKey: .occurredAt)
    // Explicit nulls are required by the backend contract.
    try c.encode(volumeML, forKey: .volumeML)
    try c.encode(diaperKind, forKey: .diaperKind)
    try c.encode(weightKG, forKey: .weightKG)
  }
}
public struct RecordCommand: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID { requestID }
  public let requestID: UUID
  public let childID: UUID
  public let referenceAt: Date
  public let source: String
  public let locale: String
  // Optional only for decoding pending entries created before phone-zone support.
  public let timeZoneID: String?
  public let mode: String
  public let text: String?
  public let event: EventPayload?
  public init(
    childID: UUID, text: String, source: String, referenceAt: Date = Date(),
    requestID: UUID = UUID(), timeZone: TimeZone = .current
  ) {
    self.childID = childID
    self.text = text
    self.source = source
    self.referenceAt = referenceAt
    self.requestID = requestID
    locale = "en"
    timeZoneID = timeZone.identifier
    mode = "text"
    event = nil
  }
  public init(
    childID: UUID, event: EventPayload, referenceAt: Date = Date(), requestID: UUID = UUID(),
    timeZone: TimeZone = .current
  ) {
    self.childID = childID
    self.event = event
    self.referenceAt = referenceAt
    self.requestID = requestID
    source = "manual"
    locale = "en"
    timeZoneID = timeZone.identifier
    mode = "manual"
    text = nil
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.requestID == rhs.requestID && lhs.childID == rhs.childID
      && APIJSON.string(lhs.referenceAt) == APIJSON.string(rhs.referenceAt)
      && lhs.source == rhs.source && lhs.locale == rhs.locale && lhs.mode == rhs.mode
      && lhs.timeZoneID == rhs.timeZoneID
      && lhs.text == rhs.text && lhs.event == rhs.event
  }
  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case childID = "child_id"
    case referenceAt = "reference_at"
    case timeZoneID = "time_zone"
    case source, locale, mode, text, event
  }
}
public struct RecordResponse: Codable, Sendable {
  public let status: String
  public let message: String
  public let event: BabyEvent?
  public let replayed: Bool?
  public var isPersisted: Bool { status == "recorded" && event != nil }
}
public struct PendingRecord: Codable, Identifiable, Sendable {
  public var id: UUID { command.id }
  public let userID: UUID
  public let command: RecordCommand
  public init(userID: UUID, command: RecordCommand) {
    self.userID = userID
    self.command = command
  }
}
