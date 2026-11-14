#if !canImport(VictoriaTrackerCore)
  import XCTest
  @testable import VictoriaTracker

  private actor HistorySource: DashboardDataSource {
    private let parent = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let child = Child(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      familyID: UUID(), name: "Victoria", timeZone: "America/Vancouver")
    private let holdFirst: Bool
    private var firstRequest: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests: [DateInterval] = []
    private var shouldFail = false
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func savedSession() -> AuthSession? {
      AuthSession(
        accessToken: "test-access", refreshToken: "test-refresh", expiresAt: .distantFuture,
        userID: parent)
    }
    func children() -> [Child] { [child] }
    func pending() -> [PendingRecord] { [] }
    func events(child: Child, day: LocalDay) async throws -> [BabyEvent] {
      requests.append(day.interval)
      if holdFirst && requests.count == 1 {
        await withCheckedContinuation { continuation in
          firstRequest = continuation
          startedWaiters.forEach { $0.resume() }
          startedWaiters = []
        }
      }
      if shouldFail { throw TrackerError.message("Test day unavailable") }
      let raw: [String: Any] = [
        "id": UUID().uuidString, "child_id": child.id.uuidString, "recorded_by": parent.uuidString,
        "request_id": UUID().uuidString, "event_type": "feeding", "input_source": "manual",
        "occurred_at": APIJSON.string(day.interval.start.addingTimeInterval(3600)),
        "created_at": APIJSON.string(Date()), "volume_ml": 160,
        "diaper_kind": NSNull(), "weight_kg": NSNull(),
      ]
      return [
        try APIJSON.decoder().decode(
          BabyEvent.self, from: JSONSerialization.data(withJSONObject: raw))
      ]
    }
    func waitForFirstRequest() async {
      if !requests.isEmpty { return }
      await withCheckedContinuation { startedWaiters.append($0) }
    }
    func releaseFirstRequest() {
      firstRequest?.resume()
      firstRequest = nil
    }
    func setFailure(_ value: Bool) { shouldFail = value }
    func requestedDays() -> [DateInterval] { requests }
  }

  final class HistoryModelTests: XCTestCase {
    @MainActor func testHistoricalSelectionSurvivesRefreshAndReturnsToToday() async {
      let source = HistorySource()
      let model = AppModel(source: source)
      let target = Date().addingTimeInterval(-3 * 86400)
      await model.selectDay(target)
      let selection = model.selection
      let interval = model.day.interval
      XCTAssertTrue(model.hasLoadedDay)
      XCTAssertEqual(model.summary.milkML, 160)
      await model.refresh()
      XCTAssertEqual(model.selection, selection)
      XCTAssertEqual(model.day.interval, interval)
      let requests = await source.requestedDays()
      XCTAssertEqual(requests, [interval, interval])
      await model.selectDay(nil)
      XCTAssertEqual(model.selection, .today)
      XCTAssertTrue(model.day.isToday())
    }
    @MainActor func testRapidDateChangesDiscardStaleResponseAndLoadLatestSelection() async {
      let source = HistorySource(holdFirst: true)
      let model = AppModel(source: source)
      let initial = Task { await model.refresh() }
      await source.waitForFirstRequest()
      await model.selectDay(Date().addingTimeInterval(-3 * 86400))
      let target = Date().addingTimeInterval(-5 * 86400)
      await model.selectDay(target)
      XCTAssertFalse(model.hasLoadedDay)
      XCTAssertTrue(model.events.isEmpty)
      await source.releaseFirstRequest()
      await initial.value
      let expected = DaySelection(date: target)
      XCTAssertEqual(model.selection, expected)
      XCTAssertEqual(model.day.interval, expected.localDay().interval)
      XCTAssertTrue(model.hasLoadedDay)
      XCTAssertFalse(model.dayLoading)
      let requests = await source.requestedDays()
      XCTAssertEqual(requests.count, 2)
      XCTAssertEqual(requests.last, expected.localDay().interval)
      XCTAssertEqual(model.summary.events.count, 1)
    }
    @MainActor func testFailedHistoryLoadDoesNotPresentPriorRecordsOrFabricatedZeroCounts() async {
      let source = HistorySource()
      let model = AppModel(source: source)
      await model.refresh()
      XCTAssertTrue(model.hasLoadedDay)
      await source.setFailure(true)
      await model.selectDay(Date().addingTimeInterval(-2 * 86400))
      XCTAssertFalse(model.hasLoadedDay)
      XCTAssertTrue(model.events.isEmpty)
      XCTAssertNil(model.lastSynced)
      XCTAssertNotNil(model.error)
      XCTAssertFalse(model.dayLoading)
      await source.setFailure(false)
      await model.refresh()
      XCTAssertTrue(model.hasLoadedDay)
      XCTAssertEqual(model.summary.milkML, 160)
      XCTAssertNil(model.error)
    }
  }
#endif
