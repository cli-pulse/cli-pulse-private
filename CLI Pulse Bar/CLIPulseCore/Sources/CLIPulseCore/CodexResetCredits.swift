// Derived from steipete/CodexBar
// Sources/CodexBarCore/CreditsModels.swift (`CodexRateLimitResetCreditsSnapshot`,
// `CodexRateLimitResetCreditInventory`, `CodexRateLimitResetCredit`,
// `CodexRateLimitResetCreditStatus`), the response shape in
// Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift
// (`RateLimitResetCreditsResponse`), Sources/CodexBar/MenuCardView+CodexResetCredits.swift
// (`LimitResetCreditsPresentation`) and the countdown rule of
// Sources/CodexBarCore/UsageFormatter.swift (`resetCountdownDescription`), taken at
// upstream commit 25bba9b7, 2026-09-28 (https://github.com/steipete/CodexBar).
//
// Not verbatim:
// - The models are not `Codable`. Upstream persists them inside its usage
//   snapshot; CLI Pulse keeps them in memory only, so the persisted-ID branch of
//   upstream's decoder has no counterpart here, and every ID that reaches the
//   model is hashed.
// - The hash is domain-separated with CLI Pulse's own label, not upstream's.
// - Dates are parsed with `sharedISO8601Parse` instead of upstream's
//   `ISO8601DateParser`; both accept fractional seconds.
// - Presentation text comes from CLI Pulse's catalogues (`L10n.resetCredits`),
//   countdowns only: CLI Pulse has no "absolute reset time" display setting.
// - The countdown rule is upstream's, with its English "in " prefix left out of
//   the compact form instead of stripped from it afterwards.
// - `expirySummaryText(showing:)`, which folds countdowns into "+N" when four
//   do not fit the card's width, and the card states
//   (`CodexResetCreditsCardState`, `CodexResetCreditsDemo`) are CLI Pulse's.
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

import CryptoKit
import Foundation

/// Codex's limit reset credits: free, one-time resets of the Codex usage limit
/// that OpenAI grants a ChatGPT account, each with its own expiry.
///
/// Read from `GET /wham/rate-limit-reset-credits`, an endpoint OpenAI does not
/// document (CodexBar reads it the same way). CLI Pulse only shows them: it
/// never redeems one, and never sends anything that could.
///
/// Held in memory on the Mac that read them (`CodexResetCreditsStore`): not
/// stored, not uploaded, not synced to the iPhone. Each credit's ID is hashed
/// the moment it is decoded, so the provider's own ID never reaches a model,
/// a log line or a view.
public struct CodexRateLimitResetCreditsSnapshot: Equatable, Sendable {
    public let credits: [CodexRateLimitResetCredit]
    /// The server's own count. Shown nowhere: the card counts the inventory
    /// itself (`availableInventory`), which drops credits that expired since.
    public let availableCount: Int
    public let updatedAt: Date

    public init(credits: [CodexRateLimitResetCredit], availableCount: Int, updatedAt: Date) {
        self.credits = credits
        self.availableCount = availableCount
        self.updatedAt = updatedAt
    }

    public var nextExpiringAvailableCredit: CodexRateLimitResetCredit? {
        availableInventory(at: updatedAt).nextExpiringCredit
    }

    public func availableInventory(at date: Date) -> CodexRateLimitResetCreditInventory {
        CodexRateLimitResetCreditInventory(credits: credits, at: date)
    }

    /// The same credits and count, whenever each was read.
    public func hasTheSameCredits(as other: CodexRateLimitResetCreditsSnapshot) -> Bool {
        credits == other.credits && availableCount == other.availableCount
    }

    // MARK: - Decoding

    public enum DecodingFailure: Error, Equatable {
        case invalidResponse
    }

    /// The endpoint's body as a snapshot taken at `now`. A negative
    /// `available_count`, or anything that is not this shape, is invalid.
    public static func decode(_ data: Data, now: Date) throws -> CodexRateLimitResetCreditsSnapshot {
        let payload: ResponseDTO
        do {
            payload = try JSONDecoder().decode(ResponseDTO.self, from: data)
        } catch {
            throw DecodingFailure.invalidResponse
        }
        guard payload.availableCount >= 0 else { throw DecodingFailure.invalidResponse }
        return CodexRateLimitResetCreditsSnapshot(
            credits: payload.credits.map(\.model),
            availableCount: payload.availableCount,
            updatedAt: now
        )
    }

    private struct ResponseDTO: Decodable {
        let credits: [CreditDTO]
        let availableCount: Int

        private enum CodingKeys: String, CodingKey {
            case credits
            case availableCount = "available_count"
        }
    }

    private struct CreditDTO: Decodable {
        let id: String
        let resetType: String
        let status: CodexRateLimitResetCreditStatus
        let grantedAt: Date
        let expiresAt: Date?
        let redeemStartedAt: Date?
        let redeemedAt: Date?
        let title: String?
        let description: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case resetType = "reset_type"
            case status
            case grantedAt = "granted_at"
            case expiresAt = "expires_at"
            case redeemStartedAt = "redeem_started_at"
            case redeemedAt = "redeemed_at"
            case title
            case description
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            resetType = try container.decode(String.self, forKey: .resetType)
            status = try container.decode(CodexRateLimitResetCreditStatus.self, forKey: .status)
            grantedAt = try Self.date(container, .grantedAt)
            expiresAt = try Self.optionalDate(container, .expiresAt)
            redeemStartedAt = try Self.optionalDate(container, .redeemStartedAt)
            redeemedAt = try Self.optionalDate(container, .redeemedAt)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
        }

        private static func date(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) throws -> Date {
            let raw = try container.decode(String.self, forKey: key)
            guard let date = sharedISO8601Parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "not an ISO-8601 date"
                )
            }
            return date
        }

        private static func optionalDate(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) throws -> Date? {
            guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let date = sharedISO8601Parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container, debugDescription: "not an ISO-8601 date"
                )
            }
            return date
        }

        var model: CodexRateLimitResetCredit {
            CodexRateLimitResetCredit(
                id: id,
                resetType: resetType,
                status: status,
                grantedAt: grantedAt,
                expiresAt: expiresAt,
                redeemStartedAt: redeemStartedAt,
                redeemedAt: redeemedAt,
                title: title,
                description: description
            )
        }
    }
}

/// The credits that can still be used at a moment: available and not yet
/// expired, the soonest to expire first, credits without an expiry last, ties
/// broken by (hashed) ID so the order never depends on the server's.
public struct CodexRateLimitResetCreditInventory: Equatable, Sendable {
    public let credits: [CodexRateLimitResetCredit]

    public var count: Int { credits.count }

    public var nextExpiringCredit: CodexRateLimitResetCredit? {
        credits.first { $0.expiresAt != nil }
    }

    public init(credits: [CodexRateLimitResetCredit], at date: Date) {
        self.credits = credits
            .filter { credit in
                credit.status == .available && (credit.expiresAt.map { $0 > date } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.id < rhs.id
            }
    }
}

public struct CodexRateLimitResetCredit: Equatable, Sendable, Identifiable {
    static let stableIDPrefix = "codex-reset-credit-v1-"

    /// A SHA-256 of the provider's ID, never the ID itself.
    public let id: String
    public let resetType: String
    public let status: CodexRateLimitResetCreditStatus
    public let grantedAt: Date
    public let expiresAt: Date?
    public let redeemStartedAt: Date?
    public let redeemedAt: Date?
    public let title: String?
    public let description: String?

    /// `id` is the provider's ID; it is hashed here and not kept.
    public init(
        id: String,
        resetType: String,
        status: CodexRateLimitResetCreditStatus,
        grantedAt: Date,
        expiresAt: Date?,
        redeemStartedAt: Date?,
        redeemedAt: Date?,
        title: String?,
        description: String?
    ) {
        self.id = Self.stableID(forProviderID: id)
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.redeemStartedAt = redeemStartedAt
        self.redeemedAt = redeemedAt
        self.title = title
        self.description = description
    }

    /// Always hashes, whatever the input looks like: an ID shaped like an
    /// already-hashed one is still the provider's and is hashed again.
    static func stableID(forProviderID providerID: String) -> String {
        let domainSeparated = "yyh.CLI-Pulse.codex-reset-credit-id.v1\0\(providerID)"
        let digest = SHA256.hash(data: Data(domainSeparated.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return stableIDPrefix + digest
    }
}

public enum CodexRateLimitResetCreditStatus: Equatable, Sendable, Decodable {
    case available
    case redeeming
    case redeemed
    case expired
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "available": self = .available
        case "redeeming": self = .redeeming
        case "redeemed": self = .redeemed
        case "expired": self = .expired
        default: self = .unknown(value)
        }
    }
}

// MARK: - Presentation

/// What the Codex card shows for an inventory: "2 available" and a timeline of
/// countdowns, at most four of them and "+N" for the rest. The tooltip lists
/// every credit.
public struct CodexResetCreditsPresentation: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// "Expires in 6d 4h", or "No expiry".
        public let expiryText: String
        /// "6d 4h", or "No expiry".
        public let compactExpiryText: String
        /// "Expires in 6 days, 4 hours", or "No expiry": what VoiceOver reads,
        /// which would read the compact countdown as "6 d 4 h".
        public let spokenExpiryText: String
    }

    /// Countdowns shown before the rest collapse into "+N".
    public static let visibleCountdowns = 4

    /// "2 available".
    public let text: String
    public let items: [Item]

    /// "6d 4h · 21d 9h", or "1d · 2d · 3d · 4d · +2".
    public var expirySummaryText: String {
        expirySummaryText(showing: Self.visibleCountdowns)
    }

    /// The summary with at most `limit` countdowns (never more than
    /// `visibleCountdowns`, never fewer than one) and "+N" for the rest. The
    /// card asks for fewer when four do not fit its width, so a long language
    /// folds countdowns into "+N" instead of cutting one in half.
    public func expirySummaryText(showing limit: Int) -> String {
        let shown = max(1, min(limit, Self.visibleCountdowns))
        let visible = items.prefix(shown).map(\.compactExpiryText)
        let hidden = items.count - visible.count
        let suffix = hidden > 0 ? ["+\(hidden)"] : []
        return (visible + suffix).joined(separator: " · ")
    }

    /// Every credit on its own line, then what CLI Pulse does with them.
    public var helpText: String {
        let lines = items.enumerated().map { index, item in "\(index + 1). \(item.expiryText)" }
        return (lines + [L10n.resetCredits.readOnlyNote]).joined(separator: "\n")
    }

    public var accessibilityLabel: String {
        ([L10n.resetCredits.title, text] + items.map(\.spokenExpiryText)).joined(separator: ", ")
    }

    /// nil when nothing can be used at `now`: an empty inventory draws no row.
    public static func make(
        snapshot: CodexRateLimitResetCreditsSnapshot,
        now: Date
    ) -> CodexResetCreditsPresentation? {
        let inventory = snapshot.availableInventory(at: now)
        guard !inventory.credits.isEmpty else { return nil }
        return CodexResetCreditsPresentation(
            text: inventory.count == 1
                ? L10n.resetCredits.availableOne
                : L10n.resetCredits.available(inventory.count),
            items: inventory.credits.map { item(expiresAt: $0.expiresAt, now: now) }
        )
    }

    private static func item(expiresAt: Date?, now: Date) -> Item {
        guard let expiresAt else {
            let text = L10n.resetCredits.noExpiry
            return Item(expiryText: text, compactExpiryText: text, spokenExpiryText: text)
        }
        guard let minutes = countdownMinutes(until: expiresAt, now: now) else {
            return Item(
                expiryText: L10n.resetCredits.expiresNow,
                compactExpiryText: L10n.resetCredits.leftNow,
                spokenExpiryText: L10n.resetCredits.expiresNow
            )
        }
        let units = CountdownUnits(totalMinutes: minutes)
        let countdown = units.compactText
        return Item(
            expiryText: L10n.resetCredits.expiresIn(countdown),
            compactExpiryText: countdown,
            spokenExpiryText: L10n.resetCredits.expiresIn(spokenCountdownText(units) ?? countdown)
        )
    }

    /// Whole minutes left, rounded up; nil under a second.
    private static func countdownMinutes(until date: Date, now: Date) -> Int? {
        let seconds = date.timeIntervalSince(now)
        guard seconds >= 1, let rounded = Int(exactly: ceil(seconds / 60)) else { return nil }
        return max(1, rounded)
    }

    /// The two units a countdown shows, from whole minutes rounded up:
    /// upstream's rule (`countdownText`). The chip and VoiceOver both read
    /// these, so what is spoken is what is shown: "6d 4h" is "6 days,
    /// 4 hours", never the "6 days, 5 hours" a formatter rounding the
    /// remaining 31 minutes into the hours would say.
    enum CountdownUnits: Equatable {
        case daysHours(Int, Int)
        /// Days and minutes, when the hours are 0.
        case daysMinutes(Int, Int)
        case days(Int)
        case hoursMinutes(Int, Int)
        case hours(Int)
        case minutes(Int)

        init(totalMinutes: Int) {
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes / 60) % 24
            let minutes = totalMinutes % 60
            if days > 0 {
                if hours > 0 { self = .daysHours(days, hours) }
                else if minutes > 0 { self = .daysMinutes(days, minutes) }
                else { self = .days(days) }
            } else if hours > 0 {
                self = minutes > 0 ? .hoursMinutes(hours, minutes) : .hours(hours)
            } else {
                self = .minutes(totalMinutes)
            }
        }

        /// "6d 4h", "6 天 4 小时".
        var compactText: String {
            switch self {
            case let .daysHours(d, h): return L10n.resetCredits.leftDaysHours(d, h)
            case let .daysMinutes(d, m): return L10n.resetCredits.leftDaysMinutes(d, m)
            case let .days(d): return L10n.resetCredits.leftDays(d)
            case let .hoursMinutes(h, m): return L10n.resetCredits.leftHoursMinutes(h, m)
            case let .hours(h): return L10n.resetCredits.leftHours(h)
            case let .minutes(m): return L10n.resetCredits.leftMinutes(m)
            }
        }

        /// The same units and nothing else, for the spoken form.
        var components: DateComponents {
            switch self {
            case let .daysHours(d, h): return DateComponents(day: d, hour: h)
            case let .daysMinutes(d, m): return DateComponents(day: d, minute: m)
            case let .days(d): return DateComponents(day: d)
            case let .hoursMinutes(h, m): return DateComponents(hour: h, minute: m)
            case let .hours(h): return DateComponents(hour: h)
            case let .minutes(m): return DateComponents(minute: m)
            }
        }
    }

    /// The countdown in words, in the app's language ("6 days, 4 hours",
    /// "6天4小时"), with exactly the units of the compact one. Formatted from
    /// those units, not from the time left: given a duration, the formatter
    /// rounds the last unit it keeps. Gregorian on purpose: days and hours,
    /// whatever calendar the Mac uses.
    static func spokenCountdownText(_ units: CountdownUnits) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = LocaleOverrideStore.resolvedLocalization.map { Locale(identifier: $0) } ?? .current
        formatter.calendar = calendar
        return formatter.string(from: units.components)
    }

    /// Upstream's countdown: whole minutes rounded up, then days and hours,
    /// days and minutes when the hours are 0, and so down to minutes; "now"
    /// under a second.
    static func countdownText(until date: Date, now: Date) -> String {
        guard let totalMinutes = countdownMinutes(until: date, now: now) else {
            return L10n.resetCredits.leftNow
        }
        return CountdownUnits(totalMinutes: totalMinutes).compactText
    }
}

// MARK: - What the card draws

/// The Codex card's reset-credits row, decided from what this Mac knows.
///
/// - `.inventory`: credits read on the latest pass, at least one still usable.
/// - `.needsCodexFolderAccess`: the App Store build cannot read the Codex
///   sign-in (`~/.codex`) without a folder grant, and has none, so it cannot
///   ask OpenAI. Only the Codex CLI grant matters: the session-log grants feed
///   the cost figures, not this. Only when this Mac's Codex collector declined
///   to run: a pass that produced data read the sign-in somehow (a credential
///   bridged into the app group), so the folder is not what is missing.
/// - `.hidden`: everything else, on purpose. No credits (most accounts), a
///   failed or timed-out read, a pass that did not produce data, the remote
///   switch off, a Codex sign-in that is not a ChatGPT one: each says nothing
///   the rest of the card does not already say, and a reset count is a detail,
///   not a reason to spend a line.
public enum CodexResetCreditsCardState: Equatable, Sendable {
    case hidden
    case inventory(CodexResetCreditsPresentation)
    case needsCodexFolderAccess

    /// `snapshot` is the latest pass's reading for this card's accounts.
    /// `latestOutcome`: the Codex collector's outcome on this Mac's latest
    /// pass. A reading outlives a later pass that failed or never ran (signed
    /// out of Codex, provider switched off), and is shown only after a pass
    /// that produced data. `hasCodexFolderAccess` is asked only in a sandboxed
    /// build whose Codex collector declined to run, never on the common path.
    public static func resolve(
        snapshot: CodexRateLimitResetCreditsSnapshot?,
        latestOutcome: CollectorOutcome?,
        isSandboxed: Bool,
        hasCodexFolderAccess: () -> Bool,
        isDemoMode: Bool,
        now: Date
    ) -> CodexResetCreditsCardState {
        if isDemoMode {
            return CodexResetCreditsPresentation.make(snapshot: CodexResetCreditsDemo.snapshot(now: now), now: now)
                .map(CodexResetCreditsCardState.inventory) ?? .hidden
        }
        if latestOutcome == .producedData {
            // The sign-in was read, and the credits with it: there are none to
            // show, or the read failed. Either way, not a folder to grant.
            return snapshot
                .flatMap { CodexResetCreditsPresentation.make(snapshot: $0, now: now) }
                .map(CodexResetCreditsCardState.inventory) ?? .hidden
        }
        if isSandboxed, latestOutcome?.declinedForWantOfAccess == true, !hasCodexFolderAccess() {
            return .needsCodexFolderAccess
        }
        return .hidden
    }
}

private extension CollectorOutcome {
    /// The collector did not get as far as a request: it declined to run, or
    /// the sandbox refused it a file. Not "switched off", which the card's
    /// badge already says, and not a request that failed, which a folder grant
    /// would not fix.
    var declinedForWantOfAccess: Bool {
        switch self {
        case .notReady, .failed(.permission): return true
        default: return false
        }
    }
}

/// Demo mode's Codex reading: two credits, the shape a Plus account with
/// resets granted reads (CodexBar's own screenshot shows three). Built from
/// the moment it is drawn, so the countdowns read the same in every
/// screenshot: 6d 4h and 21d 9h.
public enum CodexResetCreditsDemo {
    public static func snapshot(now: Date) -> CodexRateLimitResetCreditsSnapshot {
        func credit(_ id: String, expiresIn: TimeInterval) -> CodexRateLimitResetCredit {
            CodexRateLimitResetCredit(
                id: id,
                resetType: "codex_rate_limits",
                status: .available,
                grantedAt: now.addingTimeInterval(expiresIn - 30 * 86_400),
                expiresAt: now.addingTimeInterval(expiresIn),
                redeemStartedAt: nil,
                redeemedAt: nil,
                title: nil,
                description: nil
            )
        }
        return CodexRateLimitResetCreditsSnapshot(
            credits: [
                credit("demo-reset-credit-1", expiresIn: 6 * 86_400 + 4 * 3_600),
                credit("demo-reset-credit-2", expiresIn: 21 * 86_400 + 9 * 3_600),
            ],
            availableCount: 2,
            updatedAt: now
        )
    }
}
