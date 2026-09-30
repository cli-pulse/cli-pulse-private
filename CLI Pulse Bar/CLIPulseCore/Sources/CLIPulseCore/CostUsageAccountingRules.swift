// Derived from steipete/CodexBar
// Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift
// (`claudeCanonicalRowKey`, `shouldReplaceClaudeRow`, and the `isIncomplete`
// test and the session id lookup inside `parseClaudeFile`), at upstream commit
// 25bba9b7 (2026-09-28) (https://github.com/steipete/CodexBar). The rules come
// from upstream #3659 and #3688.
//
// Not verbatim:
//   * upstream keys a response with a two-case enum; here the key is a string
//     with the first identifier's length in it, so it can be stored in the
//     JSON cache and two different identities still cannot produce the same
//     key ("a:b" + "c" versus "a" + "b:c");
//   * the predicates take the decoded JSON values instead of upstream's row
//     type.
//
// Ours, not upstream's: carrying a log's counted responses from one scan to
// the next (`CostUsageClaudeLogState`). Upstream keeps every row of a log in
// its cache and merges new rows into them by key; CLI Pulse keeps per-day
// totals, plus the newest rows and a hash of every counted one while a log is
// being written to.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import Foundation

/// When a line of a local Claude log counts, and under which identity. (The
/// Codex rules are in `CodexTokenAccounting.swift`.)
enum CostUsageAccountingRules {

    // MARK: - Claude

    /// The identity under which the lines of one Claude response are counted
    /// once, or nil when a line has no usable identity and counts by itself.
    ///
    /// Claude Code writes a response as several lines (one per content block)
    /// that share `message.id` and `requestId`, each repeating the usage so far.
    /// A proxy in front of Claude Code can leave `requestId` out while still
    /// repeating the snapshot; then the session and message id identify the
    /// response, provided neither is blank. Identifiers are compared exactly.
    static func claudeResponseKey(messageId: String?, requestId: String?, sessionId: String?) -> String? {
        guard let messageId else { return nil }
        if let requestId {
            return "r\(messageId.utf8.count):\(messageId)\(requestId)"
        }
        guard isNonBlank(messageId), let sessionId, isNonBlank(sessionId) else { return nil }
        return "s\(sessionId.utf8.count):\(sessionId)\(messageId)"
    }

    /// The session a Claude log line belongs to, for `claudeResponseKey`.
    /// Claude Code writes `sessionId` on the line; proxies and other writers
    /// use `session_id` or put it in a `metadata` object.
    static func claudeSessionId(line: [String: Any], message: [String: Any]) -> String? {
        line["sessionId"] as? String
            ?? line["session_id"] as? String
            ?? (line["metadata"] as? [String: Any])?["sessionId"] as? String
            ?? (message["metadata"] as? [String: Any])?["sessionId"] as? String
    }

    /// A proxy's preliminary counter: written before the response finished,
    /// with a locally estimated input that knows nothing about the prompt
    /// cache. It is not billed. Claude Code's own lines always carry the two
    /// cache fields, and a line without `stop_reason` at all is an older
    /// complete log, so neither matches.
    static func isPreliminaryClaudeProxyUsage(
        message: [String: Any],
        usage: [String: Any],
        input: Int,
        output: Int
    ) -> Bool {
        message["stop_reason"] is NSNull
            && input > 0
            && output == 0
            && usage["cache_read_input_tokens"] == nil
            && usage["cache_creation_input_tokens"] == nil
    }

    /// Whether a later line of a response replaces what an earlier line of
    /// it recorded. The later line wins (the usage in a response's lines only
    /// grows), except that a preliminary estimate never replaces a line with
    /// real usage.
    static func claudeLineReplaces(existingIsIncomplete: Bool?, lineIsIncomplete: Bool) -> Bool {
        !lineIsIncomplete || existingIsIncomplete == nil || existingIsIncomplete == true
    }

    private static func isNonBlank(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#endif
