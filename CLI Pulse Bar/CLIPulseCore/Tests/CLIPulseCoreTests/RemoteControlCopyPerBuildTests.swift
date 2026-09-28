import XCTest
@testable import CLIPulseCore

/// Two user-facing claims that were untrue for the build most people have,
/// found while fact-checking the 1.54.0 App Review notes (2026-09-28).
///
/// 1. The iPhone's Nearby Macs empty state (`remote.no_macs`) told everyone to
///    turn on Settings › Remote Control on their Mac. The Mac draws that
///    section only when `RemoteControlFeature.isAvailable()` — off by default,
///    turned on only by the Developer ID updater's manifest — and the App Store
///    build has no switch in it at all.
/// 2. The Mac App Store build showed Settings › Advanced › "Mac control requests
///    from your other devices", but only the Developer ID build has the
///    executor that acts on those requests.
final class RemoteControlCopyPerBuildTests: XCTestCase {

    private static let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]

    /// Each catalogue's own word for the direct-download build, as its
    /// `machine.mas_affordance` already uses it.
    private static let directDownloadTerm: [String: String] = [
        "en": "direct-download",
        "zh-Hans": "直接下载",
        "zh-Hant": "直接下載",
        "ja": "直接ダウンロード",
        "ko": "직접 다운로드",
        "es": "descarga directa",
    ]

    /// What each language said before: an unconditional instruction to a switch
    /// most Macs never draw.
    private static let untrueInstruction: [String: String] = [
        "en": "On the Mac, turn on Settings › Remote Control.",
        "zh-Hans": "请在 Mac 上打开「设置 › 远程控制」。",
        "zh-Hant": "請在 Mac 上開啟「設定 › 遠端控制」。",
        "ja": "Mac で「設定 › リモート操作」をオンにしてください。",
        "ko": "Mac에서 설정 › 원격 제어를 켜세요.",
        "es": "En el Mac, activa Ajustes › Control remoto.",
    ]

    private func inLocale<T>(_ locale: String, _ body: () throws -> T) rethrows -> T {
        let store = LocaleOverrideStore.shared
        let saved = store.override
        defer { store.set(saved) }
        store.set(locale)
        return try body()
    }

    // MARK: - iPhone: Nearby Macs empty state

    /// The empty state names what is actually needed — the direct-download Mac
    /// build — in the catalogue's own term, and names the Mac's section by the
    /// title the Mac draws (`L10n.remote.title`), so "no such section" is
    /// something the user can check rather than a switch to hunt for.
    ///
    /// Asserted per language. In English a broken lookup still returns the
    /// English text, so an en-only check would pass with every translation
    /// missing.
    func test_noMacsNamesTheDirectDownloadBuildInEveryLanguage() {
        let english = inLocale("en") { L10n.remote.noMacs }

        for locale in Self.locales {
            let (text, affordance, sectionTitle) = inLocale(locale) {
                (L10n.remote.noMacs, L10n.machine.masAffordance, L10n.remote.title)
            }
            XCTAssertFalse(text.isEmpty, "\(locale): empty")
            XCTAssertFalse(text.hasPrefix("remote."), "\(locale) renders the raw key")
            if locale != "en" {
                XCTAssertNotEqual(text, english, "\(locale) shows the English text")
            }

            let term = Self.directDownloadTerm[locale]!
            // Positive control: the term is this catalogue's word for the build,
            // not one the test made up.
            XCTAssertTrue(affordance.contains(term),
                          "\(locale): machine.mas_affordance does not use \"\(term)\" — the catalogue changed its term")
            XCTAssertTrue(text.contains(term),
                          "\(locale): the empty state does not name the direct-download build: \(text)")
            XCTAssertTrue(text.contains("App Store"),
                          "\(locale): the empty state does not say the App Store version lacks it: \(text)")
            XCTAssertTrue(text.contains(sectionTitle),
                          "\(locale): the empty state does not name the Mac's \"\(sectionTitle)\" section: \(text)")
        }
    }

    /// The sentence the 1.54.0 fact-check found untrue must not come back in
    /// any language.
    func test_noMacsNoLongerSendsEveryoneToASwitchMostMacsLack() {
        for locale in Self.locales {
            let text = inLocale(locale) { L10n.remote.noMacs }
            let dead = Self.untrueInstruction[locale]!
            XCTAssertFalse(text.contains(dead), "\(locale) still says: \(dead)")
        }
    }

    // MARK: - Mac: Advanced › "Mac control requests from your other devices"

    #if os(macOS)
    /// The switch is offered exactly where the thing that acts on it exists.
    /// Compared against `AppState`'s actual stored properties rather than
    /// against a copy of the `#if`, so the predicate and the executor cannot
    /// drift apart. CI runs this in both passes: plain (the App Store path,
    /// false) and `-DDEVID_BUILD` (true).
    @MainActor
    func test_theMacControlRequestSwitchIsOfferedExactlyWhereTheExecutorExists() {
        let state = AppState()
        let stored = Set(Mirror(reflecting: state).children.compactMap(\.label))

        // Positive control: the mirror lists AppState's stored `let`s at all.
        // Without it, a mirror that saw nothing would make the plain pass
        // vacuous (false == false).
        XCTAssertTrue(stored.contains("lanAgent"),
                      "Mirror does not see AppState's stored properties; this test checks nothing")

        let hasExecutor = stored.contains("remoteMachineExecutor")
        XCTAssertEqual(MacControlRequests.areHonoredByThisBuild, hasExecutor,
                       "the Advanced switch and RemoteMachineExecutor disagree about this build")
        #if DEVID_BUILD
        XCTAssertTrue(MacControlRequests.areHonoredByThisBuild,
                      "the direct-download build acts on requests and must offer the switch")
        #else
        XCTAssertFalse(MacControlRequests.areHonoredByThisBuild,
                       "a build without the executor must not offer a switch it ignores")
        #endif
    }
    #endif

    /// `AdvancedSection` lives in the app target, which has no test bundle, so
    /// this is a source scan (as in `RemoteSessionPlaneRetirementTests`): the
    /// switch, its label and its consent card are drawn only inside the
    /// `MacControlRequests` gate, and nowhere else in the file.
    func test_theAdvancedSwitchIsDrawnOnlyInsideTheBuildGate() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = appDir.appendingPathComponent("CLI Pulse Bar/AdvancedSection.swift")
        let text = try String(contentsOf: file, encoding: .utf8)

        // Code only: the comment above the gate names the things it hides.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        let gate = "if MacControlRequests.areHonoredByThisBuild {"
        let parts = code.components(separatedBy: gate)
        XCTAssertEqual(parts.count, 2, "expected exactly one \(gate) in AdvancedSection")
        guard parts.count == 2 else { return }

        // The gate's block: from its `{` to the matching `}`.
        var depth = 1
        var end = parts[1].startIndex
        for i in parts[1].indices {
            if parts[1][i] == "{" { depth += 1 }
            if parts[1][i] == "}" { depth -= 1 }
            if depth == 0 { end = i; break }
        }
        XCTAssertEqual(depth, 0, "the gate's block never closes; the scan is wrong")
        let inside = String(parts[1][..<end])
        let outside = parts[0] + String(parts[1][end...])

        for marker in ["get: { state.remoteControlEnabled }",
                       "Text(L10n.advanced.remoteControl)",
                       "Text(L10n.advanced.remoteControlHint)",
                       "remoteControlConsentCard"] {
            XCTAssertTrue(inside.contains(marker), "the gate no longer contains \(marker)")
        }
        XCTAssertFalse(outside.contains("get: { state.remoteControlEnabled }"),
                       "the Mac control requests switch is drawn outside the build gate")
        XCTAssertFalse(outside.contains("Text(L10n.advanced.remoteControl)"),
                       "the switch's label is drawn outside the build gate")
        // Outside the gate the card may only be DEFINED, never drawn.
        let cardUses = outside.components(separatedBy: "remoteControlConsentCard").count - 1
        XCTAssertTrue(outside.contains("private var remoteControlConsentCard"),
                      "the consent card's definition moved; update this scan")
        XCTAssertEqual(cardUses, 1, "the consent card is drawn outside the build gate")

        // Positive controls, so a wrong path or an over-eager comment filter
        // cannot make the absences above vacuous.
        XCTAssertTrue(code.contains("struct AdvancedSection"), "this is not AdvancedSection")
        XCTAssertGreaterThan(code.count, text.count / 2,
                             "comment filter removed too much to be a real scan")
    }
}
