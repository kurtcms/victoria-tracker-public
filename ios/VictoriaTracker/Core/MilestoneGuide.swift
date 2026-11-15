import Foundation

public struct MilestoneGuideSource: Equatable, Sendable, Identifiable {
  public var id: String { url.absoluteString }
  public let name: String
  public let url: URL
  public let retrievedOn: String
}

public enum MilestoneGuideSemantics: String, Sendable {
  case byAge, visitSurveillance
  public var explanation: String {
    switch self {
    case .byAge:
      "CDC checkpoint: skills at least 75% of children can do by this age, not the age a skill first appears."
    case .visitSurveillance:
      "Rourke visit check: observed at the 1-month visit, after typical acquisition; not a first-achievement age."
    }
  }
}

public struct MilestoneGuideEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let checkpointMonths: Int
  public let semantics: MilestoneGuideSemantics
  public let sources: [MilestoneGuideSource]

  public func recordedMilestone(in milestones: [Milestone], childID: UUID) -> Milestone? {
    // Imported memories are intentionally never matched by title or meaning.
    milestones.first { $0.childID == childID && $0.guideID == id }
  }

  public func removalCommand(
    for milestone: Milestone, childID: UUID, timeZone: TimeZone = .current
  ) -> CareCommand? {
    guard milestone.childID == childID, milestone.guideID == id else { return nil }
    var payload = CarePayload()
    payload.targetType = "milestone"
    payload.targetID = milestone.id
    payload.expectedRevision = milestone.revision
    payload.void = true
    return CareCommand(action: "propose_edit", childID: childID, payload: payload, timeZone: timeZone)
  }

  public func command(
    childID: UUID, observedOn: String? = nil, birth: String?, now: Date = Date(),
    timeZone: TimeZone = .current
  ) -> CareCommand? {
    let today = CalendarDate.string(now, timeZone: timeZone)
    let day = observedOn ?? today
    guard let observed = CalendarDate.parse(day), let latest = CalendarDate.parse(today),
      observed <= latest
    else { return nil }
    if let birth, let birthday = CalendarDate.parse(birth), observed < birthday { return nil }
    var payload = CarePayload()
    payload.title = title
    payload.guideID = id
    payload.occurredOn = day
    payload.datePrecision = "day"
    // Observing a skill does not establish when it first happened.
    payload.isFirst = false
    return CareCommand(
      action: "milestone", childID: childID, payload: payload, referenceAt: now, timeZone: timeZone)
  }
}

public struct MilestoneGuideAgeContext: Equatable, Sendable {
  public let completedMonths: Int
  public let currentCheckpoint: Int?
  public let nextCheckpoint: Int?
}

/// Keeps uncertain network attempts closed to a second tap until the app reconciles them.
public struct MilestoneGuideRecordingState: Sendable {
  private var attempts: [String: CareCommand] = [:]
  private var saving: Set<String> = []
  private var recorded: Set<String> = []
  public init() {}
  public func hasAttempt(_ id: String) -> Bool { attempts[id] != nil }
  public func isSaving(_ id: String) -> Bool { saving.contains(id) }
  public func isRecorded(_ id: String) -> Bool { recorded.contains(id) }
  public mutating func retry(_ id: String) -> CareCommand? {
    guard !saving.contains(id), let command = attempts[id] else { return nil }
    saving.insert(id)
    return command
  }
  public mutating func begin(_ command: CareCommand, guideID: String) -> Bool {
    guard attempts[guideID] == nil, !recorded.contains(guideID),
      command.action == "milestone", command.payload?.guideID == guideID
    else { return false }
    attempts[guideID] = command
    saving.insert(guideID)
    return true
  }
  /// Call only after the removal confirmation has persisted.
  public mutating func removeConfirmedObservation(_ id: String) {
    recorded.remove(id)
  }
  public mutating func reconcile(recordedGuideIDs: Set<String>) {
    recorded.formIntersection(recordedGuideIDs)
  }
  public mutating func finish(guideID: String, response: CareResponse?) {
    saving.remove(guideID)
    guard let command = attempts[guideID], let response else { return }
    if response.isPersisted, response.childID == command.childID {
      recorded.insert(guideID)
      attempts[guideID] = nil
    } else if ["rejected", "needs_clarification"].contains(response.status) {
      attempts[guideID] = nil
    }
  }
}

public enum MilestoneGuide {
  public static let checkpoints = [1, 2, 4, 6, 9, 12, 15, 18, 24, 30, 36, 48, 60]
  public static let aap = source(
    "AAP developmental milestones",
    "https://www.aap.org/en/patient-care/developmental-surveillance-and-screening-patient-care/developmental-milestones/"
  )
  public static let rourke = source(
    "Rourke Baby Record 2024 · page 1",
    "https://www.rourkebabyrecord.ca/pdf/2024/RBR%202024%20NAT-EN-3vpp-May%2018-BLACK-Feb%209.pdf#page=1"
  )
  public static let cps = source(
    "CPS · Feeding in the first year",
    "https://caringforkids.cps.ca/handouts/healthy-living/feeding_your_baby_in_the_first_year")
  public static let cpsRourke = source(
    "CPS · About the Rourke Baby Record", "https://cps.ca/en/tools-outils/rourke-baby-record")

  private static func source(_ name: String, _ url: String) -> MilestoneGuideSource {
    MilestoneGuideSource(name: name, url: URL(string: url)!, retrievedOn: "2026-11-14")
  }

  public static func ageContext(birth: String?, today: String) -> MilestoneGuideAgeContext? {
    guard let birth, let birthday = CalendarDate.parse(birth), let date = CalendarDate.parse(today),
      date >= birthday
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.dateComponents([.year, .month], from: birthday)
    let end = calendar.dateComponents([.year, .month], from: date)
    var months = (end.year! - start.year!) * 12 + end.month! - start.month!
    if let anniversary = calendar.date(byAdding: .month, value: months, to: birthday),
      date < anniversary
    {
      months -= 1
    }
    return MilestoneGuideAgeContext(
      completedMonths: months,
      currentCheckpoint: checkpoints.last { $0 <= months },
      nextCheckpoint: checkpoints.first { $0 > months })
  }

  public static func ageTitle(_ months: Int) -> String {
    if months == 1 { return "1 month" }
    if months >= 24 && months % 12 == 0 { return "\(months / 12) years" }
    if months == 12 { return "1 year" }
    return "\(months) months"
  }

  private static func cdc(_ months: Int, _ rows: [(String, String)]) -> [MilestoneGuideEntry] {
    let page: String
    switch months {
    case 12: page = "1-year"
    case 24, 36, 48, 60: page = "\(months / 12)-years"
    default: page = "\(months)-months"
    }
    let citation = source(
      "CDC · By \(ageTitle(months))", "https://www.cdc.gov/act-early/milestones/\(page).html")
    return rows.map { key, title in
      MilestoneGuideEntry(
        id: "cdc-\(months)m-\(key)", title: title, checkpointMonths: months, semantics: .byAge,
        sources: months == 2 ? [citation, aap] : [citation])
    }
  }

  // A small paraphrased selection, not a complete checklist or a screening instrument.
  // The source and age attached to an ID are part of its stable recording identity.
  public static let entries: [MilestoneGuideEntry] = {
    let early = [
      ("gaze", "Focuses their gaze"), ("startle", "Startles at a loud noise"),
      ("needs", "Cries to communicate needs"), ("comfort", "Settles with comforting"),
    ].map { key, title in
      MilestoneGuideEntry(
        id: "rbr-1m-\(key)", title: title, checkpointMonths: 1,
        semantics: .visitSurveillance, sources: [rourke])
    }
    return early
      + cdc(
        2,
        [
          ("social-smile", "Smiles in response to your smile or voice"),
          ("face", "Looks toward your face"), ("sounds", "Vocalizes beyond crying"),
          ("watch", "Watches you moving nearby"), ("tummy-head", "Raises head while on tummy"),
          ("limbs", "Moves both arms and both legs"),
        ])
      + cdc(
        4,
        [
          ("attention-smile", "Smiles to draw your attention"),
          ("chuckle", "Chuckles when you play"),
          ("coo", "Makes vowel-like cooing sounds"), ("voice", "Turns toward your voice"),
          ("head-steady", "Keeps head steady when held"),
          ("forearms", "Props up on forearms during tummy time"),
          ("toy", "Keeps hold of a toy placed in their hand"),
        ])
      + cdc(
        6,
        [
          ("familiar", "Recognizes familiar people"), ("laugh", "Laughs during interaction"),
          ("sound-turns", "Exchanges sounds with you in turns"),
          ("reach", "Reaches toward a wanted toy"), ("roll", "Rolls from tummy onto back"),
          ("supported-sit", "Sits while leaning on hands for support"),
          ("straight-arms", "Pushes up on straight arms while on tummy"),
        ])
      + cdc(
        9,
        [
          ("name", "Looks toward you when their name is called"),
          ("peekaboo", "Enjoys peekaboo with smiles or laughter"),
          ("babble", "Babbles repeated syllables"), ("pickup", "Raises arms to be picked up"),
          ("hidden", "Searches for an object dropped from view"),
          ("sit-unsupported", "Sits without needing support"),
          ("into-sitting", "Moves into a sitting position independently"),
          ("transfer", "Transfers objects between hands"),
        ])
      + cdc(
        12,
        [
          ("wave", "Waves goodbye"), ("parent-name", "Uses a special name for a parent"),
          ("container", "Places an object inside a container"),
          ("hidden", "Finds something they watched you hide"),
          ("pull-stand", "Pulls themselves into standing"),
          ("cruise", "Steps along while holding furniture"),
          ("pincer", "Picks up small objects with thumb and forefinger"),
        ])
      + cdc(
        15,
        [
          ("show", "Shows you an object they enjoy"), ("clap", "Claps to express excitement"),
          ("words", "Attempts one or two words beyond parent names"),
          ("point-request", "Points to request something or help"),
          ("stack", "Builds a stack of at least two objects"),
          ("steps", "Takes several steps independently"),
          ("finger-food", "Self-feeds using fingers"),
        ])
      + cdc(
        18,
        [
          ("point-interest", "Points out something interesting to you"),
          ("book", "Shares a few book pages with you"),
          ("words", "Attempts at least three words beyond parent names"),
          ("direction", "Follows one spoken step without a gesture"),
          ("walk", "Walks independently without holding on"), ("scribble", "Makes scribbles"),
          ("spoon", "Tries feeding with a spoon"),
        ])
      + cdc(
        24,
        [
          ("upset", "Notices someone else feeling hurt or upset"),
          ("two-words", "Combines at least two words"),
          ("body-parts", "Points to two body parts when asked"),
          ("toy-controls", "Experiments with a toy's buttons or knobs"),
          ("kick", "Kicks a ball forward"), ("run", "Runs"), ("spoon", "Eats using a spoon"),
        ])
      + cdc(
        30,
        [
          ("peers", "Plays beside peers and sometimes together"),
          ("words", "Uses roughly 50 words"),
          ("action-phrase", "Combines words including an action word"),
          ("pretend", "Uses an object as something else in pretend play"),
          ("two-steps", "Follows two connected instructions"),
          ("jump", "Jumps with both feet leaving the ground"),
          ("pages", "Turns pages individually during reading"),
        ])
      + cdc(
        36,
        [
          ("join-play", "Joins other children's play"),
          ("conversation", "Shares a conversation with two back-and-forth exchanges"),
          ("questions", "Asks who, what, where, or why"),
          ("name", "Says their first name when asked"),
          ("circle", "Copies a circle after a demonstration"),
          ("clothes", "Puts on some clothes independently"), ("fork", "Eats using a fork"),
        ])
      + cdc(
        48,
        [
          ("comfort", "Offers comfort when someone is sad or hurt"),
          ("pretend-role", "Takes on a role in pretend play"),
          ("sentences", "Uses sentences of at least four words"),
          ("day", "Tells you about something from their day"),
          ("colors", "Names a few colours"),
          ("person", "Draws a person with at least three body parts"),
          ("catch", "Usually catches a large ball"),
        ])
      + cdc(
        60,
        [
          ("game-turns", "Follows game rules or takes turns with peers"),
          ("chores", "Helps with simple household tasks"),
          ("story", "Tells a story containing at least two events"),
          ("conversation", "Keeps talking for more than three back-and-forth exchanges"),
          ("count", "Counts up to ten"),
          ("letters", "Writes some letters from their name"), ("hop", "Hops using one foot"),
        ])
  }()
}
