import XCTest

#if canImport(VictoriaTrackerCore)
  @testable import VictoriaTrackerCore
#else
  @testable import VictoriaTracker
#endif

final class MilestoneGuideTests: XCTestCase {
  func testMemorySearchAndOrderingPreserveDatesAndUseAlphabeticalTies() throws {
    func memory(_ title: String, _ date: String, note: String? = nil,
                precision: String = "day") throws -> Milestone {
      var object: [String: Any] = [
        "id": UUID().uuidString, "child_id": UUID().uuidString, "title": title,
        "occurred_on": date, "date_precision": precision, "is_first": false,
        "recorded_by": UUID().uuidString, "input_source": "manual",
        "created_at": "2026-11-14T12:00:00Z", "revision": 1,
      ]
      if let note { object["note"] = note }
      return try APIJSON.decoder().decode(
        Milestone.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let memories = try [
      memory("Zoo visit", "2026-11-14", note: "With grandma"),
      memory("Café outing", "2026-11-14"),
      memory("First smile", "2026-10-01", precision: "month"),
      memory("Apple picking", "2026-11-01"),
    ]
    XCTAssertEqual(Milestone.browse(memories).map(\.title),
                   ["Café outing", "Zoo visit", "Apple picking", "First smile"])
    XCTAssertEqual(Milestone.browse(memories, sort: .oldest).map(\.title),
                   ["First smile", "Apple picking", "Café outing", "Zoo visit"])
    XCTAssertEqual(Milestone.browse(memories, sort: .alphabetical).map(\.title),
                   ["Apple picking", "Café outing", "First smile", "Zoo visit"])
    XCTAssertEqual(Milestone.browse(memories, search: "  CAFE  ").map(\.title), ["Café outing"])
    XCTAssertEqual(Milestone.browse(memories, search: "GRANDMA").map(\.title), ["Zoo visit"])
    XCTAssertTrue(Milestone.browse(memories, search: "missing").isEmpty)
    XCTAssertTrue(Milestone.browse([]).isEmpty)
    XCTAssertEqual(Milestone.browse(memories).last?.datePrecision, "month")
  }

  func testAgeUsesBirthdayAnniversariesAndUpcomingCheckpointIncludesNineMonthsAtEight() {
    let before = MilestoneGuide.ageContext(birth: "2026-03-14", today: "2026-11-13")
    XCTAssertEqual(before?.completedMonths, 7)
    let eight = MilestoneGuide.ageContext(birth: "2026-03-14", today: "2026-11-14")
    XCTAssertEqual(eight?.completedMonths, 8)
    XCTAssertEqual(eight?.currentCheckpoint, 6)
    XCTAssertEqual(eight?.nextCheckpoint, 9)
    let nine = MilestoneGuide.ageContext(birth: "2026-03-14", today: "2026-12-14")
    XCTAssertEqual(nine?.currentCheckpoint, 9)
    XCTAssertEqual(nine?.nextCheckpoint, 12)
  }

  func testMonthEndLeapDayAndCoverageEndDoNotInventAnotherCheckpoint() {
    XCTAssertEqual(
      MilestoneGuide.ageContext(birth: "2026-01-31", today: "2026-02-28")?.completedMonths, 1)
    XCTAssertEqual(
      MilestoneGuide.ageContext(birth: "2024-02-29", today: "2025-02-28")?.completedMonths, 12)
    let older = MilestoneGuide.ageContext(birth: "2020-01-01", today: "2026-11-14")
    XCTAssertEqual(older?.currentCheckpoint, 60)
    XCTAssertNil(older?.nextCheckpoint)
    XCTAssertEqual(
      MilestoneGuide.ageContext(birth: "2026-11-14", today: "2026-11-14")?.nextCheckpoint, 1)
  }

  func testMissingInvalidOrFutureBirthDatesHaveNoGuessedAge() {
    for birth in [nil, "", "2026-02-30", "2026-11-15"] as [String?] {
      XCTAssertNil(MilestoneGuide.ageContext(birth: birth, today: "2026-11-14"))
    }
    XCTAssertNil(MilestoneGuide.ageContext(birth: "2026-01-01", today: "bad"))
  }

  func testGuideHasDirectOfficialSourcesAndDistinguishesSurveillanceFromByAge() throws {
    XCTAssertEqual(Set(MilestoneGuide.entries.map(\.id)).count, MilestoneGuide.entries.count)
    for entry in MilestoneGuide.entries {
      XCTAssertFalse(entry.title.isEmpty)
      XCTAssertLessThanOrEqual(entry.title.count, 120)
      XCTAssertFalse(entry.sources.isEmpty)
      for source in entry.sources {
        XCTAssertEqual(source.url.scheme, "https")
        XCTAssertTrue(
          ["www.cdc.gov", "www.aap.org", "www.rourkebabyrecord.ca", "caringforkids.cps.ca"]
            .contains(source.url.host))
        XCTAssertNotNil(CalendarDate.parse(source.retrievedOn))
      }
    }
    for checkpoint in [2, 4, 6, 9, 12, 15, 18, 24, 30, 36, 48, 60] {
      XCTAssertGreaterThanOrEqual(
        MilestoneGuide.entries.filter { $0.checkpointMonths == checkpoint }.count, 6)
    }
    let early = try XCTUnwrap(MilestoneGuide.entries.first { $0.id == "rbr-1m-comfort" })
    XCTAssertEqual(early.semantics, .visitSurveillance)
    let sitting = try XCTUnwrap(MilestoneGuide.entries.first { $0.id == "cdc-9m-sit-unsupported" })
    XCTAssertEqual(sitting.checkpointMonths, 9)
    XCTAssertEqual(sitting.semantics, .byAge)
    XCTAssertEqual(
      sitting.sources.first?.url.absoluteString,
      "https://www.cdc.gov/act-early/milestones/9-months.html")
  }

  func testObservationBuildsManualMilestoneWithStableIdentityAndPhoneDate() throws {
    let entry = try XCTUnwrap(MilestoneGuide.entries.first { $0.id == "cdc-9m-sit-unsupported" })
    let child = UUID()
    let now = ISO8601DateFormatter().date(from: "2026-11-15T01:30:00Z")!
    let zone = TimeZone(identifier: "America/Vancouver")!
    let command = try XCTUnwrap(
      entry.command(childID: child, observedOn: nil, birth: "2026-03-14", now: now, timeZone: zone))
    XCTAssertEqual(command.action, "milestone")
    XCTAssertEqual(command.mode, "action")
    XCTAssertEqual(command.childID, child)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: APIJSON.encoder().encode(command.payload))
        as? [String: Any])
    XCTAssertEqual(object["guide_id"] as? String, "cdc-9m-sit-unsupported")
    XCTAssertEqual(object["occurred_on"] as? String, "2026-11-14")
    XCTAssertEqual(object["date_precision"] as? String, "day")
    XCTAssertEqual(object["is_first"] as? Bool, false)
    XCTAssertNil(
      entry.command(childID: child, observedOn: "2026-11-15", birth: nil, now: now, timeZone: zone))
    XCTAssertNil(
      entry.command(
        childID: child, observedOn: "2026-03-13", birth: "2026-03-14", now: now, timeZone: zone))
    XCTAssertEqual(
      entry.command(
        childID: child, observedOn: "2026-10-01", birth: "2026-03-14", now: now, timeZone: zone)?
        .payload?.occurredOn, "2026-10-01")
  }

  func testOnlyPersistedGuideIdentityForSameChildChecksAnItemNeverImportedTitle() throws {
    let child = UUID()
    let entry = try XCTUnwrap(MilestoneGuide.entries.first { $0.id == "cdc-9m-sit-unsupported" })
    func milestone(guideID: String?, childID: UUID, title: String) throws -> Milestone {
      var object: [String: Any] = [
        "id": UUID().uuidString, "child_id": childID.uuidString, "title": title,
        "occurred_on": "2026-11-14", "date_precision": "day", "is_first": false,
        "recorded_by": UUID().uuidString, "input_source": "manual",
        "created_at": "2026-11-14T12:00:00Z", "revision": 1,
      ]
      if let guideID { object["guide_id"] = guideID }
      return try APIJSON.decoder().decode(
        Milestone.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let imported = try milestone(guideID: nil, childID: child, title: entry.title)
    let otherBaby = try milestone(guideID: entry.id, childID: UUID(), title: entry.title)
    XCTAssertNil(entry.recordedMilestone(in: [imported, otherBaby], childID: child))
    let saved = try milestone(guideID: entry.id, childID: child, title: "Parent edited this title")
    XCTAssertEqual(entry.recordedMilestone(in: [imported, saved], childID: child)?.id, saved.id)
  }

  func testUncheckTargetsOnlyMatchingGuideObservationAndItsCurrentRevision() throws {
    let entry = try XCTUnwrap(MilestoneGuide.entries.first)
    let child = UUID()
    var object: [String: Any] = [
      "id": UUID().uuidString, "child_id": child.uuidString, "title": entry.title,
      "occurred_on": "2026-11-14", "date_precision": "day", "is_first": false,
      "recorded_by": UUID().uuidString, "input_source": "manual",
      "created_at": "2026-11-14T12:00:00Z", "revision": 3,
      "guide_id": entry.id,
    ]
    func decode() throws -> Milestone {
      try APIJSON.decoder().decode(Milestone.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let saved = try decode()
    let command = try XCTUnwrap(entry.removalCommand(for: saved, childID: child))
    XCTAssertEqual(command.action, "propose_edit")
    XCTAssertEqual(command.payload?.targetType, "milestone")
    XCTAssertEqual(command.payload?.targetID, saved.id)
    XCTAssertEqual(command.payload?.expectedRevision, 3)
    XCTAssertEqual(command.payload?.void, true)
    XCTAssertNil(entry.removalCommand(for: saved, childID: UUID()))
    object.removeValue(forKey: "guide_id")
    XCTAssertNil(entry.removalCommand(for: try decode(), childID: child))
    object["guide_id"] = "another-guide-item"
    XCTAssertNil(entry.removalCommand(for: try decode(), childID: child))
  }

  func testConfirmedUncheckClearsOnlyRemovedGuideAndAllowsAnewObservation() throws {
    let entry = try XCTUnwrap(MilestoneGuide.entries.first)
    let command = try XCTUnwrap(entry.command(childID: UUID(), birth: nil))
    var state = MilestoneGuideRecordingState()
    XCTAssertTrue(state.begin(command, guideID: entry.id))
    let response = try APIJSON.decoder().decode(CareResponse.self, from: JSONSerialization.data(withJSONObject: [
      "status": "recorded", "child_id": command.childID!.uuidString,
      "event_id": UUID().uuidString, "message": "Recorded",
    ]))
    state.finish(guideID: entry.id, response: response)
    state.removeConfirmedObservation(entry.id)
    XCTAssertFalse(state.isRecorded(entry.id))
    let replacement = try XCTUnwrap(entry.command(childID: command.childID!, birth: nil))
    XCTAssertNotEqual(replacement.requestID, command.requestID)
    XCTAssertTrue(state.begin(replacement, guideID: entry.id))
    state.finish(guideID: entry.id, response: nil)
    state.removeConfirmedObservation("another-guide-item")
    XCTAssertEqual(state.retry(entry.id)?.requestID, replacement.requestID)
  }

  func testCheckoffStateRejectsRapidTapsAndNeverChecksAnUncertainAttempt() throws {
    let entry = try XCTUnwrap(MilestoneGuide.entries.first)
    let child = UUID()
    let command = try XCTUnwrap(entry.command(childID: child, birth: nil))
    var state = MilestoneGuideRecordingState()
    XCTAssertTrue(state.begin(command, guideID: entry.id))
    XCTAssertFalse(state.begin(command, guideID: entry.id))
    XCTAssertTrue(state.isSaving(entry.id))
    state.finish(guideID: entry.id, response: nil)
    XCTAssertFalse(state.isSaving(entry.id))
    XCTAssertFalse(state.isRecorded(entry.id))
    XCTAssertTrue(state.hasAttempt(entry.id))
    XCTAssertFalse(state.begin(command, guideID: entry.id))
    XCTAssertEqual(state.retry(entry.id)?.requestID, command.requestID)
    XCTAssertNil(state.retry(entry.id))
  }

  func testCheckoffRequiresPersistedResponseForTheCommandChildAndAllowsRejectedRetry() throws {
    let entry = try XCTUnwrap(MilestoneGuide.entries.first)
    let child = UUID()
    let command = try XCTUnwrap(entry.command(childID: child, birth: nil))
    var state = MilestoneGuideRecordingState()
    func response(status: String, childID: UUID, eventID: UUID?) throws -> CareResponse {
      var row: [String: Any] = [
        "status": status, "child_id": childID.uuidString, "message": "Synthetic response",
      ]
      if let eventID { row["event_id"] = eventID.uuidString }
      return try APIJSON.decoder().decode(
        CareResponse.self, from: JSONSerialization.data(withJSONObject: row))
    }
    XCTAssertTrue(state.begin(command, guideID: entry.id))
    state.finish(
      guideID: entry.id,
      response: try response(status: "recorded", childID: UUID(), eventID: UUID()))
    XCTAssertFalse(state.isRecorded(entry.id))
    // An unexpected response leaves the attempt uncertain instead of inviting another write.
    XCTAssertTrue(state.hasAttempt(entry.id))
    state.finish(
      guideID: entry.id, response: try response(status: "recorded", childID: child, eventID: UUID())
    )
    XCTAssertTrue(state.isRecorded(entry.id))
    state.reconcile(recordedGuideIDs: [entry.id])
    XCTAssertTrue(state.isRecorded(entry.id))
    state.reconcile(recordedGuideIDs: [])
    XCTAssertFalse(state.isRecorded(entry.id))
    XCTAssertTrue(state.begin(command, guideID: entry.id))
    var rejected = MilestoneGuideRecordingState()
    XCTAssertTrue(rejected.begin(command, guideID: entry.id))
    rejected.finish(
      guideID: entry.id, response: try response(status: "rejected", childID: child, eventID: nil))
    XCTAssertFalse(rejected.hasAttempt(entry.id))
    XCTAssertTrue(rejected.begin(command, guideID: entry.id))
    rejected.finish(
      guideID: entry.id, response: try response(status: "needs_clarification", childID: child, eventID: nil))
    XCTAssertFalse(rejected.hasAttempt(entry.id))
    XCTAssertTrue(rejected.begin(command, guideID: entry.id))
  }
}
