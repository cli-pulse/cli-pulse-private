// Translated in part from steipete/CodexBar, taken at upstream commit 25bba9b7
// (2026-09-28) (https://github.com/steipete/CodexBar): the fixtures and the
// expectations of these swift-testing suites, run here against CLI Pulse's
// port (`CodexResetCredits.swift`) as XCTest:
//
//   Tests/CodexBarTests/CodexRateLimitResetCreditsTests.swift
//     (decoding, the inventory's filter and order, the hashed IDs)
//   Tests/CodexBarTests/CodexResetCreditsMenuCardTests.swift
//     (the presentation: order, "No expiry", the four-countdown cap)
//
// NOT verbatim: upstream's assertions on its persisted `UsageSnapshot`, its
// menu-card layout tracking and its absolute-time style have no counterpart
// (CLI Pulse keeps the reading in memory and shows countdowns only). The text
// is also asserted in zh-Hans and es, and the card-state tests at the end are
// ours.
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
// ──────────────────────────────────────────────────────────────────

import XCTest
@testable import CLIPulseCore

/// Codex's limit reset credits: what is decoded, which credits count, how the
/// card words them, and when the card draws the row at all.
///
/// Text is asserted in zh-Hans and es as well as English: the English fallback
/// would make an English-only assertion pass with the lookup broken.
final class CodexResetCreditsTests: XCTestCase {

    private var savedOverride: String?
    private var savedSystemLocale: (() -> Locale)!

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        savedSystemLocale = LocaleOverrideStore.systemLocale
        LocaleOverrideStore.systemLocale = { Locale(identifier: "en_US") }
        LocaleOverrideStore.shared.set("en")
    }

    override func tearDown() {
        LocaleOverrideStore.systemLocale = savedSystemLocale
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    private static let now = Date(timeIntervalSince1970: 1_781_726_400)

    private static func credit(
        _ id: String,
        status: CodexRateLimitResetCreditStatus = .available,
        expiresIn: TimeInterval?
    ) -> CodexRateLimitResetCredit {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: status,
            grantedAt: Date(timeIntervalSince1970: 1_781_000_000),
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil
        )
    }

    private static func snapshot(_ credits: [CodexRateLimitResetCredit]) -> CodexRateLimitResetCreditsSnapshot {
        CodexRateLimitResetCreditsSnapshot(credits: credits, availableCount: credits.count, updatedAt: now)
    }

    private func presentation(_ credits: [CodexRateLimitResetCredit]) throws -> CodexResetCreditsPresentation {
        try XCTUnwrap(CodexResetCreditsPresentation.make(snapshot: Self.snapshot(credits), now: Self.now))
    }

    // MARK: - Decoding

    func testDecodesCreditsAndSkipsStaleAvailableExpiry() throws {
        let json = """
        {
          "credits": [
            {
              "id": "RateLimitResetCredit_expired_available",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-05-18T00:39:53Z",
              "expires_at": "2026-06-17T00:39:53Z"
            },
            {
              "id": "RateLimitResetCredit_later",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-18T00:39:53.731630Z",
              "expires_at": "2026-07-18T00:39:53.731630Z",
              "redeem_started_at": null,
              "redeemed_at": null,
              "profile_image_url": "https://example.com/codex.png",
              "profile_user_id": "Codex Team",
              "title": "One free rate limit reset",
              "description": "Thanks for using Codex!"
            },
            {
              "id": "RateLimitResetCredit_earlier",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-12T04:03:43.263391Z",
              "expires_at": "2026-07-12T04:03:43.263391Z",
              "redeem_started_at": null,
              "redeemed_at": null,
              "title": "One free rate limit reset",
              "description": "Thanks for using Codex!"
            },
            {
              "id": "RateLimitResetCredit_future_status",
              "reset_type": "codex_rate_limits",
              "status": "future_status",
              "granted_at": "2026-06-12T04:03:43Z",
              "expires_at": "2026-07-10T04:03:43Z",
              "redeem_started_at": null,
              "redeemed_at": null
            }
          ],
          "available_count": 2
        }
        """
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(Data(json.utf8), now: now)

        XCTAssertEqual(snapshot.availableCount, 2)
        XCTAssertEqual(snapshot.credits.count, 4)
        XCTAssertEqual(snapshot.credits[0].resetType, "codex_rate_limits")
        XCTAssertEqual(snapshot.credits[3].status, .unknown("future_status"))
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(
            snapshot.nextExpiringAvailableCredit?.id,
            CodexRateLimitResetCredit.stableID(forProviderID: "RateLimitResetCredit_earlier")
        )
        // The expired "available" one and the unknown status do not count.
        XCTAssertEqual(snapshot.availableInventory(at: now).count, 2)
        // The provider's IDs are gone from everything the snapshot holds.
        XCTAssertTrue(snapshot.credits.allSatisfy { !$0.id.contains("RateLimitResetCredit_") })
        XCTAssertFalse(String(reflecting: snapshot).contains("RateLimitResetCredit_"))
    }

    func testRejectsNegativeAvailableCount() {
        let json = #"{"credits":[],"available_count":-1}"#
        XCTAssertThrowsError(try CodexRateLimitResetCreditsSnapshot.decode(Data(json.utf8), now: Self.now))
    }

    func testRejectsADateThatIsNotISO8601() {
        let json = """
        {"credits":[{"id":"a","reset_type":"codex_rate_limits","status":"available",
          "granted_at":"yesterday","expires_at":null}],"available_count":1}
        """
        XCTAssertThrowsError(try CodexRateLimitResetCreditsSnapshot.decode(Data(json.utf8), now: Self.now))
    }

    func testAcceptsAnEmptyInventory() throws {
        let snapshot = try CodexRateLimitResetCreditsSnapshot.decode(
            Data(#"{"credits":[],"available_count":0}"#.utf8), now: Self.now
        )
        XCTAssertEqual(snapshot.availableCount, 0)
        XCTAssertNil(CodexResetCreditsPresentation.make(snapshot: snapshot, now: Self.now))
    }

    // MARK: - Inventory

    func testAvailableInventoryKeepsNoExpiryCreditsAndSortsDeterministically() {
        let tiedExpiry: TimeInterval = 3600
        let snapshot = CodexRateLimitResetCreditsSnapshot(
            credits: [
                Self.credit("nil-b", expiresIn: nil),
                Self.credit("expired", expiresIn: 0),
                Self.credit("finite-b", expiresIn: tiedExpiry),
                Self.credit("redeemed", status: .redeemed, expiresIn: 7200),
                Self.credit("nil-a", expiresIn: nil),
                Self.credit("finite-a", expiresIn: tiedExpiry),
            ],
            availableCount: 99,
            updatedAt: Self.now
        )

        let inventory = snapshot.availableInventory(at: Self.now)

        XCTAssertEqual(inventory.count, 4)
        let finite = ["finite-a", "finite-b"].map(CodexRateLimitResetCredit.stableID(forProviderID:)).sorted()
        let noExpiry = ["nil-a", "nil-b"].map(CodexRateLimitResetCredit.stableID(forProviderID:)).sorted()
        XCTAssertEqual(inventory.credits.map(\.id), finite + noExpiry)
        XCTAssertEqual(inventory.nextExpiringCredit?.id, finite.first)
    }

    func testProviderIDsAlwaysHashEvenWhenShapedLikeHashedOnes() throws {
        let canonicalLooking = CodexRateLimitResetCredit.stableIDPrefix + String(repeating: "a", count: 64)
        let json = """
        {"credits":[{"id":"\(canonicalLooking)","reset_type":"codex_rate_limits","status":"available",
          "granted_at":"2026-06-18T00:39:53Z","expires_at":null}],"available_count":1}
        """
        let decoded = try CodexRateLimitResetCreditsSnapshot.decode(Data(json.utf8), now: Self.now)
        let id = try XCTUnwrap(decoded.credits.first?.id)
        XCTAssertEqual(id, CodexRateLimitResetCredit.stableID(forProviderID: canonicalLooking))
        XCTAssertNotEqual(id, canonicalLooking)

        let first = Self.credit("ordinary-provider-id", expiresIn: nil)
        let second = Self.credit("ordinary-provider-id", expiresIn: nil)
        XCTAssertEqual(first.id, second.id, "the hash is stable, so the order is too")
        XCTAssertNotEqual(first.id, "ordinary-provider-id")
        XCTAssertTrue(first.id.hasPrefix(CodexRateLimitResetCredit.stableIDPrefix))
        XCTAssertEqual(first.id.count, CodexRateLimitResetCredit.stableIDPrefix.count + 64)
    }

    // MARK: - Presentation

    func testPresentationShowsOnlyAvailableInventoryInStableExpiryOrder() throws {
        let presentation = try presentation([
            Self.credit("no-expiry", expiresIn: nil),
            Self.credit("late", expiresIn: 172_800),
            Self.credit("redeemed", status: .redeemed, expiresIn: 43_200),
            Self.credit("expired", expiresIn: -1),
            Self.credit("early", expiresIn: 86_400),
        ])

        XCTAssertEqual(presentation.text, "3 available")
        XCTAssertEqual(presentation.items.map(\.expiryText), ["Expires in 1d", "Expires in 2d", "No expiry"])
        XCTAssertEqual(presentation.expirySummaryText, "1d · 2d · No expiry")
        XCTAssertEqual(
            presentation.helpText.split(separator: "\n").prefix(3).joined(separator: "\n"),
            "1. Expires in 1d\n2. Expires in 2d\n3. No expiry"
        )
        XCTAssertTrue(presentation.helpText.hasSuffix(L10n.resetCredits.readOnlyNote))
        // VoiceOver reads words, not the compact "1d".
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Limit reset credits, 3 available, Expires in 1 day, Expires in 2 days, No expiry"
        )
    }

    func testOneAvailableIsSingular() throws {
        let presentation = try presentation([Self.credit("only", expiresIn: nil)])
        XCTAssertEqual(presentation.text, "1 available")
        XCTAssertEqual(presentation.expirySummaryText, "No expiry")
    }

    /// At most four countdowns, then "+N" for the rest; the tooltip still lists
    /// every credit.
    func testCompactSummaryCapsVisibleCountdownsAtFour() throws {
        let presentation = try presentation((1...6).map {
            Self.credit("day-\($0)", expiresIn: Double($0) * 86_400)
        })
        XCTAssertEqual(presentation.text, "6 available")
        XCTAssertEqual(presentation.expirySummaryText, "1d · 2d · 3d · 4d · +2")
        let lines = presentation.helpText.split(separator: "\n")
        XCTAssertEqual(lines.count, 6 + 1, "six credits and the read-only note")
        XCTAssertEqual(lines[5], "6. Expires in 6d")

        let four = try self.presentation((1...4).map { Self.credit("d\($0)", expiresIn: Double($0) * 86_400) })
        XCTAssertEqual(four.expirySummaryText, "1d · 2d · 3d · 4d", "four fit without a +N")
    }

    /// The card asks for fewer countdowns when four do not fit its width: the
    /// rest fold into "+N", never more than four are shown and never fewer
    /// than one.
    func testANarrowerSummaryFoldsTheRestIntoPlusN() throws {
        let six = try presentation((1...6).map { Self.credit("day-\($0)", expiresIn: Double($0) * 86_400) })
        XCTAssertEqual(six.expirySummaryText(showing: 2), "1d · 2d · +4")
        XCTAssertEqual(six.expirySummaryText(showing: 1), "1d · +5")
        XCTAssertEqual(six.expirySummaryText(showing: 0), "1d · +5", "at least one countdown")
        XCTAssertEqual(six.expirySummaryText(showing: 9), "1d · 2d · 3d · 4d · +2", "at most four")

        let two = try presentation([Self.credit("a", expiresIn: 86_400), Self.credit("b", expiresIn: nil)])
        XCTAssertEqual(two.expirySummaryText(showing: 3), "1d · No expiry", "no +N when all are shown")
        XCTAssertEqual(two.expirySummaryText(showing: 1), "1d · +1")
    }

    func testAnInventoryWithNothingUsableDrawsNothing() {
        let snapshot = Self.snapshot([
            Self.credit("expired", expiresIn: -1),
            Self.credit("redeeming", status: .redeeming, expiresIn: 86_400),
            Self.credit("gone", status: .expired, expiresIn: 86_400),
        ])
        XCTAssertNil(CodexResetCreditsPresentation.make(snapshot: snapshot, now: Self.now))
    }

    /// Upstream's `resetCountdownDescription`, case by case.
    func testCountdownFollowsCodexBarsRule() {
        func text(_ seconds: TimeInterval) -> String {
            CodexResetCreditsPresentation.countdownText(until: Self.now.addingTimeInterval(seconds), now: Self.now)
        }
        XCTAssertEqual(text(30 * 3_600), "1d 6h")
        XCTAssertEqual(text(86_400 + 5 * 60), "1d 5m", "days and minutes when the hours are 0")
        XCTAssertEqual(text(2 * 86_400), "2d")
        XCTAssertEqual(text(90 * 60), "1h 30m")
        XCTAssertEqual(text(2 * 3_600), "2h")
        XCTAssertEqual(text(59), "1m", "under a minute rounds up to one")
        XCTAssertEqual(text(86_400 + 5 * 3_600 + 59 * 60 + 30), "1d 6h", "whole minutes round up")
        XCTAssertEqual(text(0.5), "now")
    }

    func testTextInChinese() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let presentation = try presentation([
            Self.credit("a", expiresIn: 86_400),
            Self.credit("b", expiresIn: 30 * 3_600),
            Self.credit("c", expiresIn: nil),
        ])
        XCTAssertEqual(presentation.text, "可用 3 张")
        XCTAssertEqual(presentation.expirySummaryText, "1 天 · 1 天 6 小时 · 永不过期")
        XCTAssertEqual(presentation.items.first?.expiryText, "1 天后过期")
        XCTAssertEqual(L10n.resetCredits.title, "限额重置券")
        XCTAssertTrue(presentation.helpText.hasSuffix(L10n.resetCredits.readOnlyNote))
        XCTAssertTrue(L10n.resetCredits.readOnlyNote.hasSuffix("只显示，从不使用。"))
        // VoiceOver's countdown is in words, in Chinese too.
        XCTAssertTrue(presentation.accessibilityLabel.hasPrefix("限额重置券, 可用 3 张, 1天后过期, "),
                      presentation.accessibilityLabel)
        XCTAssertTrue(presentation.accessibilityLabel.contains("小时后过期"), presentation.accessibilityLabel)
        XCTAssertFalse(presentation.accessibilityLabel.contains("1 天 6 小时"), "the compact form is not spoken")
    }

    /// The ASCII numbers in `text`, in order: "6 天 4 小时" and "6天4小时后过期"
    /// are both [6, 4].
    private static func numbers(_ text: String) -> [Int] {
        text.split(whereSeparator: { !("0"..."9").contains($0) }).compactMap { Int($0) }
    }

    /// VoiceOver reads the chip's own units. A formatter given the time left
    /// rounds the last unit it keeps, so 6 days, 4 hours and 31 minutes,
    /// shown "6 天 4 小时", was spoken "6天5小时", and 6 days 23 hours 45
    /// minutes, shown "6 天 23 小时", was spoken "7天".
    func testVoiceOverSpeaksTheChipsUnitsInChinese() throws {
        LocaleOverrideStore.shared.set("zh-Hans")
        let presentation = try presentation([
            Self.credit("a", expiresIn: 6 * 86_400 + 4 * 3_600 + 31 * 60),
            Self.credit("b", expiresIn: 6 * 86_400 + 23 * 3_600 + 45 * 60),
            Self.credit("c", expiresIn: 86_400 + 5 * 60),
        ])
        // Soonest first.
        XCTAssertEqual(presentation.items.map(\.compactExpiryText), ["1 天 5 分钟", "6 天 4 小时", "6 天 23 小时"])
        XCTAssertEqual(presentation.items.map { Self.numbers($0.spokenExpiryText) }, [[1, 5], [6, 4], [6, 23]],
                       presentation.items.map(\.spokenExpiryText).joined(separator: " | "))
        let spoken = presentation.items[1].spokenExpiryText
        XCTAssertTrue(spoken.hasSuffix("小时后过期") && spoken.contains("天"), spoken)
        XCTAssertFalse(spoken.contains("6 天 4 小时"), "the compact form is not spoken: \(spoken)")
        XCTAssertTrue(presentation.accessibilityLabel.contains(spoken), presentation.accessibilityLabel)
    }

    func testVoiceOverSpeaksTheChipsUnitsInJapanese() throws {
        LocaleOverrideStore.shared.set("ja")
        let presentation = try presentation([
            Self.credit("a", expiresIn: 6 * 86_400 + 4 * 3_600 + 31 * 60),
            Self.credit("b", expiresIn: 2 * 3_600 + 59 * 60 + 1),
        ])
        // Soonest first; 2 h 59 min 1 s is whole minutes rounded up, on both.
        XCTAssertEqual(presentation.items.map(\.compactExpiryText), ["3 時間", "6 日 4 時間"])
        XCTAssertEqual(presentation.items.map { Self.numbers($0.spokenExpiryText) }, [[3], [6, 4]],
                       presentation.items.map(\.spokenExpiryText).joined(separator: " | "))
        let spoken = presentation.items[1].spokenExpiryText
        XCTAssertTrue(spoken.hasPrefix("あと ") && spoken.hasSuffix("時間で期限切れ") && spoken.contains("日"), spoken)
        XCTAssertFalse(spoken.contains("6 日 4 時間"), "the compact form is not spoken: \(spoken)")
    }

    /// Every countdown up to ten days, minute steps that cross each unit
    /// boundary: the spoken numbers are the chip's numbers, in both languages.
    func testSpokenCountdownNeverRoundsAwayFromTheChip() throws {
        for language in ["zh-Hans", "ja"] {
            LocaleOverrideStore.shared.set(language)
            var mismatches: [String] = []
            for minutes in stride(from: 1, through: 10 * 24 * 60, by: 7) {
                let units = CodexResetCreditsPresentation.CountdownUnits(totalMinutes: minutes)
                let spoken = try XCTUnwrap(CodexResetCreditsPresentation.spokenCountdownText(units), "\(minutes)")
                if Self.numbers(spoken) != Self.numbers(units.compactText) {
                    mismatches.append("\(minutes) min: \(units.compactText) / \(spoken)")
                }
            }
            XCTAssertEqual(Array(mismatches.prefix(5)), [], "\(language): \(mismatches.count) countdowns spoken differently")
        }
    }

    /// The title names the credits in every language. Under the 5-hour and
    /// Weekly bars, whose detail says "resets in 3d 4h", a bare "limit reset"
    /// reads as when the quota resets, and the countdowns beside it as that
    /// time. A ticket noun, not the word for credits: that word is already the
    /// Codex card's purchased-credits row.
    func testTheTitleNamesTheCreditsInEveryLanguage() {
        let expected = [
            "en": ("Limit reset credits", "2 available"),
            "ja": ("上限リセット券", "2 枚利用可能"),
            "ko": ("한도 리셋권", "2개 사용 가능"),
            "zh-Hans": ("限额重置券", "可用 2 张"),
            "zh-Hant": ("限額重置券", "可用 2 張"),
            "es": ("Créditos de reinicio", "2 disponibles"),
        ]
        for (language, (title, count)) in expected {
            LocaleOverrideStore.shared.set(language)
            XCTAssertEqual(L10n.resetCredits.title, title, language)
            XCTAssertEqual(L10n.resetCredits.available(2), count, language)
        }
    }

    func testTextInSpanish() throws {
        LocaleOverrideStore.systemLocale = { Locale(identifier: "es_ES") }
        LocaleOverrideStore.shared.set("es")
        let one = try presentation([Self.credit("a", expiresIn: 90 * 60)])
        XCTAssertEqual(one.text, "1 disponible")
        XCTAssertEqual(one.expirySummaryText, "1 h 30 min")
        let two = try presentation([Self.credit("a", expiresIn: 86_400), Self.credit("b", expiresIn: nil)])
        XCTAssertEqual(two.text, "2 disponibles")
        XCTAssertEqual(two.items.map(\.expiryText), ["Caduca en 1 d", "Sin caducidad"])
    }

    // MARK: - What the card draws

    private func resolve(
        _ snapshot: CodexRateLimitResetCreditsSnapshot?,
        outcome: CollectorOutcome? = .producedData,
        sandboxed: Bool = false,
        hasAccess: Bool = true,
        demo: Bool = false,
        accessAsked: UnsafeMutablePointer<Bool>? = nil
    ) -> CodexResetCreditsCardState {
        CodexResetCreditsCardState.resolve(
            snapshot: snapshot,
            latestOutcome: outcome,
            isSandboxed: sandboxed,
            hasCodexFolderAccess: {
                accessAsked?.pointee = true
                return hasAccess
            },
            isDemoMode: demo,
            now: Self.now
        )
    }

    private var twoCredits: CodexRateLimitResetCreditsSnapshot {
        Self.snapshot([Self.credit("a", expiresIn: 86_400), Self.credit("b", expiresIn: 2 * 86_400)])
    }

    func testAReadingFromAPassThatProducedDataIsShown() {
        guard case .inventory(let presentation) = resolve(twoCredits) else {
            return XCTFail("expected the inventory")
        }
        XCTAssertEqual(presentation.expirySummaryText, "1d · 2d")
    }

    /// A reading outlives a later pass that failed, or that never ran (Codex
    /// signed out, the provider switched off). It must not be shown then.
    func testAReadingIsNotShownAfterAPassThatProducedNoData() {
        for outcome: CollectorOutcome? in [nil, .disabled, .ranButEmpty, .failed(.network), .notReady(.unknown)] {
            XCTAssertEqual(resolve(twoCredits, outcome: outcome), .hidden, "\(String(describing: outcome))")
        }
    }

    func testNoCreditsDrawsNothing() {
        XCTAssertEqual(resolve(nil), .hidden)
        XCTAssertEqual(resolve(Self.snapshot([])), .hidden)
    }

    /// The App Store build without the Codex CLI folder grant cannot read the
    /// sign-in the request needs, so it says what to grant.
    func testTheSandboxedBuildWithoutTheCodexFolderGrantAsksForIt() {
        for declined: CollectorOutcome in [.notReady(.unknown), .notReady(.missingCredentials), .failed(.permission)] {
            XCTAssertEqual(resolve(nil, outcome: declined, sandboxed: true, hasAccess: false),
                           .needsCodexFolderAccess, "\(declined)")
            // With the grant there is nothing to ask for: no credits is no row.
            XCTAssertEqual(resolve(nil, outcome: declined, sandboxed: true, hasAccess: true), .hidden)
        }
    }

    /// A pass that produced data read the Codex sign-in (a credential bridged
    /// into the app group, say), and the credits with it. No usable credit,
    /// or a read that failed, is then no row: the folder is not what is
    /// missing, and asking for it would say so. The bookmark store is not
    /// even read.
    func testAPassThatProducedDataNeverAsksForTheFolder() {
        let nothingUsable = Self.snapshot([Self.credit("gone", status: .redeemed, expiresIn: 86_400)])
        for snapshot in [nil, nothingUsable] {
            var asked = false
            XCTAssertEqual(resolve(snapshot, sandboxed: true, hasAccess: false, accessAsked: &asked), .hidden)
            XCTAssertFalse(asked)
        }
    }

    /// The link is for a Codex this Mac could not read, not for a provider the
    /// user switched off, a pass that has not run yet, or a request that
    /// failed, none of which a folder grant fixes.
    func testTheFolderIsAskedForOnlyWhenTheCollectorDeclinedToRun() {
        for outcome: CollectorOutcome? in [nil, .disabled, .ranButEmpty, .failed(.network), .failed(.auth)] {
            var asked = false
            XCTAssertEqual(resolve(nil, outcome: outcome, sandboxed: true, hasAccess: false, accessAsked: &asked),
                           .hidden, "\(String(describing: outcome))")
            XCTAssertFalse(asked, "\(String(describing: outcome))")
        }
    }

    /// A credential bridged into the app group can read the credits without
    /// the grant; a reading beats the request for access.
    func testAReadingBeatsTheFolderRequest() {
        guard case .inventory = resolve(twoCredits, sandboxed: true, hasAccess: false) else {
            return XCTFail("a reading must be shown even without the folder grant")
        }
    }

    /// The Developer ID build reads `~/.codex` directly: it is never asked for
    /// a grant, and never shows the request.
    func testTheUnsandboxedBuildNeverAsksForTheFolder() {
        var asked = false
        XCTAssertEqual(resolve(nil, outcome: .notReady(.unknown), sandboxed: false, hasAccess: false,
                               accessAsked: &asked), .hidden)
        XCTAssertFalse(asked, "the bookmark store is read only in a sandboxed build")
    }

    /// Demo mode shows a reading production can show: two credits, at fixed
    /// countdowns, whatever the time.
    func testDemoShowsTwoCreditsAtFixedCountdowns() {
        for offset: TimeInterval in [0, 3_599, 86_400 * 3 + 17] {
            let now = Self.now.addingTimeInterval(offset)
            let state = CodexResetCreditsCardState.resolve(
                snapshot: nil, latestOutcome: nil, isSandboxed: true,
                hasCodexFolderAccess: { false }, isDemoMode: true, now: now
            )
            guard case .inventory(let presentation) = state else {
                return XCTFail("Demo mode must show its reading")
            }
            XCTAssertEqual(presentation.text, "2 available")
            XCTAssertEqual(presentation.expirySummaryText, "6d 4h · 21d 9h")
        }
    }
}
