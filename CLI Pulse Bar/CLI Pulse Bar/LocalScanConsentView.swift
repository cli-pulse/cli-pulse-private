import SwiftUI
import CLIPulseCore

/// v1.50 W-C — the disclosure that precedes any read of this Mac.
///
/// WHY A BLOCKING CHOICE, WHEN THE TELEMETRY CARD DELIBERATELY IS NOT
/// ------------------------------------------------------------------
/// `AnonymousTelemetryDisclosureCard` argues, correctly, that a modal on first
/// launch buys consent that is really impatience, and it states its case inline
/// with a switch and gets out of the way. It can afford that because what it
/// discloses is two booleans with no file paths in them.
///
/// This is not that. Behind this screen are: 30 days of session logs (and, if
/// the person allows it, one read of up to a year of older ones), the
/// absolute paths and project folders derived from them, calls to OpenAI and
/// Anthropic using credentials another program stored on this Mac, a rewrite of
/// that program's credential file when a token needs renewing, and a cross-app
/// Keychain read. Those start the moment collection starts, so there is no
/// "alongside" to put the disclosure in — either it comes first or it comes too
/// late. On 2026-08-24 it came too late: a fresh install rotated its owner's
/// OpenAI credentials 1.5 s after the onboarding wizard's step-0 close button,
/// with the wizard's own privacy card never shown.
///
/// The two buttons carry equal weight on purpose. "Start local scan" is tinted
/// because it is the path most people want, but "Not now" is a real button next
/// to it, not a link underneath — and it is sticky. `LocalCollectionPolicy`
/// refuses to let a later sign-in quietly overturn it.
///
/// This screen is the second line, not the first. The gate that actually stops
/// the reads lives at the top of `refreshLocal`, so a bug that skipped this view
/// entirely would still collect nothing.
///
/// v1.55 — DISCLOSURE v2
/// ---------------------
/// v1 said "Session logs, last 30 days" while the one-time usage-history backfill
/// read up to a year. v2 says both, and makes the part beyond 30 days its own
/// answer, so the screen has two shapes:
///
///   * `.firstAsk` — nothing is on file and nothing is read yet. Three answers:
///     everything ("Start local scan"), the 30-day scan alone, or nothing.
///   * `.olderLogs` — the routine scan is already running (a v1 yes, or a
///     signed-in account) and the older logs have no answer. Two answers, and
///     both keep the 30-day scan: refusing v2 is not taking back v1. There is
///     no "Not now" here because it would mean something much bigger than the
///     question being asked; switching the scan off stays in Settings.
///
/// Both shapes carry the whole disclosure, not only the new line: the signed-in
/// users who see `.olderLogs` were let through on the strength of their account
/// in 1.50 and have never been shown what the scan reads.
struct LocalScanConsentView: View {
    enum Mode {
        case firstAsk
        case olderLogs
    }

    @EnvironmentObject var state: AppState
    var mode: Mode = .firstAsk

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    row(
                        icon: "doc.text.magnifyingglass",
                        title: L10n.localScanConsent.filesTitle,
                        detail: L10n.localScanConsent.filesDetail
                    )
                    row(
                        icon: "function",
                        title: L10n.localScanConsent.derivedTitle,
                        detail: L10n.localScanConsent.derivedDetail
                    )
                    row(
                        icon: "network",
                        title: L10n.localScanConsent.networkTitle,
                        detail: L10n.localScanConsent.networkDetail
                    )
                    row(
                        icon: "key",
                        title: L10n.localScanConsent.keychainTitle,
                        detail: L10n.localScanConsent.keychainDetail
                    )
                    row(
                        icon: "chart.bar.doc.horizontal",
                        title: L10n.localScanConsent.telemetryTitle,
                        detail: L10n.localScanConsent.telemetryDetail
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            Divider()

            VStack(spacing: 8) {
                switch mode {
                case .firstAsk:
                    firstAskButtons
                case .olderLogs:
                    olderLogsButtons
                }

                Text(mode == .firstAsk
                     ? L10n.localScanConsent.firstAskHint
                     : L10n.localScanConsent.changeLater)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The three answers stack instead of sharing a row: three large buttons do
    /// not fit 380 points in Spanish or Japanese, and a row that wraps would
    /// break the equal weight the two original buttons were given on purpose.
    /// "Not now" stays a full button, the same size as the other two.
    private var firstAskButtons: some View {
        VStack(spacing: 6) {
            Button {
                // The answers are state, not a one-shot: flipping them is what
                // lets the next refresh through. `answerLocalScanDisclosure`
                // kicks one off only so the answer produces a visible result
                // instead of a wait for the next tick.
                state.answerLocalScanDisclosure(.scanWithHistory)
            } label: {
                Text(L10n.localScanConsent.start).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Button {
                state.answerLocalScanDisclosure(.last30DaysOnly)
            } label: {
                Text(L10n.localScanConsent.lastThirtyDaysOnly).frame(maxWidth: .infinity)
            }

            Button {
                state.answerLocalScanDisclosure(.notNow)
            } label: {
                Text(L10n.localScanConsent.notNow).frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
    }

    /// Stacked like the first ask, for the same reason: side by side, the two
    /// labels are cut off in Spanish. No default action here — Return should not
    /// be the way someone agrees to a year of their logs being read.
    private var olderLogsButtons: some View {
        VStack(spacing: 6) {
            Button {
                state.answerLocalScanDisclosure(.scanWithHistory)
            } label: {
                Text(L10n.localScanConsent.includeHistory).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                state.answerLocalScanDisclosure(.last30DaysOnly)
            } label: {
                Text(L10n.localScanConsent.lastThirtyDaysOnly).frame(maxWidth: .infinity)
            }
        }
        .controlSize(.large)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mode == .firstAsk
                 ? L10n.localScanConsent.title
                 : L10n.localScanConsent.v2Title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(mode == .firstAsk
                 ? L10n.localScanConsent.subtitle
                 : L10n.localScanConsent.v2Subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PulseTheme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Shown on Overview after "Not now", so the answer stays visible and reversible
/// without re-presenting the sheet somebody already dismissed. Re-showing a
/// consent prompt to a person who said no is how a prompt becomes a nag, and how
/// people learn to click the tinted button without reading.
struct LocalScanDeclinedCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.localScanConsent.declinedTitle)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            Text(L10n.localScanConsent.declinedBody)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.localScanConsent.start) {
                // Turns the 30-day scan back on and nothing more. The older
                // logs are left unanswered on purpose, so the popover asks about
                // them next with the whole disclosure in view (`.olderLogs`),
                // instead of a card this small deciding a year of reads.
                state.localScanConsent = .granted
                state.requestRefresh()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
