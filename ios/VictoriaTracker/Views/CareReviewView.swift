import SwiftUI

struct CareReviewView: View {
  @Bindable var model: AppModel
  let proposal: CareResponse
  var completed: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("Review the change") {
          Text(proposal.message)
          Text("Nothing changes until you confirm.").font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Button("Confirm change") {
            Task {
              guard let id = proposal.proposalID, let child = proposal.childID else { return }
              if let response = await model.care(
                CareCommand(proposalID: id, childID: child, confirmed: true))
              {
                if response.isPersisted {
                  completed()
                  dismiss()
                } else {
                  dismiss()
                }
              }
            }
          }.disabled(model.busy)
          Button("Cancel", role: .cancel) {
            Task {
              if let id = proposal.proposalID, let child = proposal.childID {
                _ = await model.care(CareCommand(proposalID: id, childID: child, confirmed: false))
              }
              dismiss()
            }
          }.disabled(model.busy)
        }
        StatusMessages(model: model)
      }.navigationTitle("Confirm correction").navigationBarTitleDisplayMode(.inline)
    }.interactiveDismissDisabled(model.busy)
  }
}

struct EditCareView: View {
  @Bindable var model: AppModel
  let child: Child
  var event: BabyEvent? = nil
  var sleep: SleepSession? = nil
  var milestone: Milestone? = nil
  @Environment(\.dismiss) private var dismiss
  @Environment(\.timeZone) private var timeZone
  @State private var amount = ""
  @State private var leftover = false
  @State private var diaper: DiaperKind = .wet
  @State private var start = Date()
  @State private var end = Date()
  @State private var hasEnd = false
  @State private var title = ""
  @State private var note = ""
  @State private var date = Date()
  @State private var precision = "day"
  @State private var proposal: CareResponse?
  @State private var submitting: CareCommand?
  var body: some View {
    NavigationStack {
      Form {
        Section(child.name) {
          if let event {
            if event.eventType == .weight {
              Text(
                "\(event.detail) · \(CalendarDate.localDate(event.measurementDate ?? CalendarDate.string(event.occurredAt), timeZone: timeZone)?.formatted(date: .abbreviated, time: .omitted) ?? "")"
              )
            } else {
              Text(
                "\(event.detail) · \(event.occurredAt.formatted(date: .abbreviated, time: .shortened))"
              )
            }
            if event.eventType == .feeding {
              Picker("Correction", selection: $leftover) {
                Text("Consumed total").tag(false)
                Text("Left in bottle").tag(true)
              }
              TextField(leftover ? "Leftover mL" : "Corrected mL", text: $amount).keyboardType(
                .decimalPad)
              Text("Review the before and after amounts before confirming.").font(.footnote)
                .foregroundStyle(.secondary)
            }
            if event.eventType == .weight {
              TextField("Corrected kg", text: $amount).keyboardType(.decimalPad)
              DatePicker(
                "Measurement date", selection: $start, in: ...Date(), displayedComponents: .date)
            }
            if event.eventType == .diaper {
              Picker("Diaper", selection: $diaper) {
                ForEach(DiaperKind.allCases, id: \.self) { Text($0.title).tag($0) }
              }
              DatePicker("When", selection: $start, in: ...Date())
            }
          }
          if sleep != nil {
            DatePicker("Fell asleep", selection: $start, in: ...Date())
            Toggle("Wake time recorded", isOn: $hasEnd)
            if hasEnd { DatePicker("Woke up", selection: $end, in: ...Date()) }
          }
          if milestone != nil {
            TextField("Milestone", text: $title)
            TextField("Note (optional)", text: $note, axis: .vertical)
            DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
            Picker("Date precision", selection: $precision) {
              Text("Exact day").tag("day")
              Text("Month only").tag("month")
            }
          }
        }
        if submitting == nil {
          if event != nil || sleep != nil || milestone != nil {
            Button("Review correction") { Task { await propose(remove: false) } }.disabled(
              model.busy || !valid)
          }
          Button("Remove mistaken record", role: .destructive) {
            Task { await propose(remove: true) }
          }.disabled(model.busy)
        } else {
          Text(
            "This attempt is unresolved. Check the pending entry on the Day screen before trying another correction."
          )
        }
        StatusMessages(model: model)
      }.navigationTitle("Correct a record").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Close") { dismiss() }.disabled(model.busy) }
        .onAppear {
          if let event {
            amount = String(event.eventType == .weight ? event.weightKG ?? 0 : event.volumeML ?? 0)
            start =
              event.eventType == .weight
              ? (CalendarDate.localDate(
                event.measurementDate ?? CalendarDate.string(event.occurredAt), timeZone: timeZone)
                ?? event.occurredAt) : event.occurredAt
            diaper = event.diaperKind ?? .wet
          }
          if let sleep {
            start = sleep.startedAt
            end = sleep.endedAt ?? Date()
            hasEnd = sleep.endedAt != nil
          }
          if let milestone {
            title = milestone.title
            note = milestone.note ?? ""
            date = CalendarDate.localDate(milestone.occurredOn) ?? Date()
            precision = milestone.datePrecision
          }
        }
        .sheet(item: $proposal) { p in CareReviewView(model: model, proposal: p) { dismiss() } }
    }.interactiveDismissDisabled(model.busy)
  }
  private var valid: Bool {
    if event?.eventType == .feeding {
      return Double(
        amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
      ).map { $0.isFinite && $0 >= 0 && $0 <= 2000 } ?? false
    }
    if event?.eventType == .weight {
      return Double(
        amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
      ).map { $0.isFinite && $0 > 0 && $0 <= 100 } ?? false
    }
    if event?.eventType == .diaper { return true }
    if sleep != nil { return !hasEnd || end > start }
    return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private func propose(remove: Bool) async {
    var p = CarePayload()
    var action = "propose_edit"
    if let event {
      p.targetID = event.id
      if event.eventType == .feeding && !remove {
        action = "propose_feeding"
        p.correctionKind = leftover ? "leftover" : "total"
        p.amountML = Double(
          amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
      } else {
        p.targetType = "event"
        p.expectedRevision = event.revision ?? 1
        p.void = remove
        if !remove {
          p.occurredAt = start
          if event.eventType == .weight {
            p.weightKG = Double(
              amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
            p.measurementDate = CalendarDate.string(start, timeZone: timeZone)
            p.occurredAt =
              p.measurementDate
                == (event.measurementDate
                  ?? CalendarDate.string(event.occurredAt, timeZone: timeZone))
              ? event.occurredAt : CalendarDate.dayAnchor(start, timeZone: timeZone)
          } else {
            p.diaperKind = diaper.rawValue
          }
        }
      }
    } else if let sleep {
      p.targetID = sleep.id
      p.targetType = "sleep"
      p.expectedRevision = sleep.revision
      p.void = remove
      p.occurredAt = start
      p.endedAt = hasEnd ? end : nil
    } else if let milestone {
      p.targetID = milestone.id
      p.targetType = "milestone"
      p.expectedRevision = milestone.revision
      p.void = remove
      p.title = title
      p.note = note
      p.datePrecision = precision
      let value = CalendarDate.string(date)
      p.occurredOn = precision == "month" ? String(value.prefix(7)) + "-01" : value
    }
    let command = CareCommand(action: action, childID: child.id, payload: p, timeZone: timeZone)
    submitting = command
    if let r = await model.care(command) {
      submitting = nil
      if r.needsConfirmation { proposal = r }
    }
  }
}
