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
    /// it says CLI Pulse does not scan this Mac until you say so, not "nothing
    /// has been read yet".
    func test_zhHansFirstAskSaysWhatHoldsForEveryoneShownIt() {
        inLocale("zh-Hans") {
            // The lookup keeps "CLI Pulse" on one line with a no-break space
            // (`L10n.displayFormat`); compared here as the catalogue spells it.
            let subtitle = L10n.localScanConsent.subtitle
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertEqual(subtitle, "在你同意之前，CLI Pulse 不会扫描这台 Mac。开始扫描后，将启用以下各项。")
            XCTAssertFalse(subtitle.contains("尚未读取"))
            XCTAssertEqual(L10n.localScanConsent.chooseAgain, "重新选择…")
            XCTAssertTrue(L10n.localScanConsent.settingsDeclinedDetail.contains("「暂时不要」"))
        }
    }

    /// "Reads nothing until you start the scan" was the last absolute "reads
    /// nothing" on the first ask, which 1.55 replaced with "not scanning"
    /// everywhere else: the same sheet can show the note that an old
    /// Companion CLI reads this Mac every 2 minutes. The subtitle says the
    /// scan does not run until you say so, in every language.
    func test_theFirstAskSubtitleNoLongerSaysNothingIsRead() {
        let readsNothing = [
            "en": "reads nothing", "zh-Hans": "不会读取任何内容", "zh-Hant": "不會讀取任何內容",
            "ja": "何も読み取りません", "ko": "아무것도 읽지 않습니다", "es": "no lee nada",
        ]
        let english = inLocale("en") { L10n.localScanConsent.subtitle }
        for locale in Self.locales {
            let subtitle = inLocale(locale) { L10n.localScanConsent.subtitle }
            XCTAssertFalse(subtitle.hasPrefix("local_scan_consent."), "\(locale) renders the raw key")
            XCTAssertFalse(subtitle.contains(readsNothing[locale]!), "\(locale): \(subtitle)")
            if locale != "en" {
                XCTAssertNotEqual(subtitle, english, "\(locale): the subtitle is the English text")
            }
        }
        inLocale("en") {
            XCTAssertTrue(L10n.localScanConsent.subtitle.contains("doesn't scan this Mac until you say so"))
        }
    }

    /// v1.56: the year is read once, and the Codex logs again whenever a CLI
    /// Pulse update changes how it counts Codex, or when the signed-in account
    /// holds older Codex figures from this Mac to correct
    /// (`DailyUsageArchiveManager.rebuildCodexHistoryIfNeeded`: the archive's
    /// part is due once per Codex rules version, the cloud's once per rules
    /// version and account). Until 1.56 these lines said "once" and nothing
    /// more, which the rebuild would have made false. Every line that
    /// describes the read of older logs gives both reasons, in every language,
    /// and names CLI Pulse as the one whose update it is, not Codex; the
    /// titles and captions that only name it no longer call it one-time.
    func test_everyLineThatDescribesTheYearSaysCodexIsReadAgain() {
        // Whose update: CLI Pulse's, not Codex's.
        let cliPulseUpdate: [String: String] = [
            "en": "a CLI Pulse update changes how it counts Codex usage",
            "zh-Hans": "CLI Pulse 的更新改变 Codex 用量的计算方式",
            "zh-Hant": "CLI Pulse 的更新改變 Codex 用量的計算方式",
            "ja": "CLI Pulse のアップデートで Codex の使用量の数え方が変わったとき",
            "ko": "CLI Pulse 업데이트로 Codex 사용량을 세는 방식이 바뀌거나",
            "es": "una nueva versión de CLI Pulse cambie cómo cuenta el uso de Codex",
        ]
        // The second reason: the signed-in account has this Mac's older
        // Codex figures to correct (`CodexHistoryRebuild.State.cloudIsDue`).
        let signedInAccount: [String: String] = [
            "en": "or when the account you're signed in to has older Codex figures from this Mac to correct",
            "zh-Hans": "或你登录的账户里有这台 Mac 以前同步、需要更正的 Codex 数字时",
            "zh-Hant": "或你登入的帳號裡有這台 Mac 先前同步、需要更正的 Codex 數字時",
            "ja": "サインイン中のアカウントで、この Mac が以前同期した Codex の数値を修正する必要があるとき",
            "ko": "로그인한 계정에서 이 Mac이 전에 동기화한 Codex 수치를 바로잡아야 할 때",
            "es": "o cuando haya que corregir cifras antiguas de Codex de este Mac en la cuenta con la que tienes la sesión iniciada",
        ]
        // How each catalogue used to call the read once and for all.
        let oneTime: [String: [String]] = [
            "en": ["one-time", "Once, and only"],
            "zh-Hans": ["一次性", "读取一次最多", "读取一次旧日志"],
            "zh-Hant": ["讀取一次最多", "讀取一次舊日誌"],
            "ja": ["一度きり", "（一度だけ）", "一度だけ読み取ります"],
            "ko": ["는 한 번만", "한 번만 읽습니다", "한 번 읽는 작업"],
            "es": ["una sola vez", "lectura única"],
        ]
        for locale in Self.locales {
            let texts = inLocale(locale) {
                [
                    "files_detail": L10n.localScanConsent.filesDetail,
                    "v2_subtitle": L10n.localScanConsent.v2Subtitle,
                    "history_toggle_detail": L10n.localScanConsent.historyToggleDetail,
                ]
            }
            for (key, shown) in texts {
                // The brand is laid out with a no-break space (`L10n.displayFormat`).
                let text = shown.replacingOccurrences(of: "\u{00A0}", with: " ")
                XCTAssertTrue(text.contains("Codex"),
                              "\(locale): \(key) does not say the Codex logs are read again: \(text)")
                XCTAssertTrue(text.contains(cliPulseUpdate[locale]!),
                              "\(locale): \(key) does not say it is a CLI Pulse update that changes the counting: \(text)")
                XCTAssertTrue(text.contains(signedInAccount[locale]!),
                              "\(locale): \(key) leaves out the read for a signed-in account's older Codex figures: \(text)")
            }
            let named = inLocale(locale) {
                [
                    "files_title": L10n.localScanConsent.filesTitle,
                    "first_ask_hint": L10n.localScanConsent.firstAskHint,
                    "first_ask_hint_signed_in": L10n.localScanConsent.firstAskHintSignedIn,
                ]
            }
            for (key, text) in named.merging(texts, uniquingKeysWith: { a, _ in a }) {
                for phrase in oneTime[locale]! {
                    XCTAssertFalse(text.contains(phrase),
                                   "\(locale): \(key) still calls the read of older logs one-time (\"\(phrase)\"): \(text)")
                }
            }
        }
    }

    /// Spelled out once in Simplified Chinese, the locale these catalogues are
    /// checked in: the screen says 30 days and a year, that the year is read
    /// once, and that the Codex logs are read again after a counting change.
    func test_zhHansSaysThirtyDaysAYearAndWhenCodexIsReadAgain() {
        inLocale("zh-Hans") {
            XCTAssertEqual(L10n.localScanConsent.filesTitle, "会话日志：最近 30 天，经你允许还可读取最多一年")
            let subtitle = L10n.localScanConsent.v2Subtitle.replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertTrue(subtitle.contains("最近 30 天"))
            XCTAssertTrue(subtitle.contains("最多一年的旧会话日志：先读取一次"))
            XCTAssertTrue(subtitle.contains(
                "之后每当 CLI Pulse 的更新改变 Codex 用量的计算方式，或你登录的账户里有这台 Mac 以前同步、需要更正的 Codex 数字时，会再读取一次 Codex 的日志"))
            XCTAssertEqual(L10n.localScanConsent.lastThirtyDaysOnly, "仅最近 30 天")
            XCTAssertEqual(L10n.localScanConsent.includeHistory, "包括更早的历史")
        }
    }
}
