import Observation
import SwiftUI

protocol DashboardDataSource: Sendable {
  func savedSession() async throws -> AuthSession?
  func children() async throws -> [Child]
  func events(child: Child, day: LocalDay) async throws -> [BabyEvent]
  func pending() async throws -> [PendingRecord]
  func sleep(child: Child, day: LocalDay) async throws -> [SleepSession]
  func milestones(child: Child) async throws -> [Milestone]
  func weights(child: Child) async throws -> [BabyEvent]
  func pendingCare() async throws -> [PendingCareCommand]
}

extension DashboardDataSource {
  func sleep(child: Child, day: LocalDay) async throws -> [SleepSession] { [] }
  func milestones(child: Child) async throws -> [Milestone] { [] }
  func weights(child: Child) async throws -> [BabyEvent] { [] }
  func pendingCare() async throws -> [PendingCareCommand] { [] }
}
extension Backend: DashboardDataSource {}

@MainActor @Observable final class AppModel {
  var userID: UUID?
  var child: Child?
  var allChildren: [Child] = []
  var children: [Child] { allChildren.filter { $0.archivedAt == nil } }
  private(set) var selectedChildID: UUID?
  var eventsByChild: [UUID: [BabyEvent]] = [:]
  var sleepByChild: [UUID: [SleepSession]] = [:]
  var milestonesByChild: [UUID: [Milestone]] = [:]
  var weightsByChild: [UUID: [BabyEvent]] = [:]
  var carePending: [PendingCareCommand] = []
  var sleep: [SleepSession] { child.flatMap { sleepByChild[$0.id] } ?? [] }
  var milestones: [Milestone] { child.flatMap { milestonesByChild[$0.id] } ?? [] }
  var weights: [BabyEvent] { child.flatMap { weightsByChild[$0.id] } ?? [] }
  var events: [BabyEvent] = []
  var pending: [PendingRecord] = []
  var error: String?
  var notice: String?
  var loading = true
  var busy = false
  var lastSynced: Date?
  var day = LocalDay()
  private(set) var selection: DaySelection = .today
  private(set) var dayLoading = false
  private(set) var hasLoadedDay = false
  private let source: any DashboardDataSource
  private var refreshing = false
  private var refreshAgain = false
  private var selectionGeneration = 0
  private var confirmingEmail = false
  init(source: any DashboardDataSource = Backend.shared) { self.source = source }
  var summary: DaySummary {
    DaySummary(
      events: events, now: day.reference, timeZone: day.timeZone)
  }
  func refresh() async {
    guard !refreshing else {
      refreshAgain = true
      return
    }
    refreshing = true
    defer {
      refreshing = false
      loading = false
      dayLoading = false
    }
    repeat {
      refreshAgain = false
      let generation = selectionGeneration
      do {
        let currentUser = try await source.savedSession()?.userID
        if userID != currentUser {
          child = nil
          allChildren = []
          selectedChildID = nil
          eventsByChild = [:]
          sleepByChild = [:]
          milestonesByChild = [:]
          weightsByChild = [:]
          carePending = []
          events = []
          pending = []
          lastSynced = nil
          hasLoadedDay = false
        }
        userID = currentUser
        guard userID != nil else { return }
        let requestedDay = selection.localDay()
        if requestedDay.isToday() { selection = .today }
        if day.interval != requestedDay.interval
          || day.timeZone.identifier != requestedDay.timeZone.identifier
        {
          day = requestedDay
          events = []
          lastSynced = nil
          hasLoadedDay = false
        }
        dayLoading = !hasLoadedDay
        let roster = try await source.children()
        let active = roster.filter { $0.archivedAt == nil }
        let selectedChild =
          active.count == 1 ? active.first : active.first { $0.id == selectedChildID }
        var byChild: [UUID: [BabyEvent]] = [:]
        var sleeps: [UUID: [SleepSession]] = [:]
        var milestones: [UUID: [Milestone]] = [:]
        var weights: [UUID: [BabyEvent]] = [:]
        for baby in active {
          byChild[baby.id] = try await source.events(child: baby, day: requestedDay)
          sleeps[baby.id] = try await source.sleep(child: baby, day: requestedDay)
          milestones[baby.id] = try await source.milestones(child: baby)
          weights[baby.id] = try await source.weights(child: baby)
        }
        let loadedEvents = selectedChild.flatMap { byChild[$0.id] } ?? []
        let loadedPending = try await source.pending()
        let loadedCarePending = try await source.pendingCare()
        let finalUser = try await source.savedSession()?.userID
        guard generation == selectionGeneration else { continue }
        guard finalUser == currentUser else {
          refreshAgain = true
          continue
        }
        let latestDay = selection.localDay()
        guard latestDay.interval == requestedDay.interval,
          latestDay.timeZone.identifier == requestedDay.timeZone.identifier
        else {
          refreshAgain = true
          continue
        }
        allChildren = roster
        child = selectedChild
        eventsByChild = byChild
        sleepByChild = sleeps
        milestonesByChild = milestones
        weightsByChild = weights
        carePending = loadedCarePending
        day = requestedDay
        events = loadedEvents
        pending = loadedPending
        hasLoadedDay = true
        lastSynced = Date()
        error = nil
      } catch {
        if generation == selectionGeneration { self.error = error.localizedDescription }
      }
    } while refreshAgain
  }
  func selectChild(_ id: UUID?) async {
    selectedChildID = id
    selectionGeneration += 1
    child = children.count == 1 ? children.first : children.first { $0.id == id }
    events = []
    hasLoadedDay = false
    lastSynced = nil
    dayLoading = true
    await refresh()
  }
  func selectDay(_ date: Date?) async {
    selection = date.map { DaySelection(date: $0) } ?? .today
    selectionGeneration += 1
    day = selection.localDay()
    events = []
    lastSynced = nil
    hasLoadedDay = false
    dayLoading = true
    error = nil
    await refresh()
  }
  func moveDay(by days: Int) async {
    let next = selection.moving(by: days)
    await selectDay(next == .today ? nil : next.localDay().reference)
  }
  func run(_ operation: () async throws -> Void) async {
    guard !busy else { return }
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do {
      try await operation()
      await refresh()
    } catch {
      self.error = error.localizedDescription
      pending = (try? await Backend.shared.pending()) ?? pending
      carePending = (try? await Backend.shared.pendingCare()) ?? carePending
    }
  }
  func confirmEmail(_ url: URL) async {
    // Handle cold and warm URL launches even when a normal UI operation is busy.
    guard !confirmingEmail else { return }
    confirmingEmail = true
    defer { confirmingEmail = false }
    do {
      notice = try await Backend.shared.confirmEmail(url: url)
      error = nil
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func record(_ command: RecordCommand) async -> Bool {
    guard !busy else { return false }
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do {
      let response = try await Backend.shared.record(command)
      notice = response.message
      await refresh()
      return response.isPersisted
    } catch {
      self.error = error.localizedDescription
      pending = (try? await Backend.shared.pending()) ?? pending
      carePending = (try? await Backend.shared.pendingCare()) ?? carePending
      return false
    }
  }
  func retry(_ entry: PendingRecord) async {
    await run {
      let response = try await Backend.shared.retry(entry)
      notice = response.message
    }
  }
  func care(_ command: CareCommand) async -> CareResponse? {
    guard !busy else { return nil }
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do {
      let response = try await Backend.shared.performCare(command)
      notice = response.message
      if response.isAnswered {
        carePending = (try? await Backend.shared.pendingCare()) ?? carePending
      } else {
        await refresh()
      }
      return response
    } catch {
      self.error = error.localizedDescription
      carePending = (try? await Backend.shared.pendingCare()) ?? carePending
      return nil
    }
  }
  func retryCare(_ entry: PendingCareCommand) async -> CareResponse? {
    guard entry.userID == userID else {
      error = "Sign in as the parent who started this action."
      return nil
    }
    return await care(entry.command)
  }
  func signOut() async {
    await run {
      try await Backend.shared.signOut()
      userID = nil
      child = nil
      allChildren = []
      selectedChildID = nil
      eventsByChild = [:]
      sleepByChild = [:]
      milestonesByChild = [:]
      weightsByChild = [:]
      carePending = []
      events = []
      pending = []
      lastSynced = nil
      selection = .today
      selectionGeneration += 1
      day = LocalDay()
      hasLoadedDay = false
    }
  }
}
