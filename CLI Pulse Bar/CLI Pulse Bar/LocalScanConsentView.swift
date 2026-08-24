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
/// This is not that. Behind this screen are: 30 days of session logs, the
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
struct LocalScanConsentView: View {
    @EnvironmentObject var state: AppState

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
                HStack(spacing: 10) {
                    Button(L10n.localScanConsent.notNow) {
                        state.localScanConsent = .declined
                    }
                    .controlSize(.large)

                    Button(L10n.localScanConsent.start) {
                        state.localScanConsent = .granted
                        // The gate is state, not a one-shot: flipping it to
                        // `.granted` is what lets the next refresh through.
                        // Kicking one off here is only so the answer produces a
                        // visible result instead of a wait for the next tick.
                        state.requestRefresh()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }

                Text(L10n.localScanConsent.changeLater)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.localScanConsent.title)
                .font(.headline)
            Text(L10n.localScanConsent.subtitle)
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
