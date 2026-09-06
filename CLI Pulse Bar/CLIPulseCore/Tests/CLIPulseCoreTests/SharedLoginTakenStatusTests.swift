// A provider whose credentials are ONE machine-wide login (Claude, Gemini) can
// only be read by one CLI Pulse account entry. The entry that does not hold it
// used to fall to the default `.notReady(.unknown)`, which renders as
// "Not set up — Open Settings to connect this provider": false, because the
// provider IS connected, and unactionable, because Settings says so too.
//
// Diagnosed on the owner's Mac 2026-09-06, where the shared-credential owner
// named an account that no longer existed: Claude and Gemini both showed
// "Not set up" beside live data, and re-signing in could not help because the
// refusal sits upstream of every credential source.
import XCTest
@testable import CLIPulseCore

final class SharedLoginTakenStatusTests: XCTestCase {

    private let mine = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let theirs = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    // MARK: - The probe

    func test_anotherEntryHoldingTheSharedLoginIsItsOwnReason() {
        let readiness = CollectorReadinessProbe.sharedCredentialConflict(
            kind: .claude, accountID: mine, owner: { _ in self.theirs }
        )
        XCTAssertEqual(readiness, .notReady(.sharedCredentialTaken))
    }

    func test_holdingItYourselfIsNotAConflict() {
        XCTAssertNil(CollectorReadinessProbe.sharedCredentialConflict(
            kind: .claude, accountID: mine, owner: { _ in self.mine }
        ), "the entry that owns the shared login must not be told someone else has it")
    }

    func test_nobodyHoldingItIsNotAConflict() {
        XCTAssertNil(CollectorReadinessProbe.sharedCredentialConflict(
            kind: .claude, accountID: mine, owner: { _ in nil }
        ), "an unowned shared login is free to claim, not a conflict")
    }

    // MARK: - What the user reads

    func test_itDoesNotRenderAsNotSetUp() {
        let shown = CollectorOutcomePresentation.of(
            .notReady(.sharedCredentialTaken), providerName: "Claude"
        )
        XCTAssertEqual(shown.label, L10n.collectorStatus.sharedLoginTaken)
        XCTAssertNotEqual(shown.label, L10n.collectorStatus.notSetUp,
                          "back to \"Not set up\", which is false for a provider that is connected")
        XCTAssertNotEqual(shown.nextStep, L10n.collectorStatus.notSetUpHint,
                          "back to \"Open Settings to connect this provider\" — Settings says Connected")
        XCTAssertEqual(shown.severity, .attention)
    }

    func test_theHintNamesTheProvider() {
        let shown = CollectorOutcomePresentation.of(
            .notReady(.sharedCredentialTaken), providerName: "Gemini"
        )
        let step = try? XCTUnwrap(shown.nextStep)
        XCTAssertTrue((step ?? "").contains("Gemini"),
                      "the hint dropped the provider name, so it cannot say WHICH login is taken: \(step ?? "nil")")
    }

    // MARK: - Telemetry keeps its own vocabulary

    func test_theReasonHasItsOwnTelemetryToken() {
        XCTAssertEqual(CollectorOutcome.notReady(.sharedCredentialTaken).telemetryToken,
                       "not_ready_shared_credential_taken")
        XCTAssertNotEqual(CollectorOutcome.notReady(.sharedCredentialTaken).telemetryToken,
                          CollectorOutcome.notReady(.unknown).telemetryToken,
                          "the fleet cannot tell the two apart")
    }

    // MARK: - Both governed collectors ask

    /// `ProviderSharedCredentialOwner.supportedKinds` is exactly {claude,
    /// gemini}; a collector that stops asking silently goes back to
    /// "Not set up".
    func test_bothGovernedCollectorsConsultTheProbe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["ClaudeCollector.swift", "GeminiCollector.swift"] {
            let src = try String(
                contentsOf: root.appending(path: "Sources/CLIPulseCore/Collectors/\(file)"),
                encoding: .utf8)
            XCTAssertTrue(src.contains("CollectorReadinessProbe.sharedCredentialConflict"),
                          "\(file) no longer explains a taken shared login")
        }
    }
}
