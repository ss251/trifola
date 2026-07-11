import Foundation
import Testing
@testable import TrifolaKit

@Suite("Structured transcript presentation")
struct StructuredTranscriptPresentationTests {
    private func presentation(
        _ text: String,
        kind: (String) -> TranscriptEvent.Kind = { .assistantText($0) }
    ) -> TranscriptTextPresentation {
        TranscriptEvent(id: "event", timestamp: nil, kind: kind(text)).textPresentation
    }

    @Test func plainNarrationStaysPlain() {
        #expect(presentation("I checked the release gate and it passed.") == .plain)
        #expect(presentation("{not valid JSON}") == .plain)
        #expect(presentation("<comparison is not markup>") == .plain)
    }

    @Test func compactJSONIsPrettyPrintedOnceIntoNestedLines() throws {
        let result = presentation(#"{"service":{"name":"api","ports":[80,443]},"ok":true}"#)
        guard case .structured(let value) = result else {
            Issue.record("Expected structured JSON")
            return
        }
        #expect(value.format == .json)
        #expect(value.lines.first?.role == .markup)
        #expect(value.lines.contains { $0.depth >= 2 })
        #expect(value.lines.contains { $0.text.contains("ports") })
        #expect(!value.didTruncate)
    }

    @Test func markupSeparatesTagsFromContentAndBuildsGuides() throws {
        let result = presentation("<root><item><name>Trifola</name></item></root>")
        guard case .structured(let value) = result else {
            Issue.record("Expected structured markup")
            return
        }
        #expect(value.format == .xml)
        #expect(value.lines.filter { $0.role == .markup }.count == 6)
        #expect(value.lines.contains {
            $0.role == .content && $0.text == "Trifola" && $0.depth == 3
        })
    }

    @Test func unifiedDiffDistinguishesStructureAdditionsAndRemovals() throws {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,2 @@
        -let old = true
        +let current = true
         print(current)
        """
        let result = presentation(diff, kind: { .toolResult(preview: $0, isError: false) })
        guard case .structured(let value) = result else {
            Issue.record("Expected structured diff")
            return
        }
        #expect(value.format == .diff)
        #expect(value.lines.contains { $0.role == .markup && $0.text.hasPrefix("@@") })
        #expect(value.lines.contains { $0.role == .addition })
        #expect(value.lines.contains { $0.role == .removal })
    }

    @Test func projectionBoundsLinesCharactersAndGuideDepth() throws {
        let deepValue = String(repeating: "x", count: 500)
        var object: [String: Any] = ["long": deepValue]
        for index in 0..<40 { object["key-\(index)"] = index }
        let data = try JSONSerialization.data(withJSONObject: object)
        let result = presentation(String(decoding: data, as: UTF8.self))
        guard case .structured(let value) = result else {
            Issue.record("Expected structured JSON")
            return
        }
        #expect(value.didTruncate)
        #expect(value.lines.count <= StructuredTranscriptPresentation.maximumLines)
        #expect(value.lines.allSatisfy {
            $0.text.count <= StructuredTranscriptPresentation.maximumCharactersPerLine + 2
        })
        #expect(value.lines.allSatisfy {
            $0.depth <= StructuredTranscriptPresentation.maximumGuideDepth
        })
        #expect(value.lines.last?.text.contains("more lines") == true)
    }

    @Test func userPromptPreservesExistingQuotedTreatment() {
        let result = presentation(#"{"request":"keep this raw"}"#, kind: { .userPrompt($0) })
        #expect(result == .plain)
    }
}
