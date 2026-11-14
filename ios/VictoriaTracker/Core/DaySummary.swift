import Foundation

/// Snapshot the phone's local day so the database query, totals and labels agree.
public struct LocalDay: Sendable {
  public let reference: Date
  public let timeZone: TimeZone
  public init(reference: Date = Date(), timeZone: TimeZone = .current) {
    self.reference = reference
    self.timeZone = timeZone
  }
  public var interval: DateInterval {
    DaySummary.interval(now: reference, timeZone: timeZone)
  }
  public func isToday(now: Date = Date()) -> Bool {
    interval.start == Self(reference: now, timeZone: timeZone).interval.start
  }
  public func relativeLabel(now: Date = Date()) -> String? {
    if isToday(now: now) { return "Today" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    return calendar.isDate(reference, inSameDayAs: yesterday) ? "Yesterday" : nil
  }
  public var timeZoneLabel: String {
    let seconds = timeZone.secondsFromGMT(for: reference)
    let offset = String(
      format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", abs(seconds) / 3600,
      abs(seconds) % 3600 / 60)
    let name = timeZone.localizedName(for: .shortGeneric, locale: .current) ?? timeZone.identifier
    return "\(name) · \(offset)"
  }
}

/// Nil-free calendar dates keep a historical selection stable when the phone travels.
/// Today remains a live selection and follows midnight rather than freezing a date.
public enum DaySelection: Equatable, Sendable {
  case today
  case date(year: Int, month: Int, day: Int)

  public init(date: Date, now: Date = Date(), timeZone: TimeZone = .current) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    if calendar.startOfDay(for: date) >= calendar.startOfDay(for: now) {
      self = .today
    } else {
      let components = calendar.dateComponents([.year, .month, .day], from: date)
      self = .date(year: components.year!, month: components.month!, day: components.day!)
    }
  }

  public func localDay(now: Date = Date(), timeZone: TimeZone = .current) -> LocalDay {
    let today = LocalDay(reference: now, timeZone: timeZone)
    guard case .date(let year, let month, let day) = self else { return today }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard
      let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
      calendar.startOfDay(for: date) < today.interval.start
    else { return today }
    return LocalDay(reference: date, timeZone: timeZone)
  }

  public func moving(by days: Int, now: Date = Date(), timeZone: TimeZone = .current) -> Self {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let date = calendar.date(
      byAdding: .day, value: days, to: localDay(now: now, timeZone: timeZone).reference)!
    return Self(date: date, now: now, timeZone: timeZone)
  }
}

public struct DaySummary: Sendable {
  public let events: [BabyEvent]
  public var milkML: Double {
    events.reduce(0) { $0 + ($1.eventType == .feeding ? $1.volumeML ?? 0 : 0) }
  }
  public var wetCount: Int {
    events.filter { $0.diaperKind == .wet || $0.diaperKind == .mixed }.count
  }
  public var dirtyCount: Int {
    events.filter { $0.diaperKind == .dirty || $0.diaperKind == .mixed }.count
  }
  public init(events: [BabyEvent], now: Date = Date(), timeZone: TimeZone) {
    let interval = Self.interval(now: now, timeZone: timeZone)
    self.events = events.filter { $0.occurredAt >= interval.start && $0.occurredAt < interval.end }
      .sorted {
        $0.occurredAt == $1.occurredAt
          ? $0.id.uuidString < $1.id.uuidString : $0.occurredAt > $1.occurredAt
      }
  }
  public static func interval(now: Date, timeZone: TimeZone) -> DateInterval {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = calendar.startOfDay(for: now)
    return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
  }
}
public enum APIJSON {
  public static func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(string(date))
    }
    return e
  }
  public static func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
      let c = try decoder.singleValueContainer()
      let value = try c.decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let normal = ISO8601DateFormatter()
      normal.formatOptions = [.withInternetDateTime]
      guard let date = fractional.date(from: value) ?? normal.date(from: value) else {
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid server timestamp")
      }
      return date
    }
    return d
  }
  public static func string(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }
}
