import SwiftUI

struct MilestoneGuideView: View {
  @Bindable var model: AppModel
  let child: Child
  @Environment(\.timeZone) private var timeZone
  @State private var showAllAges = false
  @State private var earlierDate: MilestoneGuideEntry?
  @State private var recordingState = MilestoneGuideRecordingState()
  @State private var removalAttempts: [String: CareCommand] = [:]
  @State private var removalReview: GuideRemovalReview?

  private struct GuideRemovalReview: Identifiable {
    let guideID: String
    let proposal: CareResponse
    var id: String { proposal.id }
  }

  private var age: MilestoneGuideAgeContext? {
    MilestoneGuide.ageContext(
      birth: child.dateOfBirth, today: CalendarDate.string(Date(), timeZone: timeZone))
  }
  private var highlightedCheckpoints: [Int] {
    guard let age else { return MilestoneGuide.checkpoints }
    if showAllAges { return MilestoneGuide.checkpoints }
    return [age.currentCheckpoint, age.nextCheckpoint].compactMap { $0 }
  }

  var body: some View {
    List {
      Section {
        Text("Small discoveries, at their own pace").font(.headline)
        Text(
          "A selection of skills to notice, from the first month through age five. Record what you observe; there is no daily goal or score."
        )
        .font(.subheadline)
        if let age {
          Text("\(child.name) · \(age.completedMonths) completed months")
            .font(.subheadline).foregroundStyle(.secondary)
          if age.completedMonths >= 60 {
            Text("This guide ends at age five. Earlier checkpoints remain available for memories.")
              .font(.footnote).foregroundStyle(.secondary)
          }
        } else {
          Text(
            "Add a valid birthday in the baby profile to see age-based suggestions. You can browse all ages meanwhile."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if child.wasPremature == true {
          Text(
            "These ages use the birthday, without a prematurity adjustment. Ask your clinician about corrected age; the profile does not hold the dates needed to calculate it."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if age != nil { Toggle("Browse all ages", isOn: $showAllAges) }
      }

      ForEach(highlightedCheckpoints, id: \.self) { checkpoint in
        checkpointSection(checkpoint)
      }
      if !showAllAges, let current = age?.currentCheckpoint {
        let earlier = MilestoneGuide.checkpoints.filter { $0 < current }
        if !earlier.isEmpty {
          Section {
            DisclosureGroup("Earlier checkpoints") {
              ForEach(earlier, id: \.self) { checkpoint in
                Text(MilestoneGuide.ageTitle(checkpoint)).font(.headline).padding(.top, 8)
                checkpointDescription(checkpoint)
                ForEach(entries(at: checkpoint)) { entry in guideRow(entry) }
              }
            }
          }
        }
      }
      Section("About this guide") {
        Text(
          "Children develop differently. This selection is not a screening test or a diagnosis. Discuss concerns, missing skills at a checkpoint, or lost skills with your child's clinician."
        )
        .font(.footnote)
        Text(
          "Rourke visit checks and CDC by-age checkpoints use different timing. Sources are linked in each checkpoint description. Sources do not endorse this app."
        )
        .font(.footnote).foregroundStyle(.secondary)
        Link(MilestoneGuide.aap.name, destination: MilestoneGuide.aap.url)
        Link(MilestoneGuide.cpsRourke.name, destination: MilestoneGuide.cpsRourke.url)
        Text(
          "Feeding readiness is separate from a developmental checklist. CPS describes readiness cues around six months; use their advice and your clinician's guidance when introducing foods."
        )
        .font(.footnote)
        Link(MilestoneGuide.cps.name, destination: MilestoneGuide.cps.url)
      }
      Section { StatusMessages(model: model) }
    }
    .refreshable { await model.refresh() }
    .onChange(of: model.lastSynced) {
      guard let saved = model.milestonesByChild[child.id] else { return }
      recordingState.reconcile(recordedGuideIDs: Set(saved.compactMap(\.guideID)))
    }
    .sheet(item: $removalReview) { review in
      CareReviewView(model: model, proposal: review.proposal, isDeletion: true) {
        recordingState.removeConfirmedObservation(review.guideID)
      }
    }
    .sheet(item: $earlierDate) { entry in
      MilestoneObservedDateView(
        entry: entry, birth: child.dateOfBirth, busy: model.busy,
        unavailable: recordingState.hasAttempt(entry.id) || isPending(entry),
        message: model.error ?? model.notice
      ) { date in
        await record(entry, on: CalendarDate.string(date, timeZone: timeZone))
      }
    }
  }

  private func entries(at checkpoint: Int) -> [MilestoneGuideEntry] {
    MilestoneGuide.entries.filter { $0.checkpointMonths == checkpoint }
  }
  private func checkpointSection(_ checkpoint: Int) -> some View {
    Section {
      checkpointDescription(checkpoint)
      ForEach(entries(at: checkpoint)) { entry in guideRow(entry) }
    } header: {
      let prefix = !showAllAges && age?.nextCheckpoint == checkpoint ? "Next checkpoint · " : ""
      Text(prefix + MilestoneGuide.ageTitle(checkpoint))
    }
  }
  private func checkpointDescription(_ checkpoint: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let first = entries(at: checkpoint).first {
        Text(first.semantics.explanation).font(.footnote).foregroundStyle(.secondary)
      }
      let sources = entries(at: checkpoint).flatMap(\.sources)
      let unique = sources.enumerated().filter { index, source in
        !sources.prefix(index).contains { $0.id == source.id }
      }.map(\.element)
      ForEach(unique) { source in
        Link(source.name, destination: source.url)
          .font(.caption).buttonStyle(.borderless)
      }
    }
  }
  private func isPending(_ entry: MilestoneGuideEntry) -> Bool {
    model.carePending.contains {
      $0.command.childID == child.id && $0.command.payload?.guideID == entry.id
    }
  }
  private func guideRow(_ entry: MilestoneGuideEntry) -> some View {
    let saved = entry.recordedMilestone(
      in: model.milestonesByChild[child.id] ?? [], childID: child.id)
    let recorded = saved != nil || recordingState.isRecorded(entry.id)
    let waiting = recordingState.hasAttempt(entry.id) || isPending(entry)
    return VStack(alignment: .leading, spacing: 8) {
      Button {
        Task {
          if let saved { await remove(entry, saved: saved) }
          else { await record(entry) }
        }
      } label: {
        Label(entry.title, systemImage: recorded ? "checkmark.circle.fill" : "circle")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(entry.title + (recorded ? ", observed and recorded" : ", not recorded"))
      .accessibilityHint(recorded ? "Review removing this observation" : "Record an observation today")
      .accessibilityAddTraits(recorded ? .isSelected : [])
      .disabled(model.busy || waiting || (recorded && saved == nil) || removalAttempts[entry.id] != nil)
      if let saved {
        Text("Observed \(saved.dateLabel)").font(.subheadline).foregroundStyle(.secondary)
        if waiting {
          Text("Check the earlier recording attempt before changing this observation.")
            .font(.footnote).foregroundStyle(.secondary)
          Button("Retry / check recording") { Task { await retry(entry) } }
            .disabled(model.busy)
        }
        if removalAttempts[entry.id] != nil {
          Text("Removal needs checking before another change can be saved.")
            .font(.footnote).foregroundStyle(.secondary)
          Button("Retry / check removal") { Task { await remove(entry, saved: saved) } }
            .disabled(model.busy)
        }
      } else if recorded {
        Text("Observation recorded").font(.subheadline).foregroundStyle(.secondary)
      } else if recordingState.isSaving(entry.id) {
        ProgressView("Recording observation…")
      } else if waiting {
        Text("Recording needs checking before another observation can be saved.")
          .font(.footnote).foregroundStyle(.secondary)
        Button("Retry / check recording") { Task { await retry(entry) } }
          .disabled(model.busy)
      } else {
        Button("Choose an earlier date") { earlierDate = entry }
          .font(.subheadline).disabled(model.busy)
      }
    }
    .buttonStyle(.borderless)
    .padding(.vertical, 5)
  }
  @MainActor private func remove(_ entry: MilestoneGuideEntry, saved: Milestone) async {
    guard !model.busy else { return }
    let command = removalAttempts[entry.id]
      ?? model.carePending.first(where: {
        $0.command.childID == child.id && $0.command.action == "propose_edit"
          && $0.command.payload?.targetID == saved.id && $0.command.payload?.void == true
      })?.command
      ?? entry.removalCommand(for: saved, childID: child.id, timeZone: timeZone)
    guard let command else { return }
    removalAttempts[entry.id] = command
    guard let response = await model.care(command) else { return }
    if response.needsConfirmation, response.childID == child.id {
      removalAttempts[entry.id] = nil
      removalReview = GuideRemovalReview(guideID: entry.id, proposal: response)
    } else if ["rejected", "needs_clarification"].contains(response.status) {
      removalAttempts[entry.id] = nil
    }
  }
  @MainActor private func record(_ entry: MilestoneGuideEntry, on day: String? = nil) async {
    guard !model.busy, !isPending(entry),
      entry.recordedMilestone(in: model.milestonesByChild[child.id] ?? [], childID: child.id)
        == nil,
      let command = entry.command(
        childID: child.id, observedOn: day, birth: child.dateOfBirth, timeZone: timeZone),
      recordingState.begin(command, guideID: entry.id)
    else { return }
    let response = await model.care(command)
    recordingState.finish(guideID: entry.id, response: response)
    if response?.isPersisted == true, response?.childID == child.id { earlierDate = nil }
  }
  @MainActor private func retry(_ entry: MilestoneGuideEntry) async {
    guard !model.busy else { return }
    let command: CareCommand?
    if recordingState.hasAttempt(entry.id) {
      command = recordingState.retry(entry.id)
    } else if let pending = model.carePending.first(where: {
      $0.command.childID == child.id && $0.command.payload?.guideID == entry.id
    }), recordingState.begin(pending.command, guideID: entry.id) {
      command = pending.command
    } else {
      command = nil
    }
    guard let command else { return }
    let response = await model.care(command)
    recordingState.finish(guideID: entry.id, response: response)
  }
}

private struct MilestoneObservedDateView: View {
  let entry: MilestoneGuideEntry
  let birth: String?
  let busy: Bool
  let unavailable: Bool
  let message: String?
  let save: (Date) async -> Void
  @State private var selectedDate = Date()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.timeZone) private var timeZone

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(entry.title).font(.headline)
          Text("Choose a day you observed this skill. It does not need to be the first time.")
            .font(.subheadline)
          if let birth, let first = CalendarDate.localDate(birth, timeZone: timeZone),
            CalendarDate.dayAnchor(first, timeZone: timeZone) <= Date()
          {
            DatePicker(
              "Observed on", selection: $selectedDate,
              in: CalendarDate.dayAnchor(first, timeZone: timeZone)...Date(),
              displayedComponents: .date)
          } else {
            DatePicker(
              "Observed on", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
          }
          Button("Record observation") { Task { await save(selectedDate) } }
            .disabled(busy || unavailable)
          if busy { ProgressView("Recording…") }
          if unavailable && !busy {
            Text("Close this date form and use Retry / check recording in the guide.").font(
              .footnote)
          }
          if let message { Text(message).font(.footnote) }
        }
      }
      .navigationTitle("Observation date")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Close") { dismiss() }.disabled(busy) }
    }
    .interactiveDismissDisabled(busy)
  }
}
