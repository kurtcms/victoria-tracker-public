import AppIntents
import SwiftUI
import UIKit

@main struct VictoriaTrackerApp: App {
  @State private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase
  init() { VictoriaShortcuts.updateAppShortcutParameters() }
  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .environment(\.timeZone, .autoupdatingCurrent)
        .tint(.pink)
        .onOpenURL { url in Task { await model.confirmEmail(url) } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
          Task { await model.refresh() }
        }
        .onReceive(
          NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
        ) { _ in
          Task { await model.refresh() }
        }
        .task(id: scenePhase) {
          guard scenePhase == .active else { return }
          await model.refresh()
          while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard !Task.isCancelled else { return }
            await model.refresh()
          }
        }
    }
  }
}
