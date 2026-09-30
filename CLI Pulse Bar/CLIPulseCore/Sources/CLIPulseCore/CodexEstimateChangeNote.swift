import Foundation

/// The dated note on the Mac's Overview that says Codex figures are counted
/// differently now, and why.
///
/// WHY IT EXISTS
/// -------------
/// A number that changes by itself reads as a bug. Codex figures change in
/// this version: the usage history stops counting Codex's cached input twice
/// (`ArchiveTokenBasis`), and other changes to how Codex is counted and priced
/// can ride along. Someone who has watched their Codex numbers for months
/// needs to be told, once, on the screen where the numbers are, with the date
/// it happened on their Mac. Not in a pop-up: a card they can dismiss, gone by
/// itself after `visibleDays`.
///
/// TRUE BY CONSTRUCTION
/// --------------------
/// Every line has to be true of the build that shows it.
///
/// * Who sees it: only a Mac that had recorded Codex usage before the change
///   (`hadCodexHistory`, decided from the archive before this version first
///   writes to it). A new install never saw the old numbers, so nothing
///   changed for it.
/// * The date is the day this Mac first counted the new way, not a release
///   date that may not match.
/// * Each reason is a `Reason`, and only `Reason.shipped` is shown. A reason
///   joins `shipped` in the change that makes it true. Tests hold each one to
///   the behaviour it describes, in both directions, so a line cannot be shown
///   for a change that is missing, and a change cannot land without its line.
/// * Old days are only mentioned when there are some: the archive keeps one
///   total per day, so days no scan has counted again since keep the old
///   figures, and the note says from which day on this Mac recounted
///   (`recountedFrom`), which scans keep up to date.
///
/// Assumes the reasons ship together in one version. A reason that arrived in
/// a later version, after the note expired or was dismissed, would not bring
/// it back.
public struct CodexEstimateChangeNote: Codable, Equatable, Sendable {

    /// The archive manager's bookkeeping. Written only off the main thread by
    /// `DailyUsageArchiveManager`.
    public static let defaultsKey = "cli_pulse_codex_estimate_note_v1"
    /// The user's "Got it". A key of its own, written only by the view, so the
    /// two writers never overwrite each other.
    public static let dismissedKey = "cli_pulse_codex_estimate_note_v1_dismissed"
    /// How long the note stays up when nobody dismisses it.
    public static let visibleDays = 30

    /// What changed about Codex figures, one line each.
    public enum Reason: String, CaseIterable, Sendable {
        /// The usage history counts Codex's cached input once
        /// (`ArchiveTokenBasis`).
        case cachedInputCountedOnce
        /// Codex subagent sessions are counted. The scanner used to drop a
        /// rollout whose session id it had already seen, and a subagent's
        /// rollout carries its parent's.
        case subagentSessionsCounted
        /// Codex cost uses OpenAI's published price for each model, where some
        /// models were priced from an older model's rates.
        case publishedPrices

        /// The reasons this build makes true, in the order they are shown.
        /// `CodexEstimateChangeTripwireTests` fails when this disagrees with
        /// what the scanner and the price table actually do.
        public static let shipped: [Reason] = [.cachedInputCountedOnce]

        public var text: String {
            switch self {
            case .cachedInputCountedOnce: return L10n.codexEstimateNote.reasonCachedInputOnce
            case .subagentSessionsCounted: return L10n.codexEstimateNote.reasonSubagentSessions
            case .publishedPrices: return L10n.codexEstimateNote.reasonPublishedPrices
            }
        }
    }

    /// The day ("yyyy-MM-dd") this Mac first wrote the archive the new way.
    public var changedOn: String
    /// Whether the archive held Codex usage at that moment, i.e. whether this
    /// Mac ever showed Codex figures counted the old way.
    public var hadCodexHistory: Bool
    /// The earliest day a scan has recorded since the change. Days from here
    /// on that this Mac has logs for are counted the new way. nil until the
    /// first scan lands.
    public var recountedFrom: String?
    /// Whether the archive still holds Codex days before `recountedFrom`.
    public var olderDaysKeepOldCount: Bool

    public init(
        changedOn: String,
        hadCodexHistory: Bool,
        recountedFrom: String? = nil,
        olderDaysKeepOldCount: Bool = false)
    {
        self.changedOn = changedOn
        self.hadCodexHistory = hadCodexHistory
        self.recountedFrom = recountedFrom
        self.olderDaysKeepOldCount = olderDaysKeepOldCount
    }

    // MARK: - Bookkeeping (the archive manager)

    /// The note as it starts, from the archive as it was before this version
    /// first wrote to it.
    public static func started(before archive: DailyUsageArchive, on today: String) -> CodexEstimateChangeNote {
        CodexEstimateChangeNote(changedOn: today, hadCodexHistory: holdsCodex(archive))
    }

    /// A scan recorded `dayKeys` into `archive` (already merged). Those days
    /// are counted the new way now; say which older ones are not.
    ///
    /// A scan reads every log in its window, so everything this Mac has logs
    /// for from `recountedFrom` on is recounted, and nothing before it is:
    /// "days before `recountedFrom` keep the old figures" is true by
    /// definition. What it leaves out is a Codex day after it that came only
    /// from another device through the cloud fill, which no scan here rewrites.
    public mutating func recordRecount(ofDays dayKeys: [String], in archive: DailyUsageArchive) {
        guard let earliest = dayKeys.min() else { return }
        let from = min(recountedFrom ?? earliest, earliest)
        recountedFrom = from
        olderDaysKeepOldCount = archive.days.contains { key, day in
            key < from && Self.codexTokens(day) > 0
        }
    }

    static func holdsCodex(_ archive: DailyUsageArchive) -> Bool {
        archive.days.values.contains { codexTokens($0) > 0 }
    }

    private static func codexTokens(_ day: DayRollup) -> Int {
        day.perProvider[ProviderKind.codex.rawValue]?.tokens ?? 0
    }

    // MARK: - Presentation

    /// What the card says. Plain strings, so a test can read them in any
    /// language without drawing the view.
    public struct Presentation: Equatable, Sendable {
        public let title: String
        public let lines: [String]
        public let footer: String
        public let dismiss: String
    }

    /// The card for `todayKey`, or nil when there is nothing to show:
    /// dismissed, expired, never relevant, or nothing shipped.
    public func presentation(
        todayKey: String,
        dismissed: Bool,
        reasons: [Reason] = Reason.shipped
    ) -> Presentation? {
        guard isVisible(todayKey: todayKey, dismissed: dismissed), !reasons.isEmpty else { return nil }
        var lines = reasons.map(\.text)
        if olderDaysKeepOldCount, let recountedFrom {
            lines.append(L10n.codexEstimateNote.historyBefore(Self.displayDay(recountedFrom)))
        }
        return Presentation(
            title: L10n.codexEstimateNote.title(Self.displayDay(changedOn)),
            lines: lines,
            footer: L10n.usageDashboard.costDisclaimer,
            dismiss: L10n.firstRun.dismiss)
    }

    /// Up from the day of the change until `visibleDays` later, unless
    /// dismissed. Hidden on a clock that reads earlier than the change: "since"
    /// a day that has not come yet would be false.
    public func isVisible(todayKey: String, dismissed: Bool) -> Bool {
        guard hadCodexHistory, !dismissed,
              let elapsed = Self.daysBetween(changedOn, todayKey) else { return false }
        return elapsed >= 0 && elapsed < Self.visibleDays
    }

    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let start = DayKey.date(from: from, in: .gmt),
              let end = DayKey.date(from: to, in: .gmt) else { return nil }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    private static func displayDay(_ key: String) -> String {
        DisplayFormat.day(key) ?? key
    }

    // MARK: - Storage

    public static func decode(_ data: Data?) -> CodexEstimateChangeNote? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(CodexEstimateChangeNote.self, from: data)
    }

    public static func load(from defaults: UserDefaults) -> CodexEstimateChangeNote? {
        decode(defaults.data(forKey: defaultsKey))
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
