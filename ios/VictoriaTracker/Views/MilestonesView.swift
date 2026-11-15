import SwiftUI

struct MilestonesView: View {
  @Bindable var model: AppModel
  @State private var recording = false
  @State private var editing: Milestone?
  @State private var showingGuide = false
  var body: some View {
    Group {
      if let child = model.child {
        VStack(spacing: 0) {
          Picker("Milestones view", selection: $showingGuide) {
            Text("Memories").tag(false)
            Text("Age guide").tag(true)
          }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
          if showingGuide {
            MilestoneGuideView(model: model, child: child).id(child.id)
          } else {
            List {
              Section(child.name) {
                Button("Record a milestone", systemImage: "plus.circle") { recording = true }
              }
              if model.milestones.isEmpty {
                Section {
                  ContentUnavailableView(
                    "Little firsts, kept here", systemImage: "sparkles",
                    description: Text(
                      "Add a memory whenever it happens. There’s no daily milestone target."))
                }
              } else {
                ForEach(model.milestones) { milestone in
                  Button {
                    editing = milestone
                  } label: {
                    VStack(alignment: .leading, spacing: 6) {
                      Text(milestone.title).font(.headline)
                      Text(milestone.dateLabel).font(.subheadline).foregroundStyle(.secondary)
                      if milestone.guideID != nil {
                        Text("Age guide observation").font(.caption).foregroundStyle(.secondary)
                      }
                      if let birth = child.dateOfBirth,
                        let age = CalendarDate.ageLabel(
                          birth: birth, on: milestone.occurredOn, precision: milestone.datePrecision
                        )
                      {
                        Text(age).font(.caption).foregroundStyle(.secondary)
                      }
                      if let note = milestone.note, !note.isEmpty { Text(note).font(.body) }
                      Text(
                        milestone.recordedBy == model.userID
                          ? "Recorded by you" : "Recorded by the other parent"
                      ).font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(Color.primary).padding(.vertical, 4)
                  }.buttonStyle(.plain)
                }
              }
              Section { StatusMessages(model: model) }
            }.refreshable { await model.refresh() }
              .sheet(isPresented: $recording) {
                RecordView(model: model, child: child, initialKind: "milestone")
              }
              .sheet(item: $editing) { m in EditCareView(model: model, child: child, milestone: m) }
          }
        }
      } else {
        BabySelectionPrompt(model: model)
      }
    }.navigationTitle("Milestones")
  }
}
