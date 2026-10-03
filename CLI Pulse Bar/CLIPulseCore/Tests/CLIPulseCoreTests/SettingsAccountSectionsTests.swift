import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.55 — Settings › Privacy is shown wherever the popover can ask a question
/// that is answered or changed there.
///
/// A signed-in Mac whose account is not paired scans on the local route and is
/// asked about older logs, and after "Not now" it is offered "Choose again…",
/// which is in Settings › Privacy. Settings rendered Privacy for a paired
/// account and in local mode only, so on that Mac both answers led nowhere.
/// Plain values only, like the consent tests.
final class SettingsAccountSectionsTests: XCTestCase {

    private func sections(
        signedIn: Bool,
        paired: Bool,
        localMode: Bool = false,
        companionOffered: Bool = true
    ) -> SettingsAccountSections {
        SettingsAccountSections(
            isAuthenticated: signedIn,
            isPaired: paired,
            isLocalMode: localMode,
            runtimeOffersCompanionCLI: companionOffered,
            runtimeOffersBackgroundSync: true
        )
    }

    /// The defect, stated as a test.
    func testASignedInMacWhoseAccountIsNotPairedHasPrivacyAndCompanionCLI() {
        for localMode in [false, true] {
            let s = sections(signedIn: true, paired: false, localMode: localMode)
            XCTAssertTrue(s.privacy, "the older-logs switch and \"Choose again…\" are there")
            XCTAssertTrue(s.companionCLI, "the note in Privacy sends people there")
            XCTAssertFalse(
                s.pairedAccountSettings,
                "subscription, Remote Control and the picker still need a paired account"
            )
        }
    }

    func testAPairedAccountKeepsEverySection() {
        let s = sections(signedIn: true, paired: true)
        XCTAssertTrue(s.pairedAccountSettings)
        XCTAssertTrue(s.companionCLI)
        XCTAssertTrue(s.privacy)
    }

    func testLocalModeHasPrivacyAndCompanionCLIButNoAccountSettings() {
        let s = sections(signedIn: false, paired: false, localMode: true)
        XCTAssertTrue(s.privacy)
        XCTAssertTrue(s.companionCLI)
        XCTAssertFalse(s.pairedAccountSettings)
    }

    /// The sign-in form, without Privacy or Companion CLI. A stale pairing
    /// flag does not bring back the account's sections once signed out. (From
    /// 1.56 the Developer ID updater and background sync's part of Advanced
    /// are there too: `SettingsWithoutPairedAccountTests`.)
    func testASignedOutMacOutsideLocalModeShowsNone() {
        for paired in [false, true] {
            let s = sections(signedIn: false, paired: paired, localMode: false)
            XCTAssertFalse(s.privacy)
            XCTAssertFalse(s.companionCLI)
            XCTAssertFalse(s.pairedAccountSettings, "paired: \(paired)")
            XCTAssertEqual(s.advanced, .backgroundSync, "paired: \(paired)")
        }
    }

    /// Companion CLI also needs the runtime to offer it (the QA build does
    /// not); Privacy does not.
    func testCompanionCLIFollowsTheRuntimeAndPrivacyDoesNot() {
        for (signedIn, paired, localMode) in [(true, true, false), (true, false, false), (false, false, true)] {
            let s = sections(signedIn: signedIn, paired: paired, localMode: localMode, companionOffered: false)
            XCTAssertFalse(s.companionCLI)
            XCTAssertTrue(s.privacy)
        }
    }

    /// The invariant behind the fix, over every state: a Mac the popover asks
    /// (the first ask, the older-logs ask, "Choose again…"), or that reads this
    /// Mac at all, has Settings › Privacy.
    func testEveryMacThatIsAskedOrScansHasSettingsPrivacy() {
        var askedSignedInWithoutPairing = 0
        for signedIn in [false, true] {
            for paired in [false, true] {
                for localMode in [false, true] {
                    for demo in [false, true] {
                        for consent in LocalScanConsent.allCases {
                            for consentV2 in LocalScanConsent.allCases {
                                let asked = LocalCollectionPolicy.shouldPresentDisclosure(
                                    isAuthenticated: signedIn,
                                    isLocalMode: localMode,
                                    consent: consent
                                ) || LocalCollectionPolicy.shouldPresentV2Disclosure(
                                    isAuthenticated: signedIn,
                                    isLocalMode: localMode,
                                    isDemoMode: demo,
                                    consent: consent,
                                    consentV2: consentV2
                                ) || LocalCollectionPolicy.offersChoosingAgain(
                                    isAuthenticated: signedIn,
                                    isDemoMode: demo,
                                    consent: consent
                                )
                                let route = RefreshRouter.decide(
                                    isAuthenticated: signedIn,
                                    isDemoMode: demo,
                                    isPaired: paired,
                                    isLocalMode: localMode,
                                    isMacOS: true
                                )
                                let privacy = sections(
                                    signedIn: signedIn,
                                    paired: paired,
                                    localMode: localMode
                                ).privacy
                                let state = "signed in \(signedIn), paired \(paired), local mode \(localMode), demo \(demo), \(consent)/\(consentV2)"
                                if asked {
                                    XCTAssertTrue(privacy, "asked, with no Settings › Privacy: \(state)")
                                }
                                if route != .noOp {
                                    XCTAssertTrue(privacy, "scans, with no Settings › Privacy: \(state)")
                                }
                                if asked && signedIn && !paired { askedSignedInWithoutPairing += 1 }
                            }
                        }
                    }
                }
            }
        }
        // Control: the loop reached the state the fix is for.
        XCTAssertGreaterThan(askedSignedInWithoutPairing, 0)
    }

    /// The first ask's signed-in caption (`first_ask_hint_signed_in`) promises
    /// Settings › Privacy to every signed-in Mac, paired or not.
    func testTheSignedInCaptionsPromiseHolds() {
        for paired in [false, true] {
            XCTAssertTrue(sections(signedIn: true, paired: paired).privacy, "paired: \(paired)")
        }
        XCTAssertEqual(
            LocalScanQuestion.firstAsk.caption(isAuthenticated: true),
            L10n.localScanConsent.firstAskHintSignedIn
        )
    }
}

#endif
