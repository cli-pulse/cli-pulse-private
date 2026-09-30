import Foundation

/// Codex quota windows, named by how long they are, and the one display rule
/// that follows from having two of them: while the weekly window is used up,
/// the 5-hour window is too.
///
/// **What people saw.** Codex returns a 5-hour and a weekly window. The card
/// drew each as its own bar and the provider's headline reading (the menu bar
/// "%", the quota badge, the widget ring) came from the 5-hour one. With the
/// weekly limit spent, Codex refuses every request until the weekly reset —
/// and the card still said "60% left" on the 5-hour bar, with a green "OK".
///
/// **The rule** is CodexBar's binding cap (`RateWindow.bindingQuotaProjection`,
/// vendored in `RateWindow.swift`): a LONGER window that is exhausted and has
/// not reset yet makes the session window read exhausted too, with the reset
/// of whatever unblocks it last. It is a display projection only. Collector
/// results, the rows uploaded to `provider_quotas`, and the quota alerts all
/// keep the raw numbers; `projectedForDisplay` is applied where refreshed data
/// is handed to the UI (`AppState.applyRefreshPayload`, the Watch's own
/// assignments), so every surface — card, menu bar, widget, Watch — reads the
/// same projected value.
///
/// **Rows from older writers.** Before 1.55 no writer stored a Codex tier's
/// `role` or `windowMinutes` (the collector never set them, and the Mac app's
/// direct upload dropped both anyway), and every writer named the API's
/// primary SLOT as the 5-hour window ("5h Window", or "Session" from the
/// helpers) whatever it held. Those rows stay in the cloud as they are (the
/// stored names are not rewritten); the display infers role and length from
/// the name and, for the primary slot's names, from how far away the reset is
/// (`CodexQuotaWindows.resolved`).
///
/// Codex only. CodexBar applies the same cap to Claude and several others;
/// widening it is a separate decision, not a side effect of this one.
public enum QuotaBindingCap {

    /// Providers whose longer window gates the session window on screen.
    static let providers: Set<String> = [ProviderKind.codex.rawValue]

    // MARK: - Public entry points

    public static func projectedForDisplay(
        _ usages: [ProviderUsage],
        now: Date = Date()
    ) -> [ProviderUsage] {
        usages.map { projectedForDisplay($0, now: now) }
    }

    public static func projectedForDisplay(
        _ accounts: [ProviderAccountUsage],
        now: Date = Date()
    ) -> [ProviderAccountUsage] {
        accounts.map { projectedForDisplay($0, now: now) }
    }

    /// The provider as the UI should show it. Idempotent: projecting a
    /// projected value changes nothing, so a surface that receives already
    /// projected data (the Watch, from the iPhone) can apply it again safely.
    public static func projectedForDisplay(
        _ usage: ProviderUsage,
        now: Date = Date()
    ) -> ProviderUsage {
        guard providers.contains(usage.provider) else { return usage }
        let result = project(tiers: usage.tiers, now: now)
        let headline = result.cap.map {
            projectedHeadline(
                quota: usage.quota,
                remaining: usage.remaining,
                statusText: usage.status_text,
                reset: $0.resetTime
            )
        }
        return ProviderUsage(
            provider: usage.provider,
            today_usage: usage.today_usage,
            week_usage: usage.week_usage,
            estimated_cost_today: usage.estimated_cost_today,
            estimated_cost_week: usage.estimated_cost_week,
            estimated_cost_30_day: usage.estimated_cost_30_day,
            cost_status_today: usage.cost_status_today,
            cost_status_week: usage.cost_status_week,
            quota: usage.quota,
            remaining: headline?.remaining ?? usage.remaining,
            plan_type: usage.plan_type,
            reset_time: headline.map(\.resetTime) ?? usage.reset_time,
            tiers: result.tiers,
            status_text: headline?.statusText ?? usage.status_text,
            trend: usage.trend,
            recent_sessions: usage.recent_sessions,
            recent_errors: usage.recent_errors,
            metadata: usage.metadata
        )
    }

    /// Same projection for one account of a multi-account provider.
    public static func projectedForDisplay(
        _ account: ProviderAccountUsage,
        now: Date = Date()
    ) -> ProviderAccountUsage {
        guard providers.contains(account.provider.rawValue) else { return account }
        let result = project(tiers: account.tiers, now: now)
        let headline = result.cap.map {
            projectedHeadline(
                quota: account.quota,
                remaining: account.remaining,
                statusText: account.statusText,
                reset: $0.resetTime
            )
        }
        return ProviderAccountUsage(
            id: account.id,
            provider: account.provider,
            accountLabel: account.accountLabel,
            planEvidence: account.planEvidence,
            quota: account.quota,
            remaining: headline?.remaining ?? account.remaining,
            tiers: result.tiers,
            resetTime: headline.map(\.resetTime) ?? account.resetTime,
            observedAt: account.observedAt,
            sourceDeviceID: account.sourceDeviceID,
            statusText: headline?.statusText ?? account.statusText
        )
    }

    // MARK: - Tier projection

    struct TierProjection {
        /// Every tier, with `role`/`windowMinutes` resolved and the session
        /// tier capped when `cap` is set.
        let tiers: [TierDTO]
        /// Set exactly when the cap applied.
        let cap: Cap?
    }

    struct Cap: Equatable {
        /// The reset the capped session tier shows: the last of the blockers'
        /// resets, or `nil` when a blocker has no known reset (the cap never
        /// promises an earlier one).
        let resetTime: String?
    }

    static func project(tiers: [TierDTO], now: Date) -> TierProjection {
        let resolved = tiers.map { CodexQuotaWindows.resolved($0, now: now) }
        guard
            let sessionIndex = resolved.firstIndex(where: {
                $0.role == .primary && $0.quota > 0
            })
        else {
            return TierProjection(tiers: resolved, cap: nil)
        }
        let session = resolved[sessionIndex]
        let lanes = resolved.indices
            .filter {
                $0 != sessionIndex
                    && resolved[$0].role == .secondary
                    && resolved[$0].quota > 0
            }
            .map { resolved[$0] }
        guard
            let projection = RateWindow.bindingQuotaProjection(
                primary: rateWindow(session),
                bindingLanes: lanes.map(rateWindow),
                now: now
            )
        else {
            return TierProjection(tiers: resolved, cap: nil)
        }

        // Keep the blocker's own reset string when there is one, so the
        // session bar and the weekly bar print the identical reset.
        let resetTime: String? = projection.resetsAt.map { date in
            ([session] + lanes).first {
                $0.reset_time.flatMap(sharedISO8601Parse) == date
            }?.reset_time ?? sharedISO8601Formatter.string(from: date)
        }
        let usedUnits = Int(
            (Double(session.quota) * projection.usedPercent / 100).rounded(.up)
        )
        var projected = resolved
        projected[sessionIndex] = TierDTO(
            name: session.name,
            quota: session.quota,
            remaining: max(0, session.quota - usedUnits),
            reset_time: resetTime,
            windowMinutes: session.windowMinutes,
            role: session.role
        )
        return TierProjection(tiers: projected, cap: Cap(resetTime: resetTime))
    }

    private static func rateWindow(_ tier: TierDTO) -> RateWindow {
        let used = tier.quota > 0
            ? Double(tier.quota - tier.remaining) / Double(tier.quota) * 100
            : 0
        return RateWindow(
            usedPercent: used,
            windowMinutes: tier.windowMinutes,
            resetsAt: tier.reset_time.flatMap(sharedISO8601Parse),
            resetDescription: nil
        )
    }

    // MARK: - Headline

    private struct Headline {
        let remaining: Int?
        let resetTime: String?
        let statusText: String
    }

    /// The provider's single reading. For Codex it has always been the
    /// session window's; while the cap holds, the provider cannot be used at
    /// all, so the reading is exhausted whichever window it came from.
    private static func projectedHeadline(
        quota: Int?,
        remaining: Int?,
        statusText: String,
        reset: String?
    ) -> Headline {
        let projectedRemaining: Int? = {
            guard let quota, quota > 0 else { return remaining }
            return 0
        }()
        return Headline(
            remaining: projectedRemaining,
            resetTime: reset,
            statusText: isPercentUsedSentinel(statusText) ? "100% used" : statusText
        )
    }

    /// `CodexCollector` writes "<n>% used" from the session window. Any other
    /// status line is left alone.
    private static func isPercentUsedSentinel(_ raw: String) -> Bool {
        let suffix = "% used"
        guard raw.hasSuffix(suffix) else { return false }
        let digits = raw.dropLast(suffix.count)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// How a Codex window is named and tagged, from its length and lane. One
/// definition for the in-app collector and for reading rows other writers
/// uploaded; the Python helper (`_codex_tier_name`) and HelperSwift's
/// fetcher (`CodexQuotaFetcher.tierName`) follow the same table with their
/// own word for the 5-hour window ("Session").
public enum CodexQuotaWindows {
    public static let sessionMinutes = 300
    public static let dailyMinutes = 1440
    public static let weeklyMinutes = 10080
    public static let monthlyMinutes = 43200

    public enum Lane: Sendable {
        case session
        case weekly
    }

    /// Stored English name (translated only at render, `L10n.quotaTier`).
    /// A window of known length gets the name of that length, whichever slot
    /// the API used. A window of UNKNOWN length keeps the name its slot has
    /// always had — the only information there is.
    ///
    /// `other` is the name the other window already got. Two bars under one
    /// name cannot be told apart, and the card keys its bars by name
    /// (`UsageTier.id`), so the second of two same-named windows is the
    /// generic "Window", which is true of any window — or, when the first is
    /// already "Window" (two lengths with no name), its slot's name.
    public static func tierName(
        windowMinutes: Int?,
        lane: Lane,
        besides other: String? = nil
    ) -> String {
        let name: String
        switch windowMinutes {
        case sessionMinutes?:
            name = "5h Window"
        case dailyMinutes?:
            name = "Daily"
        case weeklyMinutes?:
            name = "Weekly"
        case monthlyMinutes?:
            name = "Monthly"
        case .some:
            // A length we have no name for. "5h Window" would be a false
            // claim about it; the generic word is not.
            name = genericName
        case nil:
            name = slotName(lane)
        }
        guard name == other else { return name }
        return name == genericName ? slotName(lane) : genericName
    }

    private static let genericName = "Window"

    private static func slotName(_ lane: Lane) -> String {
        lane == .session ? "5h Window" : "Weekly"
    }

    public static func role(for lane: Lane) -> TierRole {
        lane == .session ? .primary : .secondary
    }

    /// The row with `role` and `windowMinutes` filled in where the writer left
    /// them out, from the name it used. "Weekly" is the weekly window and
    /// "Credits" the credit balance. "5h Window" and "Session" (the helpers'
    /// word) are read with `primarySlot`, because before 1.55 they named the
    /// API's primary slot, not a length. Values the row does carry always win.
    public static func resolved(_ tier: TierDTO, now: Date) -> TierDTO {
        guard tier.role == nil || tier.windowMinutes == nil else { return tier }
        let inferred: (role: TierRole, minutes: Int?)?
        switch tier.name.lowercased() {
        case "5h window", "session":
            inferred = primarySlot(resetTime: tier.reset_time, now: now)
        case "weekly":
            inferred = (.secondary, weeklyMinutes)
        case "credits":
            inferred = (.credits, nil)
        default:
            inferred = nil
        }
        guard let inferred else { return tier }
        return TierDTO(
            name: tier.name,
            quota: tier.quota,
            remaining: tier.remaining,
            reset_time: tier.reset_time,
            windowMinutes: tier.windowMinutes ?? inferred.minutes,
            role: tier.role ?? inferred.role
        )
    }

    /// Slack for a reading device whose clock runs behind the writer's.
    static let resetClockSlack: TimeInterval = 15 * 60

    /// What an older writer's "5h Window"/"Session" row holds. Those writers
    /// gave the name to whatever came in the primary slot, and a weekly-only
    /// account's one window comes there. A 5-hour window resets within 5
    /// hours, so a reset further out means the weekly window: reading it as
    /// 5 hours would take away its pace marker and hide it from the Watch's
    /// weekly ring. A reset further out than a week fits neither, and nothing
    /// is inferred. With no reset, or one within 5 hours, the name is taken
    /// at its word — a weekly window that close to its reset looks the same.
    static func primarySlot(
        resetTime: String?,
        now: Date
    ) -> (role: TierRole, minutes: Int?)? {
        guard let reset = resetTime.flatMap(sharedISO8601Parse) else {
            return (.primary, sessionMinutes)
        }
        let untilReset = reset.timeIntervalSince(now)
        if untilReset <= TimeInterval(sessionMinutes * 60) + resetClockSlack {
            return (.primary, sessionMinutes)
        }
        if untilReset <= TimeInterval(weeklyMinutes * 60) + resetClockSlack {
            return (.secondary, weeklyMinutes)
        }
        return nil
    }
}
