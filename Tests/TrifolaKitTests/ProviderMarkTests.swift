import Testing
@testable import TrifolaKit

@Suite("Provider identity marks")
struct ProviderMarkTests {
    @Test("every Provider maps to a mark kind — exhaustive, never silently blank")
    func everyProviderHasAMarkKind() {
        // Pin the known universe so a new Provider case without an update
        // fails this test rather than shipping a blank glyph.
        let expected: [Provider: ProviderMarkKind] = [
            .claude: .claudeStarburst,
            .codex: .openAIBlossom,
        ]
        #expect(Set(expected.keys) == Set(Provider.allCases),
                "Update ProviderMarkTests and Provider.markKind when adding a provider")
        for provider in Provider.allCases {
            #expect(provider.markKind == expected[provider],
                    "\(provider) must have an explicit mark kind")
            // Exhaustive switch inside markKind already fails the build if a
            // case is missing; this asserts the mapping stays intentional.
            switch provider.markKind {
            case .claudeStarburst, .openAIBlossom:
                break
            }
        }
    }

    @Test("every Provider carries a non-empty accessibility label (Claude / OpenAI Codex)")
    func everyProviderHasAccessibilityLabel() {
        let expected: [Provider: String] = [
            .claude: "Claude",
            .codex: "OpenAI Codex",
        ]
        #expect(Set(expected.keys) == Set(Provider.allCases))
        for provider in Provider.allCases {
            let label = provider.markAccessibilityLabel
            #expect(!label.isEmpty)
            #expect(label == expected[provider])
        }
    }

    @Test("mark kinds cover the shapes ProviderMark draws")
    func markKindUniverseMatchesShapes() {
        // If a new shape case is added without a provider mapping, the
        // allCases table documents the gap for the next agent.
        #expect(ProviderMarkKind.allCases.count == 2)
        #expect(Set(Provider.allCases.map(\.markKind)) == Set(ProviderMarkKind.allCases))
    }
}
