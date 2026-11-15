import SwiftUI

struct RecordView: View {
  @Bindable var model: AppModel
  let child: Child
  var initialKind: String = "feeding"
  @State private var configured = false
  @Environment(\.dismiss) private var dismiss
  @Environment(\.timeZone) private var timeZone
  @State private var mode = 0
  @State private var text = ""
  @State private var kind = "feeding"
  @State private var amount = ""
  @State private var diaper: DiaperKind = .wet
  @State private var date = Date()
  @State private var end = Date()
  @State private var earlier = false
  @State private var title = ""
  @State private var note = ""
  @State private var precision = "day"
  @State private var first = false
  @State private var submitted: CareCommand?
  @State private var proposal: CareResponse?
  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Baby", value: child.name)
          Picker("Recording method", selection: $mode) {
            Text("Describe it").tag(0)
            Text("Manual").tag(1)
          }.pickerStyle(.segmented)
        }
        if mode == 0 {
          Section("Describe care or ask a question") {
            TextField("What would you like to record or ask?", text: $text, axis: .vertical)
              .lineLimit(3...6)
            Text(
              "Describe up to five events for one baby, ask about their day, or request a correction. Include their name, units and any earlier time. English and Cantonese descriptions are supported."
            ).font(.footnote).foregroundStyle(.secondary)
            Text(
              "Descriptions are sent to Supabase and OpenAI for interpretation. Records are shared with your family."
            ).font(.footnote).foregroundStyle(.secondary)
          }
        } else {
          Section("Event details") {
            Picker("Type", selection: $kind) {
              Text("Milk").tag("feeding")
              Text("Diaper").tag("diaper")
              Text("Weight").tag("weight")
              Text("Fell asleep").tag("sleep_start")
              Text("Woke up").tag("sleep_end")
              Text("Past sleep").tag("sleep_interval")
              Text("Milestone").tag("milestone")
            }
            if kind == "feeding" || kind == "weight" {
              TextField(kind == "feeding" ? "Volume (mL)" : "Weight (kg)", text: $amount)
                .keyboardType(.decimalPad)
            }
            if kind == "diaper" {
              Picker("Diaper", selection: $diaper) {
                ForEach(DiaperKind.allCases, id: \.self) { Text($0.title).tag($0) }
              }
            }
            if kind == "milestone" {
              TextField("What happened?", text: $title)
              TextField("Note (optional)", text: $note, axis: .vertical)
              DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
              Picker("Date precision", selection: $precision) {
                Text("Exact day").tag("day")
                Text("Month only").tag("month")
              }
              Toggle("First time", isOn: $first)
            } else if kind == "weight" {
              DatePicker(
                "Measurement date", selection: $date, in: ...Date(), displayedComponents: .date)
            } else if kind == "sleep_interval" {
              DatePicker("Fell asleep", selection: $date, in: ...Date())
              DatePicker("Woke up", selection: $end, in: ...Date())
            } else {
              Toggle("Earlier date or time", isOn: $earlier)
              if earlier {
                DatePicker("When", selection: $date, in: ...Date())
              } else {
                Text("Records the time when you save.").font(.footnote).foregroundStyle(.secondary)
              }
            }
          }
        }
        Section {
          if submitted != nil {
            Text(
              "This attempt is pending. Close this form and use Retry / check recording on the Day screen before recording again."
            ).font(.footnote)
          } else {
            Button(mode == 0 ? "Send description" : "Save event") { Task { await save() } }
              .disabled(model.busy || !valid)
          }
          if model.busy { ProgressView(mode == 0 ? "Sending…" : "Recording…") }
        }
        StatusMessages(model: model)
      }.navigationTitle(mode == 0 ? "Talk about \(child.name)" : "Record for \(child.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Close") { dismiss() }.disabled(model.busy) }
        .onAppear {
          if !configured {
            configured = true
            kind = initialKind
            if initialKind != "feeding" { mode = 1 }
          }
        }
        .sheet(item: $proposal) { p in CareReviewView(model: model, proposal: p) { dismiss() } }
    }.interactiveDismissDisabled(model.busy)
  }
  private var number: Double? {
    let decimal = Locale.current.decimalSeparator ?? "."
    guard !amount.isEmpty, amount.allSatisfy({ $0.isNumber || String($0) == decimal }),
      amount.components(separatedBy: decimal).count <= 2
    else { return nil }
    return Double(amount.replacingOccurrences(of: decimal, with: "."))
  }
  private var valid: Bool {
    if mode == 0 {
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 1000
    }
    if kind == "feeding" {
      return EventPayload(eventType: .feeding, occurredAt: date, volumeML: number).isValid
    }
    if kind == "weight" {
      return EventPayload(eventType: .weight, occurredAt: date, weightKG: number).isValid
    }
    if kind == "sleep_interval" { return end > date }
    if kind == "milestone" {
      return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 120
        && note.count <= 1000
    }
    return true
  }
  private func save() async {
    let command: CareCommand
    if mode == 0 {
      command = CareCommand(text: text, childID: child.id, source: "text", timeZone: timeZone)
    } else {
      var p = CarePayload()
      var action = kind
      if ["feeding", "diaper", "weight"].contains(kind) {
        let event = EventPayload(
          eventType: EventType(rawValue: kind)!,
          occurredAt: kind == "weight"
            ? CalendarDate.dayAnchor(date, timeZone: timeZone) : (earlier ? date : Date()),
          volumeML: kind == "feeding" ? number : nil, diaperKind: kind == "diaper" ? diaper : nil,
          weightKG: kind == "weight" ? number : nil)
        p = .event(event, timeZone: timeZone)
        action = "record"
      } else if kind == "milestone" {
        p.title = title
        p.note = note.isEmpty ? nil : note
        p.datePrecision = precision
        p.isFirst = first
        let day = CalendarDate.string(date, timeZone: timeZone)
        p.occurredOn = precision == "month" ? String(day.prefix(7)) + "-01" : day
      } else {
        p.occurredAt = kind == "sleep_interval" || earlier ? date : Date()
        p.endedAt = kind == "sleep_interval" ? end : nil
      }
      command = CareCommand(action: action, childID: child.id, payload: p, timeZone: timeZone)
    }
    submitted = command
    if let response = await model.care(command) {
      submitted = nil
      if response.needsConfirmation {
        proposal = response
      } else if response.isPersisted {
        dismiss()
      }
    }
  }
}
