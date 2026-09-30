// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Codex/CodexRateWindowNormalizer.swift
// (https://github.com/steipete/CodexBar), upstream commit 25bba9b7
// (2026-09-28). Vendored verbatim except for the adjustments noted below.
//
// Codex reports its rate limits in two slots, `primary_window` and
// `secondary_window`, and the slot says nothing about the window's length:
// an account with only a weekly limit gets it in `primary_window`. This puts
// each window in the lane its DURATION (`limit_window_seconds`) says it
// belongs to — 300 minutes is the session lane, 10080 the weekly lane — and
// leaves a window of unknown duration in the slot it came in.
//
// Not verbatim:
//   * 4-space style;
//   * the `#if DEBUG _normalizeForTesting` shim is dropped — the tests use
//     `@testable import`, which reaches `internal` directly;
//   * `switch` expressions written as `return` statements, so the file builds
//     under every Swift toolchain the CI matrix runs.
// Behaviour is unchanged. `CodexCollector.buildResult` is the only caller;
// it names and tags the tiers from the lanes this returns.
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

import Foundation

enum CodexRateWindowNormalizer {
    static func normalize(
        primary: RateWindow?,
        secondary: RateWindow?)
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        switch (primary, secondary) {
        case let (.some(primaryWindow), .some(secondaryWindow)):
            switch (self.role(for: primaryWindow), self.role(for: secondaryWindow)) {
            case (.session, .weekly), (.session, .unknown), (.unknown, .weekly):
                return (primaryWindow, secondaryWindow)
            case (.weekly, .session), (.weekly, .unknown):
                return (secondaryWindow, primaryWindow)
            default:
                return (primaryWindow, secondaryWindow)
            }
        case let (.some(primaryWindow), .none):
            switch self.role(for: primaryWindow) {
            case .weekly:
                return (nil, primaryWindow)
            case .session, .unknown:
                return (primaryWindow, nil)
            }
        case let (.none, .some(secondaryWindow)):
            switch self.role(for: secondaryWindow) {
            case .session, .unknown:
                return (secondaryWindow, nil)
            case .weekly:
                return (nil, secondaryWindow)
            }
        case (.none, .none):
            return (nil, nil)
        }
    }

    private enum WindowRole {
        case session
        case weekly
        case unknown
    }

    private static func role(for window: RateWindow) -> WindowRole {
        switch window.windowMinutes {
        case 300:
            return .session
        case 10080:
            return .weekly
        default:
            return .unknown
        }
    }
}
