#if os(macOS)
import SwiftUI

/// The one window CLI Pulse ever opens by itself.
///
/// It exists to answer the only question a brand-new user has, which the app
/// currently answers with silence: *did anything happen?* See
/// `FirstRunPresentation` for why that silence is the most expensive thing in
/// the funnel.
///
/// Deliberately NOT an onboarding flow. No pages, no account prompt, no
/// permission requests, no provider setup. Every one of those adds a step before
/// the user has seen the app work, and the measured problem is that they never
/// see it at all. One screen, one arrow at the menu bar, one button.
public struct FirstRunWelcomeView: View {
    /// Invoked when the user dismisses. The caller closes the window and marks
    /// the flag — this view owns no persistence so it stays previewable and
    /// testable.
    private let onDismiss: () -> Void

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 20) {
            // The arrow points up and to the right, which is where the menu bar
            // item is. Purely decorative, so it is hidden from VoiceOver — the
            // text below carries the same information in words.
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(L10n.firstRun.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(L10n.firstRun.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.firstRun.dismiss, action: onDismiss)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(32)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.firstRun.title)
    }
}

#Preview {
    FirstRunWelcomeView(onDismiss: {})
}
#endif
