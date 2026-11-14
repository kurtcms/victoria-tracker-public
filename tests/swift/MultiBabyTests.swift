#if !canImport(VictoriaTrackerCore)
  import XCTest
  @testable import VictoriaTracker
  private actor MultiBabySource: DashboardDataSource {
    let first = Child(id: UUID(), familyID: UUID(), name: "Victoria", timeZone: "UTC")
    let second = Child(id: UUID(), familyID: UUID(), name: "Oliver", timeZone: "UTC")
    var multiple = true
    func children() -> [Child] { multiple ? [first, second] : [first] }
    func pending() -> [PendingRecord] { [] }
    func savedSession() -> AuthSession? {
      AuthSession(
        accessToken: "test", refreshToken: "test", expiresAt: .distantFuture,
        userID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
    }
    func events(child: Child, day: LocalDay) throws -> [BabyEvent] {
      let o: [String: Any] = [
        "id": UUID().uuidString, "child_id": child.id.uuidString, "event_type": "feeding",
        "volume_ml": child.id == first.id ? 180 : 200,
        "occurred_at": APIJSON.string(day.interval.start.addingTimeInterval(3600)),
        "created_at": APIJSON.string(day.interval.start),
        "recorded_by": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "input_source": "siri",
        "request_id": UUID().uuidString,
      ]
      return [
        try APIJSON.decoder().decode(
          BabyEvent.self, from: JSONSerialization.data(withJSONObject: o))
      ]
    }
    func single() { multiple = false }
  }
  final class MultiBabyTests: XCTestCase {
    @MainActor func testFamilyOverviewDoesNotCombineBabiesAndSelectionSurvivesRefresh() async throws
    {
      let source = MultiBabySource()
      let model = AppModel(source: source)
      await model.refresh()
      XCTAssertEqual(model.children.count, 2)
      XCTAssertNil(model.child)
      XCTAssertTrue(model.events.isEmpty)
      let ids = await source.children().map(\.id)
      XCTAssertEqual(model.eventsByChild[ids[0]]?.first?.volumeML, 180)
      XCTAssertEqual(model.eventsByChild[ids[1]]?.first?.volumeML, 200)
      await model.selectChild(ids[1])
      XCTAssertEqual(model.child?.id, ids[1])
      XCTAssertEqual(model.summary.milkML, 200)
      await model.refresh()
      XCTAssertEqual(model.child?.id, ids[1])
      XCTAssertEqual(model.summary.milkML, 200)
      await model.selectChild(nil)
      XCTAssertNil(model.child)
      XCTAssertTrue(model.events.isEmpty)
    }
    @MainActor func testSingleBabyGoesDirectlyToItsDashboard() async {
      let source = MultiBabySource()
      await source.single()
      let model = AppModel(source: source)
      await model.refresh()
      XCTAssertEqual(model.children.count, 1)
      XCTAssertEqual(model.child?.name, "Victoria")
      XCTAssertEqual(model.summary.milkML, 180)
    }
  }
#endif
