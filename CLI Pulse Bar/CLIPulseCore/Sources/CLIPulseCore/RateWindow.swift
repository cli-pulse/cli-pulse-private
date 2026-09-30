// Derived from steipete/CodexBar
// Sources/CodexBarCore/UsageFetcher.swift (the `RateWindow` struct only)
// and Sources/CodexBarCore/RateWindow+BindingCap.swift (the binding-quota
// projection at the end of this file, taken at upstream commit 25bba9b7,
// 2026-09-28) (https://github.com/steipete/CodexBar). Vendored verbatim
// except for the project-style adjustments noted below.
//
// Binding cap, not verbatim in one respect: upstream keeps it in its own
// `RateWindow+BindingCap.swift`; here it sits beside the type it extends
// (4-space style). The logic, names and public surface are upstream's. The
// adapter that applies it to CLI Pulse's tier rows is ours
// (`QuotaBindingCap.swift`), because upstream feeds it `UsageSnapshot` lanes
// we do not have.
//
// CodexBar-parity Phase A / G4 — rate-limit window value type backing the
// pace/forecast engine (`UsagePace`/`UsagePaceText`). Pure Foundation;
// shared across macOS + iOS + watchOS (NOT `#if os(macOS)` gated).
// `NamedRateWindow` / `ProviderIdentitySnapshot` are intentionally NOT
// vendored here — they depend on CodexBar's `UsageProvider` and are not
// needed by the G4 engine.
//
// Note: `CodexCollector` already has a *nested* `CodexCollector.RateWindow`
// with a different shape; this top-level public `RateWindow` does not clash.
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

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        nextRegenPercent: Double? = nil)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    public func backfillingResetTime(from cached: RateWindow?, now: Date = .init()) -> RateWindow {
        if self.resetsAt != nil { return self }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        return RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: self.windowMinutes ?? cached?.windowMinutes,
            resetsAt: cachedReset,
            resetDescription: self.resetDescription ?? cached?.resetDescription,
            nextRegenPercent: self.nextRegenPercent)
    }
}

// MARK: - Binding quota projection (upstream RateWindow+BindingCap.swift)

public struct RateWindowBindingQuotaProjection: Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(usedPercent: Double, resetsAt: Date?, resetDescription: String?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }
}

extension RateWindow {
    /// The primary slot is the session lane even when a provider omits duration metadata.
    private static let sessionWindowMinutes = 5 * 60

    /// Projects the displayed primary percentage and reset through exhausted longer binding lanes.
    /// Raw primary detail remains owned by the primary lane and is not replaced by this projection.
    public static func bindingQuotaProjection(
        primary: RateWindow,
        bindingLanes: [RateWindow],
        now: Date) -> RateWindowBindingQuotaProjection?
    {
        let primaryMinutes = primary.windowMinutes ?? Self.sessionWindowMinutes
        let exhaustedBindingLanes = bindingLanes.filter { lane in
            guard let minutes = lane.windowMinutes, minutes > primaryMinutes else { return false }
            return Self.isActivelyExhausted(lane, now: now)
        }
        guard !exhaustedBindingLanes.isEmpty else { return nil }

        var blockers = exhaustedBindingLanes
        if Self.isActivelyExhausted(primary, now: now) {
            blockers.append(primary)
        }
        let reset = Self.effectiveReset(blockers: blockers)
        return RateWindowBindingQuotaProjection(
            usedPercent: 100,
            resetsAt: reset.date,
            resetDescription: reset.description)
    }

    private static func isActivelyExhausted(_ window: RateWindow, now: Date) -> Bool {
        guard window.remainingPercent <= 0 else { return false }
        return window.resetsAt.map { $0 > now } ?? true
    }

    /// All exhausted gates must reset before the primary lane is usable again. Do not promise an
    /// earlier known reset when another active blocker has no comparable reset date.
    private static func effectiveReset(blockers: [RateWindow]) -> (date: Date?, description: String?) {
        let unknownResetBlockers = blockers.filter { $0.resetsAt == nil }
        if !unknownResetBlockers.isEmpty {
            let description = unknownResetBlockers[0].resetDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard blockers.count == 1, let description, !description.isEmpty else { return (nil, nil) }
            return (nil, description)
        }

        let latest = blockers.max { lhs, rhs in
            guard let lhsReset = lhs.resetsAt, let rhsReset = rhs.resetsAt else { return false }
            return lhsReset < rhsReset
        }
        return (latest?.resetsAt, nil)
    }
}
