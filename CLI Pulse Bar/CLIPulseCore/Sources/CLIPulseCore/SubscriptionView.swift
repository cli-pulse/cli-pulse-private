import SwiftUI
import StoreKit

public struct SubscriptionView: View {
    @ObservedObject private var manager: SubscriptionManager
    @State private var isYearly = true
    @State private var purchaseError: String?
    @State private var isPurchasing = false

    public init(manager: SubscriptionManager = .shared) {
        self._manager = ObservedObject(wrappedValue: manager)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                currentPlanSection
                billingToggle
                planCards
                restoreSection

                if let error = purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding()
        }
        #if os(iOS)
        .navigationTitle(L10n.subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 36))
                .foregroundStyle(PulseTheme.accent)

            Text(L10n.subscription.proTitle)
                .font(.title2.bold())

            Text(L10n.subscription.unlock)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Current Plan

    private var currentPlanSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.settings.currentPlan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(manager.tierName(for: manager.currentTier))
                        .font(.headline)
                    SubscriptionBadge(tier: manager.currentTier)
                }
                // v1.52 — a Developer ID / Homebrew install is granted Pro by
                // the channel, not by a purchase, and until now the app never
                // said so. Those users could not tell a gift from something
                // they had bought.
                if manager.isChannelGrantedPro {
                    Text(L10n.subscription.channelGrant)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding()
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Billing Toggle

    private var billingToggle: some View {
        Picker(L10n.subscription.billing, selection: $isYearly) {
            Text(L10n.subscription.monthly).tag(false)
            Text(L10n.subscription.yearlySave).tag(true)
        }
        #if os(watchOS)
        .pickerStyle(.wheel)
        #else
        .pickerStyle(.segmented)
        #endif
    }

    // MARK: - Plan Cards

    private var planCards: some View {
        VStack(spacing: 12) {
            // v1.51 — every bullet below names a benefit that some code
            // actually withholds from free. See
            // `scripts/check_paywall_claims.sh`, which fails CI if a bullet
            // appears here without a registered enforcement site.
            //
            // Five bullets were removed here because nothing implemented
            // them: priority_alerts, cost_analytics, shared_alerts,
            // admin_controls, team_dashboards. Three more were removed
            // because the limit they name is not enforced anywhere:
            // up_to_5_devices / unlimited_devices (every tier can pair 20 —
            // `migrate_v0.36_desktop_otp.sql:66`) and data_retention_90 /
            // data_retention_365 (the nightly cleanup is tier-blind and
            // reads `user_settings.data_retention_days`, which defaults to 7
            // for everyone and is never written from the tier —
            // `migrate_v0.21_cleanup_cron.sql:41`).
            planCard(
                name: L10n.subscription.pro,
                tier: .pro,
                product: isYearly ? manager.proYearly : manager.proMonthly,
                features: [
                    L10n.subscription.unlimitedProviders,
                    L10n.subscription.homeScreenWidgets
                ],
                color: PulseTheme.accent,
                isPopular: true
            )

            // v1.52 — the Team card is GONE, not merely honest.
            //
            // v1.51 reduced it to one bullet ("Everything in Pro") because that
            // was literally all it bought. A production check then showed the
            // tier does not work either: of the eight team RPCs the client
            // calls, only `my_teams` exists in the live database. A Team
            // subscriber pressing "Create Team" gets an error. One team has
            // ever been created, by anyone, ever.
            //
            // Selling a tier with no exclusive benefit that also does not
            // function is the thing this whole workstream exists to stop, so it
            // is withdrawn from sale. Existing Team entitlements are untouched:
            // `scanStoreKitEntitlements` still recognises the Team product IDs.

            // v1.52 — the Lifetime tile is withdrawn from sale.
            //
            // `com.clipulse.pro.lifetime` has been MISSING_METADATA in App
            // Store Connect since v1.14 — no localization, no price point, no
            // review schedule, no review screenshot. StoreKit omits it from
            // every response, so for 37 versions this rendered a dead "Not
            // Available" button on the largest single payment in the app, and
            // nobody noticed. The one purchase this product has ever recorded
            // was a monthly subscription, so there is no evidence of demand for
            // a one-time price either.
            //
            // Anyone who somehow already owns it keeps it: `isLifetime` and the
            // entitlement scan are unchanged.
        }
    }


    private func planCard(
        name: String,
        tier: SubscriptionTier,
        product: Product?,
        features: [String],
        color: Color,
        isPopular: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(name)
                    .font(.title3.bold())
                if isPopular {
                    Text(L10n.subscription.popular)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.2))
                        .foregroundStyle(color)
                        .clipShape(Capsule())
                }
                Spacer()
                if let product {
                    VStack(alignment: .trailing) {
                        Text(product.displayPrice)
                            .font(.title3.bold())
                        Text(isYearly ? L10n.subscription.perYear : L10n.subscription.perMonth)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("--")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(features, id: \.self) { feature in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(color)
                        Text(feature)
                            .font(.subheadline)
                    }
                }
            }

            if manager.currentTier == tier {
                Text(L10n.settings.currentPlan)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(color.opacity(0.15))
                    .foregroundStyle(color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let product {
                Button {
                    Task { await purchaseProduct(product) }
                } label: {
                    HStack {
                        if isPurchasing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(manager.currentTier == .free ? "\(L10n.subscription.upgradePro)" : "\(L10n.subscription.switchPro)")
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(color)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isPurchasing)
            } else {
                Text(L10n.subscription.notAvailable)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.15))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(manager.currentTier == tier ? color : Color.clear, lineWidth: 2)
        )
    }

    // MARK: - Restore

    private var restoreSection: some View {
        VStack(spacing: 12) {
            Button {
                Task { await manager.restorePurchases() }
            } label: {
                Text(L10n.subscription.restore)
                    .font(.subheadline)
                    .foregroundStyle(PulseTheme.accent)
            }
            .buttonStyle(.plain)

            legalLinks
        }
        .padding(.top, 4)
    }

    // MARK: - Legal Links

    private var legalLinks: some View {
        HStack(spacing: 16) {
            Link(L10n.settings.privacyPolicy, destination: URL(string: "https://cli-pulse.github.io/cli-pulse/privacy.html")!)
            Text("·")
                .foregroundStyle(.tertiary)
            Link(L10n.settings.termsOfUse, destination: URL(string: "https://cli-pulse.github.io/cli-pulse/terms.html")!)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Purchase

    private func purchaseProduct(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil
        do {
            _ = try await manager.purchase(product)
        } catch {
            purchaseError = error.localizedDescription
        }
        isPurchasing = false
    }
}
