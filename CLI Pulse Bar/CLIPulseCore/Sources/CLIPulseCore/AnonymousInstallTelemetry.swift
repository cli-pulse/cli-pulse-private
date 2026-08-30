import Foundation
import os

private let telemetryLogger = Logger(subsystem: "com.clipulse", category: "AnonymousTelemetry")

/// Two counters for the users v1.44 made invisible.
///
/// Removing the login wall was the right call and it cost us our only view of
/// whether the app works for anyone. `devices.user_id` is NOT NULL, so a
/// local-mode user leaves no trace: six days after 1.44 shipped, `profiles` had
/// gained one row, a number that means nothing precisely because those users
/// never reach `profiles`.
///
/// This reports two facts and nothing else — the app ran for the first time,
/// and it later found a CLI and had a number to show. The ratio between them is
/// the first-value funnel the 2026-07-25 activation investigation said we
/// needed and could not see.
///
/// See `backend/supabase/migrate_v0.73_anonymous_install_telemetry.sql` for the
/// server side, including why the ingest RPC validates rather than coerces.
public enum DistributionChannel: String, Sendable, CaseIterable {
    case mas
    case devid
    case brew
    case unknown

    /// Which channel this copy came from — the one question App Store Connect
    /// analytics cannot answer, because it only sees the App Store.
    ///
    /// The Mac App Store build is sandboxed and carries a receipt; that check
    /// comes first because a sandboxed app cannot see the Homebrew prefix at
    /// all, so asking about Homebrew first would give a wrong answer via a
    /// denied read rather than an honest one.
    ///
    /// Homebrew installs the identical Developer ID app into /Applications, so
    /// nothing inside the bundle distinguishes them. The Caskroom entry for our
    /// own cask is the only evidence available, and probing for it is a single
    /// existence check on one fixed path — not a scan of the user's machine.
    public static func detect(
        hasAppStoreReceipt: Bool,
        isSandboxed: Bool,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> DistributionChannel {
        if hasAppStoreReceipt || isSandboxed {
            return .mas
        }
        for prefix in ["/opt/homebrew", "/usr/local"] where directoryExists("\(prefix)/Caskroom/cli-pulse") {
            return .brew
        }
        return .devid
    }

    public static func detectCurrent() -> DistributionChannel {
        let receiptURL = Bundle.main.appStoreReceiptURL
        let hasReceipt = receiptURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        return detect(hasAppStoreReceipt: hasReceipt, isSandboxed: sandboxed)
    }
}

/// The one thing a user's UI language is allowed to be reported as.
///
/// A closed set, coarsened on the client, because `migrate_v0.76` rejects
/// anything else outright rather than storing it — the same posture as
/// `channel`. `other` covers a locale we do not ship a catalogue for; those
/// users read English, and the funnel needs to know they did.
public enum ReportedUILanguage: String, Sendable, CaseIterable, Equatable {
    case en, es, ja, ko
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case other

    /// Which catalogue the app is actually reading. See
    /// `LocaleOverrideStore.resolvedLocalization` for why this is the resolved
    /// `.lproj` and not the user's preferred languages.
    public static func current() -> ReportedUILanguage {
        guard let resolved = LocaleOverrideStore.resolvedLocalization else { return .other }
        return ReportedUILanguage(rawValue: resolved) ?? .other
    }
}

/// Exactly what leaves the machine. There is no `extra` dictionary and no
/// free-text field on purpose: a payload that cannot carry an unplanned value
/// cannot leak one by accident later.
public struct AnonymousInstallPayload: Equatable, Sendable, Encodable {
    /// Which server contract this payload is shaped for.
    ///
    /// `migrate_v0.76` adds three parameters, and the client may reach a
    /// database that has not had it applied yet — the migration is owner-gated
    /// and deploys independently of the app. PostgREST answers an unknown
    /// parameter set with 404/`PGRST202`, so the transport retries once in
    /// `.legacy` shape rather than letting every install go silent. Silent is
    /// the worst outcome available here: it is indistinguishable from "nobody
    /// installed the app", which is the exact confusion this telemetry exists
    /// to end.
    public enum WireVersion: Sendable, Equatable {
        /// v0.76 and later: milestones and UI language included.
        case current
        /// The v0.73 five-parameter shape. Nothing new is sent, and nothing is
        /// lost that the next launch cannot re-send once the migration lands —
        /// the milestone latches only set on a successful send.
        case legacy
    }

    public let installID: UUID
    public let channel: DistributionChannel
    public let appVersion: String
    public let osVersion: String
    public let providerDetected: Bool
    public let helperConnected: Bool
    public let costShown: Bool
    public let uiLanguage: ReportedUILanguage
    public let wireVersion: WireVersion

    public init(
        installID: UUID,
        channel: DistributionChannel,
        appVersion: String,
        osVersion: String,
        providerDetected: Bool,
        helperConnected: Bool = false,
        costShown: Bool = false,
        uiLanguage: ReportedUILanguage = .other,
        wireVersion: WireVersion = .current
    ) {
        self.installID = installID
        self.channel = channel
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.providerDetected = providerDetected
        self.helperConnected = helperConnected
        self.costShown = costShown
        self.uiLanguage = uiLanguage
        self.wireVersion = wireVersion
    }

    /// The same facts, shaped for a database that has not had v0.76 applied.
    public func legacyShaped() -> AnonymousInstallPayload {
        AnonymousInstallPayload(
            installID: installID, channel: channel, appVersion: appVersion,
            osVersion: osVersion, providerDetected: providerDetected,
            helperConnected: helperConnected, costShown: costShown,
            uiLanguage: uiLanguage, wireVersion: .legacy
        )
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case installID = "p_install_id"
        case channel = "p_channel"
        case appVersion = "p_app_version"
        case osVersion = "p_os_version"
        case providerDetected = "p_provider_detected"
        case helperConnected = "p_helper_connected"
        case costShown = "p_cost_shown"
        case uiLanguage = "p_ui_language"
    }

    /// Keys a `.legacy` payload must never carry. PostgREST binds by the names
    /// present in the body, so one stray key is the whole difference between
    /// the fallback working and 404-ing a second time.
    static let v076OnlyKeys: [CodingKeys] = [.helperConnected, .costShown, .uiLanguage]

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(installID.uuidString.lowercased(), forKey: .installID)
        try c.encode(channel.rawValue, forKey: .channel)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(providerDetected, forKey: .providerDetected)
        guard wireVersion == .current else { return }
        try c.encode(helperConnected, forKey: .helperConnected)
        try c.encode(costShown, forKey: .costShown)
        try c.encode(uiLanguage.rawValue, forKey: .uiLanguage)
    }
}

/// Version shaping.
///
/// DRIFT WARNING. The two patterns below duplicate the CHECKs in
/// `migrate_v0.73_anonymous_install_telemetry.sql`. The server rejects anything
/// that does not match, so a client that drifts does not degrade — it goes
/// silent, and silently losing the only signal we have is the exact failure
/// this whole feature exists to end. `AnonymousInstallTelemetryTests` pins both
/// patterns against the migration file; if you change one, that test fails.
public enum AnonymousTelemetryVersionShaping {
    /// `^[0-9]{1,4}(\.[0-9]{1,4}){0,4}$`
    public static func sanitizedAppVersion(_ raw: String) -> String? {
        shape(raw, maxComponents: 5)
    }

    /// `^[0-9]{1,4}(\.[0-9]{1,4}){0,2}$` — major.minor only.
    ///
    /// Coarsened deliberately. A full OS build string ("15.1.1 (24B2091)") is
    /// meaningfully identifying in a population this size, and nothing we ask
    /// needs it.
    public static func coarsenedOSVersion(major: Int, minor: Int) -> String {
        "\(max(0, min(major, 9999))).\(max(0, min(minor, 9999)))"
    }

    /// Takes the leading numeric components of a marketing version, so a
    /// prerelease tag ("1.45.0-beta.2") still reports as "1.45.0" rather than
    /// being dropped. Returns nil when there is no leading number at all, in
    /// which case the caller must not send: inventing a version would be worse
    /// than a missing row.
    static func shape(_ raw: String, maxComponents: Int) -> String? {
        var parts: [String] = []
        for component in raw.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = component.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 4 else { break }
            parts.append(String(digits))
            if digits.count != component.count { break }
            if parts.count == maxComponents { break }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }
}

/// Where the two bits of state live.
///
/// UserDefaults, not the Keychain, and that is a privacy decision rather than a
/// convenience one: Keychain entries survive an uninstall, which would turn a
/// per-install counter into a per-machine identifier that follows someone
/// across reinstalls. This id is meant to die when the app is removed.
public protocol AnonymousTelemetryStore: AnyObject, Sendable {
    var isEnabled: Bool { get }
    var hasSeenDisclosure: Bool { get set }
    var installID: UUID { get }
    var installReported: Bool { get set }
    var activationReported: Bool { get set }
    var helperConnectedReported: Bool { get set }
    var costReported: Bool { get set }
}

public final class UserDefaultsAnonymousTelemetryStore: AnonymousTelemetryStore, @unchecked Sendable {
    // EVERY key here must start with `privacy.` or `cli_pulse_`.
    //
    // `UnsandboxedDataMigration.appOwnedKeyPrefixes` is a strict allowlist, and
    // anything outside it is dropped when a user moves from the sandboxed Mac
    // App Store build to the Developer ID one. For the opt-out flag that is not
    // a lost preference, it is a user who switched telemetry OFF being silently
    // switched back ON by an upgrade — so the prefixes are load-bearing, and
    // `AnonymousTelemetryMigrationAllowlistTests` pins them.
    public static let enabledKey = "privacy.anonymousTelemetryEnabled"
    public static let disclosureKey = "privacy.anonymousTelemetryDisclosed"
    // The id survives the move deliberately: the same person changing channel
    // should update one row, not be counted as a second install.
    static let installIDKey = "cli_pulse_anonymous_install_id"
    static let installReportedKey = "cli_pulse_anonymous_install_reported"
    static let activationReportedKey = "cli_pulse_anonymous_activation_reported"
    static let helperConnectedReportedKey = "cli_pulse_anonymous_helper_connected_reported"
    static let costReportedKey = "cli_pulse_anonymous_cost_reported"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent means on, so the switch defaults to enabled. That is only
        // defensible because the first launch discloses it before anything is
        // sent; `AnonymousInstallTelemetry` will not send while
        // `hasSeenDisclosure` is false.
        if defaults.object(forKey: Self.enabledKey) == nil {
            defaults.set(true, forKey: Self.enabledKey)
        }
    }

    /// `localOnlyMode` wins.
    ///
    /// It is the existing master switch, and its own description promises to
    /// "skip all cross-app data sources". Someone who turned that on has
    /// already stated the preference; making them find a second switch to stop
    /// a second kind of network call would make the first switch a lie. This is
    /// deliberately one-directional — local-only forces telemetry off, but
    /// turning telemetry off says nothing about the other sources.
    public var isEnabled: Bool {
        guard !defaults.bool(forKey: "privacy.localOnlyMode") else { return false }
        return defaults.bool(forKey: Self.enabledKey)
    }

    public var hasSeenDisclosure: Bool {
        get { defaults.bool(forKey: Self.disclosureKey) }
        set { defaults.set(newValue, forKey: Self.disclosureKey) }
    }

    public var installReported: Bool {
        get { defaults.bool(forKey: Self.installReportedKey) }
        set { defaults.set(newValue, forKey: Self.installReportedKey) }
    }

    public var activationReported: Bool {
        get { defaults.bool(forKey: Self.activationReportedKey) }
        set { defaults.set(newValue, forKey: Self.activationReportedKey) }
    }

    public var helperConnectedReported: Bool {
        get { defaults.bool(forKey: Self.helperConnectedReportedKey) }
        set { defaults.set(newValue, forKey: Self.helperConnectedReportedKey) }
    }

    public var costReported: Bool {
        get { defaults.bool(forKey: Self.costReportedKey) }
        set { defaults.set(newValue, forKey: Self.costReportedKey) }
    }

    /// Generated once, lazily, and never derived from anything about the
    /// machine — not the serial, not the hardware UUID, not a hash of either.
    public var installID: UUID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = defaults.string(forKey: Self.installIDKey),
           let parsed = UUID(uuidString: existing) {
            return parsed
        }
        let fresh = UUID()
        defaults.set(fresh.uuidString, forKey: Self.installIDKey)
        return fresh
    }
}

public protocol AnonymousTelemetryTransport: Sendable {
    func send(_ payload: AnonymousInstallPayload) async throws
}

/// Decides whether anything is sent at all, and reports each fact once.
///
/// Retries across launches rather than within one. If the first launch happens
/// offline the install would otherwise be lost forever, and "we only measure
/// users who had a network on first run" is a bias we would never notice.
public actor AnonymousInstallTelemetry {
    private let store: AnonymousTelemetryStore
    private let transport: AnonymousTelemetryTransport
    private let channel: DistributionChannel
    private let appVersion: String?
    private let osVersion: String

    public init(
        store: AnonymousTelemetryStore,
        transport: AnonymousTelemetryTransport,
        channel: DistributionChannel = .unknown,
        rawAppVersion: String,
        osMajor: Int,
        osMinor: Int,
        uiLanguage: @escaping @Sendable () -> ReportedUILanguage = { ReportedUILanguage.current() }
    ) {
        self.store = store
        self.transport = transport
        self.channel = channel
        self.appVersion = AnonymousTelemetryVersionShaping.sanitizedAppVersion(rawAppVersion)
        self.osVersion = AnonymousTelemetryVersionShaping.coarsenedOSVersion(
            major: osMajor, minor: osMinor
        )
        self.uiLanguage = uiLanguage
    }

    /// Injected rather than read inline so a test can pin it without swapping
    /// the process's resource bundle. Defaults to the real resolution.
    private let uiLanguage: @Sendable () -> ReportedUILanguage

    /// The single gate. Every send goes through it, so there is exactly one
    /// place to audit when someone asks "can this app phone home?".
    private var maySend: Bool {
        store.isEnabled && store.hasSeenDisclosure && appVersion != nil
    }

    /// Returns whether the install is durably recorded once this call finishes.
    ///
    /// The return value is the whole contract, and it is deliberately "is it
    /// recorded now?" rather than "did I send just now": callers cache it to
    /// avoid repeating work, and a caller that caches *intent* instead of
    /// *outcome* will silently drop the event. See the header on
    /// `recordFirstProviderDetectedIfNeeded`.
    @discardableResult
    public func recordInstallIfNeeded() async -> Bool {
        if store.installReported { return true }
        guard maySend else { return false }
        return await send(providerDetected: false) { [store] in store.installReported = true }
    }

    /// Called the first time any provider is detected. This is first value: the
    /// moment the app has an actual number to show.
    ///
    /// Returns whether activation is durably recorded once this call finishes —
    /// `false` when the gate refused (no disclosure yet, opted out) or the send
    /// failed, in both cases meaning "ask again later".
    ///
    /// v1.46: this used to return `Void`, which made a refusal indistinguishable
    /// from a success at the call site. `AnonymousTelemetryCoordinator` latched
    /// on having *called* this, so on the launch where the user acknowledges the
    /// disclosure — the only launch that card is ever shown — the sink had
    /// already burned the latch against a refusal and the activation event was
    /// never sent. It surfaced a launch later, or not at all for anyone who
    /// uninstalled first, which biased the v1.45 funnel pessimistically for
    /// exactly the upgrade wave that dominated its first days.
    @discardableResult
    public func recordFirstProviderDetectedIfNeeded() async -> Bool {
        if store.activationReported { return true }
        guard maySend else { return false }
        // Reports the install too. The RPC upserts, and coalesces the
        // activation timestamp, so a user whose very first launch already finds
        // a CLI is counted once as installed and once as activated.
        return await send(providerDetected: true) { [store] in
            store.installReported = true
            store.activationReported = true
        }
    }

    /// Called the first time the local helper answers a `hello` over UDS.
    ///
    /// v0.76 step 2, and the reason the funnel needed more than two points.
    /// "No providers" is what the user sees whether they have no CLI installed
    /// or the helper never came up — a stale SMAppService bundle path, a socket
    /// shadowed by an old `.pkg`, a LaunchAgent that died quietly, a TCC prompt
    /// that never returned. Until now those were the same row.
    ///
    /// Same contract as the others: the return value is "is it recorded now?",
    /// not "did I send just now", so a caller that caches it cannot lose the
    /// event by caching intent instead of outcome.
    @discardableResult
    public func recordHelperConnectedIfNeeded() async -> Bool {
        if store.helperConnectedReported { return true }
        guard maySend else { return false }
        return await send(helperConnected: true) { [store] in
            store.installReported = true
            store.helperConnectedReported = true
        }
    }

    /// Called the first time the app has a non-zero cost for today.
    ///
    /// Distinct from provider detection on purpose: a provider can be found and
    /// still price at zero, which is what happened when `claude-opus-5` shipped
    /// against a fallback price table and 15.4 billion tokens valued at $0. The
    /// product's whole claim is the number, so "found a CLI" and "had a number"
    /// have to be separable.
    @discardableResult
    public func recordFirstCostIfNeeded() async -> Bool {
        if store.costReported { return true }
        guard maySend else { return false }
        return await send(costShown: true) { [store] in
            store.installReported = true
            store.costReported = true
        }
    }

    /// Every send carries the CURRENT state of all milestones, not just the one
    /// that triggered it.
    ///
    /// The RPC coalesces, so re-asserting a milestone is free — and it means any
    /// single successful send backfills whatever earlier sends lost to a missing
    /// network. Sending only the triggering milestone would make the funnel
    /// depend on the app having been online at four separate moments.
    private func send(
        providerDetected: Bool = false,
        helperConnected: Bool = false,
        costShown: Bool = false,
        onSuccess: @Sendable () -> Void
    ) async -> Bool {
        guard let appVersion else { return false }
        let payload = AnonymousInstallPayload(
            installID: store.installID,
            channel: channel,
            appVersion: appVersion,
            osVersion: osVersion,
            providerDetected: providerDetected || store.activationReported,
            helperConnected: helperConnected || store.helperConnectedReported,
            costShown: costShown || store.costReported,
            uiLanguage: uiLanguage()
        )
        do {
            try await transport.send(payload)
            onSuccess()
            return true
        } catch {
            // Deliberately quiet, and deliberately not retried in-process. The
            // flag stays false, so the next launch tries again; a failure here
            // must never surface to a user who did not ask for this feature.
            telemetryLogger.debug("anonymous telemetry deferred to next launch")
            return false
        }
    }
}
