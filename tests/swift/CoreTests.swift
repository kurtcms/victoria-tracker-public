import XCTest

#if canImport(VictoriaTrackerCore)
  @testable import VictoriaTrackerCore
#else
  @testable import VictoriaTracker
#endif

final class CoreTests: XCTestCase {
  let child = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  let parent = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  let vancouver = TimeZone(identifier: "America/Vancouver")!
  func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  func event(
    _ type: String, at: String, volume: Double? = nil, diaper: String? = nil, weight: Double? = nil
  ) throws -> BabyEvent {
    let object: [String: Any] = [
      "id": UUID().uuidString, "child_id": child.uuidString, "recorded_by": parent.uuidString,
      "request_id": UUID().uuidString, "event_type": type, "occurred_at": at, "created_at": at,
      "input_source": "siri",
      "volume_ml": volume.map { $0 as Any } ?? NSNull(),
      "diaper_kind": diaper.map { $0 as Any } ?? NSNull(),
      "weight_kg": weight.map { $0 as Any } ?? NSNull(),
    ]
    return try APIJSON.decoder().decode(
      BabyEvent.self, from: JSONSerialization.data(withJSONObject: object))
  }
  func testMixedCountsInBothTotalsAndWeightDoesNotChangeMilk() throws {
    let items = try [
      event("feeding", at: "2026-11-12T18:00:00Z", volume: 160),
      event("feeding", at: "2026-11-12T19:00:00Z", volume: 120),
      event("diaper", at: "2026-11-12T20:00:00Z", diaper: "mixed"),
      event("diaper", at: "2026-11-12T21:00:00Z", diaper: "wet"),
      event("weight", at: "2026-11-12T22:00:00Z", weight: 7.5),
    ]
    let summary = DaySummary(events: items, now: date("2026-11-12T23:00:00Z"), timeZone: vancouver)
    XCTAssertEqual(summary.milkML, 280)
    XCTAssertEqual(summary.wetCount, 2)
    XCTAssertEqual(summary.dirtyCount, 1)
    XCTAssertEqual(summary.events.first?.eventType, .weight)
  }
  func testLocalMidnightUsesHalfOpenInterval() throws {
    let interval = DaySummary.interval(now: date("2026-11-12T23:00:00Z"), timeZone: vancouver)
    let items = try [
      event("feeding", at: APIJSON.string(interval.start.addingTimeInterval(-1)), volume: 100),
      event("feeding", at: APIJSON.string(interval.start), volume: 120),
      event("feeding", at: APIJSON.string(interval.end.addingTimeInterval(-1)), volume: 160),
      event("feeding", at: APIJSON.string(interval.end), volume: 200),
    ]
    let summary = DaySummary(events: items, now: date("2026-11-12T23:00:00Z"), timeZone: vancouver)
    XCTAssertEqual(summary.milkML, 280)
    XCTAssertEqual(summary.events.count, 2)
  }
  func testSpringDSTDayIs23Hours() {
    let interval = DaySummary.interval(now: date("2025-03-09T18:00:00Z"), timeZone: vancouver)
    XCTAssertEqual(interval.duration, 23 * 3600)
  }
  func testAutumnDSTDayIs25Hours() {
    let interval = DaySummary.interval(now: date("2025-11-02T18:00:00Z"), timeZone: vancouver)
    XCTAssertEqual(interval.duration, 25 * 3600)
  }
  func testManualPayloadExplicitlyEncodesNulls() throws {
    let payload = EventPayload(
      eventType: .feeding, occurredAt: date("2026-11-12T18:00:00Z"), volumeML: 160)
    let command = RecordCommand(childID: child, event: payload)
    let raw = try XCTUnwrap(
      JSONSerialization.jsonObject(with: APIJSON.encoder().encode(command)) as? [String: Any])
    let event = try XCTUnwrap(raw["event"] as? [String: Any])
    XCTAssertTrue(event["diaper_kind"] is NSNull)
    XCTAssertTrue(event["weight_kg"] is NSNull)
    XCTAssertNil(raw["text"])
    XCTAssertEqual(raw["mode"] as? String, "manual")
  }
  func testRetryRoundTripPreservesUUIDAndReferenceTime() throws {
    let c = RecordCommand(
      childID: child, text: "Victoria drank 100 mL half an hour ago.", source: "siri",
      referenceAt: date("2026-11-12T18:00:00Z"))
    let restored = try APIJSON.decoder().decode(
      RecordCommand.self, from: APIJSON.encoder().encode(c))
    XCTAssertEqual(c, restored)
    XCTAssertEqual(APIJSON.string(c.referenceAt), APIJSON.string(restored.referenceAt))
    XCTAssertNotEqual(c.id, RecordCommand(childID: child, text: c.text!, source: "siri").id)
  }
  func testInvalidManualPayloadsCannotSave() {
    let now = Date()
    XCTAssertFalse(EventPayload(eventType: .feeding, occurredAt: now, volumeML: -1).isValid)
    XCTAssertFalse(
      EventPayload(eventType: .feeding, occurredAt: now, volumeML: 120, weightKG: 7.5).isValid)
    XCTAssertFalse(EventPayload(eventType: .weight, occurredAt: now, weightKG: .infinity).isValid)
    XCTAssertFalse(EventPayload(eventType: .feeding, occurredAt: now, volumeML: 10.001).isValid)
    XCTAssertFalse(EventPayload(eventType: .diaper, occurredAt: now).isValid)
    XCTAssertTrue(EventPayload(eventType: .weight, occurredAt: now, weightKG: 7.555).isValid)
  }
  func testPendingCommandMatchesAfterSubmillisecondDateRoundTrip() throws {
    let c = RecordCommand(
      childID: child, event: EventPayload(eventType: .weight, occurredAt: Date(), weightKG: 7.5))
    let restored = try APIJSON.decoder().decode(
      RecordCommand.self, from: APIJSON.encoder().encode(c))
    XCTAssertEqual(c, restored)
  }
  func testServerTimestampsWithAndWithoutFractionalSeconds() throws {
    let a = try event("feeding", at: "2026-11-12T18:00:00.123456+00:00", volume: 160)
    let b = try event("feeding", at: "2026-11-12T18:00:00Z", volume: 160)
    XCTAssertEqual(a.occurredAt.timeIntervalSince(b.occurredAt), 0.123456, accuracy: 0.001)
  }
  func testSuccessRequiresReturnedEvent() throws {
    let raw = Data(
      #"{"status":"recorded","message":"Recorded 160 millilitres for Victoria."}"#.utf8)
    let response = try APIJSON.decoder().decode(RecordResponse.self, from: raw)
    XCTAssertFalse(response.isPersisted)
  }
  func testFutureEventRejectionDecodesAsDialogWithoutClaimingPersistence() throws {
    let raw = Data(
      #"{"status":"rejected","code":"future_event","message":"I can only record events that have already happened. Nothing was recorded."}"#
        .utf8)
    let response = try APIJSON.decoder().decode(RecordResponse.self, from: raw)
    XCTAssertEqual(response.status, "rejected")
    XCTAssertEqual(
      response.message, "I can only record events that have already happened. Nothing was recorded."
    )
    XCTAssertFalse(response.isPersisted)
    XCTAssertNil(response.event)
  }
  func testUnclearAndUnavailableInterpretationResponsesKeepGuidanceWithoutClaimingPersistence() throws {
    let messages = [
      ("needs_clarification", "clarification", "What exactly happened? Please repeat one complete event with the child, amount and unit or diaper type, and time if needed."),
      ("rejected", "interpretation_unavailable", "I couldn’t interpret that event right now. Nothing was recorded. Please try again, or use Record an event in Victoria Tracker."),
    ]
    for (status, code, message) in messages {
      let data = try JSONSerialization.data(withJSONObject: [
        "status": status, "code": code, "message": message,
      ])
      let response = try APIJSON.decoder().decode(RecordResponse.self, from: data)
      XCTAssertEqual(response.status, status)
      XCTAssertEqual(response.message, message)
      XCTAssertFalse(response.isPersisted)
      XCTAssertNil(response.event)
    }
  }
  func testTravelChangesLocalDayTotalsWithoutChangingEventInstants() throws {
    let now = date("2025-11-13T01:00:00Z")
    let home = LocalDay(reference: now, timeZone: vancouver)
    let away = LocalDay(reference: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    XCTAssertEqual(home.interval.start, date("2025-11-12T08:00:00Z"))
    XCTAssertEqual(away.interval.start, date("2025-11-12T15:00:00Z"))
    let events = try [
      event("feeding", at: "2025-11-12T10:00:00Z", volume: 100),
      event("feeding", at: "2025-11-12T22:00:00Z", volume: 160),
    ]
    XCTAssertEqual(DaySummary(events: events, now: now, timeZone: home.timeZone).milkML, 260)
    XCTAssertEqual(DaySummary(events: events, now: now, timeZone: away.timeZone).milkML, 160)
    XCTAssertEqual(events[0].occurredAt, date("2025-11-12T10:00:00Z"))
  }
  func testCommandRetryPreservesCapturedPhoneZoneAndUTCReference() throws {
    let c = RecordCommand(
      childID: child, text: "Victoria drank 120 mL at 2 pm.", source: "siri",
      referenceAt: date("2026-11-12T20:00:00Z"), timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    let encoded = try APIJSON.encoder().encode(c)
    let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(raw["time_zone"] as? String, "Asia/Tokyo")
    let retry = try APIJSON.decoder().decode(RecordCommand.self, from: encoded)
    XCTAssertEqual(retry, c)
    XCTAssertEqual(retry.timeZoneID, "Asia/Tokyo")
    let changed = RecordCommand(
      childID: child, text: c.text!, source: c.source,
      referenceAt: c.referenceAt, requestID: c.id, timeZone: vancouver)
    XCTAssertNotEqual(changed, retry)
    XCTAssertEqual(changed.referenceAt, retry.referenceAt)
  }
  func testLegacyPendingEntryDoesNotAcquireCurrentTimezoneOnRetry() throws {
    let c = RecordCommand(childID: child, text: "Victoria drank 120 mL.", source: "siri")
    var raw = try XCTUnwrap(
      JSONSerialization.jsonObject(with: APIJSON.encoder().encode(c)) as? [String: Any])
    raw.removeValue(forKey: "time_zone")
    let legacy = try APIJSON.decoder().decode(
      RecordCommand.self, from: JSONSerialization.data(withJSONObject: raw))
    XCTAssertNil(legacy.timeZoneID)
    let restored = try XCTUnwrap(
      JSONSerialization.jsonObject(with: APIJSON.encoder().encode(legacy)) as? [String: Any])
    XCTAssertNil(restored["time_zone"])
    XCTAssertEqual(legacy.id, c.id)
  }
  func testLocalTimezoneLabelIncludesFractionalUTCOffset() {
    let day = LocalDay(
      reference: date("2025-11-13T01:00:00Z"), timeZone: TimeZone(identifier: "Asia/Kathmandu")!)
    XCTAssertTrue(day.timeZoneLabel.contains("UTC+05:45"))
  }
  func testDayNavigationCrossesYearsAndClampsFutureDaysToToday() {
    let now = date("2025-01-01T20:00:00Z")
    let yesterday = DaySelection.today.moving(by: -1, now: now, timeZone: vancouver)
    XCTAssertEqual(yesterday, .date(year: 2024, month: 12, day: 31))
    XCTAssertEqual(yesterday.moving(by: 1, now: now, timeZone: vancouver), .today)
    XCTAssertEqual(DaySelection.today.moving(by: 1, now: now, timeZone: vancouver), .today)
    XCTAssertEqual(
      DaySelection(date: now.addingTimeInterval(86400), now: now, timeZone: vancouver), .today)
  }
  func testCalendarNavigationHandlesShortAndLongDSTDays() {
    for (value, year, month, day, hours) in [
      ("2025-03-10T18:00:00Z", 2025, 3, 9, 23),
      ("2025-11-03T18:00:00Z", 2025, 11, 2, 25),
    ] {
      let now = date(value)
      let selected = DaySelection.today.moving(by: -1, now: now, timeZone: vancouver)
      XCTAssertEqual(selected, .date(year: year, month: month, day: day))
      XCTAssertEqual(
        selected.localDay(now: now, timeZone: vancouver).interval.duration, Double(hours * 3600))
      XCTAssertEqual(selected.moving(by: 1, now: now, timeZone: vancouver), .today)
    }
  }
  func testTodayFollowsMidnightWhileHistorySelectionStaysFixed() {
    let before = date("2025-11-13T07:59:00Z")
    let after = date("2025-11-13T08:01:00Z")
    XCTAssertNotEqual(
      DaySelection.today.localDay(now: before, timeZone: vancouver).interval,
      DaySelection.today.localDay(now: after, timeZone: vancouver).interval)
    let history = DaySelection.date(year: 2025, month: 11, day: 11)
    XCTAssertEqual(
      history.localDay(now: before, timeZone: vancouver).interval,
      history.localDay(now: after, timeZone: vancouver).interval)
  }
  func testHistoricalCalendarDateSurvivesTravelAndUsesNewPhoneZone() {
    let selected = DaySelection.date(year: 2025, month: 11, day: 12)
    let now = date("2025-11-15T12:00:00Z")
    let home = selected.localDay(now: now, timeZone: vancouver)
    let away = selected.localDay(now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    XCTAssertEqual(home.interval.start, date("2025-11-12T08:00:00Z"))
    XCTAssertEqual(away.interval.start, date("2025-11-11T15:00:00Z"))
  }
  func testRelativeDayLabelsFollowSelectedDay() {
    let now = date("2025-11-13T20:00:00Z")
    XCTAssertEqual(LocalDay(reference: now, timeZone: vancouver).relativeLabel(now: now), "Today")
    XCTAssertEqual(
      DaySelection.date(year: 2025, month: 11, day: 12).localDay(now: now, timeZone: vancouver)
        .relativeLabel(now: now), "Yesterday")
    XCTAssertNil(
      DaySelection.date(year: 2025, month: 11, day: 11).localDay(now: now, timeZone: vancouver)
        .relativeLabel(now: now))
  }
}
