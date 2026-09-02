import XCTest
@testable import CLIPulseCore

/// Remote-control M0 — the egress redactor that stands between the
/// helper's UNREDACTED `output_delta` stream and a phone on the LAN.
///
/// The tests that matter here are the two the acceptance criteria would
/// happily pass without: chunk-boundary splitting and ANSI interleaving.
/// A successful demo actively conceals both — the secret shows up on the
/// phone looking exactly like ordinary terminal output.
final class LANEgressRedactorTests: XCTestCase {

    // A realistic secret in a realistic line. `sk-ant-` is the shape the
    // repo's own users would actually leak.
    private let secret = "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH"

    /// A BARE token, with no `NAME_KEY=` in front of it — e.g. a CLI
    /// echoing a credential it just loaded. This is the hard case and the
    /// one the streaming buffer exists for.
    ///
    /// With an `export ANTHROPIC_API_KEY=` prefix the split is NOT
    /// dangerous, and it took a failing control to notice: the
    /// `NAME_KEY=\S+` line pattern matches the first chunk whatever the
    /// split point, so the leading fragment is always redacted and the
    /// whole secret can never reassemble. Testing only that shape would
    /// have produced a green suite that proved nothing.
    private var bareLine: String { "Loaded credential \(secret) from disk\n" }

    private func leaks(_ s: String) -> Bool { s.contains(secret) }

    // MARK: - Control: prove the naive approach actually leaks
    //
    // Without this, every test below could pass against a redactor that
    // does nothing surprising, and we would not know the streaming
    // machinery earns its complexity. This asserts the FAILURE we are
    // defending against is real in this codebase, with these patterns.

    func testControl_naivePerChunkRedactionLeaksAcrossASplit() {
        // Split so NEITHER side matches: the first chunk keeps fewer than
        // the 8 characters `sk-ant-[A-Za-z0-9_\-]{8,}` requires after the
        // prefix, and the second chunk has no `sk-` prefix at all.
        let line = bareLine
        let cutIndex = line.range(of: "sk-ant-a")!.upperBound
        let first = String(line[line.startIndex..<cutIndex])
        let second = String(line[cutIndex...])
        XCTAssertEqual(first + second, line, "split must be lossless")

        let naive = LANEgressRedactor.redact(first) + LANEgressRedactor.redact(second)

        // The control: per-chunk redaction reassembles into the secret.
        XCTAssertTrue(
            leaks(naive),
            """
            CONTROL FAILED — naive per-chunk redaction did NOT leak, so this \
            test can no longer prove the streaming buffer is doing real work. \
            Either the patterns changed or the split point stopped defeating \
            both of them. Fix this control before trusting the tests below.
            """
        )
    }

    // MARK: - Chunk boundaries

    func testStreaming_secretSplitAtEveryByteOffsetIsRedacted() {
        let text = bareLine
        // Every interior split point, not a sampled few: the failure is
        // offset-specific and a sample would miss it.
        for offset in 1..<text.count {
            let idx = text.index(text.startIndex, offsetBy: offset)
            let a = String(text[text.startIndex..<idx])
            let b = String(text[idx...])

            var stream = LANEgressRedactor.Streaming()
            var out = stream.submit(a)
            out += stream.submit(b)
            out += stream.flush()

            XCTAssertFalse(
                leaks(out),
                "secret leaked when split at offset \(offset): \(out.debugDescription)"
            )
        }
    }

    func testStreaming_isLosslessForOrdinaryOutput() {
        let text = "hello world\nsecond line\nthird"
        var stream = LANEgressRedactor.Streaming()
        var out = ""
        for ch in text {
            out += stream.submit(String(ch))
        }
        out += stream.flush()
        XCTAssertEqual(out, text, "no secret present, so nothing may be altered or dropped")
    }

    func testStreaming_emitsNothingBeforeALineIsComplete() {
        var stream = LANEgressRedactor.Streaming()
        XCTAssertEqual(stream.submit("partial line with no newline"), "")
        XCTAssertTrue(stream.hasPendingBytes)
        XCTAssertEqual(stream.submit(" and the rest\n"),
                       "partial line with no newline and the rest\n")
        XCTAssertFalse(stream.hasPendingBytes)
    }

    func testStreaming_forceEmitsWhenNoNewlineArrivesAndCapIsExceeded() {
        // A progress bar redrawing with \r never sends a newline. The
        // stream must not buffer forever.
        var stream = LANEgressRedactor.Streaming(maxCarry: 64, overlapWindow: 16)
        let blob = String(repeating: "x", count: 200)
        let out = stream.submit(blob)
        XCTAssertFalse(out.isEmpty, "cap exceeded, so something must be emitted")
        let total = out + stream.flush()
        XCTAssertEqual(total, blob, "force-emit must stay lossless")
    }

    func testStreaming_forceEmitStillProtectsASecretAtTheCut() {
        // Secret positioned so a naive cut at (count - overlap) bisects it.
        var stream = LANEgressRedactor.Streaming(maxCarry: 80, overlapWindow: 48)
        let padding = String(repeating: "x", count: 60)
        var out = stream.submit(padding + secret)
        out += stream.submit(" trailing\n")
        out += stream.flush()
        XCTAssertFalse(leaks(out), "secret leaked across the forced cut: \(out.debugDescription)")
    }

    // MARK: - ANSI interleaving

    func testAnsiInterleavedSecretFailsClosedRatherThanLeaking() {
        // Escape sequences inside the token defeat literal matching but
        // the terminal still renders the secret.
        let obfuscated = "export ANTHROPIC_API_KEY=sk-ant-\u{1B}[0mapi03-AAAABBBBCCCCDDDDEEEEFFFF"
        let out = LANEgressRedactor.redact(obfuscated)
        XCTAssertFalse(
            out.contains("api03-AAAABBBBCCCCDDDDEEEEFFFF"),
            "ANSI-obfuscated secret survived egress: \(out.debugDescription)"
        )
    }

    func testOrdinaryAnsiFormattingIsPreservedNotWithheld() {
        // Fail-closed must not mean "withhold every coloured line", or
        // the terminal is unreadable and someone will disable it.
        let coloured = "\u{1B}[32mBuild succeeded\u{1B}[0m\nall good\n"
        XCTAssertEqual(LANEgressRedactor.redact(coloured), coloured)
    }

    // MARK: - Idempotence
    //
    // Load-bearing: the Python .pkg helper already redacts output_delta,
    // so on that helper this runs over clean text. If redaction were not
    // idempotent, the marker itself would be re-mangled.

    func testRedactionIsIdempotent() {
        let once = LANEgressRedactor.redact(bareLine)
        XCTAssertEqual(LANEgressRedactor.redact(once), once)
        XCTAssertTrue(once.contains(LANEgressRedactor.redactionMarker))
        XCTAssertFalse(leaks(once))
    }

    func testKnownSecretShapesAreRedacted() {
        let cases = [
            "sk-ant-api03-AAAABBBBCCCCDDDDEEEE",
            "ghp_AAAABBBBCCCCDDDDEEEEFFFFGGGG",
            "AIzaSyAAAABBBBCCCCDDDDEEEEFFFFGGGG",
            "AKIAIOSFODNN7EXAMPLE",
            "npm_AAAABBBBCCCCDDDDEEEEFFFF",
            "xoxb-1234567890-abcdefghij",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghij",
        ]
        for c in cases {
            let out = LANEgressRedactor.redact("prefix \(c) suffix")
            XCTAssertFalse(out.contains(c), "not redacted: \(c)")
        }
    }

    func testEmptyAndPlainInputAreUnchanged() {
        XCTAssertEqual(LANEgressRedactor.redact(""), "")
        XCTAssertEqual(LANEgressRedactor.redact("$ ls -la\ntotal 0\n"), "$ ls -la\ntotal 0\n")
    }
}

/// Drift gate for a copied security constant.
///
/// `LANEgressRedactor`'s pattern lists are a port of
/// `HelperSwift/Sources/HelperKit/Redactor.swift`, because CLIPulseCore
/// is not allowed to depend on HelperKit. Two copies of a secret-matching
/// list silently diverge — the helper gains a provider's token shape, the
/// egress path does not, and the gap is invisible until it leaks.
///
/// This reads the HelperKit source at test time rather than comparing
/// against a snapshot, so it fails when the ORIGINAL moves, which is the
/// direction drift actually travels.
final class LANEgressRedactorDriftTests: XCTestCase {

    private func helperRedactorSource() throws -> String {
        // Tests/CLIPulseCoreTests/<file> → repo root is five levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let path = url
            .appendingPathComponent("HelperSwift/Sources/HelperKit/Redactor.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Extract the quoted regex literals from one `let <name>: [(String, ...)]`
    /// array, in source order.
    private func patternLiterals(in source: String, arrayNamed name: String) -> [String] {
        guard let start = source.range(of: "let \(name)") else { return [] }
        let tail = source[start.upperBound...]
        guard let close = tail.range(of: "\n    ]") else { return [] }
        let body = String(tail[tail.startIndex..<close.lowerBound])

        var out: [String] = []
        for rawLine in body.split(separator: "\n") {
            let l = rawLine.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("(\"") else { continue }   // skips // comment lines
            guard let first = l.firstIndex(of: "\"") else { continue }
            // Walk to the matching close quote, honouring backslash escapes.
            // Decode the Swift string literal to the value it evaluates
            // to, because that value is what we compare against. Source
            // text `\\s` is the two characters `\` + `s` at runtime, so a
            // raw-text comparison would report drift on every line even
            // when the lists are identical — which is exactly how this
            // test failed the first time it ran.
            var idx = l.index(after: first)
            var lit = ""
            var escaped = false
            while idx < l.endIndex {
                let c = l[idx]
                if escaped {
                    // Only the escapes these patterns actually use.
                    switch c {
                    case "\\": lit.append("\\")
                    case "\"": lit.append("\"")
                    case "n": lit.append("\n")
                    case "t": lit.append("\t")
                    default: lit.append("\\"); lit.append(c)
                    }
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    break
                } else {
                    lit.append(c)
                }
                idx = l.index(after: idx)
            }
            out.append(lit)
        }
        return out
    }

    func testPatternListsMatchHelperKitExactly() throws {
        let source = try helperRedactorSource()

        let helperLineKey = patternLiterals(in: source, arrayNamed: "lineKeyPatterns")
        let helperTokens = patternLiterals(in: source, arrayNamed: "tokenShapePatterns")

        // Guard the guard: if parsing silently returned nothing, this test
        // would pass while comparing empty to empty.
        XCTAssertGreaterThan(helperLineKey.count, 10,
                             "parsed too few lineKeyPatterns from HelperKit — parser broke, not the patterns")
        XCTAssertGreaterThan(helperTokens.count, 10,
                             "parsed too few tokenShapePatterns from HelperKit — parser broke, not the patterns")

        let mineLineKey = LANEgressRedactor.lineKeyPatterns.map(\.0)
        let mineTokens = LANEgressRedactor.tokenShapePatterns.map(\.0)

        XCTAssertEqual(
            mineLineKey, helperLineKey,
            """
            lineKeyPatterns drifted from HelperKit's Redactor. Add the pattern \
            in HelperSwift/Sources/HelperKit/Redactor.swift FIRST, then mirror \
            it into LANEgressRedactor — the helper is the source of truth.
            """
        )
        XCTAssertEqual(
            mineTokens, helperTokens,
            """
            tokenShapePatterns drifted from HelperKit's Redactor. Add the \
            pattern in HelperSwift/Sources/HelperKit/Redactor.swift FIRST, \
            then mirror it here.
            """
        )
    }

    func testMarkerMatchesHelperKit() throws {
        let source = try helperRedactorSource()
        XCTAssertTrue(
            source.contains("redactionMarker = \"\(LANEgressRedactor.redactionMarker)\""),
            "redaction marker drifted from HelperKit's"
        )
    }
}
