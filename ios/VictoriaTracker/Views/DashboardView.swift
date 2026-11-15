import AppIntents
import SwiftUI

struct DashboardView: View {
  @Bindable var model: AppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var recording = false
  @State private var showingSiri = false
  @State private var invite: String?
  @State private var dismissEntry: PendingRecord?
  @State private var showingCalendar = false
  @State private var calendarDate = Date()
  @State private var showingDayInfo = false
  @State private var editingEvent: BabyEvent?
  @State private var editingSleep: SleepSession?
  @State private var editingMilestone: Milestone?
  var body: some View {
    Group {
      if model.child == nil { allBabies } else { individualDay }
    }
  }
  private var individualDay: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text(model.child?.name ?? "Your baby").font(.largeTitle.bold())
          dayNavigation
        }.padding(.vertical, 8)
        dailyMetrics(summary: model.summary, sessions: model.sleep)
        Button {
          recording = true
        } label: {
          recordingLabel("Record an event", systemImage: "plus.circle.fill")
        }
        .accessibilityIdentifier("recordEvent")

        Button {
          showingSiri = true
        } label: {
          recordingLabel("Record with Siri", systemImage: "waveform")
        }
        if let child = model.child {
          SleepSummaryView(model: model, child: child, sessions: model.sleep, day: model.day)
        }
        if let weight = model.weights.last(where: { $0.occurredAt < model.day.interval.end }) {
          NavigationLink {
            GrowthView(model: model)
          } label: {
            Text(
              "Latest weight: \((weight.weightKG ?? 0).formatted()) kg · \(CalendarDate.localDate(weight.measurementDate ?? CalendarDate.string(weight.occurredAt))?.formatted(date:.abbreviated,time:.omitted) ?? "")"
            )
            .font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
      if model.error != nil || model.notice != nil { Section { StatusMessages(model: model) } }
      CarePendingSection(model: model)
      if !model.pending.isEmpty {
        Section("Needs confirmation") {
          Text(
            "These entries may already be saved. Retry here to check safely with the same recording ID. Please don’t record them again."
          ).font(.footnote).foregroundStyle(.secondary)
          ForEach(model.pending) { entry in
            VStack(alignment: .leading, spacing: 6) {
              Text(
                entry.command.text
                  ?? "Manual \(entry.command.event?.eventType.title.lowercased() ?? "event")")
              Text(entry.command.referenceAt, style: .time).font(.caption).foregroundStyle(
                .secondary)
              Button("Retry / check recording") { Task { await model.retry(entry) } }.disabled(
                model.busy)
              Button("Dismiss pending entry", role: .destructive) { dismissEntry = entry }.font(
                .caption
              ).disabled(model.busy)
            }
          }
        }
      }
      Section {
        if model.dayLoading {
          ProgressView("Loading records…").frame(maxWidth: .infinity)
        } else if !model.hasLoadedDay {
          ContentUnavailableView(
            "Couldn’t load this day", systemImage: "wifi.exclamationmark",
            description: Text("Pull to refresh and try again."))
        } else if activities.isEmpty {
          ContentUnavailableView(
            "No records for this day", systemImage: "calendar",
            description: Text("Choose another date or return to today."))
        } else {
          ForEach(activities) { item in
            switch item {
            case .event(let event):
              Button {
                editingEvent = event
              } label: {
                HStack(alignment: .top, spacing: 12) {
                  Image(systemName: event.eventType.symbol).foregroundStyle(.pink).frame(width: 28)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(event.detail).font(.headline)
                    Text(
                      "\(event.recordedBy==model.userID ? "You":"Other parent") · \(event.inputSource.capitalized)"
                    ).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 6)
                  // Weight observations are dated measurements. A date-only
                  // entry's UTC day anchor must not appear as a measured clock time.
                  if event.eventType == .weight,
                    let date = CalendarDate.localDate(event.measurementDate ?? "")
                  {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                      .font(.subheadline).foregroundStyle(.secondary)
                  } else {
                    Text(event.occurredAt, format: timeStyle).font(.subheadline.monospacedDigit())
                      .foregroundStyle(.secondary)
                  }
                }.foregroundStyle(Color.primary).padding(.vertical, 5)
              }.buttonStyle(.plain).accessibilityHint("Review or correct this record")
            case .sleep(let sleep):
              Button {
                editingSleep = sleep
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Label(
                    sleep.endedAt == nil
                      ? "Sleep ongoing" : "Sleep · \(sleep.duration().sleepDuration)",
                    systemImage: "moon.zzz.fill"
                  ).font(.headline)
                  Text(
                    sleepTimeRange(sleep)
                  ).font(.caption).foregroundStyle(.secondary)
                  Text(
                    sleep.recordedBy == model.userID
                      ? "Started by you" : "Started by the other parent"
                  ).font(.caption).foregroundStyle(.secondary)
                }.foregroundStyle(Color.primary).padding(.vertical, 5)
              }.buttonStyle(.plain)
            }
          }
        }
      } header: {
        Text(model.day.isToday() ? "Today’s timeline" : "Timeline")
      } footer: {
        Button {
          showingDayInfo = true
        } label: {
          TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
              Text("Phone local time · \(updateStatus(now: context.date))").lineLimit(1)
              Image(systemName: "info.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(minHeight: 44)
          }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows timezone, syncing, and diaper count details")
        .accessibilityIdentifier("dayInformation")
      }
      let moments = model.milestones.filter {
        $0.datePrecision == "day"
          && $0.occurredOn == CalendarDate.string(model.day.reference, timeZone: model.day.timeZone)
      }
      if !moments.isEmpty {
        Section("Milestones on this day") {
          ForEach(moments) { m in
            Button {
              editingMilestone = m
            } label: {
              Label(m.title, systemImage: "sparkles").foregroundStyle(Color.primary)
            }.buttonStyle(.plain)
          }
        }
      }

    }
    .listStyle(.insetGrouped)
    .refreshable { await model.refresh() }
    .sheet(isPresented: $recording) {
      if let child = model.child { RecordView(model: model, child: child) }
    }
    .sheet(item: $editingEvent) { e in
      if let child = model.child { EditCareView(model: model, child: child, event: e) }
    }
    .sheet(item: $editingSleep) { s in
      if let child = model.child { EditCareView(model: model, child: child, sleep: s) }
    }
    .sheet(item: $editingMilestone) { m in
      if let child = model.child { EditCareView(model: model, child: child, milestone: m) }
    }
    .sheet(isPresented: $showingSiri) { SiriHelpView() }
    .sheet(isPresented: $showingDayInfo) {
      NavigationStack {
        Form {
          Section("Local time") {
            Text(model.day.timeZone.identifier.replacingOccurrences(of: "_", with: " "))
            Text(model.day.timeZoneLabel).foregroundStyle(.secondary)
            Text(
              "Times and daily totals use this phone’s current timezone. Parents in different timezones may see different daily totals."
            )
          }
          Section("Diaper counts") {
            Text("A change that is both wet and dirty counts once in each total.")
          }
          Section("Sleep totals") {
            Text(
              "Sleep shows the duration recorded within the selected local day, including any ongoing session up to now. A session spanning midnight contributes only its time within each day; it counts as a session on each day it overlaps."
            )
          }
          Section("Keeping up to date") {
            Text(
              "Records refresh every 10 seconds while the app is open. Pull down to refresh any time."
            )
            if let synced = model.lastSynced {
              LabeledContent("Last updated") {
                Text(synced, format: .dateTime.month(.abbreviated).day().hour().minute())
              }
            } else {
              Text("This day hasn’t been updated yet.").foregroundStyle(.secondary)
            }
          }
        }
        .navigationTitle("About this day").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { showingDayInfo = false } }
      }
      .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showingCalendar) {
      NavigationStack {
        DatePicker(
          "Choose a day", selection: $calendarDate, in: ...Date(), displayedComponents: .date
        )
        .datePickerStyle(.graphical).padding()
        .environment(\.calendar, localCalendar)
        .navigationTitle("Choose a day").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { showingCalendar = false }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              showingCalendar = false
              Task { await model.selectDay(calendarDate) }
            }
          }
        }
      }
      .presentationDetents([.medium, .large])
    }
    .confirmationDialog(
      "Dismiss this pending entry?",
      isPresented: Binding(get: { dismissEntry != nil }, set: { if !$0 { dismissEntry = nil } }),
      titleVisibility: .visible
    ) {
      Button("Dismiss pending entry", role: .destructive) {
        guard let entry = dismissEntry else { return }
        Task { await model.run { try await Backend.shared.dismissPending(entry) } }
        dismissEntry = nil
      }
    } message: {
      Text(
        "The event may already be saved. Check your timeline first. This removes only the retry from this phone; it does not delete a database event. Recording again could create a duplicate."
      )
    }
  }
  private var activities: [DayActivity] {
    (model.summary.events.map { DayActivity.event($0) }
      + model.sleep.filter { $0.overlap(with: model.day) > 0 }.map { DayActivity.sleep($0) }).sorted
    { $0.time > $1.time }
  }
  private var allBabies: some View {
    List {
      Section {
        Text("All babies").font(.largeTitle.bold())
        dayNavigation
      }
      if model.dayLoading { ProgressView("Loading records…") }
      if let error = model.error { Text(error).foregroundStyle(.red) }
      ForEach(model.children) { baby in
        Section {
          Button {
            Task { await model.selectChild(baby.id) }
          } label: {
            HStack {
              Text(baby.name).font(.title2.bold())
              Spacer()
              Image(systemName: "chevron.right")
            }.foregroundStyle(.primary)
          }
          let summary = DaySummary(
            events: model.eventsByChild[baby.id] ?? [], now: model.day.reference,
            timeZone: model.day.timeZone)
          dailyMetrics(summary: summary, sessions: model.sleepByChild[baby.id] ?? [])
          SleepSummaryView(
            model: model, child: baby, sessions: model.sleepByChild[baby.id] ?? [], day: model.day)
        }
      }
      if model.children.isEmpty {
        Text("Add a baby in Family to start recording.").foregroundStyle(.secondary)
      }
      CarePendingSection(model: model)
      if !model.pending.isEmpty {
        Section("Earlier pending recordings") {
          ForEach(model.pending) { entry in
            Button("Retry / check earlier recording") { Task { await model.retry(entry) } }
              .disabled(model.busy)
          }
        }
      }
      Section { StatusMessages(model: model) }
    }.listStyle(.insetGrouped).refreshable { await model.refresh() }
      .sheet(isPresented: $showingCalendar) {
        NavigationStack {
          DatePicker(
            "Choose a day", selection: $calendarDate, in: ...Date(), displayedComponents: .date
          ).datePickerStyle(.graphical).padding().toolbar {
            Button("Done") {
              showingCalendar = false
              Task { await model.selectDay(calendarDate) }
            }
          }
        }
      }
  }
  private func updateStatus(now: Date) -> String {
    if model.dayLoading { return "Updating…" }
    guard let synced = model.lastSynced else { return "Not updated" }
    let age = max(0, now.timeIntervalSince(synced))
    if age < 60 { return "Updated just now" }
    if age < 3600 { return "Updated \(Int(age / 60)) min ago" }
    if age < 86400 { return "Updated \(Int(age / 3600)) hr ago" }
    return "Updated \(Int(age / 86400)) d ago"
  }
  private var localCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .autoupdatingCurrent
    return calendar
  }
  private var dayCaption: String {
    model.day.reference.formatted(dayStyle)
  }
  private var dayNavigation: some View {
    HStack(spacing: 4) {
      Button {
        Task { await model.moveDay(by: -1) }
      } label: {
        Image(systemName: "chevron.left").frame(width: 44, height: 44)
      }
      .accessibilityLabel("Previous day").accessibilityIdentifier("previousDay")
      Button {
        calendarDate = model.day.reference
        showingCalendar = true
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "calendar")
          Text(dayCaption).lineLimit(1).minimumScaleFactor(0.9)
          Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
      }
      .accessibilityLabel(
        "Choose date, \(model.day.relativeLabel().map { "\($0), " } ?? "")\(dayCaption)"
      )
      .accessibilityIdentifier("chooseDay")
      .accessibilityHint("Opens the calendar")
      .frame(maxWidth: .infinity)
      Button {
        Task { await model.selectDay(nil) }
      } label: {
        Text("Today").font(.callout.weight(.medium)).frame(width: 52, height: 44)
      }
      .disabled(model.day.isToday())
      .accessibilityIdentifier("returnToToday")
      Button {
        Task { await model.moveDay(by: 1) }
      } label: {
        Image(systemName: "chevron.right").frame(width: 44, height: 44)
      }
      .disabled(model.day.isToday())
      .accessibilityLabel("Next day").accessibilityIdentifier("nextDay")
    }
    .font(.subheadline).foregroundStyle(.secondary).buttonStyle(.borderless)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  private func recordingLabel(_ title: String, systemImage: String) -> some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: systemImage).frame(width: 24)
    }
    .font(.body.weight(.medium))
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    .padding(.vertical, 4)
  }
  private var timeStyle: Date.FormatStyle {
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.timeZone = model.day.timeZone
    return style
  }
  private var dayStyle: Date.FormatStyle {
    var style = Date.FormatStyle().month(.abbreviated).day()
    if localCalendar.component(.year, from: model.day.reference)
      != localCalendar.component(.year, from: Date())
    {
      style = style.year()
    }
    style.timeZone = model.day.timeZone
    return style
  }
  private func dailyMetrics(summary: DaySummary, sessions: [SleepSession]) -> some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let sleep = SleepDaySummary(sessions: sessions, day: model.day, asOf: context.date)
      let milk =
        model.hasLoadedDay
        ? summary.milkML.formatted(.number.precision(.fractionLength(0...2))) : "—"
      let duration = model.hasLoadedDay ? sleep.total.sleepDuration : "—"
      let count =
        model.hasLoadedDay
        ? "\(sleep.sessionCount) \(sleep.sessionCount == 1 ? "session" : "sessions")" : "recorded"
      let wet = model.hasLoadedDay ? String(summary.wetCount) : "—"
      let dirty = model.hasLoadedDay ? String(summary.dirtyCount) : "—"
      let columns = dynamicTypeSize >= .accessibility3 ? 1 : 2
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .leading),
          count: columns), alignment: .leading, spacing: 16
      ) {
        metric("Milk", value: milk, unit: "mL", symbol: "waterbottle.fill")
        metric("Sleep", value: duration, unit: count, symbol: "moon.zzz.fill")
        metric("Wet", value: wet, unit: "diapers", symbol: "drop.fill")
        metric("Dirty", value: dirty, unit: "diapers", symbol: "sparkles")
      }.padding(.vertical, 8)

    }
  }
  private func sleepTimeRange(_ sleep: SleepSession) -> String {
    func label(_ date: Date) -> String {
      let clock = date.formatted(timeStyle)
      if date < model.day.interval.start { return "Previous day, " + clock }
      if date >= model.day.interval.end { return "Next day, " + clock }
      return clock
    }
    return label(sleep.startedAt) + " → " + (sleep.endedAt.map(label) ?? "ongoing")
  }
  private func metric(_ title: String, value: String, unit: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        .minimumScaleFactor(0.85)
      Text(value).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
      Text(unit).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).accessibilityElement(
      children: .combine)
  }
}

struct SiriHelpView: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Section("Talk to your tracker") {
          Text("1. Say “Hey Siri, Victoria Tracker.”")
          Text(
            "2. When Siri asks “What’s up?”, describe what happened and include your baby’s name.")
          Text(
            "3. Listen for the answer or saving confirmation. Review any change before confirming.")
        }
        Section {
          DisclosureGroup("Example things to say") {
            Text("Victoria drank 180 mL.")
            Text("Oliver had a wet and dirty diaper.")
            Text("Victoria fell asleep five minutes ago.")
            Text("Victoria woke up.")
            Text("Victoria weighed 7.365 kg on August 21.")
            Text("Victoria first waved hello on November 1.")
            Text("Victoria drank 120 mL and had a wet diaper.")
            Text("How much milk has Victoria had today?")
            Text("Change Victoria’s last feeding from 30 to 80 mL.")
            Text("Remove Victoria’s last wet diaper.")
          }
        }
        Section("English or Cantonese") {
          Text("Victoria 飲咗一百二十毫升奶。")
          Text("Victoria 今日飲咗幾多奶？")
          Text(
            "Siri recognition depends on its language setting and your device. You can also type a description in the app."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Not sure it saved?") {
          Text(
            "Check the app’s timeline first. Use “Retry / check recording” when shown to check or finish the original recording. Repeating the Siri command could save it twice."
          )
        }
        Section {
          DisclosureGroup("If Siri only opens the app") {
            Text(
              "Try “Hey Siri, Talk to Victoria Tracker.” Then describe what happened when Siri asks."
            )
          }
        }
      }
      .navigationTitle("Record with Siri").navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Done") { dismiss() } }
    }
  }
}
