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
/// It is deliberately not a modal with an OK button. A blocking dialog on
/// first launch, before the user has seen the app do anything, buys consent
/// that is really just impatience. This states what happens, offers the switch
/// inline, and gets out of the way.
struct AnonymousTelemetryDisclosureCard: View {
    @ObservedObject private var settings = PrivacySettings.shared
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
                Text("Anonymous install statistics")
                    .font(.headline)

                Text(suppressedByLocalOnly
                     ? """
                       Local-only mode is on, so CLI Pulse is sending nothing \
                       at all. Without it, it would report four steps: that it \
                       was installed, whether the helper connected, whether it \
                       ever found a CLI to track, and whether it ever had a \
                       cost to show — plus which language it is displaying in.
                       """
                     : """
                       CLI Pulse reports how far it got: that it was installed, \
                       whether the helper connected, whether it ever found a \
                       CLI to track, and whether it ever had a cost to show. It \
                       also reports which language it is displaying in. That's \
                       how we tell where the app stops working for people — \
                       there's no account involved, so otherwise we can't.
                       """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("No file paths, project names, provider names, token counts or costs. Nothing that identifies you or your machine. The id is random and is deleted when you uninstall.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Disabled rather than hidden when local-only mode is on, so the
                // master switch's effect is visible instead of a control that
                // silently does nothing. Same treatment as PrivacySettingsSection.
                Toggle(isOn: $settings.anonymousTelemetryEnabled) {
                    Text(suppressedByLocalOnly
                         ? "Off — local-only mode covers this too."
                         : "Send anonymous install statistics")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(suppressedByLocalOnly)
                .padding(.top, 2)

                HStack(spacing: 8) {
                    Button("Got it", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .tint(PulseTheme.accent)
                        .controlSize(.small)

                    Text("You can change this any time in Settings › Privacy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
}
