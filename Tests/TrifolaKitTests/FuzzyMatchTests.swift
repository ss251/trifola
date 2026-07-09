import Foundation
import Testing
@testable import TrifolaKit

// MARK: - The scorer (subsequence + contiguity + start-boundary)

@Suite struct FuzzyMatchScoreTests {

    @Test func emptyQueryMatchesEverythingAtZero() {
        #expect(FuzzyMatch.score("", "anything") == 0)
        #expect(FuzzyMatch.score("", "") == 0)
    }

    @Test func nonSubsequenceReturnsNil() {
        #expect(FuzzyMatch.score("xyz", "my-app") == nil)
        // Right chars, wrong order → not a subsequence.
        #expect(FuzzyMatch.score("ba", "abc") == nil)
        // Query longer than candidate → nil.
        #expect(FuzzyMatch.score("controlx", "control") == nil)
    }

    @Test func caseInsensitiveSubsequenceMatches() {
        #expect(FuzzyMatch.score("CMC", "core-metrics-console") != nil)
        #expect(FuzzyMatch.score("over", "Overview") != nil)
    }

    @Test func startBoundaryOutranksMidWord() {
        // "over" at the very start of "Overview" must beat a mid-word run in
        // "discover" — the start-boundary + first-char bonus is the whole point.
        let atStart = try! #require(FuzzyMatch.score("over", "Overview"))
        let midWord = try! #require(FuzzyMatch.score("over", "discover"))
        #expect(atStart > midWord)
    }

    @Test func contiguousOutranksScattered() {
        // "spend" contiguous beats the same letters scattered across a phrase.
        let contiguous = try! #require(FuzzyMatch.score("spend", "Spend & Routing"))
        let scattered = try! #require(FuzzyMatch.score("spend", "supper-end"))
        #expect(contiguous > scattered)
    }

    @Test func separatorBoundaryScores() {
        // "control" after a "-" separator earns the boundary bonus, so
        // "mission-control" scores it higher than an unbroken embedding.
        let afterSep = try! #require(FuzzyMatch.score("control", "mission-control"))
        let embedded = try! #require(FuzzyMatch.score("control", "xcontrolx"))
        #expect(afterSep > embedded)
    }

    @Test func acronymAcrossWordBoundariesRanksWell() {
        // The classic: "cmc" lands on the three word-initial letters of
        // core-metrics-console and should outscore a same-letters scatter.
        let acronym = try! #require(FuzzyMatch.score("cmc", "core-metrics-console"))
        let scatter = try! #require(FuzzyMatch.score("cmc", "cormac"))
        #expect(acronym > scatter)
    }

    @Test func exactPrefixIsStrong() {
        let s = try! #require(FuzzyMatch.score("compiler", "compiler"))
        #expect(s > 0)
    }
}

// MARK: - The ranker (query → ranked results, ordering, empty query)

@Suite struct PaletteRankerTests {

    private func cand(_ id: String, _ primary: String, secondary: [String] = [],
                      recency: Date? = nil, group: Int = 0) -> PaletteCandidate {
        PaletteCandidate(id: id, primary: primary, secondary: secondary, recency: recency, group: group)
    }

    @Test func emptyQueryOrdersByGroupThenRecencyThenName() {
        let now = Date()
        let cands = [
            cand("sess-old", "webapp", recency: now.addingTimeInterval(-3600), group: 3),
            cand("sess-new", "crypto", recency: now.addingTimeInterval(-60), group: 3),
            cand("screen-a", "Audit", group: 0),
            cand("screen-b", "Overview", group: 0),
        ]
        let hits = PaletteRanker.rank(cands, query: "", now: now)
        // group 0 (screens) first, alpha within group; then group 3 sessions by recency.
        #expect(hits.map(\.id) == ["screen-a", "screen-b", "sess-new", "sess-old"])
    }

    @Test func nonMatchesAreDropped() {
        let hits = PaletteRanker.rank([
            cand("a", "Overview"),
            cand("b", "Spend & Routing"),
            cand("c", "toolbox"),
        ], query: "over")
        #expect(hits.map(\.id) == ["a"])   // only Overview is a subsequence of "over"
    }

    @Test func rankByRelevanceStartBoundaryWins() {
        // "over" at the front of "Overview" (start boundary) must outrank the same
        // contiguous run buried mid-word in "makeover".
        let hits = PaletteRanker.rank([
            cand("makeover", "makeover"),
            cand("overview", "Overview"),
        ], query: "over")
        #expect(hits.first?.id == "overview")
        #expect(Set(hits.map(\.id)) == ["overview", "makeover"])
    }

    @Test func primaryFieldOutranksSecondaryField() {
        // Same query; one matches in its title, the other only in a keyword.
        let hits = PaletteRanker.rank([
            cand("kw", "widget", secondary: ["compression"]),   // title doesn't match "comp"; only the keyword does
            cand("title", "compressor"),
        ], query: "comp")
        #expect(hits.first?.id == "title")   // primary match beats the discounted secondary
    }

    @Test func secondaryFieldStillMatchesWhenPrimaryDoesnt() {
        let hits = PaletteRanker.rank([
            cand("s", "Stack", secondary: ["probes", "tools", "mcp"]),
        ], query: "probe")
        #expect(hits.map(\.id) == ["s"])     // found via the secondary keyword
    }

    @Test func recencyBreaksComparableTextScores() {
        let now = Date()
        // Identical primary text → identical text score; recency decides.
        let hits = PaletteRanker.rank([
            cand("stale", "crypto", recency: now.addingTimeInterval(-20 * 3600), group: 3),
            cand("fresh", "crypto", recency: now.addingTimeInterval(-60), group: 3),
        ], query: "crypto", now: now)
        #expect(hits.first?.id == "fresh")
    }

    @Test func limitCapsResults() {
        let cands = (0..<200).map { cand("c\($0)", "session\($0)", group: 3) }
        let hits = PaletteRanker.rank(cands, query: "session", now: Date(), limit: 25)
        #expect(hits.count == 25)
    }

    @Test func recencyBonusDecaysToZero() {
        let now = Date()
        #expect(PaletteRanker.recencyBonus(now, now: now) == 30)
        #expect(PaletteRanker.recencyBonus(now.addingTimeInterval(-40 * 3600), now: now) == 0)
        #expect(PaletteRanker.recencyBonus(nil, now: now) == 0)
    }
}
