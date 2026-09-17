import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 5: extracted from SettingsTab.swift (pre-extraction
/// `generalSection` + `alertThresholdRow` + `filterChip` + `toggleFilterItem`
/// + `alertThresholds` state). Contains Connection/Notifications/CostTracking/
/// Integrations sub-sections plus the webhook event filter.
struct GeneralSection: View {
    @EnvironmentObject var state: AppState
    @State private var alertThresholds: AlertThresholds = AlertThresholdsStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.settings.connection, icon: "server.rack")

            HStack {
                Text(L10n.settings.server)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.settings.serverName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.settings.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(state.serverOnline ? .green : .red)
                    .frame(width: 6, height: 6)
                Text(state.serverOnline ? L10n.settings.connected : L10n.settings.disconnected)
                    .font(.system(size: 10))
                    .foregroundStyle(state.serverOnline ? .green : .red)
            }

            HStack {
                Text(L10n.settings.refreshCadence)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                // Titled for VoiceOver; `.labelsHidden()` hides the title from
                // sight only, since the Text beside it already shows it.
                Picker(L10n.settings.refreshCadence, selection: Binding(
                    get: { state.refreshInterval },
                    set: { state.updateRefreshInterval($0) }
                )) {
                    Text(L10n.settings.refreshAdaptive).tag(0)   // v1.40 PR-8: 2–30 min by usage
                    Text("1m").tag(60)
                    Text("2m").tag(120)
                    Text("5m").tag(300)
                    Text("10m").tag(600)
                    Text("30m").tag(1800)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 300)
            }

            // v1.40 PR-7: display currency (costs convert at display time; storage stays USD).
            HStack {
                Text(L10n.settings.currency)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(L10n.settings.currency, selection: Binding(
                    get: { state.displayCurrency },
                    set: { state.setDisplayCurrency($0) }
                )) {
                    ForEach(DisplayCurrency.allCases, id: \.self) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 120)
            }

            Divider()

            SectionHeader(title: L10n.settings.notifications, icon: "bell")

            Toggle(isOn: $state.notificationsEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.desktopNotifications)
                        .font(.system(size: 11))
                    Text(L10n.settings.desktopNotificationsHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $state.sessionQuotaNotifications) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.sessionQuotaNotifications)
                        .font(.system(size: 11))
                    Text(L10n.settings.sessionQuotaHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            alertThresholdRow

            Divider()

            SectionHeader(title: L10n.settings.costTracking, icon: "dollarsign.circle")

            Toggle(isOn: $state.showCost) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.showCostSummary)
                        .font(.system(size: 11))
                    Text(L10n.settings.showCostSummaryHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $state.checkProviderStatus) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.checkProviderStatus)
                        .font(.system(size: 11))
                    Text(L10n.settings.autoPollStatus)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            SectionHeader(title: L10n.integrations.title, icon: "link")

            Toggle(isOn: Binding(
                get: { state.webhookEnabled },
                set: { state.webhookEnabled = $0; state.pushSettingsToServer() }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.integrations.webhookNotifications)
                        .font(.system(size: 11))
                    Text(L10n.integrations.webhookHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if state.webhookEnabled {
                TextField(L10n.integrations.webhookURLPlaceholder, text: $state.webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { state.pushSettingsToServer() }

                HStack {
                    Button {
                        state.pushSettingsToServer()
                        Task { await state.testWebhook() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paperplane")
                            Text(L10n.integrations.testWebhook)
                        }
                    }
                    .controlSize(.small)
                    .disabled(state.webhookURL.isEmpty)

                    Spacer()
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.integrations.eventFilterHint)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)

                        // Chips keep their label on one line and the row wraps
                        // between them: translated labels do not fit one row at
                        // the popover's width, and a chip squeezed to fit broke
                        // "デバイスオフライン" mid-word.
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(L10n.integrations.filterSeverities)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            WebhookChipFlowLayout(spacing: 4) {
                                ForEach(WebhookEventFilter.selectableSeverities, id: \.self) { severity in
                                    filterChip(
                                        label: WebhookEventFilter.severityLabel(severity),
                                        isSelected: state.webhookEventFilter.severities.contains(severity),
                                        color: severity == "Critical" ? .red : (severity == "Warning" ? .orange : .blue)
                                    ) {
                                        toggleFilterItem(&state.webhookEventFilter.severities, severity)
                                    }
                                }
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(L10n.integrations.filterTypes)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            WebhookChipFlowLayout(spacing: 4) {
                                ForEach(WebhookEventFilter.selectableTypes, id: \.self) { type in
                                    filterChip(label: WebhookEventFilter.typeLabel(type), isSelected: state.webhookEventFilter.types.contains(type)) {
                                        toggleFilterItem(&state.webhookEventFilter.types, type)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .onChange(of: state.webhookEventFilter) { _ in
                        state.pushSettingsToServer()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 10))
                        Text(L10n.integrations.eventFilter)
                            .font(.system(size: 10))
                        if !state.webhookEventFilter.isEmpty {
                            Text("(\(state.webhookEventFilter.severities.count + state.webhookEventFilter.types.count))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var alertThresholdRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.settings.quotaAlertThresholds)
                .font(.system(size: 11, weight: .medium))
            Text(L10n.settings.quotaAlertThresholdsHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Stepper(value: Binding(
                    get: { alertThresholds.warning },
                    set: { newValue in
                        alertThresholds = AlertThresholds.clamped(
                            warning: newValue, critical: alertThresholds.critical
                        )
                        AlertThresholdsStore.save(alertThresholds)
                    }
                ), in: AlertThresholds.warningRange, step: 5) {
                    Text(L10n.settings.warningPct(alertThresholds.warning))
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
                .controlSize(.small)

                Stepper(value: Binding(
                    get: { alertThresholds.critical },
                    set: { newValue in
                        alertThresholds = AlertThresholds.clamped(
                            warning: alertThresholds.warning, critical: newValue
                        )
                        AlertThresholdsStore.save(alertThresholds)
                    }
                ), in: (alertThresholds.warning + 1)...AlertThresholds.criticalUpperBound, step: 5) {
                    Text(L10n.settings.criticalPct(alertThresholds.critical))
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
                .controlSize(.small)

                if alertThresholds != .defaults {
                    Button(L10n.settings.reset) {
                        alertThresholds = .defaults
                        AlertThresholdsStore.save(.defaults)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 2)
    }

    private func filterChip(label: String, isSelected: Bool, color: Color = PulseTheme.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isSelected ? color.opacity(0.2) : Color.gray.opacity(0.1))
                .foregroundStyle(isSelected ? color : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleFilterItem(_ array: inout [String], _ item: String) {
        if let index = array.firstIndex(of: item) {
            array.remove(at: index)
        } else {
            array.append(item)
        }
    }
}

/// Lays chips left to right and starts a new row when the next one would not
/// fit, so each chip keeps its ideal size. Takes the width it is offered and is
/// as tall as its rows; its first text baseline is the first chip's, so a label
/// beside it lines up with the first row.
private struct WebhookChipFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width, subviews: subviews)
        let width = proposal.width ?? rows.usedWidth
        return CGSize(width: width.isFinite ? width : rows.usedWidth, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        return bounds.minY + first.dimensions(in: .unspecified)[.firstTextBaseline]
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (origins: [CGPoint], usedWidth: CGFloat, height: CGFloat) {
        let maxWidth = width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (origins, usedWidth, y + rowHeight)
    }
}
