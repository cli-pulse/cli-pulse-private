/// Runs a live provider action only for a runtime that is allowed to inspect
/// local credentials, browser state, CLI state, or provider networks.
public enum RuntimeProtectedProviderAction {
    public static func perform<T>(
        runtimeEnvironment: CLIPulseRuntimeEnvironment,
        action: () async throws -> T
    ) async rethrows -> T? {
        guard runtimeEnvironment.capabilities.allowsLiveCollection else {
            return nil
        }
        return try await action()
    }
}
