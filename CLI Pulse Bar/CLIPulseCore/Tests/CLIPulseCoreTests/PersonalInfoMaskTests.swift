import XCTest
@testable import CLIPulseCore

/// "Hide personal information" masks the account labels that read as email
/// addresses, on the Mac, the iPhone and the Watch, which follows the iPhone.
///
/// Asserted in Simplified Chinese: in English the masked name ("Account 2")
/// is also what a missing translation falls back to, so an English check
/// cannot tell the catalogue lookup worked.
final class PersonalInfoMaskTests: XCTestCase {

    private var previousLocale: String?

    override func setUp() {
        super.setUp()
        previousLocale = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousLocale)
        super.tearDown()
    }

    // MARK: - The mask

    func testAnAddressIsShownAsItsPositionWithTheSwitchOn() {
        let name = PersonalInfoMask.accountName(
            label: "alice@example.com",
            index: 1,
            accountCount: 2,
            hidePersonalInfo: true
        )
        XCTAssertEqual(name, "账户 2")
        XCTAssertFalse(name.contains("@"))
    }

    /// Negative control: the switch off shows the label exactly as written.
    func testTheSwitchOffShowsTheAddress() {
        XCTAssertEqual(
            PersonalInfoMask.accountName(
                label: "alice@example.com",
                index: 1,
                accountCount: 2,
                hidePersonalInfo: false
            ),
            "alice@example.com"
        )
        XCTAssertEqual(
            PersonalInfoMask.accountLabel(
                "alice@example.com",
                index: 0,
                hidePersonalInfo: false
            ),
            "alice@example.com"
        )
    }

    /// Only addresses are masked: a label the owner chose as a name is theirs.
    func testLabelsThatAreNotAddressesStay() {
        for label in ["Work", "dev-box", "Claude · Personal", "团队 A"] {
            XCTAssertEqual(
                PersonalInfoMask.accountName(
                    label: label,
                    index: 0,
                    accountCount: 2,
                    hidePersonalInfo: true
                ),
                label
            )
        }
    }

    /// Every spelling of an address that could reach the screen: no dot after
    /// the at sign, surrounding spaces, and the full-width and small at signs
    /// a Chinese or Japanese keyboard types.
    func testNoAtSignIsLeftOnScreen() {
        let labels = [
            "name@company",
            "  alice@example.com  ",
            "alice\u{FF20}example.com",
            "alice\u{FE6B}example.com",
            "Work (alice@example.com)",
        ]
        for (index, label) in labels.enumerated() {
            let name = PersonalInfoMask.accountName(
                label: label,
                index: index,
                accountCount: labels.count,
                hidePersonalInfo: true
            )
            XCTAssertEqual(name, "账户 \(index + 1)", label)
            XCTAssertFalse(
                name.contains { "@\u{FF20}\u{FE6B}".contains($0) },
                "\(label) left an at sign: \(name)"
            )
        }
    }

    /// An account without a label is named as before, whatever the switch.
    func testUnlabeledAccountsKeepTheirNames() {
        for hide in [false, true] {
            for blank in [nil, "", "   "] as [String?] {
                XCTAssertEqual(
                    PersonalInfoMask.accountName(
                        label: blank,
                        index: 0,
                        accountCount: 1,
                        hidePersonalInfo: hide
                    ),
                    "默认账户"
                )
                XCTAssertEqual(
                    PersonalInfoMask.accountName(
                        label: blank,
                        index: 2,
                        accountCount: 3,
                        hidePersonalInfo: hide
                    ),
                    "账户 3"
                )
                XCTAssertNil(
                    PersonalInfoMask.accountLabel(
                        blank,
                        index: 0,
                        hidePersonalInfo: hide
                    )
                )
            }
        }
    }

    /// The line under a single-account provider's card on the Mac.
    func testTheCardLineOfASingleAccountIsMasked() {
        XCTAssertEqual(
            PersonalInfoMask.accountLabel(
                "me@example.com",
                index: 0,
                hidePersonalInfo: true
            ),
            "账户 1"
        )
        XCTAssertEqual(
            PersonalInfoMask.accountLabel(
                "me@example.com",
                index: nil,
                hidePersonalInfo: true
            ),
            "账户 1",
            "an account missing from the list still loses its address"
        )
    }

    /// Settings › Providers asks before removing an account, and names it
    /// with the masked name. The Korean title added its own 계정 ("account")
    /// after the name, so a masked account read "Claude · 계정 2 계정을
    /// 제거할까요?". In every language the title names the account once.
    func testTheRemoveConfirmationNamesAMaskedAccountOnce() {
        for locale in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            LocaleOverrideStore.shared.set(locale)
            let name = PersonalInfoMask.accountName(
                label: "alice@example.com",
                index: 1,
                accountCount: 2,
                hidePersonalInfo: true
            )
            let accountWord = name
                .replacingOccurrences(of: "2", with: "")
                .trimmingCharacters(in: .whitespaces)
            let title = L10n.providers.removeAccountTitle("Claude", name)
            XCTAssertFalse(accountWord.isEmpty, locale)
            XCTAssertTrue(title.contains(name), "\(locale): \(title)")
            XCTAssertFalse(title.contains("@"), "\(locale): \(title)")
            XCTAssertEqual(
                title.components(separatedBy: accountWord).count - 1,
                1,
                "\(locale) names the account more than once: \(title)"
            )
        }

        LocaleOverrideStore.shared.set("ko")
        XCTAssertEqual(
            L10n.providers.removeAccountTitle(
                "Claude",
                PersonalInfoMask.accountName(
                    label: "alice@example.com",
                    index: 1,
                    accountCount: 2,
                    hidePersonalInfo: true
                )
            ),
            "Claude · 계정 2을(를) 제거할까요?"
        )
        // An account without a label ("기본 계정") had the same doubled word.
        XCTAssertEqual(
            L10n.providers.removeAccountTitle(
                "Claude",
                PersonalInfoMask.accountName(
                    label: nil,
                    index: 0,
                    accountCount: 1,
                    hidePersonalInfo: true
                )
            ),
            "Claude · 기본 계정을(를) 제거할까요?"
        )
    }

    // MARK: - The Watch follows the iPhone

    func testTheWatchMasksWhatTheIPhoneMasks() throws {
        let (phone, phoneSuite) = try Self.makeDefaults()
        let (watch, watchSuite) = try Self.makeDefaults()
        defer {
            phone.removePersistentDomain(forName: phoneSuite)
            watch.removePersistentDomain(forName: watchSuite)
        }
        let label = "alice@example.com"

        func sendAndShow(_ phoneChoice: Bool) -> String {
            var context: [String: Any] = ["cli_pulse_context": true]
            PersonalInfoMask.addPhoneChoice(phoneChoice, to: &context)
            PersonalInfoMask.adoptPhoneChoice(
                PersonalInfoMask.phoneChoice(inWatchContext: context),
                defaults: watch
            )
            return PersonalInfoMask.accountName(
                label: label,
                index: 0,
                accountCount: 2,
                hidePersonalInfo: PersonalInfoMask.isOn(defaults: watch)
            )
        }

        XCTAssertFalse(PersonalInfoMask.isOn(defaults: watch), "off until the iPhone says otherwise")
        XCTAssertEqual(sendAndShow(true), "账户 1")
        // Negative control: the iPhone turning it off shows the address again.
        XCTAssertEqual(sendAndShow(false), label)
        XCTAssertEqual(sendAndShow(true), "账户 1")
    }

    /// A context without the choice (an iPhone app older than it) must not
    /// show the addresses the owner hid.
    func testAContextWithoutTheChoiceKeepsTheWatchsOwn() throws {
        let (watch, suite) = try Self.makeDefaults()
        defer { watch.removePersistentDomain(forName: suite) }

        PersonalInfoMask.adoptPhoneChoice(true, defaults: watch)
        let silent: [String: Any] = ["cli_pulse_context": true]
        XCTAssertNil(PersonalInfoMask.phoneChoice(inWatchContext: silent))
        PersonalInfoMask.adoptPhoneChoice(
            PersonalInfoMask.phoneChoice(inWatchContext: silent),
            defaults: watch
        )
        XCTAssertTrue(PersonalInfoMask.isOn(defaults: watch))
    }

    /// WatchConnectivity hands the context back as property-list values; a
    /// Bool arrives as an NSNumber.
    func testTheChoiceSurvivesAPropertyListRoundTrip() throws {
        var context: [String: Any] = [:]
        PersonalInfoMask.addPhoneChoice(true, to: &context)
        let data = try PropertyListSerialization.data(
            fromPropertyList: context,
            format: .binary,
            options: 0
        )
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(PersonalInfoMask.phoneChoice(inWatchContext: decoded), true)
    }

    // MARK: - The switch itself

    /// The key installs already hold the switch under: a new one would turn
    /// it off for everyone who turned it on. It must also survive the move
    /// from the App Store build to the direct-download one.
    func testTheSwitchKeepsItsKey() {
        XCTAssertEqual(PersonalInfoMask.defaultsKey, "cli_pulse_hide_personal_info")
        XCTAssertTrue(
            UnsandboxedDataMigration.appOwnedKeyPrefixes.contains {
                PersonalInfoMask.defaultsKey.hasPrefix($0)
            }
        )
    }

    /// The Settings switch writes the key the views read, and announces a
    /// change (the iPhone then sends it to the Watch), once per change.
    @MainActor
    func testTheSettingsSwitchWritesTheKeyTheViewsRead() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: PersonalInfoMask.defaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: PersonalInfoMask.defaultsKey)
            } else {
                defaults.removeObject(forKey: PersonalInfoMask.defaultsKey)
            }
        }
        defaults.set(false, forKey: PersonalInfoMask.defaultsKey)

        let state = AppState()
        let posts = PostCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .hidePersonalInfoDidChange,
            object: state,
            queue: nil
        ) { _ in posts.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        state.hidePersonalInfo = true
        XCTAssertTrue(PersonalInfoMask.isOn(defaults: defaults))
        XCTAssertEqual(posts.value, 1)

        state.hidePersonalInfo = true
        XCTAssertEqual(posts.value, 1, "setting the same value again is not a change")

        state.hidePersonalInfo = false
        XCTAssertFalse(PersonalInfoMask.isOn(defaults: defaults))
        XCTAssertEqual(posts.value, 2)
    }

    /// Notifications are posted on the thread that changes the switch, here
    /// the test's; the lock only satisfies the observer block's `Sendable`.
    private final class PostCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private static func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "PersonalInfoMaskTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
