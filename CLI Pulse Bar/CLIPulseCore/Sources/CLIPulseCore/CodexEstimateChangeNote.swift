import Foundation

/// The dated note on the Mac's Overview that says Codex figures are counted
/// differently now, and why, and the line in the Usage Dashboard that says
/// which days still hold figures counted the old way.
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
/// The history is a different matter. The Mac's archive keeps one total per
/// day and provider, so a Codex day recorded before the change keeps its old
/// figure until a scan records that day again. On most updated Macs that never
/// happens for days older than the routine month: the year-long read ran
/// before 1.55 for everyone whose scan worked, and does not run again. Those
/// days can stay in the history for a year, and in its monthly totals for
/// good. So the dashboard says so, for as long as any remain, whether or not
/// the card is still up.
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
/// * Each reason is a `Reason`, and a line is shown only for a reason in
///   `Reason.shipped`. A reason joins `shipped` in the change that makes it
///   true. Tests hold each one to the behaviour it describes, in both
///   directions, so a line cannot be shown for a change that is missing, and a
///   change cannot land without its line.
/// * A reason that ships in a later version than the note starts a note of its
///   own, with its own date and its own "Got it" (`next(after:before:on:shipped:)`),
///   so nobody who dismissed the first one misses it, and it is never shown
///   under a date on which it had not happened.
/// * The days that keep old figures are the days themselves
///   (`oldCodexDays`): every Codex day the archive held when the note started,
///   less each day whose Codex share a later write took from a read. Not a
///   boundary guessed from what a scan returned: a scan only writes the days
///   it has entries for, and a Codex day it has none for (its log deleted, or
///   the Codex folder not readable in the App Store build while the Claude one
///   is) keeps its old figure. Nor every day a read wrote: where it merges a
///   day provider by provider (the year-long read, and the routine read's
///   oldest day), a read with no Codex entries for that day leaves the stored
///   Codex slice, and its old figure, in place.
///
/// Month rollups (`DailyUsageArchive.months`) hold no per-provider split, so
/// whether a month folded before the change held Codex is unknown; nothing is
/// said about those rather than guessed. A day that was old when the note
/// started and is folded later stays in `oldCodexDays`: its figure lives on in
/// the monthly total, still counted the old way.
public struct CodexEstimateChangeNote: Codable, Equatable, Sendable {

    /// The archive manager's bookkeeping. Written only off the main thread by
    /// `DailyUsageArchiveManager`.
    public static let defaultsKey = "cli_pulse_codex_estimate_note_v1"
    /// The `id` of the note the user said "Got it" to. A key of its own,
    /// written only by the view, so the two writers never overwrite each other.
    /// An id rather than a flag: a later note has a different one, so an
    /// earlier "Got it" does not hide it.
    public static let dismissedKey = "cli_pulse_codex_estimate_note_v1_dismissed_id"
    /// How long the card stays up when nobody dismisses it. The dashboard's
    /// line does not expire.
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
        /// Codex cost estimates use the API prices OpenAI publishes. Until
        /// then, `gpt-5.5` carried `gpt-5.4`'s rates and newer models fell
        /// back to that row. A model with no published price can still borrow
        /// one, so the line does not say every model has its own.
        case publishedPrices

        /// The reasons this build makes true, in the order they are shown.
        /// `CodexEstimateChangeTripwireTests` fails when this disagrees with
        /// what the scanner and the price table actually do.
        public static let shipped: [Reason] = [.cachedInputCountedOnce, .subagentSessionsCounted, .publishedPrices]

        public var text: String {
            switch self {
            case .cachedInputCountedOnce: return L10n.codexEstimateNote.reasonCachedInputOnce
            case .subagentSessionsCounted: return L10n.codexEstimateNote.reasonSubagentSessions
            case .publishedPrices: return L10n.codexEstimateNote.reasonPublishedPrices
            }
        }

        /// What this change still leaves out, said right after it, or nil.
        ///
        /// Subagents and forks are counted by a subset of CodexBar's rules
        /// (`CodexTokenAccountant` rules 2 to 5). Reading a fork's inherited
        /// counter from its parent's file is not among them, so a fork whose
        /// first event repeats its parent's last snapshot, or a subagent
        /// written without a history ordinal whose copied history has no turn
        /// marker, counts a copied request again.
        /// `CodexEstimateChangeTripwireTests` holds this line to that: it
        /// fails once the scanner stops counting the copied request, so the
        /// line goes when the limit does.
        public var caveat: String? {
            switch self {
            case .subagentSessionsCounted: return L10n.codexEstimateNote.subagentRulesSimplified
            case .cachedInputCountedOnce, .publishedPrices: return nil
            }
        }

        /// The card's lines for this reason: what changed, then what it
        /// still leaves out.
        public var lines: [String] { [text] + (caveat.map { [$0] } ?? []) }
    }

    /// The day ("yyyy-MM-dd") this Mac first wrote the archive counting this
    /// note's reasons.
    public var changedOn: String
    /// Whether the archive held Codex usage at that moment, i.e. whether this
    /// Mac ever showed Codex figures counted the old way.
    public var hadCodexHistory: Bool
    /// The reasons this note tells about (`Reason.rawValue`): the ones the
    /// build that started it shipped and no earlier note had told.
    public var reasons: [String]
    /// Every reason a note on this Mac has told about, this one's included.
    public var toldReasons: [String]
    /// The Codex days ("yyyy-MM-dd", ascending) still counted the old way:
    /// every Codex day in the archive when this note started, less each day
    /// whose Codex share a write has since taken from a read or the cloud. A
    /// day folded into the monthly totals stays.
    public var oldCodexDays: [String]
    /// Whether a Codex day counted the new way lies before the last of
    /// `oldCodexDays`, so only some of the Codex figures up to it are old.
    /// Once true it stays true while old days remain: "some" is true whenever
    /// any are, and a day folded away can no longer be looked at.
    public var newDaysAmongOld: Bool

    public init(
        changedOn: String,
        hadCodexHistory: Bool,
        reasons: [Reason] = Reason.shipped,
        toldReasons: [Reason]? = nil,
        oldCodexDays: [String] = [],
        newDaysAmongOld: Bool = false)
    {
        self.changedOn = changedOn
        self.hadCodexHistory = hadCodexHistory
        self.reasons = reasons.map(\.rawValue)
        self.toldReasons = (toldReasons ?? reasons).map(\.rawValue)
        self.oldCodexDays = oldCodexDays.sorted()
        self.newDaysAmongOld = newDaysAmongOld
    }

    /// Tells one note from the next, for "Got it".
    public var id: String { changedOn + "|" + reasons.joined(separator: ",") }

    // MARK: - Bookkeeping (the archive manager)

    /// Before a write: the note to store, or nil to keep `stored` as it is.
    ///
    /// A new note starts on the first write of this version, and again on the
    /// first write of a later version that ships a reason `stored` has not
    /// told. It is decided from `archive` as the previous version left it.
    public static func next(
        after stored: CodexEstimateChangeNote?,
        before archive: DailyUsageArchive,
        on today: String,
        shipped: [Reason] = Reason.shipped
    ) -> CodexEstimateChangeNote? {
        let told = stored?.toldReasons ?? []
        let new = shipped.filter { !told.contains($0.rawValue) }
        if stored != nil, new.isEmpty { return nil }
        let codexDays = archive.days.filter { codexTokens($0.value) > 0 }.keys.sorted()
        var note = CodexEstimateChangeNote(
            changedOn: today,
            hadCodexHistory: !codexDays.isEmpty,
            reasons: new,
            oldCodexDays: codexDays)
        note.toldReasons = told + new.map(\.rawValue)
        return note
    }

    /// After a write to `archive` (already merged): `written` are the days
    /// whose Codex share it took from a read or the cloud, which are counted
    /// the new way now. A day the write merged provider by provider without
    /// Codex entries is not among them: it kept its stored Codex slice.
    public mutating func recordWrite(of written: Set<String>, in archive: DailyUsageArchive) {
        guard !oldCodexDays.isEmpty else { return }
        oldCodexDays.removeAll { written.contains($0) }
        guard let last = oldCodexDays.last else {
            newDaysAmongOld = false
            return
        }
        guard !newDaysAmongOld else { return }
        let old = Set(oldCodexDays)
        newDaysAmongOld = archive.days.contains { key, day in
            key < last && !old.contains(key) && Self.codexTokens(day) > 0
        } || written.contains { key in
            // Written, then folded into a monthly total by the same merge:
            // whether it held Codex can no longer be seen, so assume it did.
            key < last && archive.days[key] == nil
        }
    }

    static func codexTokens(_ day: DayRollup) -> Int {
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

    /// This note's reasons that the build ships, in `shipped`'s order.
    public func shownReasons(_ shipped: [Reason] = Reason.shipped) -> [Reason] {
        shipped.filter { reasons.contains($0.rawValue) }
    }

    /// The card for `todayKey`, or nil when there is nothing to show:
    /// dismissed, expired, never relevant, or nothing shipped.
    public func presentation(
        todayKey: String,
        dismissed: Bool,
        shipped: [Reason] = Reason.shipped
    ) -> Presentation? {
        guard isVisible(todayKey: todayKey, dismissed: dismissed) else { return nil }
        var lines = shownReasons(shipped).flatMap(\.lines)
        guard !lines.isEmpty else { return nil }
        if let last = oldCodexDays.last {
            let day = Self.displayDay(last)
            lines.append(newDaysAmongOld
                         ? L10n.codexEstimateNote.historySomeThrough(day)
                         : L10n.codexEstimateNote.historyThrough(day))
        }
        return Presentation(
            title: L10n.codexEstimateNote.title(Self.displayDay(changedOn)),
            lines: lines,
            footer: L10n.usageDashboard.costDisclaimer,
            dismiss: L10n.firstRun.dismiss)
    }

    /// The Usage Dashboard's line while Codex figures counted the old way
    /// remain, or nil. Neither "Got it" nor the card's month ends it: only the
    /// days themselves being counted again.
    public func dashboardLine(shipped: [Reason] = Reason.shipped) -> String? {
        guard hadCodexHistory, !shownReasons(shipped).isEmpty, let last = oldCodexDays.last else { return nil }
        let day = Self.displayDay(last)
        return newDaysAmongOld
            ? L10n.codexEstimateNote.dashboardSomeThrough(day)
            : L10n.codexEstimateNote.dashboardThrough(day)
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
