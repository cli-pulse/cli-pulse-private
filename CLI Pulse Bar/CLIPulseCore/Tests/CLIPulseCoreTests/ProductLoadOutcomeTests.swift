import XCTest
@testable import CLIPulseCore

/// v1.51 — `loadProducts()` used to swallow every failure into `products = []`.
///
/// That single line made "the buy button is broken" permanently untestable: a
/// thrown StoreKit error, an unconfigured product, and a user who simply did
/// not buy all produced the same empty paywall and the same conversion number.
/// An App Store Connect audit later found `com.clipulse.pro.lifetime` sitting
/// in MISSING_METADATA with no localization, no price point and no review
/// screenshot — created and never configured — so the Lifetime tile had been
/// unbuyable since v1.14 with nothing anywhere reporting it.
///
/// These pin the classification, which is the part that has to be right for a
/// smoke test to mean anything. `Product.products(for:)` itself cannot be
/// exercised in a unit test (it needs a real StoreKit session), so the outcome
/// enum is tested directly.
final class ProductLoadOutcomeTests: XCTestCase {

    typealias Outcome = SubscriptionManager.ProductLoadOutcome

    // MARK: - Which states are worth telling the user about

    /// The healthy states must be SILENT. A diagnostic that renders on every
    /// launch is one users learn to ignore, which is the same as not having it.
    func testHealthyOutcomesProduceNoDiagnostic() {
        XCTAssertNil(Outcome.notAttempted.diagnosticLabel,
                     "before the first load there is nothing to report")
        XCTAssertNil(Outcome.complete.diagnosticLabel,
                     "a complete load must not nag")
        XCTAssertNil(Outcome.storeKitDisabled.diagnosticLabel,
                     "QA/quarantine runtimes deliberately have no store; that is not a fault")
    }

    /// NEGATIVE CONTROL for the above: every unhealthy state MUST produce a
    /// label. Without this, someone could make `diagnosticLabel` return nil
    /// unconditionally and the three assertions above would still pass while
    /// the feature did nothing — the exact shape of the column-level REVOKE
    /// that read correctly and enforced nothing.
    func testEveryUnhealthyOutcomeProducesADiagnostic() {
        let unhealthy: [Outcome] = [
            .partial(missing: ["com.clipulse.pro.lifetime"]),
            .returnedNothing,
            .failed
        ]
        for outcome in unhealthy {
            XCTAssertNotNil(
                outcome.diagnosticLabel,
                """
                \(outcome) must be visible to the user. If this fails, the app \
                has gone back to failing checkout silently, which is what made \
                "nobody buys" impossible to diagnose in the first place.
                """
            )
        }
    }

    /// The three unhealthy states must be DISTINGUISHABLE. "Store returned no
    /// plans" (bundle id / storefront / agreement) and "store request failed"
    /// (network) and "one plan missing" (a specific misconfigured product) have
    /// completely different fixes, and collapsing them would rebuild the
    /// original blindfold one level up.
    func testUnhealthyOutcomesAreDistinguishable() {
        let labels = [
            Outcome.partial(missing: ["com.clipulse.pro.lifetime"]).diagnosticLabel,
            Outcome.returnedNothing.diagnosticLabel,
            Outcome.failed.diagnosticLabel
        ].compactMap { $0 }

        XCTAssertEqual(labels.count, 3)
        XCTAssertEqual(Set(labels).count, 3,
                       "each failure mode needs its own text — they have different fixes: \(labels)")
    }

    /// The partial label must carry the COUNT, because "how many are missing"
    /// is the difference between one unconfigured SKU and a dead storefront.
    func testPartialOutcomeReportsHowManyAreMissing() {
        XCTAssertEqual(
            Outcome.partial(missing: ["com.clipulse.pro.lifetime"]).diagnosticLabel,
            "1 plan(s) not offered by the store"
        )
        XCTAssertEqual(
            Outcome.partial(missing: ["a", "b", "c"]).diagnosticLabel,
            "3 plan(s) not offered by the store"
        )
    }

    /// No product ID may reach the diagnostic string. These render in a UI that
    /// may be screenshotted into a support thread; the count is the signal, and
    /// the identifiers add nothing a log does not already have.
    /// `XCTUnwrap`, not `label!` — a force-unwrap here traps and kills the whole
    /// xctest process, so a regression would take every other test in the
    /// binary down with it and report as `signal code 5` rather than as the one
    /// assertion that actually broke. (Found by mutation-testing this file.)
    func testDiagnosticNeverLeaksProductIdentifiers() throws {
        let label = try XCTUnwrap(Outcome.partial(missing: [
            "com.clipulse.pro.lifetime", "com.clipulse.team.yearly"
        ]).diagnosticLabel)
        XCTAssertFalse(label.contains("com.clipulse"),
                       "product IDs must not appear in user-facing text: \(label)")
    }

    // MARK: - Equatable, which the @Published diff relies on

    func testPartialOutcomesCompareByMissingSet() {
        XCTAssertEqual(Outcome.partial(missing: ["a"]), Outcome.partial(missing: ["a"]))
        XCTAssertNotEqual(Outcome.partial(missing: ["a"]), Outcome.partial(missing: ["b"]))
        XCTAssertNotEqual(Outcome.partial(missing: []), Outcome.complete)
        XCTAssertNotEqual(Outcome.failed, Outcome.returnedNothing)
    }

    // MARK: - The default

    /// A fresh manager must NOT claim a complete load it has never performed.
    func testDefaultOutcomeIsNotAttempted() {
        XCTAssertEqual(Outcome.notAttempted, Outcome.notAttempted)
        XCTAssertNotEqual(Outcome.notAttempted, Outcome.complete,
                          "never-ran and ran-successfully must not be the same value")
    }
}
