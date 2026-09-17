// Controls VoiceOver can only name after an SF Symbol, or not at all.
//
// A button or menu whose whole label is `Image(systemName:)` is announced with
// the symbol's own description ("power", "square.and.arrow.up", "Share") in the
// SYSTEM language, whatever language the app is set to; `.help` adds a hint
// after that name, it does not replace it. A `Slider` with no label is
// "adjustable, 40%", and a `Picker("", …)` is "pop-up button, USD":
// `.labelsHidden()` only hides a title from sight, so an empty one is no name.
//
// Review of this PR found each of these fixed at the site a finding named and
// left at the others: nine more `Picker("")`s, then eleven more icon-only
// controls beside the Quit button, and both fan sliders. So the class is swept,
// across every Apple UI source, rather than the sites pinned one by one.
//
// A structural test, not a locale one: the names themselves are asserted in ja
// in MenuBarReadoutTests.
import Foundation
import XCTest

final class UnnamedControlsSweepTests: XCTestCase {

    static let scannedDirectories = [
        "CLI Pulse Bar",
        "CLI Pulse Bar iOS",
        "CLI Pulse Bar Watch",
        "CLI Pulse Widgets",
        "CLIPulseCore/Sources/CLIPulseCore",
    ]

    func test_everyIconOnlyControlAndSliderHasAName() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CLIPulseCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // CLIPulseCore
            .deletingLastPathComponent()   // CLI Pulse Bar

        var scannedFiles = 0
        var namedControls = 0
        var unnamed: [String] = []
        for dir in Self.scannedDirectories {
            let base = appRoot.appendingPathComponent(dir)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil),
                                           "cannot enumerate \(dir)")
            var filesHere = 0
            for case let file as URL in enumerator {
                if file.pathComponents.contains(".build") { enumerator.skipDescendants(); continue }
                guard file.pathExtension == "swift" else { continue }
                filesHere += 1
                let findings = Self.scan(try String(contentsOf: file, encoding: .utf8))
                namedControls += findings.filter(\.named).count
                for finding in findings where !finding.named {
                    unnamed.append("\(dir)/\(file.lastPathComponent):\(finding.line): \(finding.kind)")
                }
            }
            XCTAssertGreaterThan(filesHere, 0, "no Swift sources under \(dir): the scan path is wrong")
            scannedFiles += filesHere
        }

        XCTAssertEqual(unnamed, [], """
            These controls have no VoiceOver name. Add `.accessibilityLabel(L10n…)` \
            with a localized name (the string a `.help` beside it already uses, where there is one):
            \(unnamed.joined(separator: "\n"))
            """)
        // Positive controls: a wrong path, or a scanner that matches nothing,
        // must not pass as "no unnamed controls".
        XCTAssertGreaterThan(scannedFiles, 150, "scanned too few files to be believable")
        XCTAssertGreaterThan(namedControls, 15, "the scanner recognised too few icon-only controls to be believable")
    }

    /// The scanner has to fire on the defect and stay quiet on its fixes, or a
    /// green result above says nothing.
    func test_scannerFlagsUnnamedControls_andAcceptsNamedOnes() {
        let source = """
            Button { quit() } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help(L10n.menu.quit)
            Menu { items } label: { Image(systemName: "ellipsis.circle") }
            Slider(value: $rpm, in: 0...6000, step: 100)
            Button { quit() } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .help(L10n.menu.quit)
            #endif
            .accessibilityLabel(L10n.menu.quit)
            Button { go() } label: { Label(L10n.x, systemImage: "power") }
            Button(action: go) { Image(systemName: "xmark").accessibilityLabel(L10n.common.close) }
            Slider(value: $rpm, in: 0...6000) { Text(L10n.machine.fanTarget) }
            Slider(
                value: $rpm, in: 0...6000,
                onEditingChanged: { _ in apply(")") })
                .disabled(busy)
                .accessibilityLabel(L10n.machine.fanTarget)
            // Button { } label: { Image(systemName: "in a comment") }
            let s = "label: { Image(systemName: \\"in a string\\") }"
            Picker("", selection: $mode) {
                Text(L10n.a).tag(0)
            }
            .labelsHidden()
            Picker("", selection: $mode) { items }
                .labelsHidden()
                .accessibilityLabel(L10n.display.mode)
            Picker(L10n.alerts.filter, selection: $filter) { items }.labelsHidden()
            let t = "Picker(\\"\\", selection: $x)"
            """
        let findings = Self.scan(source)
        XCTAssertEqual(findings.filter { !$0.named }.map(\.line), [1, 6, 7, 26])
        XCTAssertEqual(findings.filter(\.named).map(\.line), [8, 18, 19, 30])
    }

    // MARK: - Scanner

    struct Finding: Equatable {
        let line: Int
        let kind: String
        let named: Bool
    }

    /// Finds icon-only `label:` closures, `Button(action:) { Image }`,
    /// `Slider(…)` and `Picker("", …)` calls, and says whether each carries a
    /// name. Works on the source with string literals and comments blanked
    /// out, so neither can open a brace or look like a modifier.
    static func scan(_ source: String) -> [Finding] {
        let code = blankStringsAndComments(Array(source.utf8))
        let masked = String(decoding: code, as: UTF8.self)
        let openBrace = UInt8(ascii: "{"), openParen = UInt8(ascii: "(")
        var findings: [Finding] = []

        func line(at offset: Int) -> Int { code[..<offset].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) } }
        func slice(_ range: Range<Int>) -> String { String(decoding: code[range], as: UTF8.self) }
        func isIconOnly(_ body: String) -> Bool {
            body.contains("Image(systemName:")
                && !body.contains("Text(") && !body.contains("Label(") && !body.contains("accessibilityLabel")
        }

        // `label: { … }`: Button, Menu, Toggle, Picker …
        for start in offsets(of: #"label:\s*\{"#, in: masked) {
            guard let open = code[start...].firstIndex(of: openBrace),
                  let close = matching(code, from: open) else { continue }
            guard isIconOnly(slice((open + 1)..<close)) else { continue }
            findings.append(Finding(line: line(at: start), kind: "icon-only label",
                                    named: chainNames(code, after: close + 1)))
        }
        // `Button(action: …) { Image(systemName:) }`
        for start in offsets(of: #"\bButton\s*\("#, in: masked) {
            guard let parenOpen = code[start...].firstIndex(of: openParen),
                  let parenClose = matching(code, from: parenOpen),
                  slice(parenOpen..<parenClose).contains("action:"),
                  let open = nextNonSpace(code, from: parenClose + 1), code[open] == openBrace,
                  let close = matching(code, from: open),
                  isIconOnly(slice((open + 1)..<close)) else { continue }
            findings.append(Finding(line: line(at: start), kind: "icon-only Button(action:)",
                                    named: chainNames(code, after: close + 1)))
        }
        // `Slider(…)`: named by a trailing label closure or by the modifier chain.
        for start in offsets(of: #"\bSlider\s*\("#, in: masked) {
            guard let parenOpen = code[start...].firstIndex(of: openParen),
                  let parenClose = matching(code, from: parenOpen) else { continue }
            if let next = nextNonSpace(code, from: parenClose + 1), code[next] == openBrace {
                findings.append(Finding(line: line(at: start), kind: "Slider", named: true))
            } else {
                findings.append(Finding(line: line(at: start), kind: "Slider without a label",
                                        named: chainNames(code, after: parenClose + 1)))
            }
        }
        // `Picker("", …)`: the masked text keeps the quote marks and blanks
        // what is between them, so `""` here is an empty title and nothing else.
        for start in offsets(of: #"\bPicker\s*\(\s*""\s*,"#, in: masked) {
            guard let parenOpen = code[start...].firstIndex(of: openParen),
                  let parenClose = matching(code, from: parenOpen) else { continue }
            var end = parenClose
            if let next = nextNonSpace(code, from: parenClose + 1), code[next] == openBrace,
               let close = matching(code, from: next) {
                end = close
            }
            findings.append(Finding(line: line(at: start), kind: "Picker with an empty title",
                                    named: chainNames(code, after: end + 1)))
        }
        return findings.sorted { $0.line < $1.line }
    }

    /// The modifier chain that follows a view: the rest of its closing line,
    /// then every line that starts with `.` or `#if` / `#else` / `#endif`.
    private static func chainNames(_ code: [UInt8], after offset: Int) -> Bool {
        let rest = String(decoding: code[min(offset, code.count)...], as: UTF8.self)
        var lines = rest.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var chain = String(lines.popFirst() ?? "")
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.isEmpty || line.hasPrefix(".") || line.hasPrefix("#if") || line.hasPrefix("#else")
                || line.hasPrefix("#endif") else { break }
            chain += "\n" + line
        }
        return chain.contains(".accessibilityLabel(") || chain.contains(".accessibilityHidden(true)")
    }

    /// Byte offsets of each match. The masked text keeps every byte in place.
    private static func offsets(of pattern: String, in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { text.utf8.distance(from: text.utf8.startIndex, to: $0.lowerBound) }
        }
    }

    private static func nextNonSpace(_ code: [UInt8], from offset: Int) -> Int? {
        var i = offset
        while i < code.count, [0x20, 0x09, 0x0A, 0x0D].contains(code[i]) { i += 1 }
        return i < code.count ? i : nil
    }

    /// The index of the bracket that closes the one at `open` (`{` or `(`).
    private static func matching(_ code: [UInt8], from open: Int) -> Int? {
        let openByte = code[open]
        let closeByte = openByte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: ")")
        var depth = 0
        for i in open..<code.count {
            if code[i] == openByte { depth += 1 }
            if code[i] == closeByte { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    /// Blanks the inside of every string literal (interpolations included) and
    /// every comment with spaces, keeping newlines and the quote marks, so byte
    /// offsets and line numbers stay true. A control's name is never inside a
    /// literal, so nothing the scan needs is lost.
    static func blankStringsAndComments(_ input: [UInt8]) -> [UInt8] {
        var out = input
        let n = input.count
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), newline: UInt8 = 0x0A
        func at(_ i: Int, _ s: StaticString) -> Bool {
            let len = s.utf8CodeUnitCount
            guard i + len <= n else { return false }
            return (0..<len).allSatisfy { input[i + $0] == s.utf8Start[$0] }
        }
        func blank(_ range: Range<Int>) {
            for i in range where out[i] != newline { out[i] = 0x20 }
        }
        /// `i` is just past `\(`; returns the index just past its `)`.
        func endOfInterpolation(_ start: Int) -> Int {
            var i = start, depth = 1
            while i < n {
                if input[i] == quote { i = endOfString(i); continue }
                if input[i] == UInt8(ascii: "(") { depth += 1 }
                if input[i] == UInt8(ascii: ")") { depth -= 1; if depth == 0 { return i + 1 } }
                i += 1
            }
            return n
        }
        /// `i` is at the opening quote(s); returns the index just past the closing ones.
        func endOfString(_ start: Int) -> Int {
            let multiline = at(start, "\"\"\"")
            var i = start + (multiline ? 3 : 1)
            while i < n {
                if input[i] == backslash, i + 1 < n {
                    i = input[i + 1] == UInt8(ascii: "(") ? endOfInterpolation(i + 2) : i + 2
                    continue
                }
                if multiline ? at(i, "\"\"\"") : input[i] == quote { return i + (multiline ? 3 : 1) }
                if !multiline, input[i] == newline { return i }
                i += 1
            }
            return n
        }
        var i = 0
        while i < n {
            if at(i, "//") {
                let end = input[i...].firstIndex(of: newline) ?? n
                blank(i..<end); i = end
            } else if at(i, "/*") {
                var end = i + 2
                while end < n, !at(end, "*/") { end += 1 }
                end = min(end + 2, n)
                blank(i..<end); i = end
            } else if input[i] == quote {
                let end = endOfString(i)
                let quotes = at(i, "\"\"\"") ? 3 : 1
                if end - quotes > i + quotes { blank((i + quotes)..<(end - quotes)) }
                i = end
            } else {
                i += 1
            }
        }
        return out
    }
}
