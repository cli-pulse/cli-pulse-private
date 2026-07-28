import Foundation

// The vocabulary below (CollectorOutcome and its two reason enums) is
// deliberately NOT `#if os(macOS)`-gated even though collectors only run on
// macOS. `DataRefreshManager.Callbacks` is one struct compiled for every
// platform, so a macOS-only field would force a per-platform initializer just
// to carry a value iOS and watchOS never populate. The enums are pure and cost
// nothing off-macOS; only the machinery that touches `ProviderCollector` /
// `CollectorError` is gated further down.

/// v1.44 W3 — one shared answer to "what happened to this provider?".
///
/// The problem this exists to fix: `DataRefreshManager.runCollectors` filtered
/// providers down to the runnable ones *before* executing anything, and
/// `runOneCollector` returned `nil` on throw. Four completely different
/// situations — the user disabled it, no collector is implemented for it, the
/// collector exists but has no credentials, the collector ran and failed —
/// arrived at the UI as the same thing: absence. Nothing to render, so nothing
/// rendered, so the user (and we) could not tell a missing tool from a broken
/// parser. `CollectorErrorLog` captured the last case but has zero references
/// in the macOS UI target, so it only ever reached a log file.
///
/// Production shape of that blindness: 23 active devices, 7 with no quota and
/// 12 with no cost, and no way to know which of the four causes applied to any
/// of them. This type turns that into a sorted work queue.
///
/// Deliberately a *reporting* layer, not a second execution path. There are
/// already two collector drivers — `DataRefreshManager.runCollectors` (bounded
/// fan-out, filters first) and `HelperDaemon.collectProviderQuotas` (sequential)
/// — and they have already diverged. Both reviews of the v1.44 plan flagged
/// copying the daemon's state machine into the app as the wrong move for
/// exactly that reason. So the classification lives here, in the package the
/// tests can reach, and each driver keeps its own scheduling.
public enum CollectorOutcome: Sendable, Equatable {
    /// The user switched this provider off. Not a problem to report.
    case disabled
    /// No collector is implemented for this provider kind at all. The provider
    /// can still show scanned cost/session data — it just has no quota source.
    case unsupported
    /// A collector exists but declined to run. See `CollectorNotReadyReason`.
    case notReady(CollectorNotReadyReason)
    /// Ran, and returned something with numbers in it.
    case producedData
    /// Ran, returned successfully, and carried no usable numbers. This is the
    /// case that used to be invisible: from the outside it looks identical to
    /// success, and it renders as a healthy tile.
    case ranButEmpty
    /// Ran and threw. See `CollectorFailureCategory`.
    case failed(CollectorFailureCategory)

    /// True when this provider needs the user to do something. Drives whether a
    /// row gets a call to action; `disabled` and `producedData` are quiet, and
    /// `unsupported` is quiet too because there is nothing the user can do
    /// about a provider we never wrote a collector for.
    public var isActionable: Bool {
        switch self {
        case .disabled, .unsupported, .producedData:
            return false
        case .notReady, .ranButEmpty, .failed:
            return true
        }
    }

    /// Stable short token for telemetry (`devices.collector_status`, v0.71).
    /// Kept flat and low-cardinality — this is aggregated across devices, not
    /// read per-row. Must stay stable: changing a token silently splits history.
    public var telemetryToken: String {
        switch self {
        case .disabled: return "disabled"
        case .unsupported: return "unsupported"
        case .notReady(let reason): return "not_ready_\(reason.rawValue)"
        case .producedData: return "ok"
        case .ranButEmpty: return "empty"
        case .failed(let category): return "failed_\(category.rawValue)"
        }
    }
}

/// Why a collector declined to run.
///
/// `ProviderCollector.isAvailable` returns a bare `Bool` across ~120 collectors
/// and conflates "the tool isn't installed" with "the tool is here but we have
/// no credentials" — a distinction the user needs, because the fixes are
/// completely different ("install Codex" vs "run `codex login`"). Rewriting all
/// 120 signatures to find that out would be a far larger and riskier change
/// than this release warrants, so `unknown` is a first-class case and the
/// default. It is honest: it says we don't know, and the UI says "not set up"
/// rather than inventing a reason. Collectors that DO know override
/// `readiness(config:)` and get a precise label.
public enum CollectorNotReadyReason: String, Sendable, Equatable {
    /// The provider's CLI/app is not present on this machine.
    case notInstalled = "not_installed"
    /// The tool is installed but its local service isn't answering. Distinct
    /// from `notInstalled` because the fixes differ and the wrong one wastes
    /// real time: telling someone whose Ollama is merely stopped to *install*
    /// Ollama sends them to redo something they already did. Applies to the
    /// probe-a-local-port collectors, and to a configured-but-unreachable
    /// remote host.
    case notRunning = "not_running"
    /// The tool is present and signed out — the user fixes this inside that
    /// tool (`codex login`, opening the app), not in CLI Pulse.
    case missingCredentials = "missing_credentials"
    /// We need an API key or token entered HERE. Split from
    /// `missingCredentials` because the advice is not interchangeable:
    /// Copilot has no "sign in and we'll pick it up" path — the user must
    /// supply `COPILOT_API_TOKEN` — so telling them to sign in to the Copilot
    /// app and that "no key is needed here" is advice that cannot work.
    case missingApiKey = "missing_api_key"
    /// `isAvailable` said no and the collector did not say why.
    case unknown
}

/// Failure classes, mapped from the error cases collectors actually throw
/// (`CollectorError`) rather than invented. Anything unrecognised is `other` —
/// a category that lies is worse than one that admits ignorance.
public enum CollectorFailureCategory: String, Sendable, Equatable {
    /// Credential was sent and the upstream rejected it (401/403), or the
    /// collector reports it is signed out. The user must re-authenticate.
    case auth
    /// Reachability: DNS, connection refused, timeout, offline.
    case network
    /// We got a response and could not read it — usually an upstream format
    /// change. This one is ours to fix, not the user's.
    case parse
    /// Upstream answered with a non-success status that isn't auth-related.
    case http
    /// Sandbox / file-permission denial. On MAS this is the missing
    /// security-scoped bookmark; the fix is one tap, so it must not be buried
    /// in `other`.
    case permission
    case other

    /// Map a thrown error to a category.
    ///
    /// Pure and total so it is testable without running a collector. Ordering
    /// matters: `CollectorError` is checked before the `NSError` fallbacks
    /// because a `CollectorError.httpError(401)` is auth, not http.
    public static func categorize(_ error: Error) -> CollectorFailureCategory {
        #if os(macOS)
        if let collectorError = error as? CollectorError {
            switch collectorError {
            case .notSignedIn:
                return .auth
            case .missingCredentials:
                // Thrown from inside `collect()` rather than caught by
                // `isAvailable` — same user-visible meaning as `.notReady`,
                // but it reached us as a failure, so report it as auth: the
                // fix is still "give us a credential".
                return .auth
            case .httpError(let status, _):
                return (status == 401 || status == 403) ? .auth : .http
            case .parseFailed:
                return .parse
            case .invalidURL:
                return .other
            case .silentBackoff:
                // Repeated OAuth-refresh failure after a token expired.
                return .auth
            }
        }
        #endif

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network
        }
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code) {
            return .permission
        }
        if error is DecodingError {
            return .parse
        }
        return .other
    }
}

// Everything below touches `ProviderCollector` / `CollectorResult`, which are
// macOS-only, so the machinery is gated even though the vocabulary above is not.
#if os(macOS)

/// One provider's result from a collector pass.
public struct CollectorRun: Sendable {
    public let kind: ProviderKind
    public let outcome: CollectorOutcome
    /// Present only when a collector actually returned one — i.e. for
    /// `.producedData` and `.ranButEmpty`. Callers that only want usable data
    /// should filter on the outcome, not on this being non-nil.
    public let result: CollectorResult?

    public init(kind: ProviderKind, outcome: CollectorOutcome, result: CollectorResult? = nil) {
        self.kind = kind
        self.outcome = outcome
        self.result = result
    }
}

public enum CollectorRunner {

    /// Classify a returned result as data-bearing or empty.
    ///
    /// Delegates to `HelperAPIClient.classifyCollectorOutcome`, which is the
    /// same predicate the sync daemon reports with (migrate_v0.71). One
    /// predicate, one meaning — a second copy here would drift, and the last
    /// time this judgement was duplicated the app-target copy turned out to be
    /// a tautology that reported `ok` for precisely the silent-zero devices the
    /// feature existed to find.
    public static func classify(_ result: CollectorResult) -> CollectorOutcome {
        // The numeric predicate below only means anything for `.quota`
        // results. `CollectorDataKind` says so itself: `.credits` is "a
        // credit-based balance", `.statusOnly` is "local status only, no quota
        // model". Those collectors report their payload in `status_text` —
        // "$12.34 / $50.00", "12.5 req/min · 4300 tok/min" — and hardcode
        // today/week/quota/remaining to zero-or-nil on their SUCCESS path.
        //
        // Feeding those five fields to the counter predicate therefore called
        // 26 healthy collectors empty: a working Groq or OpenRouter card got a
        // permanent orange "No data returned" warning sitting directly under
        // the live numbers it had just fetched. Worse, `producedValue` needs a
        // `.producedData` to exist, so a user whose providers are all
        // credits/status-only would never trigger W5 — and every report to
        // `devices.collector_status` logged them as "empty", poisoning the
        // silent-zero diagnostic this release exists to power.
        //
        // I excluded `status_text` from the predicate deliberately, because for
        // quota providers it is always populated and made the check a
        // tautology. That reasoning was right for `.quota` and wrong to
        // generalise: for these two kinds `status_text` IS the data. Rather
        // than reintroduce a string test, trust the collector's own
        // declaration — it returned successfully as the kind it says it is.
        guard result.dataKind == .quota else { return .producedData }

        let token = HelperAPIClient.classifyCollectorOutcome(
            tiersCount: result.usage.tiers.count,
            quota: result.usage.quota,
            remaining: result.usage.remaining,
            todayUsage: result.usage.today_usage,
            weekUsage: result.usage.week_usage
        )
        return token == "ok" ? .producedData : .ranButEmpty
    }

    /// Decide, without executing anything, what can be said about a provider
    /// before a collector runs. Returns `nil` when the provider should be
    /// executed.
    ///
    /// Pure — takes the collector lookup as a parameter so tests can drive
    /// every branch without a real registry.
    public static func preflight(
        config: ProviderConfig,
        collector: ProviderCollector?
    ) -> CollectorOutcome? {
        guard config.isEnabled else { return .disabled }
        guard let collector else { return .unsupported }
        let readiness = collector.readiness(config: config)
        switch readiness {
        case .ready:
            return nil
        case .notReady(let reason):
            return .notReady(reason)
        }
    }

    /// Full pass over every configured provider.
    ///
    /// The important property: the returned array has one entry per input
    /// config — including the disabled, the unsupported and the not-ready.
    /// `runCollectors` used to drop those before execution, which is why the UI
    /// could never say anything about them.
    public static func run(
        configs: [ProviderConfig],
        maxConcurrent: Int,
        execute: @Sendable @escaping (ProviderConfig, ProviderCollector) async -> Result<CollectorResult, Error>
    ) async -> [CollectorRun] {
        var preflighted: [CollectorRun] = []
        var toExecute: [(ProviderConfig, ProviderCollector)] = []

        for config in configs {
            // NOTE: `CollectorRegistry.collector(for:config:)` folds
            // `isAvailable` into its lookup and returns nil for a not-ready
            // collector, which would make "unsupported" and "no credentials"
            // indistinguishable again. Resolve by kind only, then let
            // `preflight` ask about readiness separately.
            let collector = CollectorRegistry.collectors.first { $0.kind == config.kind }
            if let outcome = Self.preflight(config: config, collector: collector) {
                preflighted.append(CollectorRun(kind: config.kind, outcome: outcome))
            } else if let collector {
                toExecute.append((config, collector))
            }
        }

        let executed = await mapWithConcurrencyLimit(
            toExecute,
            maxConcurrent: maxConcurrent
        ) { pair -> CollectorRun? in
            let (config, collector) = pair
            switch await execute(config, collector) {
            case .success(let result):
                return CollectorRun(kind: config.kind, outcome: Self.classify(result), result: result)
            case .failure(let error):
                return CollectorRun(
                    kind: config.kind,
                    outcome: .failed(CollectorFailureCategory.categorize(error))
                )
            }
        }

        return preflighted + executed
    }

    /// Per-provider telemetry map for `helper_report_app_version`'s
    /// `p_collector_status` (migrate_v0.71). Keyed by provider raw value.
    public static func telemetryMap(_ runs: [CollectorRun]) -> [String: String] {
        var map: [String: String] = [:]
        for run in runs {
            map[run.kind.rawValue] = run.outcome.telemetryToken
        }
        return map
    }

    /// Should this pass's outcome map be uploaded?
    ///
    /// A refresh tick is 60–120s, so reporting unconditionally would be well
    /// over a thousand writes per device per day to answer a question that
    /// changes maybe twice a week. Upload when the picture actually changed,
    /// and otherwise at most once per `minInterval` so a device that is
    /// steadily fine still proves it is alive and reporting.
    ///
    /// Pure — clock and previous state are injected — because the alternative
    /// is a throttle that can only be verified by watching production write
    /// volume after the fact.
    public static func shouldReportTelemetry(
        current: [String: String],
        lastReported: [String: String]?,
        lastReportedAt: Date?,
        now: Date,
        minInterval: TimeInterval = 3600
    ) -> Bool {
        guard !current.isEmpty else { return false }
        guard let lastReported, let lastReportedAt else { return true }
        if current != lastReported { return true }
        return now.timeIntervalSince(lastReportedAt) >= minInterval
    }
}

/// Readiness, split out from `isAvailable` so a collector can explain itself.
public enum CollectorReadiness: Sendable, Equatable {
    case ready
    case notReady(CollectorNotReadyReason)
}

public enum CollectorReadinessProbe {

    /// Distinguish "the tool was never installed" from "it is installed and we
    /// have no credentials", by asking whether its config directory exists.
    ///
    /// The sandbox case is the trap. Under MAS with no security-scoped
    /// bookmark, `fileExists` at `~/.codex` returns false whether or not the
    /// directory is there — so the naive version of this reports
    /// `notInstalled` to every App Store user who has not yet granted folder
    /// access. That is precisely the class of confident-and-wrong label W3
    /// exists to eliminate, and it would send a user who simply needs to tap
    /// "Grant access" off to reinstall a CLI they already have. When we cannot
    /// see, we say `unknown` and let the folder-access banner do its job.
    ///
    /// The rule: **never claim `notInstalled` while sandboxed.** A negative
    /// existence check there is genuinely ambiguous — absent directory and
    /// unreadable directory are the same answer — so the sandboxed branch
    /// degrades to `unknown` rather than picking one. Only an unsandboxed
    /// build, which can actually see the filesystem, is allowed to say the
    /// tool is missing.
    ///
    /// Pure apart from the two injected probes, so every branch — including
    /// the sandboxed-and-blind one — is testable without a sandbox.
    /// `SandboxFileAccess.fileExists` is the default because it is
    /// nonisolated (this runs off the main actor, inside the collector
    /// fan-out) and already resolves a bookmark when one exists.
    public static func fromConfigDirectory(
        path: String,
        isSandboxed: Bool = MASSandboxGate.isSandboxed,
        directoryExists: (String) -> Bool = { SandboxFileAccess.fileExists(at: $0) }
    ) -> CollectorReadiness {
        if directoryExists(path) {
            return .notReady(.missingCredentials)
        }
        return .notReady(isSandboxed ? .unknown : .notInstalled)
    }
}

public extension ProviderCollector {
    /// Default: fall back to the existing `isAvailable` Bool and admit we don't
    /// know why it said no. Collectors override this to give the user a
    /// specific next step. Keeping the default honest rather than guessing
    /// `missingCredentials` matters — most collectors return false from
    /// `isAvailable` for a missing key, but several (Ollama, Warp, Zed) return
    /// false when the *tool* is absent, and telling those users to go find an
    /// API key would send them somewhere that does not exist.
    func readiness(config: ProviderConfig) -> CollectorReadiness {
        isAvailable(config: config) ? .ready : .notReady(.unknown)
    }
}
#endif
