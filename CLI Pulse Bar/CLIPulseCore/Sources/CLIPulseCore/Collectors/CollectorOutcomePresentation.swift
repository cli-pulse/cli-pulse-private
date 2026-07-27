import Foundation

/// v1.44 W3 — how a `CollectorOutcome` is shown to a person.
///
/// Lives in CLIPulseCore rather than in the view for the usual reason: a
/// mapping that decides what the user is told about their own machine is
/// exactly the kind of thing that should be pinned by tests, and views in the
/// app target are out of this package's reach.
///
/// The rule every label here follows: **say what we know, and give one thing
/// to do about it.** The previous behaviour said nothing at all, which the
/// user reads as "this tool isn't supported" — the single most expensive
/// wrong conclusion available, because it is usually false.
public struct CollectorOutcomePresentation: Sendable, Equatable {
    /// Short badge text for the provider row.
    public let label: String
    /// One concrete next step, or nil when there is genuinely nothing for the
    /// user to do. Never a restatement of the label.
    public let nextStep: String?
    /// How loudly to render it.
    public let severity: Severity

    public enum Severity: Sendable, Equatable {
        /// Working, or intentionally off. No colour.
        case normal
        /// The user can fix this.
        case attention
        /// Something is broken. Not necessarily the user's fault.
        case problem
    }

    public init(label: String, nextStep: String?, severity: Severity) {
        self.label = label
        self.nextStep = nextStep
        self.severity = severity
    }

    /// Map an outcome to its presentation.
    ///
    /// `providerName` is interpolated into the install prompt so the row says
    /// "Install Codex" rather than "Install this provider" — the whole point of
    /// the row is to be specific enough to act on without further hunting.
    public static func of(_ outcome: CollectorOutcome, providerName: String) -> CollectorOutcomePresentation {
        switch outcome {
        case .disabled:
            // The user did this on purpose. Saying "off" is enough; prompting
            // them to turn it back on would be nagging about their own choice.
            return .init(label: L10n.collectorStatus.off, nextStep: nil, severity: .normal)

        case .unsupported:
            // We never wrote a collector for this one. Nothing the user can do,
            // so no call to action — but say it plainly rather than rendering
            // an empty row they will read as "broken".
            return .init(
                label: L10n.collectorStatus.noQuotaSource,
                nextStep: L10n.collectorStatus.noQuotaSourceHint,
                severity: .normal
            )

        case .producedData:
            return .init(label: L10n.collectorStatus.ok, nextStep: nil, severity: .normal)

        case .notReady(.notInstalled):
            return .init(
                label: L10n.collectorStatus.notInstalled,
                nextStep: L10n.collectorStatus.notInstalledHint(providerName),
                severity: .normal
            )

        case .notReady(.notRunning):
            return .init(
                label: L10n.collectorStatus.notRunning,
                nextStep: L10n.collectorStatus.notRunningHint(providerName),
                severity: .normal
            )

        case .notReady(.missingCredentials):
            return .init(
                label: L10n.collectorStatus.notSignedIn,
                nextStep: L10n.collectorStatus.notSignedInHint(providerName),
                severity: .attention
            )

        case .notReady(.missingApiKey):
            // Distinct from the above on purpose: "sign in to the app, no key
            // needed here" is unactionable for a provider that only reads a
            // token, and sends the user to a screen that cannot help them.
            return .init(
                label: L10n.collectorStatus.needsKey,
                nextStep: L10n.collectorStatus.needsKeyHint(providerName),
                severity: .attention
            )

        case .notReady(.unknown):
            // We could not tell why. Do not guess a cause — point at the one
            // screen that can resolve any of them.
            return .init(
                label: L10n.collectorStatus.notSetUp,
                nextStep: L10n.collectorStatus.notSetUpHint,
                severity: .attention
            )

        case .ranButEmpty:
            // The silent-zero case. It used to render as a healthy 100% tile,
            // which is worse than useless — it actively told the user things
            // were fine.
            return .init(
                label: L10n.collectorStatus.noData,
                nextStep: L10n.collectorStatus.noDataHint,
                severity: .attention
            )

        case .failed(.auth):
            // Wording is deliberately neutral about WHICH credential lapsed.
            // The category covers both an expired OAuth session and a revoked
            // API key, and we cannot tell them apart from a 401 — so the old
            // "your saved session has lapsed" was a confident guess that is
            // simply false for every key-based provider.
            return .init(
                label: L10n.collectorStatus.authFailed,
                nextStep: L10n.collectorStatus.authFailedHint(providerName),
                severity: .attention
            )

        case .failed(.permission):
            // One tap away — the folder-access grant. Must not be buried.
            return .init(
                label: L10n.collectorStatus.accessBlocked,
                nextStep: L10n.collectorStatus.accessBlockedHint,
                severity: .attention
            )

        case .failed(.network):
            return .init(
                label: L10n.collectorStatus.unreachable,
                nextStep: L10n.collectorStatus.unreachableHint,
                severity: .problem
            )

        case .failed(.parse):
            // Ours, not theirs. Telling this user to check their credentials
            // would send them to fix something that is not broken.
            return .init(
                label: L10n.collectorStatus.cannotRead,
                nextStep: L10n.collectorStatus.cannotReadHint,
                severity: .problem
            )

        case .failed(.http):
            return .init(
                label: L10n.collectorStatus.failed,
                nextStep: L10n.collectorStatus.failedHint,
                severity: .problem
            )

        case .failed(.other):
            // Must NOT claim "the provider returned an error" — `.other`
            // includes `invalidURL`, where no request was ever sent. Saying
            // otherwise points the user at an upstream that never heard from
            // us, and at a fault that is on our side.
            return .init(
                label: L10n.collectorStatus.failed,
                nextStep: L10n.collectorStatus.failedOtherHint,
                severity: .problem
            )
        }
    }
}
