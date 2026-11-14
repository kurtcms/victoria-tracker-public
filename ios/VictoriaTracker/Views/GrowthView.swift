import Charts
import SwiftUI

private struct ReferenceCurvePoint: Identifiable {
  let day: Int
  let label: String
  let weight: Double
  var id: String { "\(label)-\(day)" }
}
private struct WeightPoint: Identifiable {
  let event: BabyEvent
  let day: Int
  let weight: Double
  var id: UUID { event.id }
}
struct GrowthView: View {
  @Bindable var model: AppModel
  @State private var reference: GrowthReference?
  @State private var referenceKey = ""
  @State private var range = 24
  @State private var selectedMonth: Double?
  @State private var recording = false
  @State private var editing: BabyEvent?
  @State private var profile = false
  var body: some View {
    Group {
      if let child = model.child {
        content(child)
          .task(id: "\(child.id)-\(child.profileVersion ?? 1)") {
            referenceKey = "\(child.id)-\(child.profileVersion ?? 1)"
            reference =
              canUseReference(child)
              ? try? GrowthReference.load(sex: child.growthReferenceSex ?? "") : nil
          }
          .sheet(isPresented: $recording) {
            RecordView(model: model, child: child, initialKind: "weight")
          }
          .sheet(item: $editing) { event in EditCareView(model: model, child: child, event: event) }
          .sheet(isPresented: $profile) { ChildProfileView(model: model, existing: child) }
      } else {
        BabySelectionPrompt(model: model)
      }
    }.navigationTitle("Growth")
  }
  private func canUseReference(_ c: Child) -> Bool {
    c.dateOfBirth != nil && c.growthReferenceConfirmed == true && c.wasPremature == false
      && ["female", "male"].contains(c.growthReferenceSex ?? "")
  }
  private func dateString(_ e: BabyEvent) -> String {
    e.measurementDate ?? CalendarDate.string(e.occurredAt)
  }
  private func points(_ c: Child) -> [WeightPoint] {
    guard let birth = c.dateOfBirth else { return [] }
    return model.weights.compactMap { e in
      guard let w = e.weightKG, let d = CalendarDate.days(from: birth, to: dateString(e)) else {
        return nil
      }
      return WeightPoint(event: e, day: d, weight: w)
    }
  }
  private func percentile(_ e: BabyEvent, child: Child) -> Double? {
    guard canUseReference(child), referenceKey == "\(child.id)-\(child.profileVersion ?? 1)",
      let b = child.dateOfBirth, let d = CalendarDate.days(from: b, to: dateString(e)),
      let w = e.weightKG
    else { return nil }
    return reference?.parameters(day: d)?.percentile(weight: w)
  }
  private func content(_ child: Child) -> some View {
    List {
      Section(child.name) {
        Button("Record weight", systemImage: "plus.circle") { recording = true }
        Button("Growth profile", systemImage: "person.crop.circle") { profile = true }
        if !canUseReference(child) {
          Text(
            child.wasPremature == true
              ? "Measurements are saved here. Percentiles need a supported reference and age approach for premature babies."
              : "Add a birth date, choose a WHO chart and complete the birth profile to show percentile curves."
          )
          .font(.footnote).foregroundStyle(.secondary)
        } else if reference == nil {
          Text("The growth reference couldn’t be loaded. Measurements remain available.").font(
            .footnote
          ).foregroundStyle(.secondary)
        }
      }
      if child.dateOfBirth != nil {
        Section("Weight over time") {
          VStack(alignment: .leading, spacing: 6) {
            Picker("Age from birth", selection: $range) {
              Text("Birth–6 mo").tag(6)
              Text("Birth–2 yr").tag(24)
              Text("Birth–5 yr").tag(60)
            }.pickerStyle(.segmented)
            Text("Baby’s age from birth")
              .font(.caption).foregroundStyle(.secondary)
          }
          weightChart(child)
          if let selectedMonth,
            let nearest = points(child).filter({ $0.day <= dayLimit }).min(by: {
              abs(Double($0.day) / 30.4375 - selectedMonth)
                < abs(Double($1.day) / 30.4375 - selectedMonth)
            })
          {
            Text(
              "\(nearest.weight.formatted()) kg · \(CalendarDate.localDate(dateString(nearest.event))?.formatted(date:.abbreviated,time:.omitted) ?? dateString(nearest.event))"
            ).font(.caption)
          }
          Text(
            "WHO weight-for-age reference · age in months. Points are recorded measurements; curves are reference percentiles, not targets."
          ).font(.caption).foregroundStyle(.secondary)
          if model.weights.count == 1 {
            Text(
              "One measurement is a starting point. A trajectory appears as more measurements are recorded."
            ).font(.footnote).foregroundStyle(.secondary)
          }
          if points(child).contains(where: { $0.day > 1856 }) {
            Text(
              "Some measurements are beyond this WHO reference’s age range; they remain in the list below."
            ).font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
      Section("Measurements") {
        if model.weights.isEmpty {
          Text(
            "Record a weight whenever you have a measurement. Daily weighing isn’t required by this app."
          ).foregroundStyle(.secondary)
        }
        ForEach(model.weights.reversed()) { e in
          Button {
            editing = e
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text("\((e.weightKG ?? 0).formatted()) kg").font(.headline)
                Text(
                  CalendarDate.localDate(dateString(e))?.formatted(
                    date: .abbreviated, time: .omitted) ?? dateString(e)
                ).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if let p = percentile(e, child: child) {
                Text("Percentile \(p.formatted(.number.precision(.fractionLength(0...1))))").font(
                  .caption
                ).foregroundStyle(.secondary)
              }
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.foregroundStyle(Color.primary)
          }.buttonStyle(.plain)
        }
      }
      Section {
        Text(
          "Growth measurements and reference curves help describe change over time. They do not diagnose a condition or assign a good or bad percentile."
        ).font(.footnote).foregroundStyle(.secondary)
        Link(
          "WHO reference source",
          destination: URL(
            string: "https://www.who.int/toolkits/child-growth-standards/standards/weight-for-age")!
        )
        StatusMessages(model: model)
      }
    }.refreshable { await model.refresh() }
  }
  private var dayLimit: Int { Int(Double(range) * 30.4375) }
  private func curves() -> [ReferenceCurvePoint] {
    guard let child = model.child, canUseReference(child),
      referenceKey == "\(child.id)-\(child.profileVersion ?? 1)", let reference
    else { return [] }
    return GrowthReference.curves.flatMap { curve in
      reference.rows.filter {
        $0.day <= dayLimit && ($0.day <= 31 || $0.day % 7 == 0 || $0.day == dayLimit)
      }.compactMap { row in
        row.weight(z: curve.z).map {
          ReferenceCurvePoint(day: row.day, label: curve.label, weight: $0)
        }
      }
    }
  }
  private func weightChart(_ child: Child) -> some View {
    Chart {
      ForEach(curves()) { p in
        LineMark(
          x: .value("Age (months)", Double(p.day) / 30.4375), y: .value("Weight (kg)", p.weight),
          series: .value("Percentile", p.label)
        )
        .foregroundStyle(by: .value("Percentile", p.label)).lineStyle(
          StrokeStyle(lineWidth: 1, dash: p.label == "50th" ? [] : [3, 3]))
      }
      ForEach(points(child).filter { $0.day <= dayLimit }) { p in
        PointMark(
          x: .value("Age (months)", Double(p.day) / 30.4375), y: .value("Weight (kg)", p.weight)
        ).foregroundStyle(.pink).symbolSize(40)
      }
    }
    .chartForegroundStyleScale(
      domain: ["3rd", "15th", "50th", "85th", "97th"],
      range: [
        Color.gray, Color.gray.opacity(0.7), Color.pink.opacity(0.7), Color.gray.opacity(0.7),
        Color.gray,
      ]
    )
    .chartXScale(domain: 0...Double(range)).chartXAxisLabel("Age (months)")
    .chartYAxisLabel("kg")
    .chartXSelection(value: $selectedMonth).frame(height: 250)
    .accessibilityLabel(
      "Recorded weights against WHO weight-for-age reference curves. Exact measurements are listed below."
    )
  }
}
