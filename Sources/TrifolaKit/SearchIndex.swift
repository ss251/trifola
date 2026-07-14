import Foundation

/// Exact search over the human-authored/narrative parts of local transcripts.
/// Tool calls, tool results, thinking, summaries, and system records are never
/// projected into this index.
public enum SearchText {
    public static let maximumTokenLength = 64
    public static let maximumDistinctTokensPerDocument = 4_096
    public static let maximumOrderedTokensPerDocument = 20_000

    /// Lowercase Unicode-alphanumeric runs. This handles whitespace-delimited
    /// languages well. CJK text without spaces is commonly one long token, so
    /// searching a remembered substring inside that run is a documented v1 limit.
    public static func tokens(in text: String) -> [String] {
        let normalized = text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        var output: [String] = []
        var current = ""
        func flush() {
            guard current.count >= 2, current.count <= maximumTokenLength else {
                current.removeAll(keepingCapacity: true)
                return
            }
            output.append(current)
            current.removeAll(keepingCapacity: true)
        }
        for character in normalized {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return output
    }

    public static func searchableText(from event: TranscriptEvent) -> String? {
        switch event.kind {
        case .userPrompt(let text), .assistantText(let text): return text
        case .thinking, .toolUse, .toolResult, .system, .summary: return nil
        }
    }

    public static func searchableEvents(at url: URL,
                                        provider: Provider) -> [TranscriptEvent]? {
        switch provider {
        case .claude:
            guard let data = try? Data(contentsOf: url) else { return nil }
            var events: [TranscriptEvent] = []
            forEachLine(in: data) { lineNumber, line in
                events.append(contentsOf: TranscriptParser.events(
                    fromLine: line, fallbackID: "search-L\(lineNumber)"))
            }
            return events
        case .codex:
            return CodexRolloutTranscriptParser.events(
                at: url, maximumEvents: .max)
        }
    }

    private static func forEachLine(
        in data: Data,
        _ body: (Int, Data) -> Void
    ) {
        var start = data.startIndex
        var lineNumber = 0
        while start < data.endIndex,
              let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start {
                body(lineNumber, data.subdata(in: start..<newline))
            }
            lineNumber += 1
            start = data.index(after: newline)
        }
        if start < data.endIndex {
            body(lineNumber, data.subdata(in: start..<data.endIndex))
        }
    }
}

public struct SearchQuery: Sendable, Equatable {
    public let rawValue: String
    public let tokens: [String]

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.tokens = SearchText.tokens(in: rawValue)
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

public enum SearchScope: Sendable, Equatable {
    case all
    case conversationText
}

public struct SearchCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    public let provider: Provider
    public let project: String
    public let cwd: String
    public let title: String
    public let filePath: String
    public let lastActivity: Date?
    public let score: Double
    public let exactPhrase: Bool
    public let matchedConversationText: Bool

    public init(id: String, provider: Provider, project: String, cwd: String,
                title: String, filePath: String, lastActivity: Date?,
                score: Double, exactPhrase: Bool,
                matchedConversationText: Bool) {
        self.id = id
        self.provider = provider
        self.project = project
        self.cwd = cwd
        self.title = title
        self.filePath = filePath
        self.lastActivity = lastActivity
        self.score = score
        self.exactPhrase = exactPhrase
        self.matchedConversationText = matchedConversationText
    }
}

public struct SearchHighlight: Sendable, Equatable, Codable {
    public let start: Int
    public let length: Int

    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

public struct SearchSnippet: Sendable, Equatable {
    public let text: String
    public let highlights: [SearchHighlight]
    public let role: String

    public init(text: String, highlights: [SearchHighlight], role: String) {
        self.text = text
        self.highlights = highlights
        self.role = role
    }
}

public struct SearchResult: Identifiable, Sendable, Equatable {
    public let candidate: SearchCandidate
    public let snippet: SearchSnippet?
    public var id: String { candidate.id }

    public init(candidate: SearchCandidate, snippet: SearchSnippet?) {
        self.candidate = candidate
        self.snippet = snippet
    }
}

public struct SearchIndexStatistics: Sendable, Equatable {
    public let documentCount: Int
    public let uniqueTermCount: Int
    public let tokenCount: Int
    public let estimatedBytes: Int
}

public struct SearchIndexUpdate: Sendable {
    public let index: SearchIndex
    public let rebuiltDocuments: Int
    public let reusedDocuments: Int
    public let removedDocuments: Int
}

public enum SearchIndexLoadResult: Sendable {
    case ready(SearchIndex)
    case missing
    case versionMismatch(found: Int)
    case corrupt
}

/// A separately versioned, dependency-free inverted index. Cache changes here
/// must never bump or silently reuse SessionStore's session-index v21 artifact.
public struct SearchIndex: Sendable {
    public static let currentVersion = 1

    private struct Document: Sendable, Codable {
        let key: String
        let sessionID: String
        let provider: Provider
        let project: String
        let cwd: String
        let title: String
        let filePath: String
        let fileSize: UInt64
        let modifiedAt: Date
        let lastActivity: Date?
        let metadataFrequency: [String: Int]
        let conversationFrequency: [String: Int]
        let metadataTokens: [String]
        let conversationTokens: [String]

        var allFrequency: [String: Int] {
            metadataFrequency.merging(conversationFrequency, uniquingKeysWith: +)
        }

        func matches(_ summary: SessionSummary, size: UInt64,
                     mtime: Date) -> Bool {
            provider == summary.provider
                && filePath == summary.filePath
                && fileSize == size
                && modifiedAt == mtime
                && project == summary.project
                && cwd == summary.cwd
                && title == summary.displayTitle
                && lastActivity == summary.lastActivity
        }
    }

    private struct CacheFile: Codable {
        let version: Int
        let documents: [Document]
    }

    private var documents: [String: Document]
    private var allPostings: [String: [String: Int]]
    private var conversationPostings: [String: [String: Int]]

    public init() {
        documents = [:]
        allPostings = [:]
        conversationPostings = [:]
    }

    private init(documents: [String: Document]) {
        self.documents = documents
        (allPostings, conversationPostings) = Self.makePostings(documents)
    }

    public var statistics: SearchIndexStatistics {
        let tokenCount = documents.values.reduce(0) {
            $0 + $1.metadataTokens.count + $1.conversationTokens.count
        }
        let stringBytes = documents.values.reduce(0) { partial, document in
            partial + document.project.utf8.count + document.cwd.utf8.count
                + document.title.utf8.count + document.filePath.utf8.count
                + document.metadataTokens.reduce(0) { $0 + $1.utf8.count }
                + document.conversationTokens.reduce(0) { $0 + $1.utf8.count }
        }
        let postingEntries = allPostings.values.reduce(0) { $0 + $1.count }
        return SearchIndexStatistics(
            documentCount: documents.count,
            uniqueTermCount: allPostings.count,
            tokenCount: tokenCount,
            estimatedBytes: stringBytes + postingEntries * 48)
    }

    /// Reuses byte-identical file documents and wholly replaces changed ones.
    /// Whole-document replacement is deliberate: appends, truncations, and
    /// rewrites cannot leave stale term or phrase positions behind.
    public static func update(
        _ previous: SearchIndex,
        sessions: [SessionSummary]
    ) -> SearchIndexUpdate {
        struct Work: Sendable {
            let summary: SessionSummary
            let key: String
            let size: UInt64
            let mtime: Date
        }

        var reused: [String: Document] = [:]
        var work: [Work] = []
        for summary in sessions {
            let key = documentKey(for: summary)
            let attributes = (try? FileManager.default.attributesOfItem(
                atPath: summary.filePath)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attributes[.modificationDate] as? Date) ?? .distantPast
            if let old = previous.documents[key],
               old.matches(summary, size: size, mtime: mtime) {
                reused[key] = old
            } else {
                work.append(Work(summary: summary, key: key,
                                 size: size, mtime: mtime))
            }
        }

        let items = work
        let state = Locked(reused)
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            let item = items[index]
            let document = makeDocument(
                summary: item.summary, key: item.key,
                size: item.size, mtime: item.mtime)
            state.withLock { $0[item.key] = document }
        }
        let merged = state.withLock { $0 }
        let currentKeys = Set(merged.keys)
        let removed = previous.documents.keys.reduce(0) {
            $0 + (currentKeys.contains($1) ? 0 : 1)
        }
        return SearchIndexUpdate(
            index: SearchIndex(documents: merged),
            rebuiltDocuments: work.count,
            reusedDocuments: reused.count,
            removedDocuments: removed)
    }

    public func query(
        _ query: SearchQuery,
        scope: SearchScope = .all,
        limit: Int = 20,
        now: Date = Date()
    ) -> [SearchCandidate] {
        guard !query.tokens.isEmpty, limit > 0 else { return [] }
        let postings = scope == .conversationText
            ? conversationPostings : allPostings
        let uniqueTerms = Array(Set(query.tokens))
        guard let first = uniqueTerms.first,
              var candidates = postings[first].map({ Set($0.keys) }) else {
            return []
        }
        for term in uniqueTerms.dropFirst() {
            guard let keys = postings[term] else { return [] }
            candidates.formIntersection(keys.keys)
            if candidates.isEmpty { return [] }
        }

        var ranked: [SearchCandidate] = []
        ranked.reserveCapacity(min(limit, candidates.count))
        func precedes(_ lhs: SearchCandidate, _ rhs: SearchCandidate) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsDate = lhs.lastActivity ?? .distantPast
            let rhsDate = rhs.lastActivity ?? .distantPast
            return lhsDate == rhsDate ? lhs.id < rhs.id : lhsDate > rhsDate
        }
        for key in candidates {
            guard let document = documents[key] else { continue }
            let frequency = scope == .conversationText
                ? document.conversationFrequency : document.allFrequency
            let hits = uniqueTerms.reduce(0) { $0 + (frequency[$1] ?? 0) }
            let phrase: Bool
            switch scope {
            case .all:
                phrase = Self.containsPhrase(query.tokens, in: document.metadataTokens)
                    || Self.containsPhrase(query.tokens, in: document.conversationTokens)
            case .conversationText:
                phrase = Self.containsPhrase(
                    query.tokens, in: document.conversationTokens)
            }
            let conversationMatch = uniqueTerms.allSatisfy {
                document.conversationFrequency[$0] != nil
            }
            let recency: Double
            if let last = document.lastActivity {
                let days = max(0, now.timeIntervalSince(last) / 86_400)
                recency = max(0, 30 * (1 - min(days, 365) / 365))
            } else {
                recency = 0
            }
            let score = Double(hits * 12 + uniqueTerms.count * 25)
                + recency + (phrase ? 1_000 : 0)
            let candidate = SearchCandidate(
                id: document.sessionID,
                provider: document.provider,
                project: document.project,
                cwd: document.cwd,
                title: document.title,
                filePath: document.filePath,
                lastActivity: document.lastActivity,
                score: score,
                exactPhrase: phrase,
                matchedConversationText: conversationMatch)
            if ranked.count < limit {
                ranked.append(candidate)
            } else if let worstIndex = ranked.indices.max(by: {
                precedes(ranked[$0], ranked[$1])
            }), precedes(candidate, ranked[worstIndex]) {
                ranked[worstIndex] = candidate
            }
        }
        ranked.sort(by: precedes)
        return ranked
    }

    public func cacheData(version: Int = currentVersion) throws -> Data {
        try JSONEncoder().encode(CacheFile(
            version: version,
            documents: documents.values.sorted { $0.key < $1.key }))
    }

    public static func load(data: Data) -> SearchIndexLoadResult {
        guard let file = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return .corrupt
        }
        guard file.version == currentVersion else {
            return .versionMismatch(found: file.version)
        }
        return .ready(SearchIndex(documents: Dictionary(
            file.documents.map { ($0.key, $0) },
            uniquingKeysWith: { _, newest in newest })))
    }

    public static func load(from url: URL) -> SearchIndexLoadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        return load(data: data)
    }

    public func save(to url: URL) throws {
        let data = try cacheData()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func documentKey(for summary: SessionSummary) -> String {
        [summary.provider.rawValue, summary.machineID,
         summary.id, summary.filePath].joined(separator: "\u{1}")
    }

    private static func makeDocument(
        summary: SessionSummary,
        key: String,
        size: UInt64,
        mtime: Date
    ) -> Document {
        var metadata = TokenCollector()
        metadata.add(summary.displayTitle)
        metadata.add(summary.project)
        metadata.add(summary.cwd)

        var conversation = TokenCollector()
        if !summary.filePath.isEmpty,
           let events = SearchText.searchableEvents(
                at: URL(fileURLWithPath: summary.filePath),
                provider: summary.provider) {
            for event in events {
                if let text = SearchText.searchableText(from: event) {
                    conversation.add(text)
                }
            }
        }
        return Document(
            key: key,
            sessionID: summary.id,
            provider: summary.provider,
            project: summary.project,
            cwd: summary.cwd,
            title: summary.displayTitle,
            filePath: summary.filePath,
            fileSize: size,
            modifiedAt: mtime,
            lastActivity: summary.lastActivity,
            metadataFrequency: metadata.frequency,
            conversationFrequency: conversation.frequency,
            metadataTokens: metadata.ordered,
            conversationTokens: conversation.ordered)
    }

    private static func makePostings(
        _ documents: [String: Document]
    ) -> ([String: [String: Int]], [String: [String: Int]]) {
        var all: [String: [String: Int]] = [:]
        var conversation: [String: [String: Int]] = [:]
        for (key, document) in documents {
            for (term, count) in document.allFrequency {
                all[term, default: [:]][key] = count
            }
            for (term, count) in document.conversationFrequency {
                conversation[term, default: [:]][key] = count
            }
        }
        return (all, conversation)
    }

    private static func containsPhrase(_ phrase: [String],
                                       in text: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= text.count else { return false }
        if phrase.count == 1 { return text.contains(phrase[0]) }
        for start in 0...(text.count - phrase.count) {
            var matches = true
            for offset in phrase.indices where text[start + offset] != phrase[offset] {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }

    private struct TokenCollector {
        var frequency: [String: Int] = [:]
        var ordered: [String] = []

        mutating func add(_ text: String) {
            var added = false
            for token in SearchText.tokens(in: text) {
                let admitted = frequency[token] != nil
                    || frequency.count < SearchText.maximumDistinctTokensPerDocument
                guard admitted else { continue }
                added = true
                frequency[token, default: 0] += 1
                if ordered.count < SearchText.maximumOrderedTokensPerDocument {
                    ordered.append(token)
                }
            }
            if added, ordered.count < SearchText.maximumOrderedTokensPerDocument {
                ordered.append("\u{0}")
            }
        }
    }
}

public enum SearchSnippetExtractor {
    public static let maximumCharacters = 220

    public static func snippet(
        for candidate: SearchCandidate,
        query: SearchQuery
    ) -> SearchSnippet? {
        guard !candidate.filePath.isEmpty,
              let events = SearchText.searchableEvents(
                at: URL(fileURLWithPath: candidate.filePath),
                provider: candidate.provider) else { return nil }

        var best: (text: String, role: String, score: Int)?
        let unique = Set(query.tokens)
        for event in events {
            guard let text = SearchText.searchableText(from: event) else { continue }
            let tokens = SearchText.tokens(in: text)
            let present = unique.reduce(0) { $0 + (tokens.contains($1) ? 1 : 0) }
            guard present > 0 else { continue }
            let phrase = phraseAppears(query.rawValue, in: text)
            let score = present * 100 + (phrase ? 1_000 : 0)
            let role: String
            switch event.kind {
            case .userPrompt: role = "You"
            case .assistantText: role = "Assistant"
            default: continue
            }
            if best == nil || score > best!.score {
                best = (text, role, score)
            }
        }
        guard let best else { return nil }
        let excerpt = excerpt(from: best.text, terms: query.tokens)
        return SearchSnippet(
            text: excerpt,
            highlights: highlights(in: excerpt, terms: query.tokens),
            role: best.role)
    }

    private static func phraseAppears(_ phrase: String, in text: String) -> Bool {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive],
                          locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    private static func excerpt(from text: String, terms: [String]) -> String {
        guard text.count > maximumCharacters else { return text }
        let first = terms.compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive],
                       locale: Locale(identifier: "en_US_POSIX"))?.lowerBound
        }.min() ?? text.startIndex
        let location = text.distance(from: text.startIndex, to: first)
        let startOffset = max(0, location - maximumCharacters / 3)
        let endOffset = min(text.count, startOffset + maximumCharacters)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        return (startOffset > 0 ? "…" : "")
            + String(text[start..<end])
            + (endOffset < text.count ? "…" : "")
    }

    private static func highlights(in text: String,
                                   terms: [String]) -> [SearchHighlight] {
        var output: [SearchHighlight] = []
        let locale = Locale(identifier: "en_US_POSIX")
        for term in Set(terms) {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: cursor..<text.endIndex,
                    locale: locale) {
                output.append(SearchHighlight(
                    start: text.distance(from: text.startIndex, to: range.lowerBound),
                    length: text.distance(from: range.lowerBound, to: range.upperBound)))
                cursor = range.upperBound
            }
        }
        return output.sorted { $0.start < $1.start }
    }
}
