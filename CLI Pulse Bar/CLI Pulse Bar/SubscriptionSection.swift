import SwiftUI
import StoreKit
import CLIPulseCore

/// v1.10 P2-2 slice 3: extracted from SettingsTab.swift (pre-extraction
/// `subscriptionSection` + `inlineIAPCards` + `inlineProductRow` + `iapError`
/// state). Shows current plan, quotas, Manage button for Pro/Team, or inline
/// IAP purchase cards for free-tier users.
struct SubscriptionSection: View {
    @EnvironmentObject var state: AppState
    /// v1.10 P2-3 slice 2: observe SubscriptionManager directly instead of
    /// relying on AppState's old `subscriptionCancellable.sink` forwarder.
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.openWindow) private var openWindow
    @State private var iapError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.settings.subscription, icon: "creditcard")

            HStack {
                Text(L10n.settings.currentPlan)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                SubscriptionBadge(tier: subscriptionManager.currentTier)
            }

            // Diagnostic line — only renders when the tier hasn't been
            // confirmed yet (cold launch race) or the most recent
            // refresh fell into the degraded path (server / receipt
            // validator failed). PR #18 follow-up: pre-fix, a Pro user
            // who hit a transient receipt-validator hiccup got a
            // confirmed-free verdict + a "free plan limits" banner.
            // Showing the resolution state here gives the user (and
            // future debugging) a way to see *why* the badge says what
            // it says without digging through Xcode logs.
            if subscriptionManager.tierResolutionState != .resolvedConfirmed {
                tierResolutionDiagnostic
            }

            // v1.51 — renders only when the store did not hand us everything
            // the app asks for. Silent in the healthy case.
            productLoadDiagnostic

            HStack {
                Text(L10n.settings.providers)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(subscriptionManager.maxProviders < 0 ? "Unlimited" : "\(subscriptionManager.maxProviders)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // v1.51 — "Devices" and "Data retention" rows removed here for the
            // same reason as `iOSSettingsTab`: `maxDevices` (2/5/∞) and
            // `dataRetentionDays` (7/90/365) are printed numbers with no
            // mechanism behind them, and the retention one was actively
            // misleading paying users (server deletes at 7 days regardless).

            if subscriptionManager.isProOrAbove {
                Button {
                    openWindow(id: "subscription")
                } label: {
                    Label(L10n.settings.manageSubscription, systemImage: "gear")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            } else {
                if subscriptionManager.products.isEmpty {
                    if subscriptionManager.isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(L10n.subscription.loadingPlans)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L10n.subscription.unavailable)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await subscriptionManager.loadProducts() }
                        } label: {
                            Text(L10n.subscription.retry)
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(PulseTheme.accent)
                    }
                } else {
                    inlineIAPCards
                }

                if let iapError {
                    Text(iapError)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }

                Button {
                    openWindow(id: "subscription")
                } label: {
                    Text(L10n.subscription.viewAllPlans)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            }
        }
    }

    /// One-line diagnostic shown when the tier hasn't been confirmed
    /// (init race) or the last refresh degraded (server / validator
    /// fail). Stays grey + small so it doesn't compete with the
    /// SubscriptionBadge above. No PII — just internal category
    /// strings (`no-api-client`, `server-tier-error`, etc.).
    @ViewBuilder
    private var tierResolutionDiagnostic: some View {
        HStack(spacing: 4) {
            Image(systemName: subscriptionManager.tierResolutionState == .unresolved
                  ? "hourglass" : "exclamationmark.triangle")
                .font(.system(size: 9))
            Text(tierResolutionDiagnosticText())
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            // User-initiated retry — no automatic AppStore.sync to
            // avoid surprising store interactions on cold launch.
            if subscriptionManager.tierResolutionState == .resolvedDegraded {
                Button {
                    Task { await subscriptionManager.updateCurrentEntitlements() }
                } label: {
                    Text("Retry")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func tierResolutionDiagnosticText() -> String {
        switch subscriptionManager.tierResolutionState {
        case .unresolved:
            return "Tier check in progress…"
        case .resolvedDegraded:
            let category = subscriptionManager.lastTierRefreshError?.rawValue ?? "unknown"
            return "Tier check incomplete (\(category)). Showing best-effort plan."
        case .resolvedConfirmed:
            return ""
        }
    }

    /// v1.51 — surfaces what the last `loadProducts()` actually did.
    ///
    /// Until now a store failure and "no plans configured" both rendered as
    /// the same silent empty list, so "the buy button is broken" could never
    /// be ruled in or out — it stayed a live explanation for every conversion
    /// number the product has produced. This is the smallest change that lets
    /// someone smoke-test the purchase path and get an answer.
    ///
    /// Strictly local. No network call, no telemetry, no new data collection —
    /// deliberately, since behavioural funnel measurement is Analytics-purpose
    /// and needs an App Store privacy-label change first.
    @ViewBuilder
    private var productLoadDiagnostic: some View {
        if let label = subscriptionManager.lastProductLoadOutcome.diagnosticLabel {
            HStack(spacing: 4) {
                Image(systemName: "cart.badge.questionmark")
                    .font(.system(size: 9))
                Text("Store: \(label)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    Task { await subscriptionManager.loadProducts() }
                } label: {
                    Text(L10n.subscription.retry)
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PulseTheme.accent)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var inlineIAPCards: some View {
        VStack(spacing: 6) {
            // v1.51 — this is the SECOND paywall surface, and it carried the
            // same fictions as the first in hardcoded English: "5 devices" for
            // a limit nothing enforces, and "team features" for RPCs that are
            // not deployed to production. `check_paywall_claims.sh` now reads
            // this file too, so the strings below must stay backed.
            if let pro = subscriptionManager.proMonthly {
                inlineProductRow(product: pro, label: "Pro Monthly", features: L10n.subscription.unlimitedProviders)
            }
            if let proY = subscriptionManager.proYearly {
                inlineProductRow(product: proY, label: "Pro Yearly", features: "Save 17%")
            }
            // v1.52 — Team rows removed. The tier is withdrawn from sale:
            // it has no exclusive benefit (TeamView gates on isProOrAbove) and
            // does not function (7 of its 8 RPCs are absent from production).
            // Existing Team entitlements still resolve; see
            // `SubscriptionManager.allProductIDs`.
            // v1.52 — Lifetime row removed. `com.clipulse.pro.lifetime` has
            // been MISSING_METADATA in App Store Connect since v1.14, so
            // StoreKit never returned it and this row never rendered anyway.
            // Withdrawn from sale rather than left as a permanent no-op.
        }
    }

    private func inlineProductRow(product: Product, label: String, features: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                Text(features)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task {
                    iapError = nil
                    do {
                        _ = try await subscriptionManager.purchase(product)
                    } catch {
                        iapError = error.localizedDescription
                    }
                }
            } label: {
                Text(product.displayPrice)
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .controlSize(.small)
        }
        .padding(6)
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
