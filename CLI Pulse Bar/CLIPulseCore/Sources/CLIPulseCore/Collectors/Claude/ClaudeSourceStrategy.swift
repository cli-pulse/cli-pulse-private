#if os(macOS)
import Foundation
import os

// MARK: - Strategy protocol

/// A single source strategy for fetching Claude usage data.
/// Each strategy represents one method of obtaining quota information
/// (OAuth API, Web session, CLI PTY probe).
public protocol ClaudeSourceStrategy: Sendable {
    /// Human-readable identifier for logging/diagnostics.
    var sourceLabel: String { get }

    /// The SourceType this strategy produces.
    var sourceType: SourceType { get }

    /// Quick check: can this strategy plausibly run with the given config?
    /// Must not perform network I/O.
    func isAvailable(config: ProviderConfig) -> Bool

    /// Fetch Claude usage data. Throws on failure.
    func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot
}

// MARK: - Unified snapshot from any source

/// Normalized Claude usage data that any strategy produces.
/// Maps directly to CollectorResult via `ClaudeResultBuilder`.
public struct ClaudeSnapshot: Sendable {
    public let sessionUsed: Int?        // 0-100 utilization %
    public let weeklyUsed: Int?
    public let opusUsed: Int?
    public let sonnetUsed: Int?
    /// The Daily Routines window (`ClaudeRoutinesWindow`). 1.59 dropped the
    /// "Designs" lane: its key, `iguana_necktie`, now carries cloud credits.
    public let dailyRoutinesUsed: Int?
    public let sessionReset: String?    // ISO8601 or human-readable
    public let weeklyReset: String?
    public let dailyRoutinesReset: String?
    public let extraUsage: ClaudeExtraUsage?
    public let rateLimitTier: String?
    public let accountEmail: String?
    public let sourceLabel: String
    /// Weekly limits scoped to one model ("Fable only"), from the usage
    /// body's `limits` array (`ClaudeUsageLimits`). Empty when there are none.
    public let scopedWeekly: [ClaudeUsageLimits.Scoped]
    /// What `/api/oauth/profile` calls the plan ("Ultra plan"). The token's
    /// `rateLimitTier` is set at sign-in and goes stale when the plan changes.
    public let planDisplayLabel: String?

    public init(
        sessionUsed: Int? = nil, weeklyUsed: Int? = nil,
        opusUsed: Int? = nil, sonnetUsed: Int? = nil,
        dailyRoutinesUsed: Int? = nil,
        sessionReset: String? = nil, weeklyReset: String? = nil,
        dailyRoutinesReset: String? = nil,
        extraUsage: ClaudeExtraUsage? = nil,
        rateLimitTier: String? = nil,
        accountEmail: String? = nil,
        sourceLabel: String,
        scopedWeekly: [ClaudeUsageLimits.Scoped] = [],
        planDisplayLabel: String? = nil
    ) {
        self.sessionUsed = sessionUsed
        self.weeklyUsed = weeklyUsed
        self.opusUsed = opusUsed
        self.sonnetUsed = sonnetUsed
        self.dailyRoutinesUsed = dailyRoutinesUsed
        self.sessionReset = sessionReset
        self.weeklyReset = weeklyReset
        self.dailyRoutinesReset = dailyRoutinesReset
        self.extraUsage = extraUsage
        self.rateLimitTier = rateLimitTier
        self.accountEmail = accountEmail
        self.sourceLabel = sourceLabel
        self.scopedWeekly = scopedWeekly
        self.planDisplayLabel = planDisplayLabel
    }

    /// True when at least one of the quota windows has a parsed value.
    /// Used by `ClaudeResultBuilder` to decide whether to emit a real quota
    /// envelope or an "unavailable" placeholder.
    public var hasAnyUsage: Bool {
        sessionUsed != nil
            || weeklyUsed != nil
            || sonnetUsed != nil
            || opusUsed != nil
            || dailyRoutinesUsed != nil
            || !scopedWeekly.isEmpty
    }

    /// Return a copy with `accountEmail` / `rateLimitTier` / `weeklyReset`
    /// filled in from `info` only when this snapshot's corresponding field is
    /// nil. Usage fields are never touched — the account cache is metadata-only.
    /// Called by `ClaudeSourceResolver` after the strategy chain returns so the
    /// pure `ClaudeResultBuilder.build` transform stays untouched.
    public func mergingAccountInfo(_ info: ClaudeAccountInfo?) -> ClaudeSnapshot {
        guard let info else { return self }
        return ClaudeSnapshot(
            sessionUsed: sessionUsed,
            weeklyUsed: weeklyUsed,
            opusUsed: opusUsed,
            sonnetUsed: sonnetUsed,
            dailyRoutinesUsed: dailyRoutinesUsed,
            sessionReset: sessionReset,
            weeklyReset: weeklyReset ?? info.weeklyReset,
            dailyRoutinesReset: dailyRoutinesReset,
            extraUsage: extraUsage,
            rateLimitTier: rateLimitTier ?? info.rateLimitTier,
            accountEmail: accountEmail ?? info.accountEmail,
            sourceLabel: sourceLabel,
            scopedWeekly: scopedWeekly,
            planDisplayLabel: planDisplayLabel
        )
    }
}

/// Account-level metadata Claude provides that can be cached independently
/// of the strict quota snapshot. Written by any strategy that gets this data
/// even when the quota fetch itself failed.
public struct ClaudeAccountInfo: Sendable {
    public let accountEmail: String?
    public let rateLimitTier: String?
    public let weeklyReset: String?

    public init(accountEmail: String? = nil, rateLimitTier: String? = nil, weeklyReset: String? = nil) {
        self.accountEmail = accountEmail
        self.rateLimitTier = rateLimitTier
        self.weeklyReset = weeklyReset
    }

    public var isEmpty: Bool {
        accountEmail == nil && rateLimitTier == nil && weeklyReset == nil
    }
}

/// Extra usage / credit info from Claude.
public struct ClaudeExtraUsage: Sendable {
    public let isEnabled: Bool
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let currency: String?

    public init(isEnabled: Bool, monthlyLimit: Double? = nil,
                usedCredits: Double? = nil, currency: String? = nil) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.currency = currency
    }
}

// MARK: - Result builder

/// Converts a `ClaudeSnapshot` into a `CollectorResult`.
public enum ClaudeResultBuilder {
    public static func build(from snapshot: ClaudeSnapshot) -> CollectorResult {
        var tiers: [TierDTO] = []
        if let u = snapshot.sessionUsed {
            tiers.append(TierDTO(name: "5h Window", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.sessionReset))
        }
        if let u = snapshot.weeklyUsed {
            tiers.append(TierDTO(name: "Weekly", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.weeklyReset))
        }
        // One per-model week from the flat keys, named for the model it is:
        // it used to read "Sonnet only" when it held Opus's number.
        if let u = snapshot.sonnetUsed {
            tiers.append(TierDTO(name: "Sonnet only", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.weeklyReset))
        } else if let u = snapshot.opusUsed {
            tiers.append(TierDTO(name: "Opus only", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.weeklyReset))
        }
        if let u = snapshot.dailyRoutinesUsed {
            tiers.append(TierDTO(name: "Daily Routines", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.dailyRoutinesReset))
        }
        // A week scoped to one model ("Fable only"). The name keeps the
        // vendor's model noun verbatim; `scripts/quota_tier_names.json` lists
        // it as composed at runtime. A model that already has its row from
        // the flat keys (`seven_day_sonnet` → "Sonnet only") is the same
        // limit and is not drawn twice.
        for scoped in snapshot.scopedWeekly {
            let title = "\(scoped.modelName) only"
            let row = { (name: String) in
                TierDTO(name: name, quota: 100, remaining: max(0, 100 - scoped.used),
                        reset_time: scoped.resetsAt ?? snapshot.weeklyReset,
                        windowMinutes: 7 * 24 * 60, role: .modelSpecific)
            }
            if let index = tiers.firstIndex(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) {
                // The same limit: keep the row's name, take the scoped
                // entry's own reset (the flat row only had the week's).
                tiers[index] = row(tiers[index].name)
            } else {
                tiers.append(row(title))
            }
        }

        let planType = ClaudePlanType.resolve(rateLimitTier: snapshot.rateLimitTier,
                                              planDisplayLabel: snapshot.planDisplayLabel)

        // Be honest: if no strategy populated any of the three quota windows
        // we used to emit `quota=100, remaining=100, tiers=[]`, which AppState
        // turned into a misleading "Default 100% left" bar. Now we report
        // `quota=nil` so the UI can render an "unavailable" placeholder.
        let hasUsage = snapshot.hasAnyUsage
        let overallQuota: Int? = hasUsage ? 100 : nil
        // The headline is the 5-hour window, or the week on a plan that has
        // no 5-hour window (Claude's weekly-only plans: `five_hour` is null).
        // It used to fall back to 100, so such a plan read "100% left" and
        // "Operational" whatever its week stood at (owner, 2026-11-22).
        // With neither, the most-used model-scoped week, so a reply holding
        // only those cannot read "100% left" either. `reset_time` is the
        // headline's own reset, which is what the pace reads.
        let topScoped = snapshot.scopedWeekly.max { $0.used < $1.used }
        let headline: (used: Int, reset: String?)? =
            snapshot.sessionUsed.map { ($0, snapshot.sessionReset) }
            ?? snapshot.weeklyUsed.map { ($0, snapshot.weeklyReset) }
            ?? topScoped.map { ($0.used, $0.resetsAt ?? snapshot.weeklyReset) }
        let headlineUsed = headline?.used
        let overallRemaining: Int? = hasUsage ? (headlineUsed.map { max(0, 100 - $0) } ?? 100) : nil
        let statusText: String
        if let used = headlineUsed {
            statusText = "\(used)% used"
        } else if hasUsage {
            statusText = "Operational"
        } else if let email = snapshot.accountEmail {
            // Signed in but quota not reaching us (OAuth keychain not granted,
            // or Cloudflare challenge / schema drift on the web endpoint).
            // Point the user at the Connect action rather than the obsolete
            // `/usage` CLI command — that command was removed in Claude v2.x.
            statusText = ClaudeStatusSentinel.signedInConnect(email)
        } else {
            // No signal at all: no account email, no usage. Direct the user
            // to Settings → Claude where the Connect button lives.
            statusText = ClaudeStatusSentinel.quotaUnavailable
        }

        #if DEBUG
        if !hasUsage {
            print("[ClaudeResultBuilder] WARN no usage windows captured (source=\(snapshot.sourceLabel)) — emitting unavailable placeholder")
        }
        #endif

        let providerUsage = ProviderUsage(
            provider: ProviderKind.claude.rawValue,
            today_usage: snapshot.sessionUsed ?? 0,
            week_usage: snapshot.weeklyUsed ?? 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: overallQuota, remaining: overallRemaining, plan_type: planType,
            reset_time: headline.map { $0.reset } ?? snapshot.sessionReset, tiers: tiers, status_text: statusText,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Claude", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: providerUsage, dataKind: .quota)
    }
}

// MARK: - Shared credential helpers

/// Shared helpers for Claude credential resolution, used by multiple strategies.
public enum ClaudeCredentials {
    /// Real home directory (not sandbox-remapped). Uses the thread-safe
    /// `passwdHomeDirectory()` (`getpwuid_r`).
    public static var realHomeDir: String {
        if let dir = passwdHomeDirectory() { return dir }
        let nsHome = NSHomeDirectory()
        if let range = nsHome.range(of: "/Library/Containers/") {
            return String(nsHome[nsHome.startIndex..<range.lowerBound])
        }
        return nsHome
    }

    public struct Creds: Sendable {
        public let accessToken: String
        public let rateLimitTier: String?
        /// When the access token stops working, if the credentials say.
        /// Claude Code writes it as milliseconds since 1970 (`expiresAt`).
        public let expiresAt: Date?

        public init(accessToken: String, rateLimitTier: String?, expiresAt: Date? = nil) {
            self.accessToken = accessToken
            self.rateLimitTier = rateLimitTier
            self.expiresAt = expiresAt
        }

        /// True only when the credentials name an expiry and it has passed.
        /// Credentials without one are taken as current, as before.
        public func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt <= now
        }
    }

    /// `expiresAt` / `expires_at` as Claude Code writes it: milliseconds since
    /// 1970. A value small enough to be seconds is read as seconds.
    static func parseExpiry(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }

    /// Parse credentials from JSON data (supports both snake_case and camelCase).
    public static func parseCredentialsJSON(_ data: Data) -> Creds? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = json["claude_ai_oauth"] as? [String: Any],
           let token = oauth["access_token"] as? String, !token.isEmpty {
            return Creds(accessToken: token, rateLimitTier: oauth["rate_limit_tier"] as? String,
                         expiresAt: parseExpiry(oauth["expires_at"]))
        }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return Creds(accessToken: token, rateLimitTier: oauth["rateLimitTier"] as? String,
                         expiresAt: parseExpiry(oauth["expiresAt"]))
        }
        return nil
    }

    /// Read credentials from ~/.claude/.credentials.json file.
    public static func readCredentialsFile() -> Creds? {
        let path = (realHomeDir as NSString).appendingPathComponent(".claude/.credentials.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parseCredentialsJSON(data)
    }

    /// The credentials file, unless its token has expired: for reading the
    /// plan tier, which an expired file from an earlier login names wrongly.
    static func readCurrentCredentialsFile() -> Creds? {
        guard let creds = readCredentialsFile(), !creds.isExpired(now: nowProvider()) else { return nil }
        return creds
    }

    /// Read credentials from macOS Keychain (Claude Code's keychain item).
    ///
    /// The sandboxed app cannot access cross-app keychain items without
    /// triggering a macOS authorization dialog. To avoid prompting the
    /// user on every launch, we cache the credentials in the app's own
    /// keychain after the first successful read.
    /// - Parameter bypassCooldown: pass `true` for USER-initiated reads
    ///   (the Settings "Connect Claude Code" button) so a cooldown armed by a
    ///   background 401 never blocks an explicit reconnect/re-auth. Background
    ///   refreshers leave it `false`.
    /// - Parameter cacheResult: pass `false` when importing into one account's
    ///   staged editor state. This avoids creating a provider-global cache when
    ///   the user may still cancel the account draft.
    public static func readKeychainCredentials(
        bypassCooldown: Bool = false,
        cacheResult: Bool = true
    ) -> Creds? {
        // When Claude Code last wrote its item, from the item's attributes,
        // which macOS gives without a dialog. Read before the item itself, so
        // a write landing between the two leaves a date older than the copy
        // (one more read later), never a newer one (a missed write).
        let itemModified = keychainItemModified()

        // 1. The app's own copy (never triggers a prompt), while it can still
        //    be Claude Code's login. It used to be handed out whatever it
        //    held. On the owner's Mac (2026-11-23) the login had expired the
        //    evening before: Claude Code ran only from the desktop app, which
        //    does not renew this item. Every 30 minutes the expired token was
        //    sent, refused (401), the copy cleared and the cooldown re-armed,
        //    and the row could only say "rejected token". After a renewal the
        //    same path sends the copy taken before it until it is refused, then
        //    waits out the cooldown before reading the renewed login.
        var read = ItemRead.mayAsk
        var workingCopy: Creds?
        if let cached = KeychainHelper.load(key: keychainCacheKey),
           let data = cached.data(using: .utf8),
           let creds = parseCredentialsJSON(data) {
            // The Connect button's read (`bypassCooldown`) only needs to know
            // this Mac has a Claude Code login; any copy says so, as before.
            if bypassCooldown { return creds }
            switch copyStanding(of: creds, itemModified: itemModified) {
            case .current:
                return creds
            case .readQuietly:
                read = .quiet
                if !creds.isExpired(now: nowProvider()) { workingCopy = creds }
            case .readAndMayAsk:
                break
            case .expiredAndUnchanged:
                // Claude Code has not renewed it yet. Reading the item again
                // would only ask macOS (and perhaps the user) for the same
                // expired token; Claude Code's next run rewrites it.
                ClaudeKeychainReadLog.note(.expiredLogin)
                return nil
            }
        }

        // 1b. Cross-app read cooldown (v1.30.x — keychain prompt-spam fix).
        // The cross-app read below shows a macOS authorization dialog
        // ("CLIPulseHelper wants to use Claude Code-credentials"). The cache
        // above normally means we prompt once and never again — BUT a recurring
        // OAuth 401 calls clearCachedKeychainCredentials() every refresh, wiping
        // the cache and forcing a re-read here on every ~3-4 min cycle, so the
        // user is prompted forever (and "Always Allow" doesn't stick on macOS 26
        // / when `claude` rewrites the item). When the cache was cleared due to
        // a bad token we install a cooldown: skip the cross-app read (return nil
        // → the resolver falls back to cli-pty/JSONL/web, no prompt) until it
        // expires, capping prompts to ≤1 per cooldown window. See
        // feedback_claude_oauth_keychain_prompt_spam. 1.59: a declined read
        // arms the same cooldown (below), and the cause is noted so the
        // provider row can say which one it is. A quiet read cannot show the
        // dialog, so the cooldown does not hold it back.
        if read == .mayAsk, !bypassCooldown, let cause = activeKeychainReadCooldown() {
            ClaudeKeychainReadLog.note(.onCooldown(cause))
            return nil
        }

        // 2. Read from Claude Code's keychain (may trigger one-time prompt,
        //    unless quiet)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeItemService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if read == .quiet {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        let (status, item) = copyKeychainItem(query as CFDictionary)
        guard status == errSecSuccess else {
            if read == .quiet {
                // macOS would have had to ask. Nobody said no, so no cooldown;
                // the copy, while it lasts, is still a working token.
                if let workingCopy { return workingCopy }
                ClaudeKeychainReadLog.note(.status(status))
                return nil
            }
            // 1.59 (59-15 F6): the user said no in macOS's dialog. Without a
            // cooldown every later refresh asked again (`readiness` →
            // `isAvailable` → here), so one "Deny" became a dialog every few
            // minutes. Armed in either process, like the 401 one, because
            // the cooldown is shared through the app group.
            if ClaudeKeychainMiss.isDeclined(status) {
                installKeychainReadCooldown(cause: .declined)
                keychainLogger.notice("Claude Code keychain read declined, status \(status, privacy: .public); not asking again until the cooldown ends")
            }
            ClaudeKeychainReadLog.note(.status(status))
            return nil
        }
        guard let data = item as? Data, let creds = parseCredentialsJSON(data) else {
            if let workingCopy { return workingCopy }
            ClaudeKeychainReadLog.note(.unreadable)
            return nil
        }
        let expired = creds.isExpired(now: nowProvider())
        if expired, let workingCopy {
            // The item now holds an older login than the copy: keep the copy.
            return workingCopy
        }

        // 3. Cache in the app's own keychain so the prompt never recurs, with
        //    the date of the item it copies, and clear any cooldown — a
        //    successful read means we're back to normal.
        var keptWithDate = false
        if cacheResult,
           let jsonStr = String(data: data, encoding: .utf8) {
            keptWithDate = copyLock.withLock {
                let copySaved = KeychainHelper.save(key: keychainCacheKey, value: jsonStr)
                guard let itemModified else {
                    KeychainHelper.delete(key: keychainCacheItemModifiedKey)
                    return false
                }
                let dateSaved = KeychainHelper.save(
                    key: keychainCacheItemModifiedKey,
                    value: copyDateRecord(itemModified: itemModified, token: creds.accessToken)
                )
                return copySaved && dateSaved
            }
        }
        clearKeychainReadCooldown()
        // A background read never hands out a token past its expiry: OAuth
        // would refuse it, and the refusal arms the cooldown. The Connect
        // button (`bypassCooldown`) still gets it: there it only shows that
        // this Mac has a Claude Code login.
        if expired, !bypassCooldown {
            ClaudeKeychainReadLog.note(.expiredLogin)
            if read == .mayAsk, !keptWithDate {
                // Without the copy and its date, a later refresh may read
                // (and perhaps ask) again for the same expired login. The
                // refused call this replaces armed the cooldown; so does this.
                installKeychainReadCooldown(cause: .rejectedToken)
            }
            return nil
        }
        return creds
    }

    /// How `readKeychainCredentials` reads Claude Code's item: allowing
    /// macOS's dialog, or failing instead of showing it.
    enum ItemRead: Equatable {
        case mayAsk
        case quiet
    }

    /// What `readKeychainCredentials` does with the app's own copy.
    enum CopyStanding: Equatable {
        /// Use it.
        case current
        /// Read the item without a dialog: it was rewritten since the copy
        /// (or the copy has no date) while the copy still works, so the copy
        /// carries on if macOS would have to ask.
        case readQuietly
        /// The copy has expired, and the item was rewritten since, or there
        /// is no date to tell: the read the dialog is for. The cooldown holds
        /// it back, and an expired login read without a date to keep arms
        /// the cooldown, so it asks at most once per cooldown, as the refused
        /// call it replaces did.
        case readAndMayAsk
        /// The copy has expired and the item is the one it was taken from.
        case expiredAndUnchanged
    }

    /// - Parameter itemModified: the item's modification date now, nil when
    ///   there is no item or its attributes could not be read.
    static func copyStanding(of copy: Creds, itemModified: Date?) -> CopyStanding {
        let expired = copy.isExpired(now: nowProvider())
        guard let current = itemModified.map(wholeSeconds) else {
            // No date to go by: no item, or a locked keychain, where the read
            // finds nothing or cannot ask either.
            return expired ? .readAndMayAsk : .current
        }
        // A copy from a build before this one has no date.
        let recorded = recordedItemDate(forCopyHolding: copy.accessToken)
        if recorded == current {
            return expired ? .expiredAndUnchanged : .current
        }
        return expired ? .readAndMayAsk : .readQuietly
    }

    /// Whole seconds since 1970: the keychain keeps no finer date.
    private static func wholeSeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded())
    }

    /// The item's date as stored next to the copy, with the fingerprint of
    /// the token it came with. The two are written one after the other, so
    /// two reads in one process can interleave and leave one read's token
    /// beside the other's date; the fingerprint makes such a date count as
    /// none, never as a newer token's.
    static func copyDateRecord(itemModified: Date, token: String) -> String {
        "\(wholeSeconds(itemModified)) \(ClaudeOAuthBackoffState.fingerprint(forToken: token))"
    }

    static func recordedItemDate(forCopyHolding token: String) -> Int? {
        guard let record = KeychainHelper.load(key: keychainCacheItemModifiedKey) else { return nil }
        let parts = record.split(separator: " ")
        guard parts.count == 2,
              parts[1] == ClaudeOAuthBackoffState.fingerprint(forToken: token) else { return nil }
        return Int(parts[0])
    }

    /// After OAuth refused `token`, read from Claude Code's item: drop the
    /// copy if it is still that token. Returns false when the copy already
    /// holds another one, read after the refused token was sent (by a later
    /// refresh in this process); the refusal says nothing about it, so it
    /// stays, and no cooldown is armed for it.
    static func dropRejectedKeychainCopy(token: String) -> Bool {
        copyLock.withLock {
            if let copy = readCachedKeychainCredentials(), copy.accessToken != token {
                return false
            }
            clearCachedKeychainCredentials()
            return true
        }
    }

    /// Held while the copy and its date are saved, and while a refused token's
    /// copy is checked and dropped, so a refusal in one refresh cannot drop
    /// the copy another refresh in this process has just saved.
    private static let copyLock = NSLock()

    /// When Claude Code last wrote its keychain item, read from the item's
    /// attributes only. Never shows a dialog: attributes are not behind the
    /// item's access list, and the query is told to fail rather than ask.
    /// nil when there is no item or the answer is anything else. Called only
    /// from `readKeychainCredentials`, so Settings › Privacy's switches cover
    /// it as they cover the read. Tests replace it.
    static var keychainItemModified: () -> Date? = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ClaudeCredentials.claudeCodeItemService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// v1.55: the read every background lookup uses. It asks Settings ›
    /// Privacy's switches, as this process follows them
    /// (`PrivacySettings.skipsClaudeKeychainOnItsOwn`: the app's own switches
    /// in the app, the app's copy in the LoginItem helper), and returns nil
    /// without reading anything while either says skip.
    ///
    /// Callers: the OAuth token resolver and the rate-limit tier lookups of the
    /// OAuth and CLI strategies. The only direct caller of
    /// `readKeychainCredentials` is the Settings "Connect Claude Code" button,
    /// because the user just asked for exactly that read.
    /// `ClaudeKeychainGateReferenceTests` fails on any other direct caller, and
    /// `HelperPrivacyInputsTests` checks that `reader` is never called under a
    /// switch.
    /// - Parameters:
    ///   - privacy: the switches to ask. Tests pass their own.
    ///   - reader: the read itself. Tests pass one that counts its calls.
    public static func readKeychainCredentialsIfAllowed(
        privacy: PrivacySettings = .shared,
        reader: () -> Creds? = { ClaudeCredentials.readKeychainCredentials() }
    ) -> Creds? {
        guard !privacy.skipsClaudeKeychainOnItsOwn else { return nil }
        return reader()
    }

    /// Clear the cached Claude Code credentials (cache-only — does NOT arm the
    /// cooldown). Used by both the OAuth-401 path and the Settings "Disconnect"
    /// button; only the 401 path arms the cooldown (it calls
    /// `installKeychainReadCooldown()` itself), so a user Disconnect followed by
    /// Connect is never blocked by the cooldown (codex review 2026-06-19).
    public static func clearCachedKeychainCredentials() {
        KeychainHelper.delete(key: keychainCacheKey)
        KeychainHelper.delete(key: keychainCacheItemModifiedKey)
    }

    // MARK: - Cross-app keychain read cooldown (prompt-spam guard)

    /// How long to suppress cross-app `Claude Code-credentials` reads after a
    /// bad-token cache clear. 30 min: long enough to stop per-cycle prompts
    /// (~3-4 min refresh), short enough that a genuine re-auth recovers soon.
    static var keychainReadCooldownInterval: TimeInterval = 30 * 60

    /// Injectable clock for tests.
    static var nowProvider: () -> Date = { Date() }

    // W4: `cli_pulse_`-prefixed so it falls inside UnsandboxedDataMigration's
    // allowlist. The primary store is the app-group suite (which doesn't move on
    // unsandbox), but `cooldownDefaults` falls back to `.standard` if the suite
    // ever fails to initialise; without the prefix that fallback value would be
    // stranded on the DEVID unsandbox transition, falsifying the migration's
    // "every app-owned standard-defaults key is prefixed" invariant. (Renaming
    // orphans any old value once — a benign 30-min anti-prompt-spam timestamp.)
    // internal (not private) so a migration-allowlist guard test can assert the
    // prefix contract directly against the real constant.
    static let keychainReadCooldownKey = "cli_pulse_claude_keychain_read_cooldown_until"

    /// Cooldown state lives in the app-group defaults (NOT the per-app
    /// keychain) so it is SHARED between the main app and the CLIPulseHelper
    /// LoginItem — both read the cross-app item, so a 401 observed in either
    /// process must suppress the read in both. Defaults to the app group;
    /// tests inject a throwaway suite.
    static var cooldownDefaults: UserDefaults =
        UserDefaults(suiteName: "group.yyh.CLI-Pulse") ?? .standard

    /// 1.59: why the cooldown was armed (`ClaudeKeychainCooldownCause`), next
    /// to its end time. Prefixed for the same reason as the key above.
    static let keychainReadCooldownCauseKey = "cli_pulse_claude_keychain_read_cooldown_cause"

    /// - Parameter cause: `.rejectedToken` for the OAuth 401 path (the
    ///   default, which is what every caller before 1.59 meant), `.declined`
    ///   when the user said no in macOS's dialog.
    static func installKeychainReadCooldown(cause: ClaudeKeychainCooldownCause = .rejectedToken) {
        let until = nowProvider().addingTimeInterval(keychainReadCooldownInterval)
        cooldownDefaults.set(until.timeIntervalSince1970, forKey: keychainReadCooldownKey)
        cooldownDefaults.set(cause.rawValue, forKey: keychainReadCooldownCauseKey)
    }

    static func clearKeychainReadCooldown() {
        cooldownDefaults.removeObject(forKey: keychainReadCooldownKey)
        cooldownDefaults.removeObject(forKey: keychainReadCooldownCauseKey)
    }

    /// True while a cooldown (a bad-token clear, or since 1.59 a declined
    /// dialog) is still active.
    static func isKeychainReadOnCooldown() -> Bool {
        activeKeychainReadCooldown() != nil
    }

    /// Why the cooldown is active, or nil when it is not. A cooldown with no
    /// cause recorded (armed before 1.59) is a rejected token: that was the
    /// only thing that armed one.
    static func activeKeychainReadCooldown() -> ClaudeKeychainCooldownCause? {
        let epoch = cooldownDefaults.double(forKey: keychainReadCooldownKey)
        guard epoch > 0 else { return nil }
        if nowProvider().timeIntervalSince1970 >= epoch {
            // Expired — clean it up so the next read attempts the cross-app
            // keychain once more.
            clearKeychainReadCooldown()
            return nil
        }
        return cooldownDefaults.string(forKey: keychainReadCooldownCauseKey)
            .flatMap(ClaudeKeychainCooldownCause.init(rawValue:)) ?? .rejectedToken
    }

    /// The cross-app read itself: `SecItemCopyMatching`, with the item it
    /// returned. Tests replace it, so no test opens the real item (a test
    /// binary is not in its access list, so macOS would show a dialog nobody
    /// answers, and the suite would hang).
    static var copyKeychainItem: (CFDictionary) -> (OSStatus, CFTypeRef?) = { query in
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query, &item)
        return (status, item)
    }

    /// The background lookup the token resolver makes: the guarded read
    /// (`readKeychainCredentialsIfAllowed`), and, when it found no token, why.
    /// The read notes its status in a `ClaudeKeychainReadLog` bound here;
    /// nothing noted means the guard did not read, so a Settings › Privacy
    /// switch (or, in the LoginItem helper, no copy of them yet) said skip.
    static func readKeychainForTokenResolver(
        privacy: PrivacySettings = .shared
    ) -> ClaudeKeychainLookup {
        let log = ClaudeKeychainReadLog()
        let creds = ClaudeKeychainReadLog.$current.withValue(log) {
            readKeychainCredentialsIfAllowed(privacy: privacy)
        }
        if let creds { return .found(creds) }
        if let miss = log.miss { return .missing(miss) }
        let access = privacy.claudeKeychainAccess
        return .missing(access.skips ? .skipped(access) : .unreadable)
    }

    /// Peek at the app's own keychain cache without ever triggering a
    /// cross-app prompt. Used by UI to show "Connected" status without
    /// side effects. Returns nil if no cached credentials exist.
    public static func readCachedKeychainCredentials() -> Creds? {
        guard let cached = KeychainHelper.load(key: keychainCacheKey),
              let data = cached.data(using: .utf8),
              let creds = parseCredentialsJSON(data) else { return nil }
        return creds
    }

    /// Claude Code's keychain item. Spelled once: `ClaudeKeychainGateReferenceTests`
    /// checks that nothing else in the app names it.
    private static let claudeCodeItemService = "Claude Code-credentials"

    private static let keychainCacheKey = "claude-code-creds-cache"
    /// The item's modification date when the copy above was taken
    /// (`copyDateRecord`). Kept next to the copy, in the same store, so each
    /// process keeps its own pair.
    private static let keychainCacheItemModifiedKey = "claude-code-creds-cache-item-modified"

    private static let keychainLogger = Logger(subsystem: "com.clipulse", category: "ClaudeCredentials")

    enum TokenSource: Equatable {
        case accountConfig
        case sharedEnvironment
        case sharedCredentialsFile
        case sharedKeychain
        case none
    }

    struct ResolvedToken {
        let token: String
        let tier: String?
        let source: TokenSource
        /// 1.59: why there is no token; nil when there is one. Read by
        /// `ClaudeCollector.readiness` (through `ClaudeTokenResolutionLog`),
        /// which used to say "Not set up" for every one of these.
        var absence: ClaudeTokenAbsence? = nil
    }

    /// - Parameters:
    ///   - environment, credentialsFile, keychain: the three machine-wide
    ///     sources, in the order they are tried. Tests pass their own, so
    ///     what this machine has never decides a result.
    ///   - now: what "expired" is measured against (the credentials file's).
    static func resolveTokenDetails(
        config: ProviderConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialsFile: () -> Creds? = { ClaudeCredentials.readCredentialsFile() },
        keychain: () -> ClaudeKeychainLookup = { ClaudeCredentials.readKeychainForTokenResolver() },
        now: Date = Date()
    ) -> ResolvedToken {
        let resolved = resolveTokenFromSources(
            config: config,
            environment: environment,
            credentialsFile: credentialsFile,
            keychain: keychain,
            now: now
        )
        if let absence = resolved.absence {
            ClaudeTokenResolutionLog.note(absence)
        }
        return resolved
    }

    private static func resolveTokenFromSources(
        config: ProviderConfig,
        environment: [String: String],
        credentialsFile: () -> Creds?,
        keychain: () -> ClaudeKeychainLookup,
        now: Date
    ) -> ResolvedToken {
        // Explicitly connected tokens are copied into this account's
        // ProviderConfig Keychain slot. They always win over machine-global
        // compatibility sources.
        if let configKey = config.apiKey,
           configKey.hasPrefix("sk-ant-oat") {
            return ResolvedToken(
                token: configKey,
                tier: nil,
                source: .accountConfig
            )
        }

        if config.sharedCredentialFallbackDisabled == true {
            return ResolvedToken(
                token: "",
                tier: nil,
                source: .none,
                absence: .fallbackDisabled
            )
        }

        // Environment variables, ~/.claude, and the Claude Code keychain item
        // identify one machine-global login. Only one local account may use
        // those sources, otherwise duplicate configs report the same quota.
        guard ProviderSharedCredentialOwner.claim(
            kind: .claude,
            accountID: config.accountID
        ) else {
            return ResolvedToken(
                token: "",
                tier: nil,
                source: .none,
                absence: .sharedLoginNotClaimed
            )
        }

        // Check environment variables: app-specific first, then Claude Code's own
        for envKey in ["CODEXBAR_CLAUDE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] {
            if let envToken = environment[envKey],
               !envToken.isEmpty, envToken.hasPrefix("sk-ant-oat") {
                return ResolvedToken(
                    token: envToken,
                    tier: nil,
                    source: .sharedEnvironment
                )
            }
        }
        // `~/.claude/.credentials.json` first, unless its token has expired.
        // Claude Code on macOS keeps its login in the keychain and does not
        // refresh this file, so one left from an earlier login stays expired
        // for good. Taken first regardless, it shadowed the keychain: every
        // OAuth call was refused and the card fell back to other sources,
        // whose weekly figure was far from Claude's own (owner, 2026-11-21,
        // with a file months past its expiry). An expired file is now the
        // last resort, used only when the keychain has nothing, as CodexBar's
        // `ClaudeOAuthCredentials.load` does. (Should the expired file hold
        // the current login and the keychain an older one, the keychain's
        // account is shown; nothing here can tell the two apart.)
        let fileCreds = credentialsFile()
        if let fileCreds, !fileCreds.isExpired(now: now) {
            return ResolvedToken(
                token: fileCreds.accessToken,
                tier: fileCreds.rateLimitTier,
                source: .sharedCredentialsFile
            )
        }
        switch keychain() {
        case .found(let keychainCreds):
            return ResolvedToken(
                token: keychainCreds.accessToken,
                tier: keychainCreds.rateLimitTier,
                source: .sharedKeychain
            )
        case .missing(let miss):
            if let fileCreds {
                // Expired, but the only token there is: the same answer as
                // before this check existed.
                return ResolvedToken(
                    token: fileCreds.accessToken,
                    tier: fileCreds.rateLimitTier,
                    source: .sharedCredentialsFile
                )
            }
            return ResolvedToken(
                token: "",
                tier: nil,
                source: .none,
                absence: .keychain(miss)
            )
        }
    }

    /// Resolve an OAuth token from all available sources.
    public static func resolveToken(
        config: ProviderConfig
    ) -> (token: String, tier: String?) {
        let resolved = resolveTokenDetails(config: config)
        return (resolved.token, resolved.tier)
    }

    /// Strip ANSI escape codes from text.
    /// Cursor-movement sequences (like ESC[1C used by TUI between words) become spaces
    /// so that "Quick[1Csafety[1Ccheck" → "Quick safety check" instead of "Quicksafetycheck".
    public static func stripANSI(_ text: String) -> String {
        // First replace cursor-movement sequences with spaces (ESC[nC = cursor forward)
        var result = text
        if let cursorFwd = try? NSRegularExpression(pattern: "\\x1B\\[\\d*C") {
            result = cursorFwd.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        // Then strip remaining ANSI escape sequences
        if let ansi = try? NSRegularExpression(pattern: "\\x1B\\[[0-?]*[ -/]*[@-~]") {
            result = ansi.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Also strip OSC sequences (ESC]...BEL)
        if let osc = try? NSRegularExpression(pattern: "\\x1B\\][^\\x07]*\\x07") {
            result = osc.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }
}

// MARK: - Error types

public enum ClaudeStrategyError: LocalizedError, Sendable {
    case noToken
    case httpError(status: Int, provider: String)
    case parseFailed(String)
    case noBinary
    case noSessionKey
    case unauthorized
    case timedOut
    case processExited
    /// OAuth strategy was skipped because a recent 429 is still in
    /// the cooldown window. `remaining` is the seconds left in the
    /// current backoff window. Always `shouldFallback == true` so
    /// the resolver immediately moves to the next strategy without
    /// hitting the network. Distinct from `httpError(429, _)` so the
    /// resolver log clearly shows "skipped pre-emptively" vs "hit
    /// 429 just now".
    case rateLimitBackoff(remaining: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .noToken: return L10n.providerConfig.errorClaudeNoToken
        case .httpError(let s, _): return L10n.providerConfig.errorClaudeHttpStatus(s)
        case .parseFailed(let m): return L10n.providerConfig.errorClaudeParseFailed(m)
        case .noBinary: return L10n.providerConfig.errorClaudeNoBinary
        case .noSessionKey: return L10n.providerConfig.errorClaudeNoSessionKey
        case .unauthorized: return L10n.providerConfig.errorClaudeUnauthorized
        case .timedOut: return L10n.providerConfig.errorClaudeTimedOut
        case .processExited: return L10n.providerConfig.errorClaudeProcessExited
        case .rateLimitBackoff(let remaining):
            // Round to whole minutes for the user-visible log line —
            // sub-minute precision adds nothing for "we're sitting out
            // a rate-limit window" diagnostics.
            let mins = Int(ceil(remaining / 60))
            return L10n.providerConfig.errorClaudeRateLimitBackoff(mins)
        }
    }

    /// Whether this error should trigger fallback to the next strategy.
    public var shouldFallback: Bool {
        switch self {
        case .httpError(let status, _):
            return status == 429 || status == 401 || status == 403
        case .noToken, .noBinary, .noSessionKey, .unauthorized, .timedOut, .processExited:
            return true
        case .parseFailed:
            return true
        case .rateLimitBackoff:
            // The whole point: skip OAuth pre-emptively, fall through
            // to the next strategy.
            return true
        }
    }
}
#endif

/// The two Claude status lines that are hints rather than numbers, written as fixed
/// English. `status_text` is data: collectors run in the Login Item helper as well as
/// the app, it crosses the App Group, and it is uploaded for other devices. Localizing
/// it here made its language whichever process produced it, not the reader's.
/// `L10n.providers.localizedStatusText` translates these at render time, and
/// `ClaudeStatusSentinelTests` pins them to the English catalogue.
public enum ClaudeStatusSentinel {
    public static func signedInConnect(_ email: String) -> String {
        "Signed in as \(email) — Connect Claude Code in Settings"
    }
    public static let quotaUnavailable = "Claude quota unavailable — Connect in Settings → Claude"

    static let signedInPrefix = "Signed in as "
    static let signedInSuffix = " — Connect Claude Code in Settings"
}
