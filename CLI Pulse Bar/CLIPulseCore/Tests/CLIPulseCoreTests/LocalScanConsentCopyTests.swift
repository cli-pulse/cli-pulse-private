import XCTest
@testable import CLIPulseCore

/// v1.55 — what the consent screen and the Settings switches say about how far
/// back CLI Pulse reads, held to what the code actually reads.
///
/// The 1.50 screen said "Session logs, last 30 days" while a one-time backfill
/// read up to a year. The copy and the read window lived in different files and
/// nothing compared them. These tests compare them: the windows are numbers in
/// `LocalScanDisclosure`, the scanner and the backfill are pinned to those
/// numbers, and every catalogue is pinned to stating both.
///
/// Asserted per language, not in English only: in English a broken lookup still
/// returns English text, so an en-only check would pass with every translation
/// missing or still saying "30 days" alone.
final class LocalScanConsentCopyTests: XCTestCase {

    private static let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]

    /// How each catalogue says "up to a year" in these strings.
    private static let yearPhrase: [String: String] = [
        "en": "a year",
        "zh-Hans": "一年",
        "zh-Hant": "一年",
        "ja": "1 年",
        "ko": "1년",
        "es": "un año",
    ]

    private func inLocale<T>(_ locale: String, _ body: () throws -> T) rethrows -> T {
        let store = LocaleOverrideStore.shared
        let saved = store.override
        defer { store.set(saved) }
        store.set(locale)
        return try body()
    }

    #if os(macOS)
    /// If either read window changes, this fails, and whoever changed it is
    /// sent to the copy that promises the old number.
    func test_theWindowsTheCopyStatesAreTheWindowsTheCodeReads() {
        XCTAssertEqual(
            CostUsageScanner.Options().daysToScan,
            LocalScanDisclosure.routineWindowDays,
            "the routine scan no longer reads what the disclosure says"
        )
        XCTAssertEqual(
            DailyUsageArchiveManager.backfillDays,
            LocalScanDisclosure.historyWindowDays,
            "the history read no longer reads what the disclosure says"
        )
        // The catalogues spell these out as "30" and "a year".
        XCTAssertEqual(LocalScanDisclosure.routineWindowDays, 30)
        XCTAssertEqual(LocalScanDisclosure.historyWindowDays, 365)
    }
    #endif

    /// The files row is the line that said "last 30 days" and nothing else.
    func test_theFilesRowNamesBothWindowsInEveryLanguage() {
        let english = inLocale("en") {
            (L10n.localScanConsent.filesTitle, L10n.localScanConsent.filesDetail)
        }
        for locale in Self.locales {
            let (title, detail) = inLocale(locale) {
                (L10n.localScanConsent.filesTitle, L10n.localScanConsent.filesDetail)
            }
            let year = Self.yearPhrase[locale]!
            for (name, text) in [("files_title", title), ("files_detail", detail)] {
                XCTAssertFalse(text.hasPrefix("local_scan_consent."), "\(locale): \(name) renders the raw key")
                XCTAssertTrue(text.contains("30"), "\(locale): \(name) lost the routine window: \(text)")
                XCTAssertTrue(text.contains(year), "\(locale): \(name) does not say \"\(year)\": \(text)")
            }
            if locale != "en" {
                XCTAssertNotEqual(title, english.0, "\(locale): files_title is the English text")
                XCTAssertNotEqual(detail, english.1, "\(locale): files_detail is the English text")
            }
        }
    }

    /// The Settings detail for the scan used to say "Reads the last 30 days",
    /// full stop. It now points at the second switch, and that switch states the
    /// year and that turning it off keeps 30 days.
    func test_theSettingsSwitchesStateTheirWindowsInEveryLanguage() {
        for locale in Self.locales {
            let (scanDetail, historyDetail) = inLocale(locale) {
                (L10n.localScanConsent.settingsToggleDetail,
                 L10n.localScanConsent.historyToggleDetail)
            }
            let year = Self.yearPhrase[locale]!
            XCTAssertTrue(scanDetail.contains("30"), "\(locale): \(scanDetail)")
            XCTAssertTrue(historyDetail.contains(year), "\(locale): \(historyDetail)")
            XCTAssertTrue(historyDetail.contains("30"),
                          "\(locale): the older-logs switch does not say off keeps 30 days: \(historyDetail)")
        }
    }

    /// The v2 screen's own text: present, and translated, in every language.
    func test_theV2CopyIsTranslatedEverywhere() {
        func texts() -> [String: String] {
            [
                "last_30_days_only": L10n.localScanConsent.lastThirtyDaysOnly,
                "first_ask_hint": L10n.localScanConsent.firstAskHint,
                "v2_title": L10n.localScanConsent.v2Title,
                "v2_subtitle": L10n.localScanConsent.v2Subtitle,
                "include_history": L10n.localScanConsent.includeHistory,
                "history_toggle": L10n.localScanConsent.historyToggle,
                "history_toggle_detail": L10n.localScanConsent.historyToggleDetail,
                "subtitle": L10n.localScanConsent.subtitle,
                "settings_declined_detail": L10n.localScanConsent.settingsDeclinedDetail,
                "choose_again": L10n.localScanConsent.chooseAgain,
                "first_ask_hint_signed_in": L10n.localScanConsent.firstAskHintSignedIn,
            ]
        }
        let english = inLocale("en") { texts() }
        for locale in Self.locales {
            let localized = inLocale(locale) { texts() }
            for (key, text) in localized {
                XCTAssertFalse(text.isEmpty, "\(locale): \(key) is empty")
                XCTAssertFalse(text.hasPrefix("local_scan_consent."), "\(locale): \(key) renders the raw key")
                if locale != "en" {
                    XCTAssertNotEqual(text, english[key], "\(locale): \(key) is the English text")
                }
            }
            XCTAssertTrue(localized["v2_subtitle"]!.contains(Self.yearPhrase[locale]!),
                          "\(locale): the v2 question does not say how far back: \(localized["v2_subtitle"]!)")
        }
    }

    /// The first ask's caption tells the two scanning buttons apart by name, so
    /// the names have to be the buttons' own labels in each catalogue — a
    /// translator who renames a button and not the caption would leave the
    /// caption pointing at a button that is not there.
    func test_theFirstAskHintQuotesTheButtonsAsTheyAreLabelled() {
        for locale in Self.locales {
            let (hint, signedIn, start, last30, notNow) = inLocale(locale) {
                (L10n.localScanConsent.firstAskHint,
                 L10n.localScanConsent.firstAskHintSignedIn,
                 L10n.localScanConsent.start,
                 L10n.localScanConsent.lastThirtyDaysOnly,
                 L10n.localScanConsent.notNow)
            }
            for caption in [hint, signedIn] {
                XCTAssertTrue(caption.contains(start), "\(locale): \"\(caption)\" does not name \"\(start)\"")
                XCTAssertTrue(caption.contains(last30), "\(locale): \"\(caption)\" does not name \"\(last30)\"")
            }
            XCTAssertTrue(signedIn.contains(notNow), "\(locale): \"\(signedIn)\" does not name \"\(notNow)\"")
        }
    }

    /// The first ask's usual caption ends "you can change it any time in
    /// Settings › Privacy", which holds without an account. A signed-in Mac
    /// reaches the first ask only through "Choose again…", has no scan switch
    /// while signed in, and gets a caption of its own. The older-logs ask keeps
    /// its caption either way.
    func test_aSignedInFirstAskHasItsOwnCaption() {
        for locale in Self.locales {
            let captions = inLocale(locale) {
                (local: LocalScanQuestion.firstAsk.caption(isAuthenticated: false),
                 signedIn: LocalScanQuestion.firstAsk.caption(isAuthenticated: true),
                 olderLocal: LocalScanQuestion.olderLogs.caption(isAuthenticated: false),
                 olderSignedIn: LocalScanQuestion.olderLogs.caption(isAuthenticated: true),
                 expected: (L10n.localScanConsent.firstAskHint,
                            L10n.localScanConsent.firstAskHintSignedIn,
                            L10n.localScanConsent.changeLater))
            }
            XCTAssertEqual(captions.local, captions.expected.0, locale)
            XCTAssertEqual(captions.signedIn, captions.expected.1, locale)
            XCTAssertNotEqual(captions.signedIn, captions.local, "\(locale): one caption for both")
            XCTAssertEqual(captions.olderLocal, captions.expected.2, locale)
            XCTAssertEqual(captions.olderSignedIn, captions.expected.2, locale)
        }
        inLocale("zh-Hans") {
            let signedIn = LocalScanQuestion.firstAsk.caption(isAuthenticated: true)
            XCTAssertFalse(signedIn.contains("随时可以改"), "the signed-in caption promises the scan switch")
            XCTAssertTrue(signedIn.contains("退出登录"), "the signed-in caption does not say signing out stops the scan")
        }
    }

    /// How each catalogue says "history already built stays on this Mac".
    private static let builtHistoryStays: [String: String] = [
        "en": "already built stays on this Mac",
        "zh-Hans": "保留在这台 Mac 上",
        "zh-Hant": "留在這台 Mac 上",
        "ja": "作成済みの履歴はこの Mac に残ります",
        "ko": "이미 만들어진 기록은 이 Mac에 남습니다",
        "es": "el historial ya creado se queda en este Mac",
    ]

    /// "Last 30 days only" deletes nothing: usage history already built stays
    /// on the Mac. Every screen that offers that answer says so — the first
    /// ask, the older-logs ask, and the Settings switch — in every language.
    func test_everyPlaceThatOffersLast30DaysOnlySaysBuiltHistoryStays() {
        for locale in Self.locales {
            let texts = inLocale(locale) {
                [
                    "first_ask_hint": L10n.localScanConsent.firstAskHint,
                    "first_ask_hint_signed_in": L10n.localScanConsent.firstAskHintSignedIn,
                    "v2_subtitle": L10n.localScanConsent.v2Subtitle,
                    "history_toggle_detail": L10n.localScanConsent.historyToggleDetail,
                ]
            }
            let phrase = Self.builtHistoryStays[locale]!
            for (key, text) in texts {
                XCTAssertTrue(text.contains(phrase),
                              "\(locale): \(key) does not say built history stays (\"\(phrase)\"): \(text)")
            }
        }
    }

    /// The Settings way back from "Not now" quotes that button by its label, in
    /// each catalogue, so it cannot point at a button that is not there.
    func test_theSettingsWayBackQuotesNotNowAsLabelled() {
        for locale in Self.locales {
            let (detail, notNow) = inLocale(locale) {
                (L10n.localScanConsent.settingsDeclinedDetail, L10n.localScanConsent.notNow)
            }
            XCTAssertTrue(detail.contains(notNow), "\(locale): \"\(detail)\" does not name \"\(notNow)\"")
        }
    }

    /// The first ask is also shown to people whose Mac was read before: a
    /// signed-in "Not now" choosing again, and a signed-in user who answered
    /// only the older-logs question and later signed out into local mode. So
    /// it says nothing is read until the scan starts, not "nothing has been
    /// read yet".
    func test_zhHansFirstAskSaysWhatHoldsForEveryoneShownIt() {
        inLocale("zh-Hans") {
            // The lookup keeps "CLI Pulse" on one line with a no-break space
            // (`L10n.displayFormat`); compared here as the catalogue spells it.
            let subtitle = L10n.localScanConsent.subtitle
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertEqual(subtitle, "开始扫描之前，CLI Pulse 不会读取任何内容。开始扫描后，将启用以下各项。")
            XCTAssertFalse(subtitle.contains("尚未读取"))
            XCTAssertEqual(L10n.localScanConsent.chooseAgain, "重新选择…")
            XCTAssertTrue(L10n.localScanConsent.settingsDeclinedDetail.contains("「暂时不要」"))
        }
    }

    /// Spelled out once in Simplified Chinese, the locale these catalogues are
    /// checked in: the screen says 30 days and a year, and the year is one read.
    func test_zhHansSaysThirtyDaysAndOneYearOnce() {
        inLocale("zh-Hans") {
            XCTAssertEqual(L10n.localScanConsent.filesTitle, "会话日志：最近 30 天，另可一次性读取最多一年")
            XCTAssertTrue(L10n.localScanConsent.v2Subtitle.contains("最近 30 天"))
            XCTAssertTrue(L10n.localScanConsent.v2Subtitle.contains("一次性读取最多一年"))
            XCTAssertEqual(L10n.localScanConsent.lastThirtyDaysOnly, "仅最近 30 天")
            XCTAssertEqual(L10n.localScanConsent.includeHistory, "包括更早的历史")
        }
    }
}
