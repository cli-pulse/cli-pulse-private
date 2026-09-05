import Foundation
import Combine

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
///
/// Lives in CLIPulseCore rather than the app target on purpose. It used to sit
/// beside `CLIPulseBarApp`, which has no test bundle, and the v1.45 activation
/// defect (see `reportActivation`) shipped through exactly that gap: nothing
/// could exercise the latch, so `ProviderPublisherSubscribeSemanticsTests` had
/// to re-implement this type's Combine chain and test the copy instead of the
/// original. Both duplications are gone now — `AnonymousTelemetryCoordinatorTests`
/// drives this class directly.
@MainActor
public final class AnonymousTelemetryCoordinator {
    /// Set once from `CLIPulseBarApp.init`. The disclosure card needs to reach
    /// this after the user acknowledges it, and it lives several levels down
    /// inside a lazily-built `MenuBarExtra` — threading it through as an
    /// environment object would mean making a non-observable controller
    /// observable purely for delivery. Matches `PetPanelController.shared` and
    /// `BookmarkManager.shared`. Stays nil when telemetry is not permitted, so
    /// the card's callback is a no-op on a QA build rather than a special case.
    public static private(set) var shared: AnonymousTelemetryCoordinator?

    private let telemetry: AnonymousInstallTelemetry
    private var cancellables: Set<AnyCancellable> = []
    private var activationSent = false
    private var helperConnectedSent = false
    private var costSent = false
    /// In-process guards so a busy link does not queue one task per frame.
    /// The durable latch is the store's; these only stop repeat work.
    private var remoteTransportSent: Set<String> = []
    private var remoteDelegateSent = false
    private var remoteNonClaudeSent = false

    /// Returns nil when the runtime forbids telemetry. Same `allowsTelemetry`
    /// capability that gates Sentry, so a QA or quarantine build is silent for
    /// exactly one reason in exactly one place. It also means a build that
    /// cannot be identified falls into quarantine and sends nothing, which is
    /// the correct failure direction.
    public init?(runtimeEnvironment: CLIPulseRuntimeEnvironment) {
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

    /// Test seam. The production initializer reaches for `Bundle.main`, the real
    /// UserDefaults and the live Supabase transport, none of which a test may
    /// touch — but the thing worth testing is the latch in `reportActivation`,
    /// which does not care where the telemetry came from.
    init(telemetry: AnonymousInstallTelemetry) {
        self.telemetry = telemetry
    }

    /// Called at launch and again when the disclosure card is dismissed.
    ///
    /// At launch this is usually a no-op on a genuinely first run: nothing may
    /// be sent before the card has been seen, and the card lives in the menu,
    /// which the user has not opened yet. Calling it anyway is what makes every
    /// LATER launch settle the install, including one that was previously lost
    /// to a missing network.
    public func start(observing providerState: ProviderState) {
        Self.shared = self
        Task { await telemetry.recordInstallIfNeeded() }

        providerState.$providers
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
            .store(in: &cancellables)
    }

    /// Step 4 of the funnel: the app has a number to show.
    ///
    /// Subscribed rather than hooked to a view, for the same reason as
    /// activation — `MenuBarExtra` builds its content lazily, so a signal
    /// taken from a view would measure menu-opening instead of the event.
    public func observeCost(appState: AppState) {
        appState.$dashboard
            .map { ($0?.total_estimated_cost_today ?? 0) > 0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasCost in
                guard hasCost else { return }
                self?.reportFirstCost()
            }
            .store(in: &cancellables)
    }

#if os(macOS)
    /// Step 2 of the funnel: the local helper answered.
    ///
    /// macOS-only because `HelperInstaller` is — it is the UDS handshake, and
    /// there is no local helper on iOS or watchOS. Kept as a separate
    /// subscription from `observeCost` because the two come from different
    /// owners, and folding them into one publisher would make either source's
    /// silence look like the other's.
    ///
    /// The `#if` is load-bearing, not tidiness: CLIPulseCore compiles for
    /// macOS, iOS and watchOS, and `swift test` on a Mac only ever builds the
    /// first. CI's five-scheme matrix caught the unguarded version.
    public func observeHelper(helperInstaller: HelperInstaller) {
        helperInstaller.$state
            .map(Self.isHelperConnected)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard connected else { return }
                self?.reportHelperConnected()
            }
            .store(in: &cancellables)
    }

    /// An OBSERVED round trip, not a registration claim.
    ///
    /// Both of these states are only reachable after the helper answered a
    /// `hello` over the socket and named its version. `.registered` from
    /// `HelperLifecycleManager` would have been the easy signal and the wrong
    /// one: it means launchd accepted the plist, which is true in every one of
    /// the failure modes this milestone exists to separate.
    static func isHelperConnected(_ state: HelperInstaller.State) -> Bool {
        switch state {
        case .running, .bundled:
            return true
        case .checking, .notInstalled, .unreachable, .downloading,
             .installing, .updateAvailable, .error:
            return false
        }
    }
#endif

    /// The disclosure has been acknowledged, so the install can go out now
    /// rather than on the next launch — and if a provider was already found
    /// while the card was up, that counts too.
    // MARK: - Remote control (plan §8)
    //
    // Called from `LANLinkAgent`, which is the only place that knows these
    // facts: it sees which address class a phone arrived on and what the
    // sessions it drives are. Each is a once-ever latch; the coordinator is
    // nil on a build that may not send, so these are no-ops there.

    public func remoteTransportUsed(_ kind: LANDirectAddress.Kind) {
        let key = kind == .tailnet ? "tailnet" : "lan"
        guard !remoteTransportSent.contains(key) else { return }
        remoteTransportSent.insert(key)
        Task { [telemetry] in await telemetry.recordRemoteTransportIfNeeded(kind) }
    }

    public func remoteDelegateRequested() {
        guard !remoteDelegateSent else { return }
        remoteDelegateSent = true
        Task { [telemetry] in await telemetry.recordRemoteDelegateIfNeeded() }
    }

    public func remoteNonClaudeDriven() {
        guard !remoteNonClaudeSent else { return }
        remoteNonClaudeSent = true
        Task { [telemetry] in await telemetry.recordRemoteNonClaudeIfNeeded() }
    }

    public func disclosureAcknowledged(providerState: ProviderState) {
        Task { await telemetry.recordInstallIfNeeded() }
        if !providerState.providers.isEmpty {
            reportActivation()
        }
    }

    private func reportHelperConnected() {
        guard !helperConnectedSent else { return }
        let telemetry = self.telemetry
        Task { @MainActor [weak self] in
            guard await telemetry.recordHelperConnectedIfNeeded() else { return }
            self?.helperConnectedSent = true
        }
    }

    private func reportFirstCost() {
        guard !costSent else { return }
        let telemetry = self.telemetry
        Task { @MainActor [weak self] in
            guard await telemetry.recordFirstCostIfNeeded() else { return }
            self?.costSent = true
        }
    }

    private func reportActivation() {
        // Cheap in-process cache so a provider list that churns does not queue
        // a task per change. The durable "only once ever" guarantee is the
        // persisted flag inside AnonymousInstallTelemetry; this only avoids
        // pointless work within a single run.
        //
        // It is set from the RESULT, never from the attempt. Setting it up
        // front is what broke v1.45: on a first launch the sink runs before the
        // disclosure card has been acknowledged, `maySend` is false, nothing is
        // sent — and a latch set on entry would then make the "Got it" callback
        // below a no-op, losing activation for the entire launch on which the
        // card is shown. Cache the outcome and a refusal stays retryable.
        guard !activationSent else { return }
        let telemetry = self.telemetry
        Task { @MainActor [weak self] in
            guard await telemetry.recordFirstProviderDetectedIfNeeded() else { return }
            self?.activationSent = true
        }
    }
}
