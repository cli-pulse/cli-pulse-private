#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.44 W3 — pin what the user is actually told.
///
/// These strings are the entire user-visible surface of W3. The failure mode
/// they guard against is not a crash but a confident lie: sending someone to
/// reinstall a CLI they already have, or to hunt for an API key that was never
/// the problem. Wrong advice here is worse than the silence it replaces,
/// because silence at least does not waste their afternoon.
final class CollectorOutcomePresentationTests: XCTestCase {

    private func presentation(_ outcome: CollectorOutcome) -> CollectorOutcomePresentation {
        CollectorOutcomePresentation.of(outcome, providerName: "Codex")
    }

    /// Every actionable outcome must offer a next step. An actionable state
    /// with nothing to do is a dead end — it tells the user something is wrong
    /// and abandons them there.
    func testEveryActionableOutcomeOffersANextStep() {
        let actionable: [CollectorOutcome] = [
            .notReady(.notInstalled), .notReady(.missingCredentials), .notReady(.unknown),
            .ranButEmpty,
            .failed(.auth), .failed(.network), .failed(.parse),
            .failed(.permission), .failed(.http), .failed(.other),
        ]
        for outcome in actionable {
            XCTAssertNotNil(
                presentation(outcome).nextStep,
                "\(outcome) tells the user something is wrong — it must also say what to do"
            )
        }
    }

    /// The two quiet states must NOT nag. `disabled` is the user's own
    /// deliberate choice, and there is nothing to say about a provider that
    /// just worked.
    func testWorkingAndDisabledSayNothingFurther() {
        XCTAssertNil(presentation(.producedData).nextStep)
        XCTAssertNil(presentation(.disabled).nextStep)
        XCTAssertEqual(presentation(.producedData).severity, .normal)
        XCTAssertEqual(presentation(.disabled).severity, .normal)
    }

    /// The provider's own name has to reach the advice. "Sign in to Codex" is
    /// actionable; "sign in to this provider" sends the user back to guessing
    /// which of their tools the row was about.
    func testAdviceNamesTheProvider() {
        for outcome in [CollectorOutcome.notReady(.notInstalled),
                        .notReady(.missingCredentials),
                        .failed(.auth)] {
            let step = CollectorOutcomePresentation.of(outcome, providerName: "Codex").nextStep
            XCTAssertEqual(
                step?.contains("Codex"), true,
                "\(outcome) advice must name the provider, got: \(step ?? "nil")"
            )
        }
    }

    /// A parse failure is our bug, not the user's misconfiguration. If this
    /// ever routes to credential advice, users will re-authenticate over and
    /// over against a format change they cannot fix.
    func testParseFailureIsNotBlamedOnTheUser() {
        let step = presentation(.failed(.parse)).nextStep ?? ""
        XCTAssertFalse(step.lowercased().contains("sign in"),
                       "a format change is not fixed by signing in again")
        XCTAssertFalse(step.lowercased().contains("install"),
                       "a format change is not fixed by installing anything")
    }

    /// The sandbox denial has a one-tap fix, so it must point at that tap
    /// rather than landing in the generic failure bucket.
    func testPermissionFailurePointsAtFolderAccess() {
        let step = presentation(.failed(.permission)).nextStep ?? ""
        XCTAssertTrue(step.lowercased().contains("folder") || step.lowercased().contains("access"),
                      "permission denial must point at the folder-access grant, got: \(step)")
    }

    /// `unsupported` means we never wrote a collector. It must not read as
    /// breakage, and it must not imply the user's other data is missing —
    /// cost and sessions still work for these providers.
    func testUnsupportedIsCalmAndDoesNotImplyBreakage() {
        let p = presentation(.unsupported)
        XCTAssertEqual(p.severity, .normal, "we never supported it — that is not an alarm")
        XCTAssertNotNil(p.nextStep, "still explain it, or an empty row reads as broken")
    }

    /// Severity drives colour. Getting this backwards would paint a working
    /// machine red or a broken one grey.
    func testSeverityMatchesHowBadTheStateIs() {
        XCTAssertEqual(presentation(.notReady(.missingCredentials)).severity, .attention)
        XCTAssertEqual(presentation(.ranButEmpty).severity, .attention)
        XCTAssertEqual(presentation(.failed(.auth)).severity, .attention)
        XCTAssertEqual(presentation(.failed(.network)).severity, .problem)
        XCTAssertEqual(presentation(.failed(.parse)).severity, .problem)
        // Not installed is not a fault — the user simply doesn't use this tool.
        XCTAssertEqual(presentation(.notReady(.notInstalled)).severity, .normal)
    }

    /// No label may be empty, or the row renders a coloured blank.
    func testNoLabelIsEmpty() {
        let all: [CollectorOutcome] = [
            .disabled, .unsupported, .producedData, .ranButEmpty,
            .notReady(.notInstalled), .notReady(.missingCredentials), .notReady(.unknown),
            .failed(.auth), .failed(.network), .failed(.parse),
            .failed(.permission), .failed(.http), .failed(.other),
        ]
        for outcome in all {
            XCTAssertFalse(presentation(outcome).label.isEmpty, "\(outcome) has an empty label")
        }
    }

    /// Labels must be real translations, not the raw lookup keys leaking
    /// through — which is what a missing entry in a .strings file looks like.
    func testLabelsAreResolvedNotRawKeys() {
        let all: [CollectorOutcome] = [
            .disabled, .unsupported, .producedData, .ranButEmpty,
            .notReady(.notInstalled), .notReady(.missingCredentials), .notReady(.unknown),
            .failed(.auth), .failed(.network), .failed(.parse),
            .failed(.permission), .failed(.http), .failed(.other),
        ]
        for outcome in all {
            let p = presentation(outcome)
            XCTAssertFalse(p.label.hasPrefix("collector_status."),
                           "\(outcome) label fell through to its key: \(p.label)")
            if let step = p.nextStep {
                XCTAssertFalse(step.hasPrefix("collector_status."),
                               "\(outcome) hint fell through to its key: \(step)")
            }
        }
    }
}
#endif
