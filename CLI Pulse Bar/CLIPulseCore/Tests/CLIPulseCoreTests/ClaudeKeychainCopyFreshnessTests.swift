#if os(macOS)
import Security
import XCTest
@testable import CLIPulseCore

/// 2026-11-23: the app's copy of Claude Code's keychain login is used only
/// while it can still be that login.
///
/// Claude Code renews its login every few hours and rewrites its keychain
/// item. The copy was handed out regardless, so after each renewal OAuth
/// refused it, the copy was cleared and a 30-minute cooldown left the card
/// without Claude figures. Now the item's modification date (read without a
/// dialog) and the copy's expiry decide whether to read the item again, and
/// how: a rewrite while the copy still works is read without a dialog, so
/// this never asks the user more often than before.
///
/// Every source is injected: the item's date, `SecItemCopyMatching`, the
/// clock, and the copy itself (KeychainHelper's in-memory store under XCTest).
final class ClaudeKeychainCopyFreshnessTests: XCTestCase {

    private var now = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private var cooldownSuite: String!

    /// The item: its date, and what reading it answers.
    private var itemDate: Date? = Date(timeIntervalSinceReferenceDate: 2_990_000)
    private var itemAnswer: (OSStatus, CFTypeRef?) = (errSecItemNotFound, nil)
    /// Each read of the item, and whether it was told not to show the dialog.
    private var reads: [Bool] = []
    private var dateQueries = 0
    private var originalItemModified: (() -> Date?)!
    private var originalCopyKeychainItem: ((CFDictionary) -> (OSStatus, CFTypeRef?))!

    override func setUp() {
        super.setUp()
        cooldownSuite = "test.claude-copy-freshness.\(UUID().uuidString)"
        ClaudeCredentials.cooldownDefaults = UserDefaults(suiteName: cooldownSuite)!
        ClaudeCredentials.nowProvider = { [weak self] in self?.now ?? Date() }
        ClaudeCredentials.keychainReadCooldownInterval = 30 * 60
        ClaudeCredentials.clearKeychainReadCooldown()
        ClaudeCredentials.clearCachedKeychainCredentials()
        reads = []
        dateQueries = 0
        originalItemModified = ClaudeCredentials.keychainItemModified
        originalCopyKeychainItem = ClaudeCredentials.copyKeychainItem
        ClaudeCredentials.keychainItemModified = { [weak self] in
            guard let self else { return nil }
            self.dateQueries += 1
            return self.itemDate
        }
        ClaudeCredentials.copyKeychainItem = { [weak self] query in
            guard let self else { return (errSecItemNotFound, nil) }
            let dict = query as NSDictionary
            let quiet = (dict[kSecUseAuthenticationUI as String] as? String)
                == (kSecUseAuthenticationUIFail as String)
            self.reads.append(quiet)
            return self.itemAnswer
        }
    }

    override func tearDown() {
        KeychainHelper.lockedKeysForTesting = []
        ClaudeCredentials.clearCachedKeychainCredentials()
        ClaudeCredentials.copyKeychainItem = originalCopyKeychainItem
        ClaudeCredentials.keychainItemModified = originalItemModified
        ClaudeCredentials.nowProvider = { Date() }
        ClaudeCredentials.cooldownDefaults = UserDefaults(suiteName: "group.yyh.CLI-Pulse") ?? .standard
        UserDefaults().removePersistentDomain(forName: cooldownSuite)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Claude Code's item holding `token`, valid until `expiresIn` from now.
    private func item(_ token: String, expiresIn: TimeInterval = 3600) -> (OSStatus, CFTypeRef?) {
        let ms = Int64(now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"\#(token)","rateLimitTier":"default_claude_max_5x","expiresAt":\#(ms)}}"#
        return (errSecSuccess, Data(json.utf8) as CFData)
    }

    /// The background read the token resolver makes (Settings › Privacy's
    /// switches off).
    private func backgroundRead(skip: Bool = false) -> ClaudeKeychainLookup {
        let suite = "test.claude-copy-freshness.privacy.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let privacy = PrivacySettings(defaults: UserDefaults(suiteName: suite)!)
        privacy.skipClaudeKeychain = skip
        return ClaudeCredentials.readKeychainForTokenResolver(privacy: privacy)
    }

    private func token(_ lookup: ClaudeKeychainLookup) -> String? {
        if case .found(let creds) = lookup { return creds.accessToken }
        return nil
    }

    private func miss(_ lookup: ClaudeKeychainLookup) -> ClaudeKeychainMiss? {
        if case .missing(let miss) = lookup { return miss }
        return nil
    }

    /// Reads the item once so the copy holds `token`, taken at `itemDate`.
    private func copy(_ token: String, expiresIn: TimeInterval = 3600) {
        itemAnswer = item(token, expiresIn: expiresIn)
        XCTAssertEqual(self.token(backgroundRead()), token)
        reads = []
    }

    // MARK: - The copy while it is current

    func test_currentCopy_ofAnUnchangedItem_readsNothing() {
        copy("sk-ant-oat01-a")
        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-a")
        XCTAssertEqual(reads, [], "a current copy read the item again")
    }

    // MARK: - Claude Code rewrote the item

    func test_rewrittenItem_whileTheCopyWorks_isReadWithoutADialog_andReplacesTheCopy() {
        copy("sk-ant-oat01-a")
        itemDate = itemDate!.addingTimeInterval(4 * 3600)
        itemAnswer = item("sk-ant-oat01-b")

        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b")
        XCTAssertEqual(reads, [true], "a rewrite while the copy works must not show the dialog")

        // The new copy carries the new date: nothing more to read.
        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b")
        XCTAssertEqual(reads, [true])
    }

    func test_rewrittenItem_thatWouldNeedTheDialog_keepsTheWorkingCopy_andArmsNothing() {
        copy("sk-ant-oat01-a")
        itemDate = itemDate!.addingTimeInterval(4 * 3600)
        itemAnswer = (errSecInteractionNotAllowed, nil)

        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-a")
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown(),
                     "nobody said no; a quiet read that failed is no reason for a cooldown")
    }

    func test_rewrittenItem_holdingAnOlderLogin_keepsTheCopy() {
        copy("sk-ant-oat01-a")
        itemDate = itemDate!.addingTimeInterval(60)
        itemAnswer = item("sk-ant-oat01-old", expiresIn: -60)

        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-a")
        XCTAssertEqual(ClaudeCredentials.readCachedKeychainCredentials()?.accessToken, "sk-ant-oat01-a")
    }

    func test_quietRead_isNotHeldBackByACooldown() {
        copy("sk-ant-oat01-a")
        ClaudeCredentials.installKeychainReadCooldown(cause: .declined)
        itemDate = itemDate!.addingTimeInterval(4 * 3600)
        itemAnswer = item("sk-ant-oat01-b")

        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b")
        XCTAssertEqual(reads, [true])
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown(),
                     "a successful read ends the cooldown, as it always has")
    }

    // MARK: - The copy has expired (the 2026-11-23 case)

    func test_expiredCopy_ofARewrittenItem_readsTheItem_andMayAsk() {
        copy("sk-ant-oat01-a", expiresIn: 3600)
        now = now.addingTimeInterval(2 * 3600)
        itemDate = itemDate!.addingTimeInterval(3600)
        itemAnswer = item("sk-ant-oat01-b")

        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b",
                       "the renewed login, at once: no refused call, no cooldown")
        XCTAssertEqual(reads, [false], "the read the dialog is for")
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown())
    }

    func test_expiredCopy_ofARewrittenItem_waitsForACooldown() {
        copy("sk-ant-oat01-a", expiresIn: 3600)
        now = now.addingTimeInterval(2 * 3600)
        itemDate = itemDate!.addingTimeInterval(3600)
        ClaudeCredentials.installKeychainReadCooldown(cause: .declined)

        XCTAssertEqual(miss(backgroundRead()), .onCooldown(.declined))
        XCTAssertEqual(reads, [], "the cooldown still holds back a read that may ask")
    }

    func test_expiredCopy_ofAnUnchangedItem_readsNothing_andSaysTheLoginExpired() {
        copy("sk-ant-oat01-a", expiresIn: 3600)
        now = now.addingTimeInterval(2 * 3600)

        for _ in 0..<3 {
            XCTAssertEqual(miss(backgroundRead()), .expiredLogin)
        }
        XCTAssertEqual(reads, [], "Claude Code has not renewed it; reading it again gives the same token")
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown())
    }

    func test_itemReadWithAnExpiredLogin_isNotHandedOut_norReadAgain_untilRewritten() {
        itemAnswer = item("sk-ant-oat01-a", expiresIn: -60)
        XCTAssertEqual(miss(backgroundRead()), .expiredLogin)
        XCTAssertEqual(miss(backgroundRead()), .expiredLogin)
        XCTAssertEqual(reads, [false], "the unchanged item was read again")

        itemDate = itemDate!.addingTimeInterval(3600)
        itemAnswer = item("sk-ant-oat01-b")
        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b")
        XCTAssertEqual(reads, [false, false])
    }

    /// The refused call this replaces armed the cooldown; when the expired
    /// login cannot be kept with its date, nothing else stops the next
    /// refresh from reading (and perhaps asking) again.
    func test_expiredLoginThatCannotBeKept_armsTheCooldown() {
        for key in ["claude-code-creds-cache", "claude-code-creds-cache-item-modified"] {
            ClaudeCredentials.clearKeychainReadCooldown()
            KeychainHelper.lockedKeysForTesting = [key]
            reads = []
            itemAnswer = item("sk-ant-oat01-a", expiresIn: -60)

            XCTAssertEqual(miss(backgroundRead()), .expiredLogin, key)
            XCTAssertEqual(ClaudeCredentials.activeKeychainReadCooldown(), .rejectedToken, key)
            XCTAssertEqual(miss(backgroundRead()), .onCooldown(.rejectedToken), key)
            XCTAssertEqual(reads, [false], "\(key): read again with nothing kept")
        }
    }

    func test_expiredLoginKeptWithItsDate_armsNothing() {
        itemAnswer = item("sk-ant-oat01-a", expiresIn: -60)
        XCTAssertEqual(miss(backgroundRead()), .expiredLogin)
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown(),
                     "a renewal must be picked up at once, not after a cooldown")
    }

    // MARK: - No date to go by

    /// Without a date the read may ask, as the refused call's cooldown read
    /// did before; keeping no date arms the cooldown, so it asks at most once
    /// per cooldown for a login that is still expired.
    func test_noItemDate_expiredCopy_readsAtMostOncePerCooldown() {
        itemDate = nil
        copy("sk-ant-oat01-a", expiresIn: 3600)
        now = now.addingTimeInterval(2 * 3600)
        itemAnswer = item("sk-ant-oat01-a", expiresIn: -3600)

        XCTAssertEqual(miss(backgroundRead()), .expiredLogin)
        XCTAssertEqual(ClaudeCredentials.activeKeychainReadCooldown(), .rejectedToken)
        XCTAssertEqual(miss(backgroundRead()), .onCooldown(.rejectedToken))
        XCTAssertEqual(reads, [false])
    }

    func test_noItemDate_expiredCopy_takesARenewedLogin() {
        itemDate = nil
        copy("sk-ant-oat01-a", expiresIn: 3600)
        now = now.addingTimeInterval(2 * 3600)
        itemAnswer = item("sk-ant-oat01-b")

        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b")
        XCTAssertEqual(reads, [false])
        XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown())
    }

    func test_noItemDate_currentCopy_readsNothing() {
        itemDate = nil
        copy("sk-ant-oat01-a")
        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-a")
        XCTAssertEqual(reads, [])
    }

    /// A copy taken by a build before this one has no date beside it.
    func test_copyWithoutADate_isReadAgainQuietly_whileItWorks() {
        let date = itemDate
        itemDate = nil
        copy("sk-ant-oat01-a")
        itemDate = date
        itemAnswer = item("sk-ant-oat01-b")

        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b")
        XCTAssertEqual(reads, [true])
        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b")
        XCTAssertEqual(reads, [true], "the new copy has its date")
    }

    func test_dateRecordedBesideAnotherToken_countsAsNoDate() {
        copy("sk-ant-oat01-a")
        // Two reads in one process wrote their halves out of order: a's
        // token beside b's date.
        KeychainHelper.save(
            key: "claude-code-creds-cache-item-modified",
            value: ClaudeCredentials.copyDateRecord(itemModified: itemDate!, token: "sk-ant-oat01-b"))
        XCTAssertNil(ClaudeCredentials.recordedItemDate(forCopyHolding: "sk-ant-oat01-a"))

        itemAnswer = item("sk-ant-oat01-b")
        XCTAssertEqual(token(backgroundRead()), "sk-ant-oat01-b",
                       "a's copy was not taken for the item's current login")
        XCTAssertEqual(reads, [true])
    }

    // MARK: - The Connect button

    func test_connect_takesAnyCopy_evenAnExpiredOne() {
        copy("sk-ant-oat01-a", expiresIn: 3600)
        now = now.addingTimeInterval(2 * 3600)
        let creds = ClaudeCredentials.readKeychainCredentials(bypassCooldown: true, cacheResult: false)
        XCTAssertEqual(creds?.accessToken, "sk-ant-oat01-a", "Connect only needs to know there is a login")
        XCTAssertEqual(reads, [])
    }

    func test_connect_getsAnItemWhoseLoginExpired() {
        itemAnswer = item("sk-ant-oat01-a", expiresIn: -60)
        let creds = ClaudeCredentials.readKeychainCredentials(bypassCooldown: true, cacheResult: false)
        XCTAssertEqual(creds?.accessToken, "sk-ant-oat01-a")
        XCTAssertNil(ClaudeCredentials.readCachedKeychainCredentials(), "Connect stages; it does not cache")
    }

    // MARK: - A refused token

    func test_refusedToken_dropsTheCopyOnlyWhileItHoldsThatToken() {
        copy("sk-ant-oat01-b")
        XCTAssertFalse(ClaudeCredentials.dropRejectedKeychainCopy(token: "sk-ant-oat01-a"),
                       "a refusal of the token sent before says nothing about the copy read since")
        XCTAssertEqual(ClaudeCredentials.readCachedKeychainCredentials()?.accessToken, "sk-ant-oat01-b")

        XCTAssertTrue(ClaudeCredentials.dropRejectedKeychainCopy(token: "sk-ant-oat01-b"))
        XCTAssertNil(ClaudeCredentials.readCachedKeychainCredentials())
        XCTAssertNil(ClaudeCredentials.recordedItemDate(forCopyHolding: "sk-ant-oat01-b"),
                     "the date went with the copy")
    }

    func test_refusedToken_withNoCopy_stillCounts() {
        XCTAssertTrue(ClaudeCredentials.dropRejectedKeychainCopy(token: "sk-ant-oat01-a"),
                      "no copy (one that could not be saved): the cooldown must still be armed")
    }

    // MARK: - Settings › Privacy

    func test_skipSwitch_asksForNoDate_andReadsNothing() {
        XCTAssertEqual(miss(backgroundRead(skip: true)), .skipped(.skippedBySetting))
        XCTAssertEqual(dateQueries, 0, "the item's date is read only behind the switches")
        XCTAssertEqual(reads, [])
    }
}
#endif
