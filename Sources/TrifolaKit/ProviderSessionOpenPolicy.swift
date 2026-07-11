/// Provider boundary for session handoff.
///
/// Trifola's live registry is a Claude Code registry. Until a Codex-native
/// resolver exists, treating a Codex thread ID as a Claude session ID could
/// activate an unrelated terminal. Keep that trust decision pure and shared by
/// every app entry point.
public enum ProviderSessionOpenRoute: Sendable, Equatable {
    case claudeRegistry
    case transcript
}

public enum ProviderSessionOpenPolicy {
    public static func route(
        provider: Provider,
        isRemote: Bool
    ) -> ProviderSessionOpenRoute {
        guard !isRemote, provider == .claude else { return .transcript }
        return .claudeRegistry
    }
}
