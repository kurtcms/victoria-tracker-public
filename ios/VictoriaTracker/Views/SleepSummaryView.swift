import SwiftUI

enum DayActivity: Identifiable {
  case event(BabyEvent)
  case sleep(SleepSession)
  var id: String {
    switch self {
    case .event(let e): "event-\(e.id)"
    case .sleep(let s): "sleep-\(s.id)"
    }
  }
  var time: Date {
    switch self {
    case .event(let e): e.occurredAt
    case .sleep(let s): s.startedAt
    }
  }
}
extension TimeInterval {
  var sleepDuration: String {
    let minutes = max(0, Int(self / 60))
    return minutes >= 60 ? "\(minutes/60)h" + (minutes%60 > 0 ? " \(minutes%60)m" : "") : "\(minutes)m"
  }
}
struct SleepSummaryView: View {
  @Bindable var model: AppModel
  let child: Child
  let sessions: [SleepSession]
  let day: LocalDay
  @State private var editing: SleepSession?
  private var active: SleepSession? { sessions.first { $0.endedAt == nil } }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      HStack(spacing: 12) {
        if model.hasLoadedDay {
          if let active {
            Text(
              "\(context.date.timeIntervalSince(active.startedAt) > 6 * 3600 ? "Sleep status uncertain" : "Recorded asleep") · \(active.duration(asOf: context.date).sleepDuration) elapsed; wake-up unconfirmed"
            )
            .font(.caption).foregroundStyle(.secondary)
          } else {
            Text("No open sleep recorded").font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if let active {
            Button {
              editing = active
            } label: {
              Image(systemName: "square.and.pencil").frame(minWidth: 36, minHeight: 44)
            }.accessibilityLabel("Correct running sleep for \(child.name)")
          }
          Button(active == nil ? "Fell asleep" : "Woke up") {
            Task {
              var p = CarePayload()
              p.occurredAt = Date()
              _ = await model.care(
                CareCommand(
                  action: active == nil ? "sleep_start" : "sleep_end", childID: child.id, payload: p
                ))
            }
          }.font(.subheadline.weight(.medium)).buttonStyle(.bordered).disabled(model.busy)
        } else {
          Text("Sleep status unavailable").font(.caption).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).buttonStyle(.borderless)
    }.sheet(item: $editing) { s in EditCareView(model: model, child: child, sleep: s) }
  }
}
struct CarePendingSection: View {
  @Bindable var model: AppModel
  @State private var proposal: CareResponse?
  @State private var dismissEntry: PendingCareCommand?
  var body: some View {
    if !model.carePending.isEmpty {
      Section("Needs checking") {
        Text(
          "An attempt may already be saved. Retry here with its original ID; don’t record it again."
        ).font(.footnote).foregroundStyle(.secondary)
        ForEach(model.carePending) { entry in
          VStack(alignment: .leading, spacing: 6) {
            Text(
              entry.command.text
                ?? (entry.command.mode == "confirm" ? "Confirm correction" : "Manual care record"))
            Text(entry.command.referenceAt, style: .time).font(.caption).foregroundStyle(.secondary)
            Button("Retry / check recording") {
              Task { if let r = await model.retryCare(entry), r.needsConfirmation { proposal = r } }
            }.disabled(model.busy)
            Button("Dismiss pending attempt", role: .destructive) { dismissEntry = entry }.font(
              .caption
            ).disabled(model.busy)
          }.buttonStyle(.borderless)
        }
      }.sheet(item: $proposal) { p in CareReviewView(model: model, proposal: p) }
        .confirmationDialog(
          "Check the timeline first. Dismissing removes only this phone’s retry, not any saved record.",
          isPresented: Binding(
            get: { dismissEntry != nil }, set: { if !$0 { dismissEntry = nil } }),
          titleVisibility: .visible
        ) {
          Button("Dismiss pending attempt", role: .destructive) {
            guard let entry = dismissEntry else { return }
            Task { await model.run { try await Backend.shared.dismissCare(entry) } }
            dismissEntry = nil
          }
        }
    }
  }
}
