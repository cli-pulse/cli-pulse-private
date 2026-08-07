import Foundation
import Combine
import CLIPulseCore

/// Owns the anonymous install telemetry for the app's lifetime and decides
/// *when* the two events fire. `AnonymousInstallTelemetry` decides *whether*.
///
/// Two events, and each is reported once ever:
///
///   install                  first launch
///   first_provider_detected  the first time a provider actually appears
///
/// The second one is subscribed rather than polled, and deliberately watches
/// `ProviderState.$providers` rather than anything in the UI. `MenuBarExtra`
/// builds its content lazily — a menu bar app has no window at launch — so a
/// hook in a view would fire only when the user happens to open the menu, and
/// "first value" would end up measuring menu-opening instead.
@MainActor
final class AnonymousTelemetryCoordinator {
    /// Set once from `CLIPulseBarApp.init`. The disclosure card needs to reach
    /// this after the user acknowledges it, and it lives several levels down
    /// inside a lazily-built `MenuBarExtra` — threading it through as an
    /// environment object would mean making a non-observable controller
    /// observable purely for delivery. Matches `PetPanelController.shared` and
    /// `BookmarkManager.shared`. Stays nil when telemetry is not permitted, so
    /// the card's callback is a no-op on a QA build rather than a special case.
    static private(set) var shared: AnonymousTelemetryCoordinator?

    private let telemetry: AnonymousInstallTelemetry
    private var cancellable: AnyCancellable?
    private var activationSent = false

    /// Returns nil when the runtime forbids telemetry. Same `allowsTelemetry`
    /// capability that gates Sentry, so a QA or quarantine build is silent for
    /// exactly one reason in exactly one place. It also means a build that
    /// cannot be identified falls into quarantine and sends nothing, which is
    /// the correct failure direction.
    init?(runtimeEnvironment: CLIPulseRuntimeEnvironment) {
        guard runtimeEnvironment.capabilities.allowsTelemetry else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        telemetry = AnonymousInstallTelemetry(
            store: UserDefaultsAnonymousTelemetryStore(),
            transport: SupabaseAnonymousTelemetryTransport(runtimeEnvironment: runtimeEnvironment),
            channel: DistributionChannel.detectCurrent(),
            rawAppVersion: info["CFBundleShortVersionString"] as? String ?? "",
            osMajor: version.majorVersion,
            osMinor: version.minorVersion
        )
    }

    /// Called at launch and again when the disclosure card is dismissed.
    ///
    /// At launch this is usually a no-op on a genuinely first run: nothing may
    /// be sent before the card has been seen, and the card lives in the menu,
    /// which the user has not opened yet. Calling it anyway is what makes every
    /// LATER launch settle the install, including one that was previously lost
    /// to a missing network.
    func start(observing providerState: ProviderState) {
        Self.shared = self
        Task { await telemetry.recordInstallIfNeeded() }

        cancellable = providerState.$providers
            .map { !$0.isEmpty }
            .removeDuplicates()
            // `reportActivation` is MainActor-isolated, and this type is too, so
            // the closure inherits that isolation — but Combine delivers on
            // whatever thread mutated the @Published value, and provider lists
            // are assigned from refresh work that does not promise to be on the
            // main thread. Under Swift 5 language mode that mismatch is
            // unchecked: it would not fail to compile, it would just be a data
            // race nobody sees until it corrupts something. Hopping explicitly
            // costs one dispatch per transition (at most two per launch).
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasProviders in
                guard hasProviders else { return }
                self?.reportActivation()
            }
    }

    /// The disclosure has been acknowledged, so the install can go out now
    /// rather than on the next launch — and if a provider was already found
    /// while the card was up, that counts too.
    func disclosureAcknowledged(providerState: ProviderState) {
        Task { await telemetry.recordInstallIfNeeded() }
        if !providerState.providers.isEmpty {
            reportActivation()
        }
    }

    private func reportActivation() {
        // Cheap in-process guard so a provider list that churns does not queue
        // a task per change. The durable "only once ever" guarantee is the
        // persisted flag inside AnonymousInstallTelemetry; this only avoids
        // pointless work within a single run.
        guard !activationSent else { return }
        activationSent = true
        Task { await telemetry.recordFirstProviderDetectedIfNeeded() }
    }
}
