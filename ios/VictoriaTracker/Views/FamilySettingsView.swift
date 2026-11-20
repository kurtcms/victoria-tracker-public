import SwiftUI

struct TrackerTabs: View {
  @Bindable var model: AppModel
  var body: some View {
    TabView {
      DashboardView(model: model).tabItem { Label("Day", systemImage: "sun.max") }
      GrowthView(model: model).tabItem { Label("Growth", systemImage: "chart.xyaxis.line") }
      MilestonesView(model: model).tabItem { Label("Milestones", systemImage: "sparkles") }
      FamilySettingsView(model: model).tabItem { Label("Family", systemImage: "person.2") }
    }.toolbar {
      if model.children.count > 1 {
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            Button("All babies") { Task { await model.selectChild(nil) } }
            ForEach(model.children) { baby in
              Button(baby.name) { Task { await model.selectChild(baby.id) } }
            }
          } label: {
            Label(model.child?.name ?? "All babies", systemImage: "chevron.down")
          }
        }
      }
    }
  }
}
struct BabySelectionPrompt: View {
  @Bindable var model: AppModel
  var body: some View {
    List {
      Section("Choose a baby") {
        ForEach(model.children) { baby in
          Button {
            Task { await model.selectChild(baby.id) }
          } label: {
            Label(baby.name, systemImage: "person.crop.circle")
          }
        }
      }
      if model.children.isEmpty {
        Text("Add a baby in Family to start recording.").foregroundStyle(.secondary)
      }
    }
  }
}
struct FamilySettingsView: View {
  @Bindable var model: AppModel
  @State private var add = false
  @State private var editing: Child?
  @State private var invite: String?
  var body: some View {
    List {
      Section("Your babies") {
        ForEach(model.children) { baby in
          Button {
            editing = baby
          } label: {
            LabeledContent(baby.name, value: "Edit profile").foregroundStyle(.primary)
          }
        }
        Button("Add another baby", systemImage: "plus.circle") { add = true }
      }
      let archived = model.allChildren.filter { $0.archivedAt != nil }
      if !archived.isEmpty {
        Section("Archived profiles") {
          ForEach(archived) { baby in Button("\(baby.name) · Restore or edit") { editing = baby } }
        }
      }
      Section("Together") {
        Button("Create invite for the second parent", systemImage: "person.badge.plus") {
          Task { await model.run { invite = try await Backend.shared.invite() } }
        }.disabled(model.busy)
        if let invite {
          Text("Share privately. Expires in 24 hours and can be used once.").font(.footnote)
          Text(invite).font(.caption.monospaced()).textSelection(.enabled)
        }
      }
      Section("Account") {
        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
          Task { await model.signOut() }
        }.disabled(model.busy)
      }
      Section { StatusMessages(model: model) }
    }.navigationTitle("Family")
      .sheet(isPresented: $add) { ChildProfileView(model: model) }
      .sheet(item: $editing) { baby in ChildProfileView(model: model, existing: baby) }
  }
}
struct ChildProfileView: View {
  @Bindable var model: AppModel
  var existing: Child? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var hasBirth = false
  @State private var birth = Date()
  @State private var sex = ""
  @State private var voicePronoun = ""
  @State private var premature = "unknown"
  @State private var archiveConfirm = false
  @State private var loaded = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Baby") {
          TextField("Name", text: $name).textContentType(.givenName)
          Picker("Voice pronoun", selection: $voicePronoun) {
            Text("Unspecified").tag("")
            Text("She").tag("she")
            Text("He").tag("he")
          }
          Text(
            "With one baby, either pronoun chooses that baby. With multiple babies, use a name or an unambiguous configured pronoun. Unset or shared pronouns may need clarification."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        Section("Growth profile (optional)") {
          Toggle("Add date of birth", isOn: $hasBirth)
          if hasBirth {
            DatePicker(
              "Date of birth", selection: $birth, in: ...Date(), displayedComponents: .date)
          }
          Picker("WHO chart", selection: $sex) {
            Text("Not selected").tag("")
            Text("Girls").tag("female")
            Text("Boys").tag("male")
          }
          Picker("Born prematurely?", selection: $premature) {
            Text("Not specified").tag("unknown")
            Text("No").tag("no")
            Text("Yes").tag("yes")
          }
          Text(
            premature == "yes"
              ? "Weights are saved. Percentiles for premature babies aren’t available yet."
              : "Birth date and WHO chart enable age-based growth curves."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if let existing {
          Section("History") {
            NavigationLink("Change history") {
              RevisionHistoryView(child: existing, userID: model.userID)
            }
          }
          Section {
            if existing.archivedAt == nil {
              Button("Archive baby profile", role: .destructive) { archiveConfirm = true }
                .disabled(model.busy)
            } else {
              Text("Saving restores this profile and its records.").font(.footnote)
            }
          } footer: {
            if existing.archivedAt == nil {
              Text(
                "Archiving hides this baby from recording. Their records are kept, and you can restore the profile later."
              )
            }
          }
        }
        StatusMessages(model: model)
      }.navigationTitle(existing == nil ? "Add baby" : "Edit baby").navigationBarTitleDisplayMode(
        .inline
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(model.busy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(existing == nil ? "Add" : "Save") { Task { await save(archive: false) } }
            .fontWeight(.semibold)
            .disabled(
              model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || name.count > 80)
        }
      }
      .onAppear {
        guard !loaded else { return }
        loaded = true
        if let existing {
          name = existing.name
          sex = existing.growthReferenceSex ?? ""
          voicePronoun = existing.voicePronoun ?? ""
          if let value = existing.dateOfBirth, let d = CalendarDate.localDate(value) {
            hasBirth = true
            birth = d
          }
          premature = existing.wasPremature.map { $0 ? "yes" : "no" } ?? "unknown"
        }
      }
      .confirmationDialog(
        "Archive this baby? Records are kept. Finish any active sleep first.",
        isPresented: $archiveConfirm, titleVisibility: .visible
      ) { Button("Archive profile", role: .destructive) { Task { await save(archive: true) } } }
    }.interactiveDismissDisabled(model.busy)
  }
  private func save(archive: Bool) async {
    await model.run {
      try await Backend.shared.saveChild(
        existing, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        birthDate: hasBirth ? CalendarDate.string(birth) : nil,
        referenceSex: sex.isEmpty ? nil : sex, referenceConfirmed: !sex.isEmpty,
        wasPremature: premature == "unknown" ? nil : premature == "yes",
        voicePronoun: voicePronoun.isEmpty ? nil : voicePronoun, archive: archive)
    }
    if model.error == nil { dismiss() }
  }
}

struct RevisionHistoryView: View {
  let child: Child
  let userID: UUID?
  @State private var items: [RecordRevision] = []
  @State private var error: String?
  @State private var loading = true
  var body: some View {
    List {
      if loading { ProgressView("Loading history…") }
      if let error { Text(error).foregroundStyle(.red) }
      if !loading && error == nil && items.isEmpty {
        Text("No corrections recorded for \(child.name).").foregroundStyle(.secondary)
      }
      ForEach(items) { item in
        VStack(alignment: .leading, spacing: 5) {
          Text(item.targetType.capitalized).font(.caption.weight(.semibold)).foregroundStyle(
            .secondary)
          Text("\(item.beforeValue.label) → \(item.afterValue.label)")
          Text(
            "\(item.changedBy==userID ? "You":"Other parent") · \(item.createdAt.formatted(date:.abbreviated,time:.shortened))"
          ).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
      }
    }.navigationTitle("Correction history").task { await load() }.refreshable { await load() }
  }
  private func load() async {
    loading = true
    defer { loading = false }
    do {
      items = try await Backend.shared.revisions(child: child)
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}
