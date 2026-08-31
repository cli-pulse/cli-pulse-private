import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 7: extracted from SettingsTab.swift (pre-extraction
/// `displaySection`). Menu-bar display mode, content mode, appearance,
/// and the Overview-providers reorder list.
struct DisplaySection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Menu Bar", icon: "menubar.rectangle")

            HStack {
                Text(L10n.display.mode)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { state.menuBarDisplayMode },
                    set: { state.menuBarDisplayMode = $0 }
                )) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 120)
            }

            Text(state.menuBarDisplayMode.description)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Toggle(isOn: $state.mergeMenuBarIcons) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.display.mergeMenuBarIcons)
                        .font(.system(size: 11))
                    Text(L10n.display.mergeMenuBarHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            SectionHeader(title: "Appearance", icon: "paintbrush")


            Divider()

            SectionHeader(title: "Overview Providers", icon: "square.grid.2x2")

            Text(L10n.display.reorderHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            List {
                ForEach(providerState.providerConfigs) { config in
                    Button {
                        state.setProviderAccountEnabled(
                            config.accountID,
                            isEnabled: !config.isEnabled
                        )
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)
                            Image(systemName: config.kind.iconName)
                                .font(.system(size: 8))
                                .foregroundStyle(PulseTheme.providerColor(config.kind.rawValue))
                            Text(displayLabel(for: config))
                                .font(.system(size: 9))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: config.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 9))
                                .foregroundStyle(config.isEnabled ? Color.green : Color.gray)
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(config.isEnabled ? PulseTheme.providerColor(config.kind.rawValue).opacity(0.06) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    state.moveProvider(from: from, to: to)
                }
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(providerState.providerConfigs.count) * 24, 240))
        }
    }

    private func displayLabel(
        for config: ProviderConfig
    ) -> String {
        let accounts = providerState.configs(for: config.kind)
        guard accounts.count > 1 else {
            return config.kind.rawValue
        }
        let label =
            config.accountLabel?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountName: String
        if let label, !label.isEmpty {
            accountName = label
        } else if let index = accounts.firstIndex(where: {
            $0.accountID == config.accountID
        }) {
            accountName = L10n.providers.accountNumber(index + 1)
        } else {
            accountName = L10n.providers.defaultAccount
        }
        return "\(config.kind.rawValue) · \(accountName)"
    }
}
