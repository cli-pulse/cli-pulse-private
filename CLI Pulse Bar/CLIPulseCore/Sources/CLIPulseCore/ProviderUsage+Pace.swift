// CodexBar-parity v1.23.0 G4 — UI-consumer bridge.
//
// Maps a `ProviderUsage` API snapshot onto the vendored UsagePace
// engine (`UsagePace`/`UsagePaceText`, Phase A / G4) so the macOS &
// iOS provider cards and the Mac menu-bar `.pace` mode can render a
// forecast. Pure Foundation; shared across macOS / iOS / watchOS
// (NOT `#if os(macOS)`-gated). Centralizing the mapping here keeps
// the vendored engine decoupled from the API schema and gives the
// SwiftUI views one tiny, unit-tested seam.
//
// Gemini 3.1 Pro R1 adoptions (2026-05-19):
//   * MEDIUM — require a *parsed, future* reset timestamp. If
//     `reset_time` is absent or not ISO8601, return nil and suppress
//     the pace UI rather than feed the engine an anchorless window
//     (no anchor ⇒ unstable `expectedUsedPercent`).
//   * MEDIUM — `paceMenuLabel` is an ultra-compact ▲/▼/≈ + delta%
//     form for the width-constrained macOS menu bar (arrow + integer
//     + "%" only ⇒ language-neutral, no new L10n keys).
//   * The engine itself gates to Codex/Claude with sufficient signal
//     (`UsagePaceText.session*`), so every accessor returns nil for
//     unsupported providers ⇒ callers get a universal graceful
//     fallback with no layout change.

import Foundation

public extension ProviderUsage {
    /// A `RateWindow` for the pace engine, or nil when there is no
    /// usable reset anchor. `ProviderUsage.usagePercent` is 0…1 while
    /// `RateWindow.usedPercent` is 0…100, hence the ×100.
    ///
    /// `windowMinutes` is the length of the window `reset_time` belongs to
    /// (`paceWindowMinutes`), nil when that is not known. It used to be nil
    /// always, and the engine then assumed 5 hours: for a Codex account
    /// whose headline is its weekly or 30-day window, the last 5 hours
    /// before that reset were paced as a 5-hour window ("▲NN%", "projected
    /// empty in …" against a week's quota). With no known length the engine
    /// now shows no pace at all (`UsagePaceText.sessionPace`).
    func paceRateWindow(now: Date = .init()) -> RateWindow? {
        guard let resetRaw = reset_time,
              let resetsAt = sharedISO8601Parse(resetRaw),
              resetsAt > now else { return nil }
        return RateWindow(
            usedPercent: usagePercent * 100,
            windowMinutes: paceWindowMinutes(resetsAt: resetsAt, now: now),
            resetsAt: resetsAt,
            resetDescription: resetRaw,
            nextRegenPercent: nil)
    }

    /// Localized pace summary ("12% in deficit · runs out in 3d"), or
    /// nil if not applicable.
    func paceSummary(now: Date = .init()) -> String? {
        guard let kind = providerKind,
              let window = paceRateWindow(now: now) else { return nil }
        return UsagePaceText.sessionSummary(provider: kind, window: window, now: now)
    }

    /// Structured pace detail (stage + expected-used) for richer card
    /// rendering, or nil if not applicable.
    func paceDetail(now: Date = .init()) -> UsagePaceText.WeeklyDetail? {
        guard let kind = providerKind,
              let window = paceRateWindow(now: now) else { return nil }
        return UsagePaceText.sessionDetail(provider: kind, window: window, now: now)
    }

    /// Ultra-compact menu-bar pace label: "▲12%" (burning into deficit
    /// vs expected pace), "▼8%" (building reserve), "≈" (on track), or
    /// nil if not applicable. Stays within macOS menu-bar width and
    /// needs no localization.
    func paceMenuLabel(now: Date = .init()) -> String? {
        guard let kind = providerKind,
              let window = paceRateWindow(now: now),
              let pace = UsagePaceText.sessionPace(provider: kind, window: window, now: now)
        else { return nil }
        switch pace.stage {
        case .onTrack:
            return "≈"
        case .slightlyAhead, .ahead, .farAhead:
            return "▲\(Int(abs(pace.deltaPercent).rounded()))%"
        case .slightlyBehind, .behind, .farBehind:
            return "▼\(Int(abs(pace.deltaPercent).rounded()))%"
        }
    }

    /// Length in minutes of the window whose reset is `reset_time`, or nil
    /// when it is not known.
    ///
    /// * Claude: the headline is the 5-hour window (300, as before), or, on a
    ///   plan without one, the week: `ClaudeResultBuilder` sets `reset_time` to
    ///   the headline's own reset, so a weekly tier with that reset means a
    ///   week. Rows with no tiers (older writers) keep 300; a reset that no
    ///   weekly tier shares gets no pace.
    /// * Codex: the headline is the session lane's window, or the weekly
    ///   lane's when the account has no session window, and that window may
    ///   be 5 hours, a week, 30 days, or a length the API did not say
    ///   (`CodexCollector.buildResult`). The length is the one carried by
    ///   the tier whose reset is the headline's; the session-role tier wins
    ///   when several share it, because that is the headline's lane. (The
    ///   binding cap gives the capped session tier the blocker's reset, so
    ///   both match then; the capped headline reads 0% left, and the engine
    ///   shows no pace for it either way.) A tier with no stored length is
    ///   read the way the bars read it (`CodexQuotaWindows.resolved`, which
    ///   the display projection has usually applied already): a length is
    ///   inferred from its name, and for the session-lane names from how far
    ///   away its reset is. A tier whose length is neither stored nor
    ///   inferable that way gets no pace.
    /// * Copilot (1.61, P3): the headline is the Premium quota's monthly
    ///   window; its tier's length, or for a tier written before 1.61 (no
    ///   length stored) the calendar month ending at the reset
    ///   (`CopilotQuotaWindow`).
    /// * Anything else: nil. The engine paces Codex, Claude and Copilot only.
    func paceWindowMinutes(resetsAt: Date, now: Date = .init()) -> Int? {
        switch providerKind {
        case .claude?:
            if tiers.isEmpty { return Self.claudeSessionMinutes }
            if let fiveHour = WatchRingMath.fiveHourTier(self) {
                // The 5-hour row is the headline unless its own reset says otherwise.
                guard let reset = fiveHour.reset_time.flatMap(sharedISO8601Parse),
                      abs(reset.timeIntervalSince(resetsAt)) >= Self.resetMatchTolerance
                else { return Self.claudeSessionMinutes }
            }
            let week = tiers.first { tier in
                guard tier.role != .credits,
                      tier.windowMinutes == Self.weekMinutes
                          || (tier.windowMinutes == nil && tier.name.localizedCaseInsensitiveContains("week")),
                      let reset = tier.reset_time.flatMap(sharedISO8601Parse) else { return false }
                return abs(reset.timeIntervalSince(resetsAt)) < Self.resetMatchTolerance
            }
            return week == nil ? nil : Self.weekMinutes
        case .codex?:
            let matching = tiers
                .map { CodexQuotaWindows.resolved($0, now: now) }
                .filter { tier in
                    guard tier.role != .credits,
                          let reset = tier.reset_time.flatMap(sharedISO8601Parse)
                    else { return false }
                    return abs(reset.timeIntervalSince(resetsAt)) < Self.resetMatchTolerance
                }
            let tier = matching.first { $0.role == .primary } ?? matching.first
            guard let minutes = tier?.windowMinutes, minutes > 0 else { return nil }
            return minutes
        case .copilot?:
            let tier = tiers.first {
                guard let reset = $0.reset_time.flatMap(sharedISO8601Parse) else { return false }
                return abs(reset.timeIntervalSince(resetsAt)) < Self.resetMatchTolerance
            }
            if let minutes = tier?.windowMinutes, minutes > 0 { return minutes }
            return CopilotQuotaWindow.minutes(endingAt: resetsAt)
        default:
            return nil
        }
    }
}

private extension ProviderUsage {
    static let claudeSessionMinutes = 300
    static let weekMinutes = 7 * 24 * 60
    /// The headline and its tier are written from the same date by the same
    /// writer; the slack only absorbs a writer that rounds one of them.
    static let resetMatchTolerance: TimeInterval = 60
}
