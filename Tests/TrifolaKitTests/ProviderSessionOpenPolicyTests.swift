import Testing
@testable import TrifolaKit

@Suite("Provider session-open routing")
struct ProviderSessionOpenPolicyTests {
    @Test("only a local Claude session may consult the Claude registry")
    func localClaudeUsesRegistry() {
        #expect(ProviderSessionOpenPolicy.route(
            provider: .claude,
            isRemote: false) == .claudeRegistry)
    }

    @Test("Codex always routes to its read-only transcript")
    func codexNeverUsesClaudeRegistry() {
        #expect(ProviderSessionOpenPolicy.route(
            provider: .codex,
            isRemote: false) == .transcript)
        #expect(ProviderSessionOpenPolicy.route(
            provider: .codex,
            isRemote: true) == .transcript)
    }

    @Test("remote Claude sessions retain their transcript fallback")
    func remoteClaudeUsesTranscript() {
        #expect(ProviderSessionOpenPolicy.route(
            provider: .claude,
            isRemote: true) == .transcript)
    }
}
