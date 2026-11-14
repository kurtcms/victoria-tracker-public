#if !canImport(VictoriaTrackerCore)
  import XCTest
  import SwiftUI
  import UIKit
  @testable import VictoriaTracker

  private actor PresentationSource: DashboardDataSource {
    private let parent = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    private let family = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
    private var multiple = false
    func setMultiple() { multiple = true }
    private func baby(_ name: String, _ id: String) -> Child {
      var c = Child(
        id: UUID(uuidString: id)!, familyID: family, name: name, timeZone: "America/Vancouver")
      c.dateOfBirth = CalendarDate.string(Date().addingTimeInterval(-240 * 86400))
      c.growthReferenceSex = "female"
      c.growthReferenceConfirmed = true
      c.wasPremature = false
      c.profileVersion = 1
      return c
    }
    func children() -> [Child] {
      let a = baby("Victoria", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
      return multiple ? [a, baby("Oliver", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")] : [a]
    }
    func savedSession() -> AuthSession? {
      AuthSession(
        accessToken: "sample", refreshToken: "sample", expiresAt: .distantFuture, userID: parent)
    }
    func pending() -> [PendingRecord] { [] }
    private func event(_ child: Child, _ type: String, _ at: Date, _ value: Double) throws
      -> BabyEvent
    {
      var o: [String: Any] = [
        "id": UUID().uuidString, "child_id": child.id.uuidString, "event_type": type,
        "occurred_at": APIJSON.string(at), "created_at": APIJSON.string(at),
        "recorded_by": parent.uuidString, "input_source": "siri", "request_id": UUID().uuidString,
        "revision": 1,
      ]
      if type == "feeding" {
        o["volume_ml"] = value
      } else if type == "weight" {
        o["weight_kg"] = value
        o["measurement_date"] = CalendarDate.string(at)
      } else {
        o["diaper_kind"] = "mixed"
      }
      return try APIJSON.decoder().decode(
        BabyEvent.self, from: JSONSerialization.data(withJSONObject: o))
    }
    func events(child: Child, day: LocalDay) throws -> [BabyEvent] {
      [
        try event(child, "feeding", day.interval.start.addingTimeInterval(12 * 3600), 180),
        try event(child, "diaper", day.interval.start.addingTimeInterval(11 * 3600), 0),
      ]
    }
    func sleep(child: Child, day: LocalDay) throws -> [SleepSession] {
      let row: [String: Any] = [
        "id": UUID().uuidString, "child_id": child.id.uuidString,
        "started_at": APIJSON.string(Date().addingTimeInterval(-43 * 60)),
        "recorded_by": parent.uuidString, "input_source": "manual",
        "created_at": APIJSON.string(Date().addingTimeInterval(-43 * 60)), "revision": 1,
      ]
      var completed = row
      completed["id"] = UUID().uuidString
      completed["started_at"] = APIJSON.string(Date().addingTimeInterval(-180 * 60))
      completed["ended_at"] = APIJSON.string(Date().addingTimeInterval(-90 * 60))
      return try [row, completed].map {
        try APIJSON.decoder().decode(
          SleepSession.self, from: JSONSerialization.data(withJSONObject: $0))
      }

    }
    func weights(child: Child) throws -> [BabyEvent] {
      try [(230, 3.3), (150, 5.2), (60, 6.7), (3, 7.5)].map { days, w in
        try event(child, "weight", Date().addingTimeInterval(-Double(days) * 86400), w)
      }
    }
    func milestones(child: Child) throws -> [Milestone] {
      let exact = CalendarDate.string(Date().addingTimeInterval(-13 * 86400))
      let month =
        String(CalendarDate.string(Date().addingTimeInterval(-125 * 86400)).prefix(7)) + "-01"
      return try [("Waved hello", exact, "day"), ("Clapped hands", month, "month")].map {
        title, date, precision in
        let row: [String: Any] = [
          "id": UUID().uuidString, "child_id": child.id.uuidString, "title": title,
          "occurred_on": date, "date_precision": precision, "is_first": true,
          "recorded_by": parent.uuidString, "input_source": "siri",
          "created_at": APIJSON.string(Date()), "revision": 1,
        ]
        return try APIJSON.decoder().decode(
          Milestone.self, from: JSONSerialization.data(withJSONObject: row))
      }
    }
  }
  final class PresentationTests: XCTestCase {
    @MainActor func testExpandedScreensRenderWithSampleData() async throws {
      let source = PresentationSource()
      let model = AppModel(source: source)
      await model.refresh()
      try await capture("expanded-day-single", RootView(model: model), navigation: false)
      try await capture("expanded-growth", GrowthView(model: model))
      try await capture("expanded-milestones", MilestonesView(model: model))
      try await capture(
        "milestone-age-dark", MilestonesView(model: model).preferredColorScheme(.dark))
      if let child = model.child {
        try await capture(
          "profile-controls", ChildProfileView(model: model, existing: child), navigation: false)
        try await capture(
          "manual-weight", RecordView(model: model, child: child, initialKind: "weight"),
          navigation: false)
      }
      try await capture("siri-help", SiriHelpView(), navigation: false)
      try await capture(
        "siri-help-dark", SiriHelpView().preferredColorScheme(.dark), navigation: false)
      await source.setMultiple()
      await model.refresh()
      try await capture("expanded-all-babies", TrackerTabs(model: model))
    }
    @MainActor private func capture<V: View>(_ name: String, _ view: V, navigation: Bool = true)
      async throws
    {
      let scene = try XCTUnwrap(
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
      let host = UIHostingController(
        rootView: Group {
          if navigation { NavigationStack { view } } else { view }
        }.tint(.pink).overlay(alignment: .bottomTrailing) {
          Text("Sample data").font(.caption2).padding(4).background(Color.white.opacity(0.9))
            .padding(.bottom, 90).padding(.trailing, 8)
        })
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      try await Task.sleep(for: .milliseconds(700))
      host.view.setNeedsLayout()
      host.view.layoutIfNeeded()
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertNotNil(image.pngData())
    }
  }
#endif
