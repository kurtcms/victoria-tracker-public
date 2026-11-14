import Foundation

public struct GrowthReference: Sendable {
  public struct LMS: Sendable {
    public let day: Int
    public let l: Double
    public let m: Double
    public let s: Double
    public func weight(z: Double) -> Double? {
      let value = abs(l) < 1e-10 ? m * exp(s * z) : m * pow(1 + l * s * z, 1 / l)
      return value.isFinite && value > 0 ? value : nil
    }
    public func percentile(weight: Double) -> Double? {
      guard weight.isFinite, weight > 0 else { return nil }
      let z = abs(l) < 1e-10 ? log(weight / m) / s : (pow(weight / m, l) - 1) / (l * s)
      // Do not extrapolate extreme-tail centiles beyond the displayed reference.
      guard z.isFinite, abs(z) <= 3 else { return nil }
      return 50 * (1 + erf(z / sqrt(2)))
    }
  }
  public let rows: [LMS]
  public init(csv: String) throws {
    let lines = csv.split(whereSeparator: \.isNewline)
    guard lines.first == "day,L,M,S" else {
      throw TrackerError.message("Growth reference is unavailable.")
    }
    var values: [LMS] = []
    for line in lines.dropFirst() {
      let c = line.split(separator: ",")
      guard c.count == 4, let day = Int(c[0]), day == values.count, let l = Double(c[1]),
        let m = Double(c[2]), let s = Double(c[3]), l.isFinite, m.isFinite, s.isFinite, m > 0, s > 0
      else { throw TrackerError.message("Invalid growth reference.") }
      values.append(LMS(day: day, l: l, m: m, s: s))
    }
    guard values.count == 1857 else { throw TrackerError.message("Incomplete growth reference.") }
    rows = values
  }
  public func parameters(day: Int) -> LMS? { rows.indices.contains(day) ? rows[day] : nil }
  public static func load(sex: String, bundle: Bundle = .main) throws -> Self {
    guard ["female", "male"].contains(sex),
      let url = bundle.url(forResource: "who-weight-\(sex)", withExtension: "csv")
    else { throw TrackerError.message("Growth reference is unavailable.") }
    return try Self(csv: String(contentsOf: url, encoding: .utf8))
  }
  public static let curves: [(label: String, z: Double)] = [
    ("3rd", -1.880793608), ("15th", -1.036433389), ("50th", 0), ("85th", 1.036433389),
    ("97th", 1.880793608),
  ]
}
