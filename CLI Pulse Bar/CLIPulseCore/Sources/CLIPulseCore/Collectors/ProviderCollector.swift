#if os(macOS)
import Foundation

/// Result classification for collector output.
/// Distinguishes real quota data from credit-based or status-only results.
public enum CollectorDataKind: Sendable {
    /// Real quota/tier with remaining count and reset time (e.g. Codex, Gemini, Claude)
    case quota
    /// Credit-based balance (e.g. OpenRouter — dollar credits, not request counts)
    case credits
    /// Local status only, no quota model (e.g. Ollama — models listed, running/not)
    case statusOnly
}

/// Output from a single provider collector run.
public struct CollectorResult: Sendable {
    public let usage: ProviderUsage
    public let dataKind: CollectorDataKind

    public init(usage: ProviderUsage, dataKind: CollectorDataKind) {
        self.usage = usage
        self.dataKind = dataKind
    }
}

/// A collector result tied to the exact configured provider account that
/// produced it. Collectors remain provider-focused; the scheduler attaches
/// account identity so the 50+ collector implementations do not need to
/// duplicate multi-account plumbing.
public struct AccountScopedCollectorResult: Sendable {
    public let accountID: UUID
    public let config: ProviderConfig
    public let result: CollectorResult

    public init(accountID: UUID, config: ProviderConfig, result: CollectorResult) {
        self.accountID = accountID
        self.config = config
        self.result = result
    }
}

struct ProviderCollectorInvocation: Sendable {
    let config: ProviderConfig
    let collector: any ProviderCollector
}

/// Protocol for provider-native local data collectors.
///
/// Each collector fetches real usage/quota/credit data from a single provider
/// using local credentials (API keys, OAuth tokens, local files, etc.).
/// Collectors run on macOS only and are `#if os(macOS)` gated.
public protocol ProviderCollector: Sendable {
    /// Which provider this collector serves.
    var kind: ProviderKind { get }

    /// Whether this collector can run given the current config.
    /// Return false if required credentials are missing.
    func isAvailable(config: ProviderConfig) -> Bool

    /// Fetch real provider data. Throws on network/parse errors.
    func collect(config: ProviderConfig) async throws -> CollectorResult
}

/// Registry of all available local collectors.
public enum CollectorRegistry {
    public static let collectors: [ProviderCollector] = [
        OpenRouterCollector(),
        CodexCollector(),
        GeminiCollector(),
        ClaudeCollector(),
        JetBrainsAICollector(),
        OllamaCollector(),
        WarpCollector(),
        ZaiCollector(),
        KimiK2Collector(),
        KiloCollector(),
        CopilotCollector(),
        CursorCollector(),
        KimiCollector(),
        AlibabaCollector(),
        MiniMaxCollector(),
        AugmentCollector(),
        VolcanoEngineCollector(),
        GLMCollector(),
        PerplexityCollector(),
        VertexAICollector(),
        CrofCollector(),
        DeepSeekCollector(),
        ElevenLabsCollector(),
        VeniceCollector(),
        AzureOpenAICollector(),
        CodebuffCollector(),
        DeepgramCollector(),
        ManusCollector(),
        AbacusCollector(),
        MistralCollector(),
        CommandCodeCollector(),
        GroqCollector(),
        MoonshotCollector(),
        LLMProxyCollector(),
        OpenAIAdminCollector(),
        StepFunCollector(),
        T3ChatCollector(),
        MiMoCollector(),
        BedrockCollector(),
        AlibabaTokenPlanCollector(),
        WindsurfCollector(),
        OpenCodeGoCollector(),
        GrokCollector(),
        PoeCollector(),
        CrossModelCollector(),
        ChutesCollector(),
        QoderCollector(),
        SakanaCollector(),
        ZedCollector(),
    ]

    /// Returns the collector for a given provider, if one exists and is available.
    public static func collector(for kind: ProviderKind, config: ProviderConfig) -> ProviderCollector? {
        collectors.first { $0.kind == kind && $0.isAvailable(config: config) }
    }
}
#endif
