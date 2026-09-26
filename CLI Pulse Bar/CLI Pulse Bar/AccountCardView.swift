import SwiftUI
import CLIPulseCore

/// v1.10 P2-2: extracted from SettingsTab.swift (pre-extraction `accountCard`).
/// Header card at the top of the authenticated Settings view: user avatar,
/// name, email (optional), pairing status. Pure state-less read from
/// `AppState`.
struct AccountCardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(PulseTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(authState.userName)
                    .font(.system(size: 12, weight: .semibold))
                if !state.hidePersonalInfo {
                    Text(authState.userEmail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                StatusBadge(
                    text: isSyncing ? L10n.settings.paired : L10n.settings.notPaired,
                    color: isSyncing ? .green : .orange
                )
            }
        }
        .padding(8)
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The badge reads "Synced". `isPaired` is the account's flag, so on a Mac
    /// that is not itself paired (`ThisMacPairing`) green would be false.
    private var isSyncing: Bool {
        authState.isPaired && authState.thisMacPairing == .notNeeded
    }
}
