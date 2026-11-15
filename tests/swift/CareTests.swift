import XCTest

#if canImport(VictoriaTrackerCore)
  @testable import VictoriaTrackerCore
#else
  @testable import VictoriaTracker
#endif

final class CareTests: XCTestCase {
  func testFeedingCorrectionUsesBottleBasisAndClearsInputWhenModeChanges() throws {
    var draft = FeedingCorrectionDraft(currentML: 160, basisML: 180)
    XCTAssertEqual(draft.resultML, 160)
    draft.select(.leftover)
    XCTAssertEqual(draft.input, "")
    XCTAssertNil(draft.resultML)
    draft.input = "30"
    XCTAssertEqual(draft.resultML, 150)
    XCTAssertEqual(draft.amountML, 30)
    draft.select(.total)
    XCTAssertNil(draft.resultML)
    draft.input = "80"
    XCTAssertEqual(draft.resultML, 80)
  }
  func testInvalidLeftoversCannotBecomeZeroOrAnExcessiveCorrection() {
    var draft = FeedingCorrectionDraft(currentML: 160, basisML: 180)
    draft.select(.leftover)
    for input in ["", " ", "milk", "-20", "180", "181", "NaN", "10.001", "1e2"] {
      draft.input = input
      XCTAssertNil(draft.resultML, input)
      XCTAssertNil(draft.amountML, input)
    }
    draft.input = "0"
    XCTAssertEqual(draft.resultML, 180)
    draft.select(.total)
    draft.input = "0"
    XCTAssertEqual(draft.resultML, 0)
  }
  func testConfirmationRetainsCantoneseAndReadAnswerIsSeparateFromSaving() throws {
    let wire =
      #"{"status":"answered","message":"今日飲咗180毫升。","language":"yue","child_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}"#
    let response = try APIJSON.decoder().decode(CareResponse.self, from: Data(wire.utf8))
    XCTAssertTrue(response.isAnswered)
    XCTAssertFalse(response.isPersisted)
    let command = CareCommand(
      proposalID: UUID(), childID: UUID(), confirmed: true, language: response.language)
    let object =
      try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(command)) as! [String: Any]
    XCTAssertEqual(object["language"] as? String, "yue")
    XCTAssertEqual(
      command,
      try APIJSON.decoder().decode(CareCommand.self, from: APIJSON.encoder().encode(command)))
  }
  func testAtomicBatchReceiptConfirmsPersistenceWithoutASingleEventID() throws {
    let wire =
      #"{"status":"recorded","message":"Recorded 2 events.","event_ids":["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"],"child_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}"#
    let response = try APIJSON.decoder().decode(CareResponse.self, from: Data(wire.utf8))
    XCTAssertTrue(response.isPersisted)
  }
  func testReadAnswerAndIncompleteReceiptsNeverConfirmPersistence() throws {
    for wire in [
      #"{"status":"answered","message":"180 mL today.","child_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}"#,
      #"{"status":"recorded","message":"Saved","event_ids":[],"child_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}"#,
      #"{"status":"recorded","message":"Saved","event_ids":["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]}"#,
      #"{"status":"recorded","message":"Saved","event_ids":["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],"child_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}"#,
    ] {
      let response = try APIJSON.decoder().decode(CareResponse.self, from: Data(wire.utf8))
      XCTAssertFalse(response.isPersisted)
    }
  }
  func testOldPendingConfirmationKeepsAbsentLanguageAndStableWireBody() throws {
    let old =
      #"{"request_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","reference_at":"2026-11-14T10:00:00.000Z","time_zone":"America/Vancouver","utc_offset_seconds":-28800,"zone_offsets":[{"from":"2026-11-01T09:00:00.000Z","seconds":-28800}],"source":"manual","mode":"confirm","child_id":"BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB","proposal_id":"CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC","confirmed":true}"#
    let command = try APIJSON.decoder().decode(CareCommand.self, from: Data(old.utf8))
    let before = try JSONSerialization.jsonObject(with: Data(old.utf8)) as! NSDictionary
    let after =
      try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(command)) as! NSDictionary
    XCTAssertEqual(before, after)
    XCTAssertNil(after["language"])
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func sleep(_ start: String, _ end: String?) throws -> SleepSession {
    let row: [String: Any] = [
      "id": UUID().uuidString, "child_id": UUID().uuidString, "started_at": start,
      "ended_at": end.map { $0 as Any } ?? NSNull(), "recorded_by": UUID().uuidString,
      "input_source": "siri", "created_at": start, "revision": 1,
    ]
    return try APIJSON.decoder().decode(
      SleepSession.self, from: JSONSerialization.data(withJSONObject: row))
  }
  func testOvernightSleepIsSplitAtLocalMidnightWithoutDoubleCounting() throws {
    let s = try sleep("2025-01-02T06:00:00Z", "2025-01-02T15:00:00Z")
    let zone = TimeZone(identifier: "America/Vancouver")!
    let first = LocalDay(reference: date("2025-01-01T20:00:00Z"), timeZone: zone)
    let second = LocalDay(reference: date("2025-01-02T20:00:00Z"), timeZone: zone)
    let now = date("2025-01-03T00:00:00Z")
    XCTAssertEqual(s.overlap(with: first, asOf: now), 2 * 3600)
    XCTAssertEqual(s.overlap(with: second, asOf: now), 7 * 3600)
    XCTAssertEqual(s.duration(asOf: now), 9 * 3600)
  }
  func testSleepElapsedTimeUsesInstantsAcrossDSTNotClockLabels() throws {
    let s = try sleep("2025-03-09T09:30:00Z", "2025-03-09T10:30:00Z")
    let day = LocalDay(
      reference: date("2025-03-09T15:00:00Z"), timeZone: TimeZone(identifier: "America/Vancouver")!)
    XCTAssertEqual(s.overlap(with: day, asOf: date("2025-03-10T00:00:00Z")), 3600)
    XCTAssertEqual(day.interval.duration, 23 * 3600)
  }
  func testOngoingSleepStopsAtNowAndDoesNotFillOtherDays() throws {
    let s = try sleep("2025-01-02T10:00:00Z", nil)
    let now = date("2025-01-02T11:00:00Z")
    XCTAssertEqual(s.duration(asOf: now), 3600)
    XCTAssertEqual(
      s.overlap(
        with: LocalDay(
          reference: date("2025-01-01T12:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!),
        asOf: now), 0)
    XCTAssertEqual(s.duration(asOf: date("2025-01-02T09:00:00Z")), 0)
  }
  func testDailySleepSummaryCombinesSessionsAndClipsOvernightAndOngoingTime() throws {
    let day = LocalDay(
      reference: date("2025-01-02T12:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
    let sessions = try [
      sleep("2025-01-01T23:00:00Z", "2025-01-02T02:00:00Z"),
      sleep("2025-01-02T10:00:00Z", nil),
      sleep("2025-01-03T01:00:00Z", "2025-01-03T02:00:00Z"),
    ]
    let summary = SleepDaySummary(sessions: sessions, day: day, asOf: date("2025-01-02T11:00:00Z"))
    XCTAssertEqual(summary.total, 3 * 3600)
    XCTAssertEqual(summary.sessionCount, 2)
    XCTAssertTrue(summary.includesOngoing)
    let empty = SleepDaySummary(sessions: [], day: day)
    XCTAssertEqual(empty.total, 0)
    XCTAssertEqual(empty.sessionCount, 0)
    XCTAssertFalse(empty.includesOngoing)
  }
  func testManualWeightDateAnchorRetainsSelectedLocalDayAcrossDSTAndTravel() throws {
    for id in ["America/Vancouver", "Asia/Hong_Kong", "Pacific/Kiritimati"] {
      let zone = try XCTUnwrap(TimeZone(identifier: id))
      for value in ["2025-03-09", "2025-11-02", "2026-08-21"] {
        let selected = try XCTUnwrap(CalendarDate.localDate(value, timeZone: zone))
        let anchor = CalendarDate.dayAnchor(selected, timeZone: zone)
        let payload = CarePayload.event(
          EventPayload(eventType: .weight, occurredAt: anchor, weightKG: 7.365), timeZone: zone)
        XCTAssertEqual(payload.measurementDate, value)
        XCTAssertEqual(CalendarDate.string(anchor, timeZone: zone), value)
        XCTAssertEqual(LocalDay(reference: selected, timeZone: zone).interval.start, anchor)
      }
    }
  }
  func testPendingCareCommandsKeepNamedTargetsAndWireStableDatesAfterRoundTrip() throws {
    var p = CarePayload()
    p.occurredAt = Date()
    p.endedAt = Date().addingTimeInterval(20)
    let command = CareCommand(action: "sleep_interval", childID: UUID(), payload: p)
    let restored = try APIJSON.decoder().decode(
      CareCommand.self, from: APIJSON.encoder().encode(command))
    XCTAssertEqual(command, restored)
    XCTAssertEqual(command.childID, restored.childID)
    XCTAssertEqual(command.timeZone, restored.timeZone)
    let confirmation = CareCommand(proposalID: UUID(), childID: UUID(), confirmed: true)
    XCTAssertEqual(
      confirmation,
      try APIJSON.decoder().decode(CareCommand.self, from: APIJSON.encoder().encode(confirmation)))
  }
  func testManualEventPayloadIncludesExplicitUnrelatedNullsForStrictValidation() throws {
    let p = CarePayload.event(EventPayload(eventType: .feeding, occurredAt: Date(), volumeML: 180))
    let o = try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(p)) as! [String: Any]
    XCTAssertTrue(o["diaper_kind"] is NSNull)
    XCTAssertTrue(o["weight_kg"] is NSNull)
    XCTAssertEqual(o["volume_ml"] as? Double, 180)
  }
  func testConfirmationProposalAndIncompleteSuccessAreNeverReportedAsSaved() throws {
    for value in [
      "{\"status\":\"needs_confirmation\",\"message\":\"Change?\",\"proposal_id\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\",\"child_id\":\"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\"}",
      "{\"status\":\"recorded\",\"message\":\"Recorded\"}",
    ] {
      let r = try APIJSON.decoder().decode(CareResponse.self, from: Data(value.utf8))
      XCTAssertFalse(r.isPersisted)
      if r.status == "needs_confirmation" { XCTAssertTrue(r.needsConfirmation) }
    }
  }
  func testDateOnlyValuesRetainCalendarDayAcrossTimezonesAndLeapBirthdays() throws {
    for id in ["America/Vancouver", "Asia/Hong_Kong", "Pacific/Kiritimati"] {
      let z = TimeZone(identifier: id)!
      let d = try XCTUnwrap(CalendarDate.localDate("2024-02-29", timeZone: z))
      XCTAssertEqual(CalendarDate.string(d, timeZone: z), "2024-02-29")
    }
    XCTAssertEqual(CalendarDate.days(from: "2024-02-29", to: "2024-03-01"), 1)
    XCTAssertNil(CalendarDate.parse("2025-02-29"))
    XCTAssertNil(CalendarDate.days(from: "2025-03-01", to: "2025-02-28"))
  }
  func testCareCommandCarriesThePhonesCurrentOffsetAndTransitionHistory() throws {
    let instant = date("2026-11-13T07:30:00Z")
    let zone = TimeZone(identifier: "America/Vancouver")!
    let command = CareCommand(text: "Victoria fell asleep", referenceAt: instant, timeZone: zone)
    XCTAssertEqual(command.utcOffsetSeconds, zone.secondsFromGMT(for: instant))
    XCTAssertEqual(command.zoneOffsets.last?.seconds, command.utcOffsetSeconds)
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(command.zoneOffsets.first?.from), instant.addingTimeInterval(-365 * 86400))
    let wire = try APIJSON.decoder().decode(
      CareCommand.self, from: APIJSON.encoder().encode(command))
    XCTAssertEqual(wire, command)
    let local = instant.addingTimeInterval(Double(command.utcOffsetSeconds))
    XCTAssertEqual(
      CalendarDate.string(local, timeZone: TimeZone(secondsFromGMT: 0)!),
      CalendarDate.string(instant, timeZone: zone))
  }
  private func reference(_ sex: String) throws -> GrowthReference {
    #if canImport(VictoriaTrackerCore)
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      return try GrowthReference(
        csv: String(
          contentsOf: root.appendingPathComponent(
            "ios/VictoriaTracker/Resources/Growth/who-weight-\(sex).csv"), encoding: .utf8))
    #else
      return try GrowthReference.load(sex: sex)
    #endif
  }
  func testOfficialWHOReferenceValuesAndInversePercentiles() throws {
    let girls = try reference("female")
    let boys = try reference("male")
    XCTAssertEqual(girls.rows.count, 1857)
    XCTAssertEqual(boys.rows.count, 1857)
    let girl = try XCTUnwrap(girls.parameters(day: 0))
    let boy = try XCTUnwrap(boys.parameters(day: 0))
    XCTAssertEqual(girl.m, 3.2322, accuracy: 0.00001)
    XCTAssertEqual(boy.m, 3.3464, accuracy: 0.00001)
    XCTAssertEqual(try XCTUnwrap(girl.weight(z: 1)), 3.711, accuracy: 0.0006)
    XCTAssertEqual(try XCTUnwrap(boy.weight(z: 2)), 4.419, accuracy: 0.0006)
    XCTAssertEqual(try XCTUnwrap(girl.percentile(weight: girl.m)), 50, accuracy: 0.00001)
    let w = try XCTUnwrap(girl.weight(z: 1.036433389))
    XCTAssertEqual(try XCTUnwrap(girl.percentile(weight: w)), 85, accuracy: 0.0001)
    XCTAssertNil(girls.parameters(day: -1))
    XCTAssertNil(girls.parameters(day: 1857))
    XCTAssertNil(girl.percentile(weight: 0))
    XCTAssertNil(girl.percentile(weight: 100))
  }
  func testMonthOnlyMilestonesShowHonestAgeRangeWithoutInventingAnExactDay() {
    XCTAssertEqual(
      CalendarDate.ageLabel(
        birth: "2026-03-15", on: "2026-07-01", precision: "month", through: "2026-11-14"),
      "About 3–4 months old")
    XCTAssertEqual(
      CalendarDate.ageLabel(
        birth: "2026-03-01", on: "2026-07-01", precision: "month", through: "2026-11-14"),
      "About 4 months old")
    XCTAssertEqual(
      CalendarDate.ageLabel(
        birth: "2026-03-15", on: "2026-11-01", precision: "day", through: "2026-11-14"),
      "7 months old")
    XCTAssertEqual(
      CalendarDate.ageLabel(
        birth: "2024-02-29", on: "2025-03-01", precision: "month", through: "2026-11-14"),
      "About 12–13 months old")
  }
  func testMonthOnlyMilestoneAgeClipsBirthAndCurrentMonthAndRejectsInvalidDates() {
    XCTAssertEqual(
      CalendarDate.ageLabel(
        birth: "2026-03-15", on: "2026-03-01", precision: "month", through: "2026-11-14"),
      "About 0–16 days old")
    XCTAssertEqual(
      CalendarDate.ageLabel(
        birth: "2026-03-15", on: "2026-07-01", precision: "month", through: "2026-07-10"),
      "About 3 months old")
    XCTAssertNil(
      CalendarDate.ageLabel(
        birth: "2026-03-15", on: "2026-02-01", precision: "month", through: "2026-11-14"))
    XCTAssertNil(
      CalendarDate.ageLabel(
        birth: "2026-03-15", on: "2026-12-01", precision: "month", through: "2026-11-14"))
    XCTAssertNil(
      CalendarDate.ageLabel(
        birth: "bad", on: "2026-07-01", precision: "month", through: "2026-11-14"))
    XCTAssertNil(
      CalendarDate.ageLabel(
        birth: "2026-03-15", on: "2026-07-01", precision: "year", through: "2026-11-14"))
  }
  func testMilestoneMonthPrecisionAndMultipleEntriesArePreserved() throws {
    let values = (0..<2).map { index in
      [
        "id": UUID().uuidString, "child_id": UUID().uuidString, "title": "Memory \(index)",
        "occurred_on": "2025-03-01", "date_precision": "month", "is_first": false,
        "recorded_by": UUID().uuidString, "input_source": "manual",
        "created_at": "2025-03-02T00:00:00Z", "revision": 1,
      ] as [String: Any]
    }
    let items = try APIJSON.decoder().decode(
      [Milestone].self, from: JSONSerialization.data(withJSONObject: values))
    XCTAssertEqual(items.count, 2)
    XCTAssertTrue(items.allSatisfy { $0.datePrecision == "month" })
    XCTAssertNotEqual(items[0].id, items[1].id)
  }
}
