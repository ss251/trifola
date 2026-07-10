import Foundation
import Combine

// MARK: - Attention state machine
// The flagship signal: with N live agents, "which one is BLOCKED on me right now?"
// A pure, testable state machine over a session transcript's tail. Nothing here
// touches AppKit/SwiftUI or the filesystem beyond one bounded tail read, so the
// whole classifier is exercised in unit tests against hand-built transcripts.
//
// Grounded in the on-disk transcript shape (verified 2026-07-06): each .jsonl line
// is one event. An `assistant` message's `.message.content[]` blocks are
// {thinking,text,tool_use}; a `tool_use` block carries `.id` (toolu_…). Its result
// arrives later inside a `user` message as a `tool_result` block whose
// `.tool_use_id` == that id. A `tool_use` at the very tail with no later matching
// `tool_result` is a dangling tool call. That proves only that work has not
// returned yet; a separate explicit signal is required before it can mean a
// permission prompt / AskUserQuestion / human gate.

public enum AttentionState: String, Sendable, Codable, CaseIterable, Hashable {
    case blocked   // 🔴 explicit permission prompt / human gate
    case waiting   // 🟡 turn ended (assistant text, stop_reason end_turn) — ball in your court
    case running   // 🟢 work streaming — recent tool activity
    case idle      // ⚪ gone quiet (>15m)

    /// Sort key: the more it needs you, the smaller the rank (sorts first).
    public var sortRank: Int {
        switch self {
        case .blocked: return 0
        case .waiting: return 1
        case .running: return 2
        case .idle:    return 3
        }
    }

    /// Short, all-caps state word for the chip (community vocabulary — @0xMorlex
    /// named these four verbatim).
    public var label: String {
        switch self {
        case .blocked: return "BLOCKED"
        case .waiting: return "WAITING"
        case .running: return "RUNNING"
        case .idle:    return "IDLE"
        }
    }

    /// True for the two states that actually ask for the human — the only things
    /// the strip surfaces prominently (no-nag doctrine: RUNNING/IDLE are counts).
    public var needsAttention: Bool { self == .blocked || self == .waiting }

    // Spec thresholds. Kept simple and named so tests and UI share one source.
    /// Human-gate evidence younger than this is allowed to settle before BLOCKED.
    /// Elapsed time alone never upgrades an ordinary tool call into a human gate.
    public static let blockedThreshold: TimeInterval = 30
    /// No activity for longer than this ⇒ the session has gone quiet (IDLE),
    /// reusing the existing `isActive` 15-minute window.
    public static let idleThreshold: TimeInterval = 15 * 60

    /// Compatibility surface for callers that need only the state. The detailed
    /// classifier below is authoritative and also explains confidence + reason.
    public static func classify(_ s: AttentionSignals, now: Date) -> AttentionState {
        classifyDetailed(s, now: now).state
    }

    /// The pure, diagnosable classifier. A dangling subagent call is positive
    /// evidence of work in flight, never a human gate. Conversely, an ended
    /// assistant turn is WAITING only when its text positively asks the human for
    /// permission, a yes/no answer, or plan approval; ordinary completion is IDLE.
    public static func classifyDetailed(
        _ s: AttentionSignals,
        now: Date
    ) -> AttentionClassification {
        guard let last = s.lastEventAt else {
            return AttentionClassification(
                state: .idle, confidence: .high,
                reason: "no meaningful transcript event")
        }
        let age = now.timeIntervalSince(last)
        let permissionEvidence = s.canObserveBlocking && s.hasPermissionGate
        let promptEvidence = AttentionSignals.humanPromptEvidence(in: s.lastAssistantText)
            ?? AttentionSignals.humanPromptEvidence(in: s.lastToolDetail)

        if permissionEvidence, age > blockedThreshold {
            return AttentionClassification(
                state: .blocked, confidence: .high,
                reason: "unanswered permission record")
        }

        if s.hasDanglingToolUse {
            if AttentionSignals.isSubagentTool(s.lastToolName) {
                return AttentionClassification(
                    state: .running, confidence: .high,
                    reason: "in-flight subagent call \(s.lastToolName ?? "unknown")")
            }
            if age > blockedThreshold {
                if s.canObserveBlocking {
                    let explicitHumanGate = AttentionSignals.isExplicitHumanGateTool(s.lastToolName)
                    if explicitHumanGate || permissionEvidence || promptEvidence != nil {
                        let reason: String
                        if explicitHumanGate {
                            reason = "unanswered human gate \(s.lastToolName ?? "unknown")"
                        } else if permissionEvidence {
                            reason = "unanswered permission record"
                        } else {
                            reason = "tool call carries \(promptEvidence!.reason) evidence"
                        }
                        return AttentionClassification(
                            state: .blocked, confidence: .high, reason: reason)
                    }
                }
                return AttentionClassification(
                    state: .running, confidence: .high,
                    reason: "\(s.lastToolName ?? "tool") still running after \(Int(max(0, age)))s; no human-gate evidence")
            }
            return AttentionClassification(
                state: .running, confidence: .medium,
                reason: "tool call is inside the \(Int(blockedThreshold))s execution window")
        }

        // ⚪ otherwise, no activity for >15m ⇒ the session has gone quiet.
        if age > idleThreshold {
            return AttentionClassification(
                state: .idle, confidence: .high,
                reason: "no meaningful activity for more than 15 minutes")
        }

        if s.lastKind == .turnComplete {
            return AttentionClassification(
                state: .waiting, confidence: .high,
                reason: "runtime turn completed; waiting on the human")
        }

        if s.lastKind == .assistantText, s.lastStopReason == "end_turn" {
            if let evidence = AttentionSignals.humanPromptEvidence(in: s.lastAssistantText) {
                return AttentionClassification(
                    state: .waiting, confidence: .high,
                    reason: "assistant requested \(evidence.reason)")
            }
            return AttentionClassification(
                state: .idle, confidence: .high,
                reason: "assistant turn ended without a human-answerable prompt")
        }

        // 🟢 everything else inside the live window: a fresh dangling tool_use
        // (<30s, tool still executing), a just-arrived tool_result, a user prompt
        // the assistant is answering — all "work in flight".
        return AttentionClassification(
            state: .running, confidence: .medium,
            reason: "recent transcript activity indicates work in flight")
    }
}

public struct AttentionClassification: Sendable, Equatable, Hashable {
    public enum Confidence: String, Sendable, Equatable, Hashable, Codable {
        case high, medium, low
    }

    public let state: AttentionState
    public let confidence: Confidence
    public let reason: String

    public init(state: AttentionState, confidence: Confidence, reason: String) {
        self.state = state
        self.confidence = confidence
        self.reason = reason
    }

    /// Pasteable in a bug report and compact enough for a future UI disclosure.
    public var diagnostic: String { "\(confidence.rawValue): \(reason)" }
}

// MARK: - Attention signals
// The time-INDEPENDENT facts extracted from a transcript tail. These change only
// when the file changes; `AttentionState.classify` layers `now` on top of them.

public struct AttentionSignals: Sendable, Equatable, Hashable {
    /// Kind of the last meaningful (non-meta) event in the tail.
    public enum LastKind: String, Sendable, Equatable, Hashable, Codable {
        case assistantText, toolUse, toolResult, userPrompt, thinking, system
        case runtimeActivity, turnComplete, none
    }

    /// Timestamp of the most recent meaningful event (drives age / staleness).
    public var lastEventAt: Date?
    /// Kind of that last event.
    public var lastKind: LastKind
    /// `stop_reason` on the most recent assistant message carrying content
    /// (`end_turn`, `tool_use`, …), or nil.
    public var lastStopReason: String?
    /// Text from the most recent assistant message, when present. WAITING needs
    /// positive evidence in this text; an ordinary completed turn is IDLE.
    public var lastAssistantText: String?
    /// True iff the tail ends on a `tool_use` whose `tool_use_id` never received a
    /// matching `tool_result` — the dangling-tool-call signal.
    public var hasDanglingToolUse: Bool
    /// When that dangling tool_use was issued (== lastEventAt when dangling).
    public var danglingToolUseAt: Date?
    /// Most recent tool_use OR tool_result timestamp — "work streaming" evidence.
    public var lastToolActivityAt: Date?
    /// Name of the freshest `tool_use` in the tail (`Edit`, `Write`, `Bash`, …) —
    /// the Fleet Board's "now-line" tool. For a BLOCKED session this is the tool
    /// it is stuck on (the dangling call); for a RUNNING one it is the tool in
    /// flight. nil when the tail carries no tool_use.
    public var lastToolName: String?
    /// The human-scannable detail for `lastToolName` — the file path for
    /// Edit/Write/Read (home-relativized), the command for Bash, etc. — reusing
    /// the transcript parser's `toolDetail` so the board's now-line and the live
    /// feed read identically. Empty/nil when the tool carried no detail.
    public var lastToolDetail: String?
    /// Positive transcript record that Claude Code is waiting at a permission
    /// boundary. A mere `permission-mode` setting is not a gate.
    public var hasPermissionGate: Bool
    /// Whether this provider's on-disk surface can persist human-gate evidence.
    /// Codex rollouts cannot, so tool-shaped input may never become BLOCKED.
    public let canObserveBlocking: Bool

    public init(lastEventAt: Date? = nil, lastKind: LastKind = .none,
                lastStopReason: String? = nil, hasDanglingToolUse: Bool = false,
                danglingToolUseAt: Date? = nil, lastToolActivityAt: Date? = nil,
                lastToolName: String? = nil, lastToolDetail: String? = nil,
                lastAssistantText: String? = nil,
                hasPermissionGate: Bool = false,
                canObserveBlocking: Bool = true) {
        self.lastEventAt = lastEventAt
        self.lastKind = lastKind
        self.lastStopReason = lastStopReason
        self.lastAssistantText = lastAssistantText
        self.hasDanglingToolUse = hasDanglingToolUse
        self.danglingToolUseAt = danglingToolUseAt
        self.lastToolActivityAt = lastToolActivityAt
        self.lastToolName = lastToolName
        self.lastToolDetail = lastToolDetail
        self.hasPermissionGate = hasPermissionGate
        self.canObserveBlocking = canObserveBlocking
    }

    /// Claude has used both `Task` and `Agent`; `TaskOutput` is the blocking
    /// join for a background subagent. None is answerable by the human.
    static func isSubagentTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return ["Agent", "Task", "TaskOutput"].contains(name)
    }

    /// Tool calls whose entire purpose is to obtain a human decision.
    static func isExplicitHumanGateTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return ["AskUserQuestion", "ExitPlanMode"].contains(name)
    }

    enum HumanPromptEvidence: String, Sendable {
        case permission
        case yesNo
        case planApproval

        var reason: String {
            switch self {
            case .permission: return "permission"
            case .yesNo: return "a yes/no answer"
            case .planApproval: return "plan approval"
            }
        }
    }

    /// Positive, deliberately narrow needs-input shapes. A question mark alone
    /// is insufficient: final explanations routinely contain rhetorical questions.
    static func humanPromptEvidence(in text: String?) -> HumanPromptEvidence? {
        guard let text else { return nil }
        let normalized = text.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        let planShapes = [
            "approve the plan", "plan approval", "approve this plan",
            "ready to proceed with this plan", "exit plan mode",
        ]
        if planShapes.contains(where: normalized.contains) { return .planApproval }

        let yesNoShapes = [
            "(y/n)", "[y/n]", "yes/no", "yes or no", "do you want me to",
            "would you like me to", "should i proceed", "may i proceed", "shall i proceed",
        ]
        if yesNoShapes.contains(where: normalized.contains) { return .yesNo }

        let permissionWord = normalized.contains("permission") || normalized.contains("approval required")
        let permissionAction = ["allow", "approve", "required", "need", "grant"]
            .contains(where: normalized.contains)
        if permissionWord && permissionAction { return .permission }
        return nil
    }

    /// Walk transcript tail lines in order, matching tool_use ids to their
    /// tool_result ids, and record the tail's shape. Tail-safe: an unmatched
    /// `tool_result` (its tool_use fell before the window) is simply ignored, so
    /// reading only the tail never invents a dangling call.
    public static func extract(fromTailLines lines: [Data]) -> AttentionSignals {
        var open: Set<String> = []          // tool_use ids still awaiting a result
        var lastKind: LastKind = .none
        var lastStop: String? = nil
        var lastEventAt: Date? = nil
        var lastToolActivityAt: Date? = nil
        var lastToolName: String? = nil     // freshest tool_use in the tail → now-line
        var lastToolDetail: String? = nil
        var lastAssistantText: String? = nil
        var hasPermissionGate = false

        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if (obj["isMeta"] as? Bool) == true { continue }
            let ts = parseDate(obj["timestamp"] as? String)

            switch type {
            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { break }
                var sawContent = false
                var assistantTexts: [String] = []
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_use":
                        if let id = b["id"] as? String { open.insert(id) }
                        lastKind = .toolUse
                        lastEventAt = ts
                        lastToolActivityAt = ts
                        // Capture the now-line: freshest tool_use wins (overwrite),
                        // reusing the live feed's exact detail extraction.
                        if let name = b["name"] as? String {
                            lastToolName = name
                            let d = TranscriptParser.toolDetail(name: name,
                                                                input: (b["input"] as? [String: Any]) ?? [:])
                            lastToolDetail = d.isEmpty ? nil : d
                        }
                        sawContent = true
                    case "text":
                        let t = (b["text"] as? String) ?? ""
                        if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lastKind = .assistantText
                            lastEventAt = ts
                            assistantTexts.append(t)
                            sawContent = true
                        }
                    case "thinking":
                        lastKind = .thinking
                        lastEventAt = ts
                        sawContent = true
                    default:
                        break
                    }
                }
                if sawContent {
                    lastStop = msg["stop_reason"] as? String
                    lastAssistantText = assistantTexts.isEmpty
                        ? nil
                        : assistantTexts.joined(separator: "\n")
                    // Any later assistant activity proves an earlier permission
                    // record is no longer the tail gate.
                    hasPermissionGate = false
                }

            case "user":
                guard let msg = obj["message"] as? [String: Any] else { break }
                if let blocks = msg["content"] as? [[String: Any]] {
                    var sawResult = false, sawText = false
                    for b in blocks {
                        switch b["type"] as? String {
                        case "tool_result":
                            if let id = b["tool_use_id"] as? String { open.remove(id) }
                            sawResult = true
                        case "text":
                            let t = (b["text"] as? String) ?? ""
                            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sawText = true }
                        default:
                            break
                        }
                    }
                    if sawResult {
                        lastKind = .toolResult
                        lastEventAt = ts
                        lastToolActivityAt = ts
                        hasPermissionGate = false
                    }
                    if sawText {                 // a typed prompt outranks the auto tool_result wrapper
                        lastKind = .userPrompt
                        lastEventAt = ts
                        lastStop = nil
                        hasPermissionGate = false
                    }
                } else if let s = msg["content"] as? String, !s.isEmpty {
                    lastKind = .userPrompt
                    lastEventAt = ts
                    lastStop = nil
                }

            case "system":
                lastKind = .system
                lastEventAt = ts

            case "permission-request", "permission_request":
                // Future- and fixture-safe support for Claude's explicit pending
                // permission records. Resolved/denied records are not pending.
                let decision = ((obj["decision"] as? String)
                    ?? (obj["status"] as? String) ?? "pending").lowercased()
                hasPermissionGate = ["pending", "requested", "waiting"].contains(decision)
                if hasPermissionGate {
                    lastKind = .system
                    lastEventAt = ts
                }

            default:
                break                            // summary / queue-op / snapshot / progress
            }
        }

        // Dangling iff the tail ENDS on an unresolved tool_use. Tying it to the
        // last kind (not merely a non-empty open set) avoids a stale tool_use from
        // earlier in the tail — since resolved by later work — reading as blocked.
        let dangling = !open.isEmpty && lastKind == .toolUse
        return AttentionSignals(
            lastEventAt: lastEventAt,
            lastKind: lastKind,
            lastStopReason: lastStop,
            hasDanglingToolUse: dangling,
            danglingToolUseAt: dangling ? lastEventAt : nil,
            lastToolActivityAt: lastToolActivityAt,
            lastToolName: lastToolName,
            lastToolDetail: lastToolDetail,
            lastAssistantText: lastAssistantText,
            hasPermissionGate: hasPermissionGate
        )
    }

    /// Read a provider transcript's bounded tail and extract its native signals.
    /// Compressed Codex rollouts pass through the bounded decompressor first.
    public static func extractFromTail(
        path: String,
        provider: Provider = .claude,
        tailBytes: Int = 256_000
    ) -> AttentionSignals? {
        let lines: [Data]?
        if provider == .codex, path.hasSuffix(".jsonl.zst") {
            guard let data = CodexRolloutFile.data(at: URL(fileURLWithPath: path)) else {
                return nil
            }
            let bounded = max(1, tailBytes)
            lines = splitTail(
                Data(data.suffix(bounded)),
                droppingPartialHead: data.count > bounded)
        } else {
            lines = readTailLines(path: path, tailBytes: tailBytes)
        }
        guard let lines else { return nil }
        switch provider {
        case .claude:
            return extract(fromTailLines: lines)
        case .codex:
            return CodexRolloutAccumulator.attentionSignals(fromTailLines: lines)
        }
    }

    private static func readTailLines(path: String, tailBytes: Int) -> [Data]? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let bounded = UInt64(max(1, tailBytes))
        let start = size > bounded ? size - bounded : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return splitTail(data, droppingPartialHead: start > 0)
    }

    private static func splitTail(_ data: Data,
                                  droppingPartialHead: Bool) -> [Data] {
        var lines = data.split(separator: UInt8(0x0A)).map { Data($0) }
        if droppingPartialHead, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

// MARK: - One classified live session

public struct AttentionItem: Identifiable, Sendable, Hashable {
    public var id: String { session.id }
    public let session: SessionSummary
    public let state: AttentionState
    /// Seconds since the session's last activity (for the chip's "2m" age).
    public let age: TimeInterval
    public let classifierConfidence: AttentionClassification.Confidence
    public let classifierReason: String

    public init(session: SessionSummary, state: AttentionState, age: TimeInterval,
                classifierConfidence: AttentionClassification.Confidence = .low,
                classifierReason: String = "state supplied without classifier evidence") {
        self.session = session
        self.state = state
        self.age = age
        self.classifierConfidence = classifierConfidence
        self.classifierReason = classifierReason
    }

    public var needsAttention: Bool { state.needsAttention }
    public var classifierDiagnostic: String {
        "\(classifierConfidence.rawValue): \(classifierReason)"
    }
}

// MARK: - The attention board (the sorted, counted heart)

public struct AttentionBoard: Sendable, Equatable {
    /// All in-window sessions, sorted BLOCKED → WAITING → RUNNING → IDLE, then by
    /// recency (freshest first).
    public let items: [AttentionItem]
    public let counts: [AttentionState: Int]

    public init(items: [AttentionItem], counts: [AttentionState: Int]) {
        self.items = items
        self.counts = counts
    }

    public func count(_ s: AttentionState) -> Int { counts[s] ?? 0 }
    public var blockedCount: Int { count(.blocked) }
    public var waitingCount: Int { count(.waiting) }
    public var runningCount: Int { count(.running) }
    public var idleCount: Int { count(.idle) }

    /// The chips the strip actually surfaces: BLOCKED then WAITING (already sorted).
    public var needsAttention: [AttentionItem] { items.filter(\.needsAttention) }

    /// The single worst state present — drives the dock badge / menu-bar glyph.
    /// nil when the board is empty.
    public var worst: AttentionState? { items.first?.state }

    /// The window beyond `isActive` (15m) that keeps a cooling session visible as
    /// IDLE for a while before it drops off the board entirely.
    public static let defaultWindow: TimeInterval = 60 * 60

    /// Build the board. Subagent transcripts are excluded — nobody gates a
    /// subagent (its parent orchestration does), so they can never be BLOCKED-on-you.
    /// `signals` is a per-session-id map from the tail extractor; a session with no
    /// entry yet falls back to a bare last-activity signal (→ RUNNING/IDLE by age).
    public static func build(sessions: [SessionSummary],
                             signals: [String: AttentionSignals],
                             now: Date,
                             window: TimeInterval = defaultWindow) -> AttentionBoard {
        var items: [AttentionItem] = []
        for s in sessions {
            // Window check FIRST: it is two Date compares, while `isSubagent`
            // is a substring scan of the file path — running the scan on all
            // 5.3k sessions (instead of the ~dozen in-window) measured ~17ms
            // per build on the main thread.
            guard let last = s.lastActivity else { continue }
            let age = now.timeIntervalSince(last)
            guard age >= 0, age <= window else { continue }
            guard !s.isSubagent else { continue }
            var sig = signals[s.id] ?? AttentionSignals(lastEventAt: last)
            if sig.lastEventAt == nil { sig.lastEventAt = last }   // never lose the recency anchor
            let classification = AttentionState.classifyDetailed(sig, now: now)
            items.append(AttentionItem(
                session: s,
                state: classification.state,
                age: age,
                classifierConfidence: classification.confidence,
                classifierReason: classification.reason))
        }
        items.sort {
            $0.state.sortRank != $1.state.sortRank
                ? $0.state.sortRank < $1.state.sortRank
                : $0.age < $1.age
        }
        var counts: [AttentionState: Int] = [:]
        for it in items { counts[it.state, default: 0] += 1 }
        return AttentionBoard(items: items, counts: counts)
    }
}

// MARK: - Attention store (signals for the live pool)
// Holds the per-session tail signals. Refreshed by reading each candidate
// transcript's tail OFF the main actor — only the live/recent pool, a handful of
// files, so it stays cheap even beside a multi-GB corpus. The time-dependent
// classification (`AttentionBoard.build`) happens fresh at render time against a
// heartbeat `now`, so states advance (RUNNING→BLOCKED, WAITING→IDLE) without any
// new file I/O.

@MainActor
public final class AttentionStore: ObservableObject {
    @Published public private(set) var signals: [String: AttentionSignals] = [:]
    /// Monotonic stamp, bumped on every real `signals` assignment — pairs with
    /// `SessionStore.revision` so the attention-board memo invalidates with two
    /// Int compares. Not @Published: it rides the assignment's own publish.
    public private(set) var revision = 0

    public init() {}

    /// Recompute signals for the given candidate sessions. `candidates` should
    /// already be the recent pool (AppServices filters by the board window); this
    /// only reads their tails.
    public func refresh(candidates: [SessionSummary], tailBytes: Int = 256_000) async {
        let jobs: [(String, String, Provider)] = candidates
            .filter { !$0.isSubagent && !$0.filePath.isEmpty }
            .map { ($0.id, $0.filePath, $0.provider) }
        let result = await Task.detached(priority: .userInitiated) {
            var out: [String: AttentionSignals] = [:]
            for (id, path, provider) in jobs {
                if let sig = AttentionSignals.extractFromTail(
                    path: path, provider: provider, tailBytes: tailBytes) {
                    out[id] = sig
                }
            }
            return out
        }.value
        // Compare-before-assign (W6 wave 4): unchanged tails must not publish —
        // every publish re-evaluates the strip, the Floor, and the palette.
        if signals != result {
            signals = result
            revision += 1
        }
    }
}
