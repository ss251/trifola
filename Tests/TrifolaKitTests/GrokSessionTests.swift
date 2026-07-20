import Foundation
import Testing
@testable import TrifolaKit

@Suite("Grok session adapter")
struct GrokSessionTests {
    @Test func pathsPreferEnvironmentOverride() {
        let home = URL(fileURLWithPath: "/Users/dev/", isDirectory: true)
        #expect(GrokPaths.resolve(home: home, environment: [:]).root.path
                == "/Users/dev/.grok")
        let overridden = GrokPaths.resolve(
            home: home, environment: ["GROK_HOME": "/Users/dev/grok-state"])
        #expect(overridden.root.path == "/Users/dev/grok-state")
        #expect(overridden.source == .environmentOverride)
    }

    @Test func transcriptUsageMetadataLineageAndModelUnion() throws {
        var accumulator = GrokSessionAccumulator(defaultID: "directory-id")
        accumulator.ingestSummary(Data(#"""
        {
          "info":{"id":"grok-child","cwd":"/Users/dev/projects/ground-truth"},
          "generated_title":"Fix the ingestion seam",
          "session_summary":"Implement the third provider",
          "created_at":"2026-07-18T03:00:00Z",
          "last_active_at":"2026-07-18T04:00:00Z",
          "num_chat_messages":4,
          "current_model_id":"grok-4.5",
          "parent_session_id":"grok-parent",
          "forked_at":"2026-07-18T03:05:00Z",
          "session_kind":"subagent_fork",
          "fork_context_source":"forked_verbatim",
          "fork_parent_prompt_id":"prompt-parent"
        }
        """#.utf8), fallbackCWD: "/Users/dev/fallback")

        let chat = [
            #"{"type":"user","content":[{"type":"text","text":"Find the real parser seam"}]}"#,
            #"{"type":"user","synthetic_reason":"context","content":[{"type":"text","text":"not a human prompt"}]}"#,
            #"{"type":"assistant","content":"The prose answer","model_id":"grok-4.5"}"#,
            #"{"type":"assistant","content":"Build-specific answer","model_id":"grok-4.5-build"}"#,
        ].joined(separator: "\n") + "\n"
        accumulator.ingestChatHistory(Data(chat.utf8))

        let updates = [
            #"{"method":"_x.ai/session/update","timestamp":"2026-07-18T03:10:00Z","params":{"sessionId":"grok-child","update":{"sessionUpdate":"turn_completed","prompt_id":"prompt-1","usage":{"inputTokens":130,"outputTokens":12,"totalTokens":142,"cachedReadTokens":30,"reasoningTokens":4,"modelCalls":2,"costIsPartial":true,"modelUsage":{"grok-4.5":{"inputTokens":100,"outputTokens":10,"totalTokens":110,"cachedReadTokens":20,"reasoningTokens":3,"modelCalls":1},"grok-4.5-build":{"inputTokens":30,"outputTokens":2,"totalTokens":32,"cachedReadTokens":10,"reasoningTokens":1,"modelCalls":1}}}}}}"#,
            #"{"method":"_x.ai/session/update","timestamp":"2026-07-18T03:11:00Z","params":{"sessionId":"grok-parent","update":{"sessionUpdate":"subagent_spawned","subagent_id":"grok-child","parent_session_id":"grok-parent","parent_prompt_id":"prompt-parent","child_session_id":"grok-child","subagent_type":"general-purpose","description":"parser lane","model":"grok-4.5"}}}"#,
        ].joined(separator: "\n") + "\n"
        accumulator.ingestUpdates(Data(updates.utf8))

        let summary = accumulator.summary(
            filePath: "/Users/dev/.grok/sessions/%2FUsers%2Fdev%2Fprojects/grok-child/chat_history.jsonl")
        #expect(summary.provider == .grok)
        #expect(summary.id == "grok-child")
        #expect(summary.cwd == "/Users/dev/projects/ground-truth")
        #expect(summary.project == "ground-truth")
        #expect(summary.displayTitle == "Fix the ingestion seam")
        #expect(summary.lastUserMessage == "Find the real parser seam")
        #expect(summary.usage.inputTokens == 100)
        #expect(summary.usage.cacheReadTokens == 30)
        #expect(summary.usage.outputTokens == 12)
        #expect(summary.usage.total == 142)
        #expect(summary.usageByModel["grok-4.5"]?.total == 110)
        #expect(summary.usageByModel["grok-4.5-build"]?.total == 32)
        #expect(summary.model == "grok-4.5 + grok-4.5-build")
        #expect(summary.tiersSeen == [.grok])
        #expect(summary.rawUsageBlocks == 1)
        #expect(summary.usageIsPartial)
        #expect(accumulator.threadMetadata.parentSessionID == "grok-parent")
        #expect(accumulator.threadMetadata.sessionKind == "subagent_fork")
        #expect(accumulator.spawnedChildren.first?.childSessionID == "grok-child")
    }

    @Test func offsetLessTimestampBucketsLikeTheCLI() throws {
        // Parity guard: the CLI's `new Date("2026-07-15T12:34:56")` parses an
        // offset-less ISO string in local time; the shared parseDate (correct
        // for Claude/Codex, which always emit `Z`) returns nil for it, which
        // would bucket the turn's tokens under "" in the app and under a real
        // local day in the CLI — a silent day/model parity break. The Grok
        // parser must fall back to a local parse so the twins agree.
        var accumulator = GrokSessionAccumulator(defaultID: "offset-less")
        accumulator.ingestSummary(Data(#"""
        {"info":{"id":"grok-tz","cwd":"/Users/dev/projects/tz"},
         "created_at":"2026-07-15T00:00:00Z"}
        """#.utf8), fallbackCWD: "/Users/dev/fallback")
        let updates =
            #"{"method":"_x.ai/session/update","timestamp":"2026-07-15T12:34:56","params":{"sessionId":"grok-tz","update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":50,"outputTokens":5,"totalTokens":55,"cachedReadTokens":0,"modelCalls":1,"modelUsage":{"grok-4.5":{"inputTokens":50,"outputTokens":5,"totalTokens":55,"cachedReadTokens":0,"modelCalls":1}}}}}}"#
            + "\n"
        accumulator.ingestUpdates(Data(updates.utf8))

        let expectedDay: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            f.isLenient = true
            let parsed = f.date(from: "2026-07-15T12:34:56")!
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = .current
            day.dateFormat = "yyyy-MM-dd"
            return day.string(from: parsed)
        }()

        let summary = accumulator.summary(
            filePath: "/Users/dev/.grok/sessions/%2FUsers%2Fdev%2Fprojects/grok-tz/chat_history.jsonl")
        // The turn landed on a real local day, never the empty "parse failed" key.
        #expect(summary.usageByModelDay[""] == nil)
        #expect(summary.usageByModelDay[expectedDay]?["grok-4.5"]?.total == 55)
    }

    @Test func transcriptProjectionExtractsOnlyHumanAndAssistantProse() {
        let user = GrokTranscriptParser.events(
            fromLine: Data(#"{"type":"user","content":[{"type":"text","text":"needle phrase"}]}"#.utf8),
            fallbackID: "u")
        let assistant = GrokTranscriptParser.events(
            fromLine: Data(#"{"type":"assistant","content":"answer phrase","model_id":"grok-4.5"}"#.utf8),
            fallbackID: "a")
        let synthetic = GrokTranscriptParser.events(
            fromLine: Data(#"{"type":"user","synthetic_reason":"fork","content":[{"type":"text","text":"hidden context"}]}"#.utf8),
            fallbackID: "s")
        #expect(user.map(\.kind) == [.userPrompt("needle phrase")])
        #expect(assistant.map(\.kind) == [.assistantText("answer phrase")])
        #expect(synthetic.isEmpty)
    }

    @Test func splitJSONLLinesResumeIndependently() {
        var accumulator = GrokSessionAccumulator(defaultID: "split")
        let chat = #"{"type":"user","content":[{"type":"text","text":"split prompt"}]}"#
        let midpoint = chat.utf8.count / 2
        let bytes = Array(chat.utf8)
        accumulator.ingestChatHistory(Data(bytes[..<midpoint]))
        #expect(accumulator.chatResumeOffset == 0)
        accumulator.ingestChatHistory(Data(bytes[midpoint...]) + Data("\n".utf8))
        #expect(accumulator.chatResumeOffset == UInt64(chat.utf8.count + 1))
        #expect(accumulator.summary(filePath: "/Users/dev/chat_history.jsonl")
            .lastUserMessage == "split prompt")
        #expect(accumulator.updatesResumeOffset == 0)
    }

    @Test func providerAndMarkCasesStayExhaustive() {
        #expect(Set(Provider.allCases) == [.claude, .codex, .grok])
        #expect(Set(Provider.allCases.map(\.markKind)) == Set(ProviderMarkKind.allCases))
        #expect(ModelTier(raw: "grok-4.5-build") == .grok)
    }
}
