import Foundation

/// Provider onboarding is deliberately set-driven: adding a fourth provider
/// cannot fall through a boolean tuple and silently inherit another runtime's
/// copy.
public enum ProviderOnboardingState: Sendable, Equatable {
    case none
    case single(Provider)
    case multiple(Set<Provider>)
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
        switch providers.count {
        case 0: return .none
        case 1: return .single(providers.first!)
        default: return .multiple(providers)
        }
    }

    var onboardingCopy: ProviderOnboardingCopy {
        let present = Provider.allCases.filter(providers.contains)
        let missing = Provider.allCases.filter { !providers.contains($0) }
        switch onboardingState {
        case .none:
            return ProviderOnboardingCopy(
                headline: "Waiting for your first coding session",
                detail: "Trifola reads local Claude Code transcripts, Codex rollouts, and Grok Build sessions. Start any provider and its sessions will appear automatically; nothing leaves this Mac.")
        case .single(let provider):
            return ProviderOnboardingCopy(
                headline: "\(Self.onboardingLabel(provider)) sessions are ready",
                detail: "Your local \(Self.onboardingLabel(provider)) corpus is available. \(Self.providerList(missing)) sessions will join the same read-only view automatically when present.")
        case .multiple:
            let labels = Self.providerList(present)
            let detail = missing.isEmpty
                ? "All local corpora are available in one read-only view; nothing leaves this Mac."
                : "These local corpora are available in one read-only view. \(Self.providerList(missing)) sessions will join automatically when present."
            return ProviderOnboardingCopy(
                headline: "\(labels) are ready",
                detail: detail)
        }
    }

    private static func providerList(_ providers: [Provider]) -> String {
        let labels = providers.map(Self.onboardingLabel)
        switch labels.count {
        case 0: return "Other provider"
        case 1: return labels[0]
        case 2: return labels.joined(separator: " and ")
        default: return labels.dropLast().joined(separator: ", ")
            + ", and " + labels.last!
        }
    }

    private static func onboardingLabel(_ provider: Provider) -> String {
        provider == .claude ? "Claude Code" : provider.label
    }
}
