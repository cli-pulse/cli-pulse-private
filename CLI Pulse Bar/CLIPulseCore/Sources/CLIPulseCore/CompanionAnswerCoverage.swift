import Foundation

/// v1.55 — whether the Companion CLI answering on this Mac follows the app's
/// local-scan answer, its account and the Privacy switches.
///
/// Companion CLI 1.30.0 and every release before it read none of them: while
/// installed and paired, it collects every 2 minutes and uploads to the account
/// it was paired with, whatever the app says, "Not now" and signing out
/// included. The screens that ask for the answer, or show it, say what CLI Pulse
/// does with it, so where a Companion like that answers `hello` they say this
/// too (`local_scan_consent.companion_not_covered` under the answer,
/// `settings.companion_ignores_switches` under the Claude keychain switches).
///
/// Decided from the `hello` reply rather than from a version floor. The
/// Companion learned to follow the answer (#627, #630) while its
/// `HELPER_VERSION` still said 1.30.0, so "1.30.0 or lower" would have named a
/// Companion that does follow it. One that follows it says so with
/// `follows_app_answer: true` (`SessionControlHello.followsAppAnswer`).
///
/// What this cannot see is a Companion that runs but does not answer, for
/// example while another helper holds the socket. It says nothing then rather
/// than guess.
public enum CompanionAnswerCoverage {
    /// The version the Companion reported (empty for one too old to report
    /// any) when a note is due, or nil when none is:
    /// - nothing answered `hello`;
    /// - the built-in agent answered: it uploads nothing;
    /// - the Companion says it follows the answer;
    /// - the Companion says it is not paired: it has no account to send to.
    public static func ignoringVersion(hello: SessionControlHello?) -> String? {
        guard let hello else { return nil }
        guard !hello.isSwiftBundled else { return nil }
        guard !hello.followsAppAnswer else { return nil }
        guard hello.paired != false else { return nil }
        return hello.helperVersion
    }

    /// How the notes name that version: "v1.30.0", or the catalogue's "an old
    /// version" for a Companion too old to report one. Worked out when shown,
    /// so it follows the display language.
    public static func versionLabel(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? L10n.sessions.helperOldVersion : "v\(trimmed)"
    }
}
