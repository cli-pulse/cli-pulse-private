#if os(macOS)
import Foundation
import ServiceManagement

/// Restarts the background-sync LoginItem once after each app update.
///
/// macOS does not restart a LoginItem when its app updates in place, so the
/// helper that keeps running is the one from before the update until the next
/// logout or reboot. A helper from before 1.55 honours no local-scan answer at
/// all: without this, a "Not now" did nothing on an updated Mac until then.
/// The same holds for any later change to what the helper does, which is why
/// this is keyed on the build rather than on 1.55.
///
/// A restart is `unregister()` and then `register()`, as the Developer ID
/// agent's repair does (`HelperLifecycleManager.reconcileBundledAgent`). If the
/// register half fails, background sync would be left off with nothing to say
/// it was the app, not the user, who turned it off; so the build is written
/// down as pending before the unregister, and a launch that finds it pending
/// with the LoginItem off registers it again.
public enum HelperLoginItemRestart {
    public static let identifier = "yyh.CLI-Pulse.helper"

    /// The build the LoginItem was last restarted for, in the app's standard
    /// defaults. `cli_pulse_` like every key kept there
    /// (`UnsandboxedDataMigration.appOwnedKeyPrefixes`).
    public static let restartedForBuildKey = "cli_pulse_helper_login_item_restarted_for_build"
    /// Set from just before the unregister until the register succeeds.
    public static let pendingBuildKey = "cli_pulse_helper_login_item_restart_pending_build"

    public enum Action: Equatable, Sendable {
        case none
        /// The LoginItem is on and has not been restarted for this build.
        case restart
        /// A restart was interrupted between its two halves: the app turned
        /// the LoginItem off, and must turn it back on.
        case reRegister
    }

    public static func action(
        isEnabled: Bool,
        currentBuild: String?,
        restartedForBuild: String?,
        pendingBuild: String?
    ) -> Action {
        if pendingBuild != nil, !isEnabled { return .reRegister }
        guard isEnabled, let currentBuild else { return .none }
        return restartedForBuild == currentBuild ? .none : .restart
    }

    public enum Outcome: Equatable, Sendable {
        case notNeeded
        case restarted
        case reRegistered
        case failed
    }

    /// The system calls, injectable for tests.
    public struct Service {
        public let isEnabled: () -> Bool
        public let unregister: () async throws -> Void
        public let register: () throws -> Void

        public init(
            isEnabled: @escaping () -> Bool,
            unregister: @escaping () async throws -> Void,
            register: @escaping () throws -> Void
        ) {
            self.isEnabled = isEnabled
            self.unregister = unregister
            self.register = register
        }

        public static var live: Service {
            Service(
                isEnabled: { SMAppService.loginItem(identifier: identifier).status == .enabled },
                unregister: { try await SMAppService.loginItem(identifier: identifier).unregister() },
                register: { try SMAppService.loginItem(identifier: identifier).register() }
            )
        }
    }

    /// Call once per launch, only in a runtime that registers the helper.
    @discardableResult
    public static func runIfNeeded(
        service: Service,
        defaults: UserDefaults,
        currentBuild: String?
    ) async -> Outcome {
        switch action(
            isEnabled: service.isEnabled(),
            currentBuild: currentBuild,
            restartedForBuild: defaults.string(forKey: restartedForBuildKey),
            pendingBuild: defaults.string(forKey: pendingBuildKey)
        ) {
        case .none:
            // A pending mark left by a restart that did complete.
            defaults.removeObject(forKey: pendingBuildKey)
            return .notNeeded
        case .reRegister:
            guard (try? service.register()) != nil else { return .failed }
            finish(defaults: defaults, currentBuild: currentBuild)
            return .reRegistered
        case .restart:
            defaults.set(currentBuild, forKey: pendingBuildKey)
            // Ignore an unregister failure: the register below is what
            // starts the current binary, and a job launchd has already
            // dropped throws here too.
            try? await service.unregister()
            guard (try? service.register()) != nil else { return .failed }
            finish(defaults: defaults, currentBuild: currentBuild)
            return .restarted
        }
    }

    private static func finish(defaults: UserDefaults, currentBuild: String?) {
        defaults.set(currentBuild, forKey: restartedForBuildKey)
        defaults.removeObject(forKey: pendingBuildKey)
    }
}
#endif
