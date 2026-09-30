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
            let (hint, start, last30) = inLocale(locale) {
                (L10n.localScanConsent.firstAskHint,
                 L10n.localScanConsent.start,
                 L10n.localScanConsent.lastThirtyDaysOnly)
            }
            XCTAssertTrue(hint.contains(start), "\(locale): \"\(hint)\" does not name \"\(start)\"")
            XCTAssertTrue(hint.contains(last30), "\(locale): \"\(hint)\" does not name \"\(last30)\"")
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
