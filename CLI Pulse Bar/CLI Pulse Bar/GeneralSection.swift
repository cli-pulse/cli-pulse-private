import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 5: extracted from SettingsTab.swift (pre-extraction
/// `generalSection` + `alertThresholdRow` + `filterChip` + `toggleFilterItem`
/// + `alertThresholds` state). Contains Connection/Notifications/CostTracking/
/// Integrations sub-sections plus the webhook event filter.
struct GeneralSection: View {
    @EnvironmentObject var state: AppState
    @State private var alertThresholds: AlertThresholds = AlertThresholdsStore.load()
    @State private var webhookFilterExpanded = false
    #if CLIPULSE_QA_RENDER
    @Environment(\.qaRenderViewState) private var qaRenderViewState
    #endif

    /// The fixed refresh intervals the picker offers, in minutes.
    static let refreshMinutes = [1, 2, 5, 10, 30]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.settings.connection, icon: "server.rack")

            HStack {
                Text(L10n.settings.server)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                // Not monospaced: the name is translated ("Supabase (도쿄)",
                // "Supabase（东京）"), and in SF Mono the CJK falls back to another
                // font while the brackets stay fixed-width and look misplaced.
                Text(L10n.settings.serverName)
                    .font(.system(size: 10))
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

            // The label sits above the picker. Beside a 300-point picker it had
            // about 30 points left, and broke inside its words in every
            // language ("Refre/sh Caden/ce", "새로고/침 주기").
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.settings.refreshCadence)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                // Titled for VoiceOver; `.labelsHidden()` hides the title from
                // sight only, since the Text above it already shows it.
                Picker(L10n.settings.refreshCadence, selection: Binding(
                    get: { state.refreshInterval },
                    set: { state.updateRefreshInterval($0) }
                )) {
                    Text(L10n.settings.refreshAdaptive).tag(0)   // v1.40 PR-8: 2–30 min by usage
                    // Minutes in the reader's own abbreviation: a bare "1m"
                    // reads as a metre in Chinese and Japanese.
                    ForEach(Self.refreshMinutes, id: \.self) { minutes in
                        Text(L10n.settings.refreshMinutesShort(minutes)).tag(minutes * 60)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(maxWidth: .infinity)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

                WebhookEventFilterDisclosure(
                    filter: state.webhookEventFilter,
                    isLoaded: state.webhookEventFilterLoaded,
                    isSignedIn: state.isAuthenticated,
                    isExpanded: $webhookFilterExpanded,
                    toggleSeverity: { severity in
                        state.editWebhookEventFilter { Self.toggle(severity, in: &$0.severities) }
                    },
                    toggleType: { type in
                        state.editWebhookEventFilter { Self.toggle(type, in: &$0.types) }
                    },
                    loadSaved: { await state.loadWebhookEventFilter() }
                )
            }
        }
        #if CLIPULSE_QA_RENDER
        .onAppear {
            // QA build only: the offscreen renderer opens the filter, as a
            // person would by clicking it.
            if qaRenderViewState?.webhookFilterExpanded == true { webhookFilterExpanded = true }
        }
        #endif
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

    /// Selects `item` if it is not selected, deselects it if it is.
    static func toggle(_ item: String, in list: inout [String]) {
        if let index = list.firstIndex(of: item) {
            list.remove(at: index)
        } else {
            list.append(item)
        }
    }
}

/// Settings › Integrations › Event Filter: the account's saved webhook event
/// filter, as chips.
///
/// It draws what it is given, so the QA renderer draws it in each state
/// (`QAWebhookEventFilterStates`). Until the saved filter has been read the
/// chips cannot be changed, and say why: a change before that would save the
/// chips on screen over a filter nobody has seen. A type the chips no longer
/// offer is shown while the filter holds it (`WebhookEventFilter.typeChips`),
/// with a line saying it is no longer raised.
struct WebhookEventFilterDisclosure: View {
    let filter: WebhookEventFilter
    let isLoaded: Bool
    /// Signed out there is no saved filter to read: the line says the filter
    /// is the account's instead of waiting for a read that cannot come.
    var isSignedIn = true
    @Binding var isExpanded: Bool
    var toggleSeverity: (String) -> Void = { _ in }
    var toggleType: (String) -> Void = { _ in }
    /// Called when the filter opens before the saved one has been read.
    var loadSaved: (() async -> Void)?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.integrations.eventFilterHint)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                if !isLoaded {
                    Text(isSignedIn ? L10n.integrations.eventFilterNotLoaded : L10n.integrations.eventFilterSignedOut)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
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
                            ForEach(WebhookEventFilter.severityChips(for: filter), id: \.self) { severity in
                                filterChip(
                                    label: WebhookEventFilter.severityLabel(severity),
                                    isSelected: filter.severities.contains(severity),
                                    color: severity == "Critical" ? .red : (severity == "Warning" ? .orange : .blue)
                                ) {
                                    toggleSeverity(severity)
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
                            ForEach(WebhookEventFilter.typeChips(for: filter), id: \.self) { type in
                                filterChip(label: WebhookEventFilter.typeLabel(type), isSelected: filter.types.contains(type)) {
                                    toggleType(type)
                                }
                            }
                        }
                    }
                }
                // Until the saved filter is read, a change would save these
                // chips over it, so they cannot be changed.
                .disabled(!isLoaded)
                .opacity(isLoaded ? 1 : 0.45)

                if let note = WebhookEventFilter.retiredTypeNote(for: filter) {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            .task {
                if !isLoaded, isSignedIn { await loadSaved?() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 10))
                Text(L10n.integrations.eventFilter)
                    .font(.system(size: 10))
                // How many chips are selected; nothing until the saved
                // filter is read, since these chips are not it yet.
                if isLoaded, filter.severities.count + filter.types.count > 0 {
                    Text("(\(filter.severities.count + filter.types.count))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
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
