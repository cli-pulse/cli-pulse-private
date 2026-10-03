import SwiftUI
import CLIPulseCore

struct iOSMainView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var alertState: AlertState
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            if !SupabaseConstants.isConfigured {
                configurationErrorBanner
            }
            Group {
                if !authState.isAuthenticated {
                    iOSLoginView()
                        .environmentObject(state)
                        .environmentObject(authState)
                        .environmentObject(alertState)
                        .environmentObject(providerState)
                } else if horizontalSizeClass == .regular {
                    iPadSplitView()
                        .environmentObject(state)
                        .environmentObject(authState)
                        .environmentObject(alertState)
                        .environmentObject(providerState)
                } else {
                    iPhoneTabView
                }
            }
        }
        .preferredColorScheme(state.appearanceMode)
        // iter8 hotfix: do NOT call requestNotificationPermission() here.
        // The previous unconditional .task fired BEFORE sign-in could
        // complete, which made syncPushToken hit the server without a JWT
        // and surface "Failed to register for push notifications: Session
        // expired" right on the login screen. The permission prompt is
        // now triggered at the right product moments instead:
        //   1. setRemoteControlEnabled(true) — the user explicitly opts in
        //   2. refreshYieldScore — when a returning user signs in and the
        //      server reports remote_control_enabled = true
        // Both gate on `isAuthenticated`, so the system permission alert
        // never appears on the login screen.
    }

    // v1.10 P3-6: persistent banner shown when `SUPABASE_ANON_KEY` is missing
    // at launch. Release builds silently fell through to an empty key,
    // leaving the user with a non-functional app and no hint why.
    private var configurationErrorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.a11y.configurationErrorTitle)
                    .font(.footnote.weight(.semibold))
                Text(L10n.a11y.configurationErrorBody)
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
        // v1.10 P3-3: combine so VoiceOver reads the icon + heading + body
        // as one element, but DON'T override with a hardcoded label —
        // let the actual Text content drive the readout so any future
        // localization/body changes propagate.
        .accessibilityElement(children: .combine)
    }

    private var iPhoneTabView: some View {
        TabView(selection: $state.selectedTab) {
            iOSTabScreen(tab: .overview)
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.overview, systemImage: "gauge.with.dots.needle.33percent")
                }
                .tag(AppState.Tab.overview)

            iOSTabScreen(tab: .providers)
                .environmentObject(state)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.providers, systemImage: "cpu")
                }
                // No count badge: a red badge asks for attention, and the
                // number of providers asks for none (the Alerts tab's does).
                .tag(AppState.Tab.providers)

            iOSTabScreen(tab: .sessions)
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.sessions, systemImage: "terminal")
                }
                .tag(AppState.Tab.sessions)

            iOSTabScreen(tab: .alerts)
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.alerts, systemImage: "bell.badge")
                }
                .badge(alertState.alerts.filter { !$0.is_resolved }.count)
                .tag(AppState.Tab.alerts)

            iOSTabScreen(tab: .settings)
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.settings, systemImage: "gear")
                }
                .tag(AppState.Tab.settings)
        }
        .tint(PulseTheme.accent)
    }
}

// MARK: - One tab's screen

/// The screen for one tab, the same in both layouts: the iPhone's tab bar and
/// the iPad's split view build every tab through this.
///
/// In a DEBUG build each screen also reports itself as showing
/// (`ScreenshotLaunch.ShowsTab`), so the screenshot capture's READY line checks
/// what the layout shows, not only what `state.selectedTab` says. On iPad the
/// two used to differ: the split view kept a selection of its own that started
/// on the Overview and followed `selectedTab` only when it changed, so a
/// capture launch, which sets the tab before the view exists, showed the
/// Overview under every screen's name.
struct iOSTabScreen: View {
    let tab: AppState.Tab

    var body: some View {
        switch tab {
        case .overview, .machine, .pet:
            // Machine (reads the local Mac's helper) and Pet are macOS-only
            // tabs: iOS offers neither in its tab bar or sidebar, so those two
            // arms are unreachable and fall back to the Overview to satisfy the
            // exhaustive switch.
            iOSOverviewTab()
                #if DEBUG
                .modifier(ScreenshotLaunch.ShowsTab(.overview))
                #endif
        case .providers:
            iOSProvidersTab()
                #if DEBUG
                .modifier(ScreenshotLaunch.ShowsTab(.providers))
                #endif
        case .sessions:
            iOSSessionsTab()
                #if DEBUG
                .modifier(ScreenshotLaunch.ShowsTab(.sessions))
                #endif
        case .alerts:
            iOSAlertsTab()
                #if DEBUG
                .modifier(ScreenshotLaunch.ShowsTab(.alerts))
                #endif
        case .settings:
            iOSSettingsTab()
                #if DEBUG
                .modifier(ScreenshotLaunch.ShowsTab(.settings))
                #endif
        }
    }
}

// MARK: - iPad Split View

/// The regular-width layout: a sidebar of the tabs, the selected tab's screen
/// beside it.
///
/// The selection is `state.selectedTab`, the one the iPhone's tab bar,
/// notification taps (iOSAppDelegate), the keyboard shortcuts and the
/// screenshot capture set. Until 1.55 this view kept a copy of its own that
/// started on the Overview and followed `selectedTab` only through
/// `.onChange` (v1.21 D1, for notification taps), which does not fire for the
/// value a view starts with: a launch that set the tab before this view
/// existed, as the screenshot capture does, showed the Overview anyway.
/// ScreenshotLaunchTests holds this view to having no selection of its own.
struct iPadSplitView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var alertState: AlertState
    @EnvironmentObject var providerState: ProviderState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            iOSTabScreen(tab: state.selectedTab)
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(PulseTheme.accent)
        .keyboardShortcut(.init("1"), modifiers: .command)
    }

    private var sidebar: some View {
        List {
            Section(L10n.dashboard.monitor) {
                sidebarButton(.overview)
                // No count badge, as on the iPhone's tab bar: a red badge asks
                // for attention, and the number of providers asks for none.
                // Beside the Alerts badge it read as three provider problems.
                sidebarButton(.providers)
                sidebarButton(.sessions)
            }
            Section(L10n.dashboard.manage) {
                sidebarButton(.alerts, badge: alertState.alerts.filter { !$0.is_resolved }.count)
                sidebarButton(.settings)
            }

            Section(L10n.dashboard.quickStats) {
                if let dash = state.dashboard {
                    HStack {
                        Text(L10n.dashboard.usageToday)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(CostFormatter.formatUsage(dash.total_usage_today))
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                    if state.showCost {
                        HStack {
                            Text(L10n.dashboard.costToday)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(CostFormatter.format(dash.total_estimated_cost_today))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                    HStack {
                        Text(L10n.dashboard.activeSessions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(dash.active_sessions)")
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle("CLI Pulse")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.requestRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(state.isLoading)
                .accessibilityLabel(L10n.common.refresh)
            }
        }
    }

    private func sidebarButton(_ tab: AppState.Tab, badge: Int = 0) -> some View {
        Button {
            state.selectedTab = tab
        } label: {
            HStack {
                Label(tab.label, systemImage: tab.icon)
                    .foregroundStyle(state.selectedTab == tab ? PulseTheme.accent : .primary)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
            }
        }
    }
}
