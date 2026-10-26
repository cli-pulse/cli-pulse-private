// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Claude/ClaudeWeb/ClaudeWebExtraRateWindowParser.swift
// and Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift
// (https://github.com/steipete/CodexBar), upstream commit d34fbb47 (2026-10-24).
// Ported: the seven keys the Daily Routines window may arrive under, their
// order, "first key whose value is an object wins", and "no numeric
// utilization, no row".
//
// Not verbatim:
//   * one parser for both of our response paths (OAuth `/api/oauth/usage` and
//     the claude.ai web `/usage`); both carry the windows as top-level keys of
//     the same shape, and upstream's two copies agree on the keys;
//   * the result is the integer percent and the raw `resets_at` string our
//     `ClaudeSnapshot` stores, not upstream's `NamedRateWindow`;
//   * the matched key is kept for tests only; nothing logs it.
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
import CoreFoundation
import Foundation

/// The Claude "Daily Routines" quota window, read from a usage response.
///
/// 1.59. Until 1.58 two lanes were read from the wrong keys:
///   * `seven_day_omelette` was shown as "Daily Routines". It was the key of
///     the Claude Design window, which Anthropic folded into the main limit;
///     upstream dropped that lane in May.
///   * `iguana_necktie` was shown as "Designs". Since October it is an object
///     of promotional cloud credits in dollars, with no `utilization`, so the
///     old parser showed "Designs 100% left" with the credit's expiry as the
///     reset time.
/// Neither key is read any more. Daily Routines comes from the first of
/// `keys` whose value is an object, and only when that object's
/// `utilization` is a number: a null or missing utilization is no row,
/// where 1.58 showed it as 100% left.
enum ClaudeRoutinesWindow {
    /// In upstream's order. The first one whose value is an object is used.
    static let keys: [String] = [
        "seven_day_routines",
        "seven_day_claude_routines",
        "claude_routines",
        "routines",
        "routine",
        "seven_day_cowork",
        "cowork",
    ]

    struct Window: Equatable, Sendable {
        /// Percent used, rounded, clamped at 0.
        let utilization: Int
        let resetsAt: String?
        /// Which of `keys` it came from.
        let sourceKey: String
    }

    static func parse(_ json: [String: Any]) -> Window? {
        guard let (object, key) = firstObject(in: json) else { return nil }
        guard let used = percent(object["utilization"]) else { return nil }
        return Window(
            utilization: max(0, Int(used.rounded())),
            resetsAt: object["resets_at"] as? String,
            sourceKey: key
        )
    }

    private static func firstObject(in json: [String: Any]) -> ([String: Any], String)? {
        for key in keys {
            if let object = json[key] as? [String: Any] { return (object, key) }
        }
        return nil
    }

    /// A JSON number. `JSONSerialization` hands `true`/`false` over as an
    /// `NSNumber` too, so a boolean is ruled out by its CF type.
    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
#endif
