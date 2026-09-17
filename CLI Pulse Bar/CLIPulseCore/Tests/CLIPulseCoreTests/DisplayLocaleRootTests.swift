#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import CLIPulseCore

/// What a language switch reaches once views are on screen, which the pure
/// tests in `LanguageChoiceTests` cannot see:
///
/// * every macOS scene and `NSHostingView` root applies `displayLocaleRoot()`,
///   so views format in the chosen language (a source guard: CI runs in en,
///   where a root without it formats exactly like one with it);
/// * a view reads the locale that root put in its environment;
/// * a child whose inputs did not change is rebuilt when keyed on the language.
///
/// The source scans stand in for running the app: `CLIPulseBarApp.swift` is in
/// the app target, which `swift test` does not build.
final class DisplayLocaleRootTests: XCTestCase {

    override func tearDown() {
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    // MARK: - Every root applies the display locale

    /// `…/CLI Pulse Bar`, the directory holding the app target and the package.
    private static let appsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
        .deletingLastPathComponent()    // …/Tests
        .deletingLastPathComponent()    // …/CLIPulseCore
        .deletingLastPathComponent()    // …/CLI Pulse Bar

    func test_everySceneRoot_appliesTheDisplayLocale() throws {
        let appFile = Self.appsRoot.appending(path: "CLI Pulse Bar/CLIPulseBarApp.swift")
        let source = SwiftSourceScan(try String(contentsOf: appFile, encoding: .utf8))
        let scenes = try XCTUnwrap(source.bodyOfFirstBlock(after: "some Scene"), "no `body: some Scene` in CLIPulseBarApp.swift")

        var found: [String] = []
        var missing: [String] = []
        for opener in scenes.matches(of: #"(?<![\w.])(MenuBarExtra|WindowGroup|Window|Settings)\b\s*[({]"#) {
            guard let content = scenes.firstBlock(from: opener.upperBound) else {
                missing.append("\(opener.text): content closure not found")
                continue
            }
            found.append(opener.text)
            if !content.contains(".displayLocaleRoot()") {
                missing.append("\(opener.text)\(content.prefix(80))…")
            }
        }

        XCTAssertTrue(found.contains { $0.hasPrefix("MenuBarExtra") } && found.count >= 5,
                      "found only \(found) — the scan is not reading the scenes")
        XCTAssertEqual(missing, [], "scene content without .displayLocaleRoot() formats dates in the system language")
    }

    func test_everyHostingViewRoot_appliesTheDisplayLocale() throws {
        let directories = [
            Self.appsRoot.appending(path: "CLI Pulse Bar"),
            Self.appsRoot.appending(path: "CLIPulseCore/Sources/CLIPulseCore"),
        ]
        var found: [String] = []
        var missing: [String] = []
        for directory in directories {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = SwiftSourceScan(try String(contentsOf: file, encoding: .utf8))
                for opener in source.matches(of: #"(?<![\w.])NSHosting(View|Controller)(<[^>]*>)?\("#) {
                    let site = "\(file.lastPathComponent): \(opener.text)"
                    found.append(site)
                    guard let arguments = source.parenthesized(endingOpenerAt: opener.upperBound),
                          arguments.contains(".displayLocaleRoot()") else {
                        missing.append(site)
                        continue
                    }
                }
            }
        }

        XCTAssertGreaterThanOrEqual(found.count, 3, "found only \(found) — the scan is not reading the sources")
        XCTAssertEqual(missing, [], "a hosting root without .displayLocaleRoot() formats dates in the system language")
    }

    // MARK: - Views read what the root put there

    /// The heatmap's month row read "Jan Feb Mar" under Chinese headings.
    ///
    /// Rendered, not read back as text: the month names are the only
    /// locale-dependent pixels in the grid, so if the view took them from
    /// anywhere but its environment (a bare `DateFormatter`, `.current`), the
    /// Korean and English renders would be identical.
    @MainActor
    func test_heatmapMonthRow_followsTheLocaleTheRootPutsInTheEnvironment() throws {
        // A language the system is not in, so a root that did nothing could not
        // pass by rendering the system language.
        let language = Locale.current.language.languageCode == .korean ? "ja" : "ko"
        let grid = UsageHeatmapGrid(archive: DailyUsageArchive(), weeks: 53)
        let english = try render(grid.environment(\.locale, Locale(identifier: "en_US")))
        let chosen = try render(grid.environment(\.locale, Locale(identifier: language)))

        XCTAssertEqual(try render(grid.environment(\.locale, Locale(identifier: language))), chosen,
                       "two renders of the same view differ, so comparing renders proves nothing")
        XCTAssertNotEqual(chosen, english, "the month row ignores the locale in its environment")

        LocaleOverrideStore.shared.set(language)
        let throughRoot = try render(grid.displayLocaleRoot())
        XCTAssertEqual(throughRoot, try render(grid.environment(\.locale, LocaleOverrideStore.shared.displayLocale)),
                       "displayLocaleRoot() does not put the display locale in the environment")
        XCTAssertNotEqual(throughRoot, english, "the month row under displayLocaleRoot() is still English")
    }

    @MainActor
    private func render(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "the view did not render")
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    // MARK: - Keyed children follow a switch

    /// What each body built, in order. Recorded rather than read back from the
    /// screen: the question is whether SwiftUI re-evaluated the body at all.
    @MainActor
    private enum BodyLog {
        static var headers: [String] = []
        static var cards: [String] = []
    }

    /// Stands in for the wizard's read-only account card: plain value inputs,
    /// no closures, text built from `L10n`.
    private struct ValueOnlyCard: View {
        let row: Int
        var body: some View {
            let title = L10n.tab.overview
            BodyLog.cards.append(title)
            return Text(title)
        }
    }

    /// Stands in for the wizard: observes the store, draws its own header, and
    /// lists the cards in a lazy stack the way the review step does.
    private struct ObservingList: View {
        @ObservedObject private var store = LocaleOverrideStore.shared

        var body: some View {
            let header = L10n.tab.sessions
            BodyLog.headers.append(header)
            return VStack {
                Text(header)
                ScrollView {
                    LazyVStack {
                        ForEach(0..<2, id: \.self) { row in
                            ValueOnlyCard(row: row)
                                .languageKeyed(store.override, row: row)
                        }
                    }
                }
            }
            .frame(width: 300, height: 200)
        }
    }

    /// Observing the store redraws the observer, but SwiftUI keeps the body of
    /// a child whose inputs compare equal. Without the key the header below is
    /// rebuilt in Korean and neither card is rebuilt at all, which is what the
    /// wizard's read-only account cards did.
    @MainActor
    func test_languageKeyedChildren_areRebuiltOnASwitch() throws {
        func text(_ key: String, _ language: String) throws -> String {
            let bundle = try XCTUnwrap(LocaleOverrideStore.bundle(forLocalization: language))
            return NSLocalizedString(key, bundle: bundle, comment: "")
        }
        let (jaCard, koCard, koHeader) = try (text("tab.overview", "ja"), text("tab.overview", "ko"), text("tab.sessions", "ko"))
        BodyLog.headers = []
        BodyLog.cards = []

        LocaleOverrideStore.shared.set("ja")
        let host = HostedWindow(ObservingList())
        defer { host.close() }
        host.pump { BodyLog.cards.filter { $0 == jaCard }.count >= 2 }
        XCTAssertGreaterThanOrEqual(BodyLog.cards.filter { $0 == jaCard }.count, 2, "cards never rendered: \(BodyLog.cards)")

        BodyLog.headers = []
        BodyLog.cards = []
        LocaleOverrideStore.shared.set("ko")
        host.pump { BodyLog.headers.contains(koHeader) && BodyLog.cards.filter { $0 == koCard }.count >= 2 }

        XCTAssertTrue(BodyLog.headers.contains(koHeader), "the observing view itself did not redraw: \(BodyLog.headers)")
        XCTAssertGreaterThanOrEqual(BodyLog.cards.filter { $0 == koCard }.count, 2,
                                    "a card was not rebuilt in the new language: \(BodyLog.cards)")
    }
}

// MARK: - Hosting

/// A SwiftUI view in a live, off-screen window, so it updates the way it does
/// in the app.
@MainActor
private final class HostedWindow {
    private let window: NSWindow

    init<Content: View>(_ content: Content) {
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
    }

    func close() { window.close() }

    /// Spins the run loop, where SwiftUI applies updates, until `done` holds or
    /// two seconds pass.
    func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        window.contentView?.layoutSubtreeIfNeeded()
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}

// MARK: - Source scanning

/// Just enough Swift lexing to find a call's closure or argument list: comments
/// are removed, and brackets inside string literals are not counted.
private struct SwiftSourceScan {
    let text: String

    init(_ source: String) {
        text = Self.strippingComments(source)
    }

    struct Match {
        let text: String
        /// Index just past the match.
        let upperBound: String.Index
    }

    func matches(of pattern: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: ns).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            return Match(text: String(text[range]), upperBound: range.upperBound)
        }
    }

    /// The contents of the first `{ … }` after `marker`.
    func bodyOfFirstBlock(after marker: String) -> SwiftSourceScan? {
        guard let range = text.range(of: marker),
              let body = firstBlock(from: range.upperBound) else { return nil }
        return SwiftSourceScan(body)
    }

    /// The contents of the first `{ … }` at or after `start`, stepping over a
    /// parenthesised argument list first (`Window("About", id: "about") {`).
    func firstBlock(from start: String.Index) -> String? {
        var index = start
        // The opener match may already have consumed the `(` or `{`.
        if index > text.startIndex {
            let previous = text[text.index(before: index)]
            if previous == "(" {
                guard let close = closing(")", openedBefore: index) else { return nil }
                index = text.index(after: close)
            } else if previous == "{" {
                guard let close = closing("}", openedBefore: index) else { return nil }
                return String(text[index..<close])
            }
        }
        guard let open = text[index...].firstIndex(of: "{") else { return nil }
        let inside = text.index(after: open)
        guard let close = closing("}", openedBefore: inside) else { return nil }
        return String(text[inside..<close])
    }

    /// The argument list of a call whose `(` ends just before `index`.
    func parenthesized(endingOpenerAt index: String.Index) -> String? {
        guard let close = closing(")", openedBefore: index) else { return nil }
        return String(text[index..<close])
    }

    /// The bracket that balances one already open before `start`.
    private func closing(_ bracket: Character, openedBefore start: String.Index) -> String.Index? {
        let opener: Character = bracket == ")" ? "(" : "{"
        var depth = 1
        var inString = false
        var previous: Character = " "
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if c == "\n" {
                inString = false
            } else if c == "\"" && previous != "\\" {
                inString.toggle()
            } else if !inString {
                if c == opener { depth += 1 }
                if c == bracket {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            previous = c
            index = text.index(after: index)
        }
        return nil
    }

    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var inString = false
        var inBlockComment = false
        var chars = Array(source)
        chars.append("\n")
        var i = 0
        while i < chars.count - 1 {
            let c = chars[i], next = chars[i + 1]
            if inBlockComment {
                if c == "*" && next == "/" { inBlockComment = false; i += 2 } else { i += 1 }
                continue
            }
            if !inString && c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if !inString && c == "/" && next == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
            // A string literal never spans a line here (multi-line literals are
            // not used around scene or hosting roots), so a newline resets it.
            if c == "\n" { inString = false }
            out.append(c)
            i += 1
        }
        return out
    }
}
#endif
