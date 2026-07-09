import Foundation

// MARK: - Fuzzy matcher (VISION 3.4 — the command palette's scorer)
// A PURE function: subsequence match ranked by CONTIGUITY (consecutive chars),
// START-BOUNDARY (a hit at index 0, after a separator, or at a camelCase seam),
// and — at the ranker layer — RECENCY. No store, no UI, no I/O, so the whole
// scorer is unit-tested (`FuzzyMatchTests`) and drives `--render-palette`.
//
// The algorithm is a memoized best-alignment over the subsequence: it finds the
// placement of the query's characters that maximizes the bonus total, so
// "over" scores highest against "Overview" (start-boundary + contiguous run),
// not against "discover" (mid-word run). Candidate strings here are short
// (project names, skill slugs, screen titles), so O(q·c²) with a cheap
// subsequence pre-gate is comfortably fast on every keystroke.

public enum FuzzyMatch {

    // Scoring weights — tuned so a start-boundary + contiguous run dominates a
    // mid-word scatter. Only the RELATIVE ordering matters (the tests assert
    // orderings, never absolute totals).
    static let scoreMatch = 10       // per matched char (keeps a match positive)
    static let bonusBoundary = 30    // matched at a word boundary (start / after separator)
    static let bonusFirstChar = 12   // extra when matched at index 0
    static let bonusCamel = 20       // matched at a camelCase seam (aB)
    static let bonusConsecutive = 20 // matched immediately after the previous match
    static let gapBase = 4           // gap penalty ramp base
    static let gapCap = 14           // deepest a single gap penalty goes

    /// The set of characters that open a "word boundary" — a match right after
    /// one earns the boundary bonus (the start-boundary half of the ranking rule).
    static let separators = Set<Character>([" ", "-", "_", "/", ".", ":", ",", "(", ")", "[", "]"])

    /// Best-alignment score of `query` as a case-insensitive subsequence of
    /// `candidate`, or nil when `query` is not a subsequence at all. An empty
    /// query matches everything with score 0 (the palette's default view).
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let orig = Array(candidate)
        let lc = Array(candidate.lowercased())
        guard q.count <= lc.count else { return nil }

        // Cheap subsequence gate: skip the DP entirely for the common non-match.
        var probe = 0
        for ch in lc where probe < q.count && ch == q[probe] { probe += 1 }
        guard probe == q.count else { return nil }

        let neg = Int.min / 4
        let cols = lc.count
        var memo = [Int](repeating: 0, count: q.count * cols)
        var seen = [Bool](repeating: false, count: q.count * cols)

        // The score for placing q[qi] at candidate index j, given the previous
        // query char sat at ci-1 (the invariant of `best(qi, ci)`).
        func place(_ qi: Int, _ ci: Int, _ j: Int) -> Int {
            var s = scoreMatch
            if j == 0 {
                s += bonusBoundary + bonusFirstChar
            } else if separators.contains(orig[j - 1]) {
                s += bonusBoundary
            } else if (orig[j - 1].isLowercase || orig[j - 1].isNumber) && orig[j].isUppercase {
                s += bonusCamel
            }
            if qi > 0 {
                if j == ci { s += bonusConsecutive }           // contiguous with the previous match
                else { s -= min(gapCap, gapBase + (j - ci)) }  // leading-gap penalty
            }
            return s
        }

        // Best score to place q[qi...] with q[qi] at some index >= ci, where
        // q[qi-1] (if any) sat at ci-1. Memoized on (qi, ci).
        func best(_ qi: Int, _ ci: Int) -> Int {
            if qi == q.count { return 0 }
            let key = qi * cols + ci
            if seen[key] { return memo[key] }
            var result = neg
            var j = ci
            while j < cols {
                if lc[j] == q[qi] {
                    let sub = best(qi + 1, j + 1)
                    if sub > neg {
                        let total = place(qi, ci, j) + sub
                        if total > result { result = total }
                    }
                }
                j += 1
            }
            seen[key] = true
            memo[key] = result
            return result
        }

        let r = best(0, 0)
        return r > neg ? r : nil
    }
}

// MARK: - Palette ranker (VISION 3.4)
// A pure ranking over lightweight candidates: fuzzy-score each candidate over
// its primary field (full weight) and secondary fields (discounted), add a
// modest recency nudge, and sort. Empty query → a calm default ordering
// (group, then recency, then name). Kept UI-free so the ranking is testable and
// the palette overlay just maps the ranked ids back to its rows.

/// One searchable command, stripped to what ranking needs. The view layer holds
/// the parallel row (icon, actions, door-light dot) and joins on `id`.
public struct PaletteCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    /// The field a match scores against at full weight (the row's title).
    public let primary: String
    /// Extra fields matched at a discount (ids, paths, descriptions, synonyms).
    public let secondary: [String]
    /// Recency signal for the tie/nudge (session last-activity, recipe mtime).
    public let recency: Date?
    /// Stable group order (screens before actions before … ) — the empty-query
    /// ordering and the score-tie breaker.
    public let group: Int

    public init(id: String, primary: String, secondary: [String] = [],
                recency: Date? = nil, group: Int = 0) {
        self.id = id
        self.primary = primary
        self.secondary = secondary
        self.recency = recency
        self.group = group
    }
}

public struct PaletteHit: Identifiable, Sendable, Equatable {
    public let id: String
    public let score: Int
    public init(id: String, score: Int) { self.id = id; self.score = score }
}

public enum PaletteRanker {
    /// A secondary-field match ranks below a primary-field one of the same shape.
    static let secondaryDiscount = 40

    /// A small, decaying nudge so a fresh session edges ahead of a stale one on a
    /// comparable text match — capped so text relevance always dominates.
    public static func recencyBonus(_ recency: Date?, now: Date) -> Int {
        guard let recency else { return 0 }
        let hours = now.timeIntervalSince(recency) / 3600
        if hours <= 0 { return 30 }
        return max(0, 30 - Int(hours))
    }

    /// The best fuzzy score for a candidate across its primary + secondary fields,
    /// or nil when nothing matches.
    public static func textScore(_ query: String, _ c: PaletteCandidate) -> Int? {
        var best = FuzzyMatch.score(query, c.primary)
        for field in c.secondary {
            guard let s = FuzzyMatch.score(query, field) else { continue }
            let discounted = s - secondaryDiscount
            best = max(best ?? discounted, discounted)
        }
        return best
    }

    /// Rank `candidates` against `query`. Empty query → group/recency/name order;
    /// non-empty → score desc, then group, then recency, then name. Capped to `limit`.
    public static func rank(_ candidates: [PaletteCandidate], query: String,
                            now: Date = Date(), limit: Int = 60) -> [PaletteHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if q.isEmpty {
            let ordered = candidates.sorted { defaultOrder($0, $1) }
            return ordered.prefix(limit).map { PaletteHit(id: $0.id, score: 0) }
        }

        var scored: [(cand: PaletteCandidate, score: Int)] = []
        scored.reserveCapacity(candidates.count)
        for c in candidates {
            guard let text = textScore(q, c) else { continue }
            scored.append((c, text + recencyBonus(c.recency, now: now)))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return defaultOrder(a.cand, b.cand)
        }
        return scored.prefix(limit).map { PaletteHit(id: $0.cand.id, score: $0.score) }
    }

    /// group asc → recency desc → name asc. The empty-query order and the tie-break.
    static func defaultOrder(_ a: PaletteCandidate, _ b: PaletteCandidate) -> Bool {
        if a.group != b.group { return a.group < b.group }
        let ra = a.recency ?? .distantPast, rb = b.recency ?? .distantPast
        if ra != rb { return ra > rb }
        return a.primary.localizedCaseInsensitiveCompare(b.primary) == .orderedAscending
    }
}
