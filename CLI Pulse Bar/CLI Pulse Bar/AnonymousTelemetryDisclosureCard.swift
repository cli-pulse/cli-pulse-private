import SwiftUI
import CLIPulseCore

/// Shown once, on first launch, before anything is sent.
///
/// The switch defaults ON, and this card is the entire reason that is
/// defensible. `AnonymousInstallTelemetry` refuses to send while
/// `hasSeenDisclosure` is false, so if this view never appears the feature
/// never activates — the disclosure is a hard precondition in code, not a
/// promise in a document.
///
/// It is deliberately not a modal. A blocking dialog on first launch, before
/// the user has seen the app do anything, buys consent that is really just
/// impatience. This states what happens and puts the switch next to the text.
///
/// On first launch it does come first, and that is a choice with a cost. Above
/// the setup wizard the card reads in full and the wizard follows it in the
/// same scroll view (`MenuBarView.scrollingUnderDisclosure`); at the default
/// 580-point popover, in English, Japanese and Spanish only the wizard's page
/// dots and close button show below the card until it is scrolled or
/// acknowledged, and the shorter Chinese and Korean cards leave the wizard's
/// icon and welcome title in view as well. So in practice the way into
/// the app runs past this text, and "Got it" is the obvious next click. What
/// keeps that from being the impatient consent a modal would buy:
/// - nothing is gated on it: the wizard is one scroll away and works with the
///   card still showing;
/// - the switch is inline, directly above the button, not a Settings trip away;
/// - nothing is sent until "Got it" is pressed (`hasSeenDisclosure`), whatever
///   the switch says, so scrolling past the card sends nothing.
/// The alternative was a card capped at a few lines above the wizard, which
/// still overflowed the popover on the longer wizard pages and left most of
/// this text behind a nested scroll. Reading the notice in full was judged
/// worth the wizard sitting below it; if that changes, collapse the card to a
/// one-line banner that expands rather than capping its text again.
struct AnonymousTelemetryDisclosureCard: View {
    @ObservedObject private var settings = PrivacySettings.shared
    /// The tallest the explanation may be before it scrolls inside the card.
    /// `nil` lets it take all the height it needs.
    ///
    /// The card sits above whatever the popover shows, inside a popover of fixed
    /// height (580 points by default). Laid out at full length above the setup
    /// wizard's welcome page, the two did not fit: in every language the card
    /// lost its title off the top, the wizard's subtitle was cut to one line,
    /// and the footer that holds the language menu was pushed out of the
    /// popover. Above a wizard the card is now `nil` here and scrolls together
    /// with the wizard (`MenuBarView.scrollingUnderDisclosure`), so it reads in
    /// full; above the tab views, which scroll on their own, the explanation is
    /// capped and scrolls inside the card.
    var explanationMaxHeight: CGFloat? = nil
    let onDismiss: () -> Void

    /// `localOnlyMode` forces telemetry off inside the telemetry store, whatever
    /// this switch says. Before v1.46 the card ignored that and stated, as
    /// present-tense fact, that CLI Pulse reports two things — to a user for whom
    /// it reports nothing, above a switch showing ON that did nothing. Settings ›
    /// Privacy already got this right; a disclosure that is wrong about what is
    /// being sent is worse than one that is merely terse.
    private var suppressedByLocalOnly: Bool { settings.telemetrySuppressedByLocalOnly }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.title3)
                .foregroundStyle(PulseTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.telemetry.disclosureTitle)
                    .font(.headline)

                explanation

                // Disabled rather than hidden when local-only mode is on, so the
                // master switch's effect is visible instead of a control that
                // silently does nothing. Same treatment as PrivacySettingsSection.
                Toggle(isOn: $settings.anonymousTelemetryEnabled) {
                    Text(suppressedByLocalOnly
                         ? L10n.telemetry.toggleLocalOnly
                         : L10n.telemetry.toggle)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(suppressedByLocalOnly)
                .padding(.top, 2)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(L10n.telemetry.gotIt, action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .tint(PulseTheme.accent)
                        .controlSize(.small)

                    // Wraps instead of ending in "Settings › Priv…": the path is
                    // the one thing in this line a reader needs whole.
                    Text(L10n.telemetry.changeLater)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(PulseTheme.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(PulseTheme.accent.opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var explanationText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(suppressedByLocalOnly
                 ? L10n.telemetry.disclosureBodyLocalOnly
                 : L10n.telemetry.disclosureBody)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.telemetry.notCollected)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The explanation whole when it fits under `explanationMaxHeight`, and in a
    /// scroll view of that height when it does not.
    @ViewBuilder
    private var explanation: some View {
        if let explanationMaxHeight {
            ViewThatFits(in: .vertical) {
                explanationText
                ScrollView(.vertical) {
                    explanationText
                        .padding(.trailing, 4)
                }
            }
            .frame(maxHeight: explanationMaxHeight)
        } else {
            explanationText
        }
    }
}
