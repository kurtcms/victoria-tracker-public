import AppIntents
import Foundation

protocol SiriRecordingBackend: Sendable {
  func performCare(_ command: CareCommand) async throws -> CareResponse
}
extension Backend: SiriRecordingBackend {}

enum SiriRecorder {
  static func record(_ text: String, using backend: any SiriRecordingBackend = Backend.shared)
    async throws -> CareResponse
  {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 1000 else {
      throw TrackerError.message(
        "Describe care or ask a question. Include the baby’s name and any amounts with units.")
    }
    // No selected dashboard child is attached to Siri speech. The authenticated
    // backend resolves an explicit name and must ask when multiple babies exist.
    return try await backend.performCare(CareCommand(text: text))
  }

  static func confirm(
    _ proposal: CareResponse, using backend: any SiriRecordingBackend = Backend.shared
  )
    async throws -> CareResponse
  {
    guard proposal.needsConfirmation, let id = proposal.proposalID, let child = proposal.childID
    else {
      throw TrackerError.message("There is no change to confirm.")
    }
    return try await backend.performCare(
      CareCommand(
        proposalID: id, childID: child, confirmed: true, source: "siri", language: proposal.language
      ))
  }

  static func retiredPreset() throws -> IntentDialog {
    // Keep old intent identifiers safe for cached/personal shortcuts after an upgrade.
    // Fail before any backend request, rather than inventing an event.
    throw TrackerError.message(
      "This fixed shortcut has been replaced. Say ‘Talk to Victoria Tracker’, then describe what happened."
    )
  }
}

struct LogEventIntent: AppIntent {
  static let title: LocalizedStringResource = "Record an event"
  static let description = IntentDescription(
    "Siri asks what’s up. Describe up to five care events for one baby, ask about their day, or correct or remove a record with confirmation. Include the baby’s name and units. You can describe care in English or Cantonese; recognition depends on Siri’s language and device support."
  )
  static let openAppWhenRun = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

  @Parameter(title: "Event", requestValueDialog: "What’s up?")
  var text: String

  static var parameterSummary: some ParameterSummary { Summary("Record \(\.$text)") }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    var response = try await SiriRecorder.record(text)
    if response.status == "needs_clarification" {
      throw $text.needsValueError(IntentDialog(stringLiteral: response.message))
    }
    if response.needsConfirmation {
      let dialog = IntentDialog(stringLiteral: response.message)
      if #available(iOS 18.0, *) {
        try await requestConfirmation(actionName: .continue, dialog: dialog)
      } else {
        try await requestConfirmation(result: .result(dialog: dialog))
      }
      response = try await SiriRecorder.confirm(response)
    }
    guard response.status == "rejected" || response.isPersisted || response.isAnswered else {
      throw TrackerError.message(
        "The database did not confirm saving. Check the pending entry in the app.")
    }
    return .result(dialog: IntentDialog(stringLiteral: response.message))
  }
}

// Compatibility tombstones. Never register, discover, or execute old fixed payloads.
struct Log160MilkIntent: AppIntent {
  static let title: LocalizedStringResource = "Retired milk shortcut"
  static let isDiscoverable = false
  static let openAppWhenRun = false
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: try SiriRecorder.retiredPreset())
  }
}
struct LogWetDiaperIntent: AppIntent {
  static let title: LocalizedStringResource = "Retired wet diaper shortcut"
  static let isDiscoverable = false
  static let openAppWhenRun = false
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: try SiriRecorder.retiredPreset())
  }
}
struct LogDirtyDiaperIntent: AppIntent {
  static let title: LocalizedStringResource = "Retired dirty diaper shortcut"
  static let isDiscoverable = false
  static let openAppWhenRun = false
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: try SiriRecorder.retiredPreset())
  }
}
struct LogMixedDiaperIntent: AppIntent {
  static let title: LocalizedStringResource = "Retired mixed diaper shortcut"
  static let isDiscoverable = false
  static let openAppWhenRun = false
  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: try SiriRecorder.retiredPreset())
  }
}

struct VictoriaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: LogEventIntent(),
      phrases: [
        "Talk to \(.applicationName)",
        "\(.applicationName)",
        "Log with \(.applicationName)",
        "Record with \(.applicationName)",
        "Record an event with \(.applicationName)",
        "Log an event with \(.applicationName)",
      ], shortTitle: "Tell Victoria Tracker", systemImageName: "waveform")
  }
}
