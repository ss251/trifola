import Foundation

/// The complete provider-presence state used by first-run and empty-state copy.
/// Keeping this pure prevents a Codex-only corpus from inheriting Claude-only
/// assumptions in whichever UI surface presents it.
public enum ProviderOnboardingState: Sendable, Equatable {
    case none
    case claudeOnly
    case codexOnly
    case both
}

public struct ProviderOnboardingCopy: Sendable, Equatable {
    public let headline: String
    public let detail: String

    public init(headline: String, detail: String) {
        self.headline = headline
        self.detail = detail
    }
}

public extension ProviderCorpusPresence {
    var onboardingState: ProviderOnboardingState {
        switch (hasClaude, hasCodex) {
        case (false, false): return .none
        case (true, false): return .claudeOnly
        case (false, true): return .codexOnly
        case (true, true): return .both
        }
    }

    var onboardingCopy: ProviderOnboardingCopy {
        switch onboardingState {
        case .none:
            return ProviderOnboardingCopy(
                headline: "Waiting for your first coding session",
                detail: "Trifola reads local Claude Code transcripts and Codex rollouts. Start either provider and its sessions will appear automatically; nothing leaves this Mac.")
        case .claudeOnly:
            return ProviderOnboardingCopy(
                headline: "Claude Code sessions are ready",
                detail: "Your local Claude Code corpus is available. Codex rollouts will join the same read-only view automatically when present.")
        case .codexOnly:
            return ProviderOnboardingCopy(
                headline: "Codex sessions are ready",
                detail: "Your local Codex rollouts are available. Claude Code sessions will join the same read-only view automatically when present.")
        case .both:
            return ProviderOnboardingCopy(
                headline: "Claude Code and Codex are ready",
                detail: "Both local corpora are available in one read-only view; nothing leaves this Mac.")
        }
    }
}
