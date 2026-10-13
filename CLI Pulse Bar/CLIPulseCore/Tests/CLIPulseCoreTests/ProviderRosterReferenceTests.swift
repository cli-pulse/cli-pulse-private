import XCTest

/// 1.57: the source-level half of "nothing offers or shows a retired
/// provider" (`ProviderRoster`; the behaviour is in `ProviderRosterTests`).
///
/// What unit tests cannot see is a new list that iterates `allCases` and so
/// offers Crof, Kimi K2 and CrossModel again, or wiring in targets without
/// unit tests (the Mac app, the Watch). This is a referential check: it reads
/// the code, so it fails on the code that would show them, not on a copy of
/// a list that might be wrong everywhere at once.
final class ProviderRosterReferenceTests: XCTestCase {

    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar

    /// Every `ProviderKind.allCases` outside tests, per file, and why each is
    /// not a list a person reads. A new one fails until it is either
    /// `ProviderKind.offered` or recorded here with its reason.
    private static let allowedAllCases: [String: (count: Int, reason: String)] = [
        "CLIPulseCore/Sources/CLIPulseCore/AppState.swift": (3, "the free-plan fallback order (Codex, Gemini, Claude), a tie-break index, and the one-time Keychain move of every kind's legacy items"),
        "CLIPulseCore/Sources/CLIPulseCore/ProviderAccountMigration.swift": (1, "marks one legacy-secret owner per kind among accounts already saved"),
        "CLIPulseCore/Sources/CLIPulseCore/ProviderAccountPresentation.swift": (1, "an ordering index for account groups; the rows themselves are filtered (`ProviderRoster.shown`)"),
    ]

    /// `.swift` files under the app's folder (every Xcode target and
    /// CLIPulseCore), tests, build output and the frozen CodexBar snapshot
    /// left out, as (path relative to `CLI Pulse Bar/`, text with `//`
    /// comments removed).
    private func sources() throws -> [(name: String, text: String)] {
        let skip: Set<String> = ["Tests", ".build", "DerivedData", "build", "codexbar"]
        guard let walker = FileManager.default.enumerator(
            at: Self.appRoot, includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot list \(Self.appRoot.path)")
            return []
        }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            if !Set(url.pathComponents).isDisjoint(with: skip) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .map { line in
                    guard let comment = line.range(of: "//") else { return line }
                    return String(line[..<comment.lowerBound])
                }
                .joined(separator: "\n")
            let base = Self.appRoot.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            out.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path, text))
        }
        return out
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func source(_ path: String) throws -> String {
        let matches = try sources().filter { $0.name == path }
        XCTAssertEqual(matches.count, 1, "expected \(path)")
        return try XCTUnwrap(matches.first?.text)
    }

    /// `text` with every run of whitespace, line breaks included, as one space,
    /// so a pin does not depend on where a line was wrapped.
    private func squeezed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let appState = "CLIPulseCore/Sources/CLIPulseCore/AppState.swift"

    /// The body of `AppState.loadProviderConfigs`, up to the next function.
    private func loadProviderConfigsBody() throws -> String {
        let text = try source(Self.appState)
        let start = try XCTUnwrap(
            text.range(of: "private func loadProviderConfigs("),
            "AppState.loadProviderConfigs moved or was renamed"
        )
        let rest = text[start.upperBound...]
        let end = rest.range(of: " func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func testAllCasesAppearsOnlyWhereItIsNotARosterAPersonReads() throws {
        let files = try sources()
        // Positive control: a moved folder must fail, not scan nothing.
        XCTAssertGreaterThan(files.count, 200, "scanned \(files.count) files under \(Self.appRoot.path)")

        var found: [String: Int] = [:]
        for file in files {
            let count = occurrences(of: "ProviderKind.allCases", in: file.text)
            if count > 0 { found[file.name, default: 0] += count }
        }
        for (name, count) in found {
            guard let allowed = Self.allowedAllCases[name] else {
                XCTFail("\(name) iterates ProviderKind.allCases \(count)x: a list a person reads must use ProviderKind.offered, or retired providers come back")
                continue
            }
            XCTAssertEqual(count, allowed.count, "\(name): \(allowed.reason)")
        }
        for name in Self.allowedAllCases.keys where found[name] == nil {
            XCTFail("\(name) no longer uses ProviderKind.allCases; drop it from the allowlist")
        }
    }

    func testTheMacProviderListIsTheOfferedRoster() throws {
        let text = try source("CLI Pulse Bar/ProviderSettingsSection.swift")
        XCTAssertEqual(occurrences(of: "ProviderKind.offered", in: text), 2)
    }

    func testBothWaysOfReadingSavedAccountsLeaveRetiredOnesOut() throws {
        let text = try source(Self.appState)
        // The QA/passive read, and the production read at launch, which
        // records the notice first (`ProviderRoster.configsKeptAtLaunch`;
        // the order inside it is in `ProviderRosterTests`).
        XCTAssertEqual(occurrences(of: "ProviderRoster.activeConfigs(", in: text), 1)
        XCTAssertEqual(occurrences(of: "ProviderRoster.configsKeptAtLaunch(", in: text), 1)
        // Who is owed the notice is asked only through it.
        XCTAssertEqual(occurrences(of: "hadUnconfirmedOperatorSetUp(", in: text), 0)
        XCTAssertEqual(occurrences(of: ".record(owed:", in: text), 0)
    }

    func testTheLaunchAsksWhoIsOwedWithTheKeysLoaded() throws {
        let body = try loadProviderConfigsBody()
        let loads = try XCTUnwrap(body.range(of: "providerConfigs[index].loadSecrets()"))
        let kept = try XCTUnwrap(body.range(of: "ProviderRoster.configsKeptAtLaunch("))
        XCTAssertLessThan(loads.lowerBound, kept.lowerBound,
                          "asked before the keys load, a saved Kimi K2 or CrossModel key never owes the notice")
        // The Mac passes a notice; only the iPhone passes none.
        let text = squeezed(body)
        XCTAssertEqual(occurrences(
            of: "let retiredProviderNotice: RetiredProviderNotice? = RetiredProviderNotice(defaults: defaults)",
            in: text), 1)
        XCTAssertEqual(occurrences(of: "notice: retiredProviderNotice", in: text), 1)
    }

    func testTheLaunchWritesBackTheKeptList() throws {
        let body = try loadProviderConfigsBody()
        let kept = try XCTUnwrap(body.range(of: "ProviderRoster.configsKeptAtLaunch("))
        let writes = try XCTUnwrap(body.range(of: "JSONEncoder().encode(providerConfigs)"))
        XCTAssertEqual(occurrences(of: "JSONEncoder().encode(providerConfigs)", in: body), 1)
        XCTAssertLessThan(kept.lowerBound, writes.lowerBound,
                          "written before the retired accounts are left out, every launch writes them back for the helper")
    }

    func testTheLaunchShowsANoticeStillPending() throws {
        // The notice is recorded while configs load; a launch shows it while
        // it is pending, which survives restarts until it is dismissed.
        let text = squeezed(try source(Self.appState))
        XCTAssertEqual(occurrences(
            of: "showsRetiredProviderNotice = RetiredProviderNotice(defaults: defaults).isPending",
            in: text), 1)
    }

    func testTheHelperLeavesRetiredAccountsOut() throws {
        // The LoginItem helper reads the saved accounts the app last wrote,
        // which keep retired ones until the app's first 1.57 launch writes
        // them back without: both of its reads leave them out, so their keys
        // are not even loaded.
        let text = try source("CLIPulseHelper/HelperDaemon.swift")
        XCTAssertEqual(occurrences(of: "ProviderRoster.activeConfigs(saved)", in: text), 2)
    }

    func testEveryPlaceRowsAreCommittedForDisplayLeavesRetiredOnesOut() throws {
        let mac = try source("CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift")
        XCTAssertEqual(occurrences(of: "ProviderRoster.shown(payload.providers)", in: mac), 1)
        XCTAssertEqual(occurrences(of: "ProviderRoster.shown(payload.providerAccounts)", in: mac), 1)
        // The Watch commits rows in three places: its own cloud fetch (rows and
        // accounts) and the two paths that take the iPhone's push.
        let watch = try source("CLI Pulse Bar Watch/WatchAppState.swift")
        XCTAssertEqual(occurrences(of: "ProviderRoster.shown(", in: watch), 4)
    }

    func testThePopoverShowsTheNoticeAndCanDismissIt() throws {
        let text = try source("CLI Pulse Bar/MenuBarView.swift")
        XCTAssertEqual(occurrences(of: "if state.showsRetiredProviderNotice", in: text), 1)
        XCTAssertEqual(occurrences(of: "state.dismissRetiredProviderNotice()", in: text), 1)
        XCTAssertEqual(occurrences(of: "L10n.menuBar.retiredProvidersNotice", in: text), 1)
    }
}
