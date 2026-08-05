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

                Text("CLI Pulse reports two things: that it was installed, and whether it ever found a CLI to track. That's how we tell whether the app actually works for people — there's no account involved, so otherwise we can't.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("No file paths, project names, provider names, token counts or costs. Nothing that identifies you or your machine. The id is random and is deleted when you uninstall.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.anonymousTelemetryEnabled) {
                    Text("Send anonymous install statistics")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
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
