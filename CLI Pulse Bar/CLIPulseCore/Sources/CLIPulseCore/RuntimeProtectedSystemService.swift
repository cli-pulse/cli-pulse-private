#if os(macOS)
import Foundation

/// Wraps a macOS system service whose status and mutation APIs must never be
/// touched by QA or quarantined runtimes.
public struct RuntimeProtectedSystemService {
    private let runtimeEnvironment: CLIPulseRuntimeEnvironment
    private let readEnabled: () -> Bool
    private let registerAction: () throws -> Void
    private let unregisterAction: () throws -> Void

    public init(
        runtimeEnvironment: CLIPulseRuntimeEnvironment,
        isEnabled: @escaping () -> Bool,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void
    ) {
        self.runtimeEnvironment = runtimeEnvironment
        self.readEnabled = isEnabled
        self.registerAction = register
        self.unregisterAction = unregister
    }

    public var isEnabled: Bool {
        guard runtimeEnvironment.capabilities.allowsHelperRegistration else {
            return false
        }
        return readEnabled()
    }

    /// Returns true only when a system mutation was actually issued.
    @discardableResult
    public func setEnabled(_ desiredEnabled: Bool) throws -> Bool {
        guard runtimeEnvironment.capabilities.allowsHelperRegistration else {
            return false
        }

        let currentEnabled = readEnabled()
        guard currentEnabled != desiredEnabled else { return false }

        if desiredEnabled {
            try registerAction()
        } else {
            try unregisterAction()
        }
        return true
    }
}
#endif
