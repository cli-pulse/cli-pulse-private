#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.56: CLI Pulse's own Google sign-in for Gemini (#404) is offered only
/// where it can work.
///
/// Every build through 1.55 shipped `GeminiOAuthManager.clientID` as the
/// placeholder `REPLACE_WITH_YOUR_CLIENT_ID…`. The Gemini editor still showed a
/// "Google OAuth" heading, "Uses your Google account. No API key needed." and a
/// "Connect Gemini" button, and the button's only result was "OAuth client ID
/// not configured — see docs/GEMINI_OAUTH_SETUP.md". Two other texts sent users
/// to it: the CLI-fallback note ("If the CLI Pulse Gemini login can't refresh")
/// and the expired-token error ("reconnect via CLI Pulse OAuth"), which fired
/// for Gemini CLI and Antigravity logins that CLI Pulse cannot reconnect.
final class GeminiOwnSignInTests: XCTestCase {

    private static let realLookingClientID =
        "123456789-abcdef.apps.googleusercontent.com"

    // MARK: - The decision

    func test_the_placeholder_is_not_a_configured_client() {
        XCTAssertFalse(
            GeminiOAuthManager.isConfiguredClientID(
                GeminiOAuthManager.placeholderClientID
            )
        )
        XCTAssertFalse(GeminiOAuthManager.isConfiguredClientID(""))
        XCTAssertTrue(
            GeminiOAuthManager.isConfiguredClientID(Self.realLookingClientID)
        )
    }

    func test_the_sign_in_is_offered_only_when_it_can_work_or_be_undone() {
        let placeholder = GeminiOAuthManager.placeholderClientID
        // Placeholder, nothing stored: nothing to offer. This is every
        // shipped build so far.
        XCTAssertFalse(
            GeminiOAuthManager.offersOwnSignIn(
                isConnected: false, clientID: placeholder
            )
        )
        // Tokens already stored: keep "Connected" and Disconnect reachable.
        XCTAssertTrue(
            GeminiOAuthManager.offersOwnSignIn(
                isConnected: true, clientID: placeholder
            )
        )
        // A real client: "Connect Gemini" can work.
        XCTAssertTrue(
            GeminiOAuthManager.offersOwnSignIn(
                isConnected: false, clientID: Self.realLookingClientID
            )
        )
    }

    /// GEMINI_OAUTH_SETUP.md Step 5 swaps the placeholder for the real ID.
    /// Done as a find-and-replace over GeminiOAuthManager.swift, that must
    /// change `clientID` and leave the sentinel the gate compares against:
    /// otherwise `clientID == placeholderClientID` with a real client, and
    /// "Connect Gemini" stays hidden and refused.
    func test_replacing_the_placeholder_in_the_source_leaves_the_sentinel_alone() throws {
        // Pinned in pieces, like the source, so this file survives the same
        // find-and-replace.
        XCTAssertEqual(
            GeminiOAuthManager.placeholderClientID,
            "REPLACE_WITH_" + "YOUR_CLIENT_ID" + ".apps.googleusercontent.com"
        )

        let lines = try Self.codeLines(Self.oauthManagerURL)
        let placeholder = "REPLACE_WITH_" + "YOUR_CLIENT_ID"
        let hits = lines.indices.filter { lines[$0].contains(placeholder) }
        // A build with a real client has no hit; one with the placeholder has
        // exactly the `clientID` declaration.
        XCTAssertEqual(
            hits.count,
            GeminiOAuthManager.isClientConfigured ? 0 : 1,
            "lines \(hits.map { $0 + 1 })"
        )
        for hit in hits {
            XCTAssertTrue(
                lines[hit].contains("public static let clientID = \""),
                "line \(hit + 1) would be rewritten with clientID: \(lines[hit])"
            )
        }
        let sentinel = lines.indices.filter {
            lines[$0].contains("static let placeholderClientID")
        }
        XCTAssertEqual(sentinel.count, 1)
    }

    func test_the_default_argument_reads_the_shipped_client_id() {
        XCTAssertEqual(
            GeminiOAuthManager.offersOwnSignIn(isConnected: false),
            GeminiOAuthManager.isConfiguredClientID(GeminiOAuthManager.clientID)
        )
        XCTAssertEqual(
            GeminiOAuthManager.isClientConfigured,
            GeminiOAuthManager.clientID != GeminiOAuthManager.placeholderClientID
        )
    }

    /// The button is hidden, but the guard inside the flow stays: anything that
    /// still reaches it is refused before a browser sheet is built.
    @MainActor
    func test_authorize_refuses_the_placeholder_before_opening_a_browser() async throws {
        try XCTSkipIf(
            GeminiOAuthManager.isClientConfigured,
            "this build has a real Gemini client ID"
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-own-sign-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = GeminiOAuthManager(
            secretStore: NoSecretStore(),
            deletionOutbox: GeminiCredentialDeletionOutbox(
                defaults: nil,
                storageKeyPrefix: "gemini-own-sign-in-\(UUID().uuidString)"
            ),
            credentialMutationLock: GeminiCredentialMutationLock(
                lockFilePath: dir.appendingPathComponent("lock").path
            ),
            sharedTokenFilePath: dir.appendingPathComponent("tokens.json").path
        )
        do {
            _ = try await manager.authorizeForEditing()
            XCTFail("authorizeForEditing ran with the placeholder client ID")
        } catch GeminiOAuthError.clientNotConfigured {
            // expected
        }
    }

    // MARK: - The expired-token message

    func test_only_cli_pulses_own_sign_in_is_told_to_reconnect_via_cli_pulse() {
        XCTAssertEqual(
            GeminiCollector.expiredTokenIssue(source: .keychain),
            .tokenExpiredReconnectOAuth
        )
        XCTAssertEqual(
            GeminiCollector.expiredTokenIssue(source: .file),
            .sessionExpiredSignInAgain
        )
        XCTAssertEqual(
            GeminiCollector.expiredTokenIssue(source: .antigravity),
            .sessionExpiredSignInAgain
        )
        for source in [GeminiCollector.TokenSource.file, .antigravity] {
            let text = CredentialProblem(
                "Gemini", GeminiCollector.expiredTokenIssue(source: source)
            ).englishText
            XCTAssertFalse(
                text.contains("CLI Pulse"),
                "\(source): \(text)"
            )
        }
    }

    // MARK: - The editor (app target, no unit tests: read its source)

    private static let editorURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .appendingPathComponent("CLI Pulse Bar/ProviderConfigEditor.swift")

    private static let oauthManagerURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .appendingPathComponent(
            "Sources/CLIPulseCore/Collectors/GeminiOAuthManager.swift"
        )

    private static let appProjectSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()   // CLI Pulse Bar

    /// Lines with `//` comments removed, so prose can name the calls freely.
    /// A `//` inside a string literal (a URL) is code, not a comment: cutting
    /// there would hide whatever follows it on the line.
    private static func codeLines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map(stripLineComment)
    }

    static func stripLineComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
            } else if ch == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = inString ? nil : ch
            index = line.index(after: index)
        }
        return line
    }

    /// The line holding the `}` that closes the first `{` at or after
    /// `start`, counting braces outside string literals; nil if it never
    /// closes. Expects comment-stripped lines.
    static func closingLine(ofDeclarationAt start: Int, in lines: [String]) -> Int? {
        var depth = 0
        var opened = false
        for index in start..<lines.count {
            var inString = false
            var escaped = false
            for ch in lines[index] {
                if inString {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == "\"" {
                        inString = false
                    }
                } else if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                    opened = true
                } else if ch == "}" {
                    depth -= 1
                    if opened && depth == 0 { return index }
                }
            }
        }
        return nil
    }

    func test_closing_line_counts_braces_not_indentation() {
        let lines = [
            "    private var rows: some View {",
            "        if a { Text(\"} not a brace {\") }",
            "        if b {",
            "    }",                      // closes `if b`, dedented by a reformat
            "        Text(\"x\")",
            "  }",                        // the real end, not four spaces
            "    var later: Int {",
            "    }",
        ]
        XCTAssertEqual(Self.closingLine(ofDeclarationAt: 0, in: lines), 5)
        XCTAssertEqual(
            Self.closingLine(ofDeclarationAt: 0, in: [
                "    private var rows: some View {",
                "        Text(\"x\")",
            ]),
            nil
        )
    }

    func test_comment_stripping_keeps_code_after_a_url() {
        XCTAssertEqual(
            Self.stripLineComment("let a = 1 // note"),
            "let a = 1 "
        )
        XCTAssertEqual(
            Self.stripLineComment(#"open("https://x.test"); L10n.providerConfig.connectGemini // c"#),
            #"open("https://x.test"); L10n.providerConfig.connectGemini "#
        )
        XCTAssertEqual(
            Self.stripLineComment(#"let s = "a \" // b"; x()"#),
            #"let s = "a \" // b"; x()"#
        )
    }

    /// The editor draws the sign-in rows only through the gate, and nothing
    /// else in the app draws "Connect Gemini" or starts the flow.
    func test_the_editor_draws_the_sign_in_only_behind_the_gate() throws {
        let lines = try Self.codeLines(Self.editorURL)
        func indices(_ needle: String) -> [Int] {
            lines.indices.filter { lines[$0].contains(needle) }
        }

        // The gate is the shared decision, not a copy of it.
        let gateDecl = indices("private var showsGeminiOwnSignIn: Bool")
        XCTAssertEqual(gateDecl.count, 1)
        if let decl = gateDecl.first {
            let body = lines[decl..<min(decl + 6, lines.count)].joined(separator: "\n")
            XCTAssertTrue(
                body.contains("GeminiOAuthManager.offersOwnSignIn("),
                body
            )
        }

        // The rows: the heading, "Connect Gemini", its note and the flow.
        let rowsDecl = indices("private var geminiOwnSignInRows: some View")
        XCTAssertEqual(rowsDecl.count, 1)
        guard let start = rowsDecl.first,
              let end = Self.closingLine(ofDeclarationAt: start, in: lines)
        else {
            return XCTFail("geminiOwnSignInRows not found, or never closes")
        }
        let rows = start...end
        // The rows are about 90 lines. A much longer range means the end was
        // found in the wrong place, and code after the rows would count as
        // gated.
        XCTAssertLessThan(rows.count, 120, "rows span lines \(start + 1)...\(end + 1)")
        for needle in [
            "L10n.providerConfig.googleOAuth",
            "L10n.providerConfig.connectGemini",
            "L10n.providerConfig.geminiUsesGoogle",
            ".authorizeForEditing(",
        ] {
            let at = indices(needle)
            XCTAssertFalse(at.isEmpty, "\(needle) is gone from the editor")
            XCTAssertTrue(
                at.allSatisfy { rows.contains($0) },
                "\(needle) is drawn outside geminiOwnSignInRows: lines \(at.map { $0 + 1 })"
            )
        }

        // Every use of the rows sits directly under `if showsGeminiOwnSignIn {`.
        let uses = indices("geminiOwnSignInRows").filter { $0 != start }
        XCTAssertEqual(uses.count, 1, "uses at lines \(uses.map { $0 + 1 })")
        for use in uses {
            let previous = lines[..<use]
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(previous, "if showsGeminiOwnSignIn {", "line \(use + 1)")
        }

        // Nothing else in the app projects offers the button or the flow.
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: Self.appProjectSources, includingPropertiesForKeys: nil
        ) else {
            return XCTFail("cannot list \(Self.appProjectSources.path)")
        }
        var elsewhere: [String] = []
        var scanned = 0
        let skipped: Set<String> = ["Tests", ".build", "DerivedData", "codexbar", ".git"]
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            if url.lastPathComponent == "ProviderConfigEditor.swift" { continue }
            scanned += 1
            let code = try Self.codeLines(url)
            for (index, line) in code.enumerated()
            where line.contains("L10n.providerConfig.connectGemini")
                || line.contains(".authorizeForEditing(")
                || line.contains("GeminiOAuthManager.shared.authorize(")
            {
                elsewhere.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the walk found too few sources")
        XCTAssertEqual(elsewhere, [], "the Gemini sign-in is reachable outside the gated editor rows")
    }
}

private struct NoSecretStore: ProviderSecretStoring {
    func save(key: String, value: String, accessGroup: String?) -> Bool { true }
    func load(key: String, accessGroup: String?) -> String? { nil }
    func delete(key: String, accessGroup: String?) -> Bool { true }
}
#endif
