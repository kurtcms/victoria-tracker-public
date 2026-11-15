#if !canImport(VictoriaTrackerCore)
  import XCTest
  import AppIntents
  @testable import VictoriaTracker

  private actor SiriTestBackend: SiriRecordingBackend {
    private var commands: [CareCommand] = []
    func performCare(_ command: CareCommand) -> CareResponse {
      commands.append(command)
      return CareResponse(
        status: "needs_clarification", message: "Which baby?", eventID: nil, childID: nil,
        proposalID: nil)
    }
    func submitted() -> [CareCommand] { commands }
  }
  final class SiriRecorderTests: XCTestCase {
    func testDescriptionsForwardUnchangedWithoutAttachingDashboardBaby() async throws {
      let backend = SiriTestBackend()
      let descriptions = [
        "Victoria drank 180 mL.", "Oliver had 200 mL.", "She had a wet diaper.",
        "Victoria left 20 millilitres.", "Oliver fell asleep five minutes ago.",
        "Victoria rolled over today.",
      ]
      for text in descriptions { _ = try await SiriRecorder.record(text, using: backend) }
      let commands = await backend.submitted()
      XCTAssertEqual(commands.map(\.text), descriptions.map(Optional.some))
      XCTAssertTrue(
        commands.allSatisfy { $0.childID == nil && $0.source == "siri" && $0.mode == "text" })
      XCTAssertEqual(Set(commands.map(\.id)).count, descriptions.count)
    }
    func testBlankOrOversizedDescriptionNeverReachesBackend() async {
      let backend = SiriTestBackend()
      for text in [" \n ", String(repeating: "x", count: 1001)] {
        do {
          _ = try await SiriRecorder.record(text, using: backend)
          XCTFail("Invalid input accepted")
        } catch {}
      }
      let commands = await backend.submitted()
      XCTAssertTrue(commands.isEmpty)
    }
    func testClarificationIsReturnedWithoutAClaimOfPersistence() async throws {
      let result = try await SiriRecorder.record("She fell asleep", using: SiriTestBackend())
      XCTAssertEqual(result.status, "needs_clarification")
      XCTAssertFalse(result.isPersisted)
      XCTAssertFalse(result.needsConfirmation)
    }
    func testCantoneseConfirmationForwardsServerLanguageAndExactProposal() async throws {
      let backend = SiriTestBackend()
      let id = UUID()
      let child = UUID()
      let proposal = CareResponse(
        status: "needs_confirmation", message: "改做80毫升？", eventID: nil,
        childID: child, proposalID: id, language: "yue")
      _ = try await SiriRecorder.confirm(proposal, using: backend)
      let commands = await backend.submitted()
      XCTAssertEqual(commands.count, 1)
      XCTAssertEqual(commands.first?.proposalID, id)
      XCTAssertEqual(commands.first?.childID, child)
      XCTAssertEqual(commands.first?.language, "yue")
      XCTAssertEqual(commands.first?.source, "siri")
      XCTAssertEqual(commands.first?.confirmed, true)
      XCTAssertNil(commands.first?.text)
    }
    func testInvalidProposalNeverSendsConfirmation() async {
      let backend = SiriTestBackend()
      let result = CareResponse(
        status: "answered", message: "180 mL today", eventID: nil,
        childID: UUID(), proposalID: nil)
      do {
        _ = try await SiriRecorder.confirm(result, using: backend)
        XCTFail("An answer must never become a confirmation")
      } catch {}
      let commands = await backend.submitted()
      XCTAssertTrue(commands.isEmpty)
    }
    func testLegacyFixedActionsAreHiddenAndFailWithoutRecording() async {
      XCTAssertFalse(Log160MilkIntent.isDiscoverable)
      XCTAssertFalse(LogWetDiaperIntent.isDiscoverable)
      XCTAssertFalse(LogDirtyDiaperIntent.isDiscoverable)
      XCTAssertFalse(LogMixedDiaperIntent.isDiscoverable)
      let actions: [() async throws -> Void] = [
        { _ = try await Log160MilkIntent().perform() },
        { _ = try await LogWetDiaperIntent().perform() },
        { _ = try await LogDirtyDiaperIntent().perform() },
        { _ = try await LogMixedDiaperIntent().perform() },
      ]
      for action in actions {
        do {
          try await action()
          XCTFail("Retired action ran")
        } catch { XCTAssertTrue(error.localizedDescription.contains("replaced")) }
      }
    }
  }
#endif
