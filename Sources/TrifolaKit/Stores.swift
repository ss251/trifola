import Foundation
import Combine

// Lenient decoding helpers ------------------------------------------------
// Transcript lines are parsed with JSONSerialization (Foundation's C parser),
// not JSONDecoder — over a multi-GB corpus that is a 3-4x throughput difference,
// and it is exactly as lenient as the old Decodable shape: any JSON *object*
// counts as a message; missing/mistyped fields simply read as nil.

/// Minimal thread-safe box for the parallel scan's shared state (macOS 15 floor,
/// so `Synchronization.Mutex` is not guaranteed; NSLock is plenty here).
public final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    public init(_ value: T) { self.value = value }
    public func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

// ISO8601DateFormatter is documented thread-safe; shared to avoid per-line allocation.
nonisolated(unsafe) private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
nonisolated(unsafe) private let isoPlain = ISO8601DateFormatter()

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    if let d = isoFractional.date(from: s) { return d }
    return isoPlain.date(from: s)
}

// LOCAL calendar-day key ("yyyy-MM-dd") for per-message-day burn bucketing. Uses
// the machine's current time zone so a message is bucketed on the day the human
// saw it — matching how the burn governor (default `.current` calendar) reads the
// key back. Shared to avoid per-line allocation; DateFormatter is thread-safe for
// read-only `string(from:)` here.
private let localDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func localDayKey(_ date: Date) -> String { localDayFormatter.string(from: date) }
/// Explicit-time-zone seam used to prove that one instant belongs to different
/// persisted day buckets after travel. The hot parser path above keeps its
/// shared formatter; this helper is for cache identity tests and diagnostics.
func localDayKey(_ date: Date, timeZone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}
func localDayKey(fromTimestamp s: String?) -> String? {
    guard let d = parseDate(s) else { return nil }
    return localDayFormatter.string(from: d)
}

// MARK: - Session accumulator
// The exact per-line aggregation the original scan performed, factored out so the
// same logic serves full scans, incremental (append-only) updates, and tests.

public struct SessionAccumulator: Sendable, Codable {
    var model: String?
    var cwd = ""
    var sid: String
    var last: Date?
    var count = 0
    /// One deduped assistant message's billed usage, tagged with the NORMALIZED
    /// model id that billed it (W2 — the pricing catalog keys on exact model,
    /// not tier) and the local calendar day it landed on. The display tier
    /// derives from the model id (`ModelTier(raw:)`).
    struct KeyedUsage: Sendable, Codable {
        var usage: SessionUsage
        var model: String
        var day: String
        var usesUnsupportedPricingMode: Bool = false
        /// Copied-history reconciliation prefers a canonical non-sidechain row
        /// when the same message/request pair appears in multiple transcripts.
        var isSidechain: Bool = false
        var tier: ModelTier { ModelTier(raw: model) }
    }
    /// Billed usage keyed per assistant message ("<message.id>:<requestId>").
    /// Claude Code writes MULTIPLE streaming lines per message — all sharing that
    /// id pair and each carrying CUMULATIVE usage — so the last-wins overwrite
    /// here collapses them to the final chunk instead of summing (which
    /// over-counted spend ~2.6x). Lines missing either id are older logs; each is
    /// kept distinct under a synthetic "#<n>" key, matching CodexBar. `usage`,
    /// `usageByTier`, and `usageByDay` all DERIVE from this deduped map, and it is
    /// held in accumulator state so an incremental tail-append updates the right
    /// key (a streaming message that straddles an append boundary still collapses).
    var usageByKey: [String: KeyedUsage] = [:]
    /// Monotonic counter minting synthetic keys for usage lines lacking a
    /// message.id/requestId — keeps each distinct across full + incremental parses.
    var unkeyedSeq: Int = 0
    /// RAW assistant usage-block count BEFORE the dedup — every streaming line
    /// that carried a `usage` object increments this, while `usageByKey`
    /// collapses them last-chunk-wins. The pair is the receipt's dedup note
    /// ("N raw usage blocks → M unique messageId:requestId", W3 provenance).
    var rawUsageBlocks: Int = 0
    /// Deduped entries carrying a non-standard `usage.speed` or
    /// `usage.service_tier`. Counted from the final last-chunk-wins map.
    var unsupportedPricingEntryCount: Int {
        usageByKey.values.reduce(0) { $0 + ($1.usesUnsupportedPricingMode ? 1 : 0) }
    }
    /// Deduped total usage — the sum of the per-message map (last cumulative
    /// chunk per key). Replaces the old per-line running sum.
    var usage: SessionUsage {
        usageByKey.values.reduce(SessionUsage()) { $0 + $1.usage }
    }
    /// Deduped usage bucketed by the model that billed it, keyed per assistant
    /// message — NOT one running total tagged with whichever model answered last.
    var usageByTier: [ModelTier: SessionUsage] {
        var out: [ModelTier: SessionUsage] = [:]
        for k in usageByKey.values { out[k.tier] = (out[k.tier] ?? SessionUsage()) + k.usage }
        return out
    }
    /// Deduped usage bucketed by local calendar day, then by billing tier — the
    /// honest per-message-day map the burn governor sums across sessions.
    var usageByDay: [String: [ModelTier: SessionUsage]] {
        var out: [String: [ModelTier: SessionUsage]] = [:]
        for k in usageByKey.values where !k.day.isEmpty {
            out[k.day, default: [:]][k.tier] = (out[k.day]?[k.tier] ?? SessionUsage()) + k.usage
        }
        return out
    }
    /// Deduped usage bucketed by NORMALIZED model id (W2) — what the pricing
    /// catalog prices exactly.
    var usageByModel: [String: SessionUsage] {
        var out: [String: SessionUsage] = [:]
        for k in usageByKey.values { out[k.model] = (out[k.model] ?? SessionUsage()) + k.usage }
        return out
    }
    /// Day → normalized model → usage, INCLUDING an "" day bucket for undated
    /// lines so `SessionSummary.cost` covers every message (the burn governor
    /// skips the "" key — an unparseable day never lands on a calendar).
    var usageByModelDay: [String: [String: SessionUsage]] {
        var out: [String: [String: SessionUsage]] = [:]
        for k in usageByKey.values {
            out[k.day, default: [:]][k.model] = (out[k.day]?[k.model] ?? SessionUsage()) + k.usage
        }
        return out
    }
    /// Day → normalized model → DEDUPED billed-message count (one per unique
    /// usage key) — the "N msgs" each receipt leg carries (W3 provenance).
    var messagesByModelDay: [String: [String: Int]] {
        var out: [String: [String: Int]] = [:]
        for k in usageByKey.values {
            out[k.day, default: [:]][k.model, default: 0] += 1
        }
        return out
    }
    /// Model tiers that ANY assistant message ran under — independent of whether
    /// that message recorded a `usage` block. This is what the subagent-doctrine
    /// audit keys on ("did this run touch Custom?"), matching the `.message.model`
    /// signal; `usageByTier` alone undercounts by the messages that billed nothing.
    var tiersSeen: Set<ModelTier> = []
    /// Assistant TURNS per NORMALIZED model id — every assistant message counted
    /// once whether or not it carried a usage block (W5). Consecutive streaming
    /// lines share `message.id` and collapse to one turn; `messagesByModelDay`
    /// can't serve here because it misses unbilled turns. This is the
    /// Opus-fallback detector's denominator ("2 of 14 assistant turns ran on Opus").
    var assistantTurnsByModel: [String: Int] = [:]
    /// The last assistant `message.id` seen — a turn is counted only when the id
    /// CHANGES. Persisted in the accumulator so a streaming message that
    /// straddles an incremental append boundary still counts once.
    var lastAssistantMessageID: String?
    /// REROUTE RECEIPTS (spree #2): mid-session model changes, captured at the
    /// assistant-turn boundary above — a flip is minted when a turn's
    /// normalized model differs from the PREVIOUS turn's. `<synthetic>` error
    /// placeholders are ignored (an API error is not a model change). Capped
    /// to bound the index cache.
    var modelFlips: [ModelFlip] = []
    /// Normalized model of the previous REAL assistant turn (synthetic skipped).
    var lastTurnModel: String?
    /// True when a `/model` command line appeared since the last assistant
    /// turn — the next flip is then a deliberate switch (`userInitiated`),
    /// listed but never counted as a silent reroute. Persisted so a `/model`
    /// straddling an incremental append boundary still marks the flip.
    var sawModelCommandSinceTurn = false
    /// Per-session cap on stored flips (bounds the on-disk index cache).
    static let maxStoredFlips = 100
    /// TOTAL `tool_use` blocks, any tool — the shape signal the Custom-vs-Opus
    /// readout bands on (W5). `skillInvocations`/`agentCalls`/`fileEdits` are
    /// named slices of this census.
    var toolCalls = 0
    /// File paths written/edited (Write/Edit/NotebookEdit/MultiEdit `file_path`
    /// / `notebook_path` inputs), keyed by the NORMALIZED model id of the
    /// assistant message that made the call — deduped in first-write order and
    /// capped at `maxStoredFilePaths` per session to bound the index cache.
    /// The Custom Ledger (W5) reads the custom legs: "Access to Custom expires on
    /// the 7th, but the files it wrote don't" (@0x_kaize, research §3.2).
    var filesTouchedByModel: [String: [String]] = [:]
    /// Total stored paths across models (the cap counter).
    var storedFilePaths = 0
    /// Per-session cap on captured file paths (bounds the on-disk index cache).
    static let maxStoredFilePaths = 200
    var contextWeight = 0
    /// Explicit `Skill` tool invocations, keyed by `skill` arg → count (the
    /// dead-skill ledger's raw material). Auto-loaded skills are not counted.
    var skillInvocations: [String: Int] = [:]
    /// Slash-command invocations (`<command-name>` transcript tags) → count.
    /// Covers BOTH shapes: user lines whose message.content carries the tag, and
    /// system lines whose top-level `content` carries it. Names are stored without
    /// the leading "/" (namespaced plugin names like "codex:rescue" kept intact).
    /// Task #41: skills fired via slash commands produced NO Skill tool_use, so the
    /// dead-skill ledger overcounted until this census existed.
    var commandInvocations: [String: Int] = [:]
    /// `Agent`/`Task` tool-call count (orchestration signal, model-mismatch).
    var agentCalls = 0
    struct PendingSubagentCall: Sendable, Codable {
        var agentType: String?
        var requestedModel: String?
    }
    /// Agent tool_use id → declared call shape until its tool_result supplies
    /// the stable agentId/resolvedModel join.
    var pendingSubagentCalls: [String: PendingSubagentCall] = [:]
    /// Completed parent→subagent legs. The child filename is agent-<agentId>.jsonl.
    var subagentInvocations: [SubagentInvocation] = []
    /// `Edit`/`Write`/`NotebookEdit`/`MultiEdit` tool-call count.
    var fileEdits = 0
    /// The transcript's auto topic title (`type:"ai-title"` record) — the name
    /// fallback when no live-registry/rename name exists for the session.
    var aiTitle: String?
    /// Cached human handle derived while streaming the transcript. Rank keeps
    /// the precedence stable even when records arrive in the opposite order:
    /// first meaningful user prompt (1) < summary (2) < ai-title (3).
    var derivedHandle: String?
    var handleSourceRank = 0
    /// Most recent human-typed prompt (tool-result/meta "user" lines don't count).
    var lastUserMessage: String?
    /// Total bytes fed into the accumulator (complete + pending partial line).
    var bytesIngested: UInt64 = 0
    /// Trailing bytes not yet terminated by a newline.
    var pending = Data()

    public init(defaultID: String) { self.sid = defaultID }

    private mutating func considerHandle(_ raw: String?, rank: Int,
                                         userMessage: Bool = false) {
        let candidate = userMessage
            ? SessionHandles.fromFirstUserMessage(raw)
            : SessionHandles.record(raw)
        guard let candidate,
              rank > handleSourceRank || (rank >= 2 && rank == handleSourceRank)
        else { return }
        derivedHandle = candidate
        handleSourceRank = rank
    }

    /// "<command-name>/commit</command-name>…" → "commit"; nil when absent/empty.
    static func extractCommandName(_ text: String) -> String? {
        guard let start = text.range(of: "<command-name>"),
              let end = text.range(of: "</command-name>", range: start.upperBound..<text.endIndex)
        else { return nil }
        var name = String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("/") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// Feed a chunk of file bytes. Complete lines are consumed; a trailing
    /// unterminated line is held in `pending` until more bytes arrive.
    public mutating func ingest(_ data: Data) {
        bytesIngested += UInt64(data.count)
        var buf = pending
        buf.append(data)
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            if nl > start { consume(line: buf.subdata(in: start..<nl)) }
            start = buf.index(after: nl)
        }
        pending = start < buf.endIndex ? Data(buf[start...]) : Data()
    }

    private mutating func consume(line data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        count += 1
        if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
        if let s = obj["sessionId"] as? String, !s.isEmpty { sid = s }
        if obj["type"] as? String == "ai-title",
           let title = obj["aiTitle"] as? String, !title.isEmpty {
            aiTitle = title
            considerHandle(title, rank: 3)
        }
        if obj["type"] as? String == "summary" {
            considerHandle(obj["summary"] as? String, rank: 2)
        }
        if let d = parseDate(obj["timestamp"] as? String) { if last == nil || d > last! { last = d } }
        // Slash-command census, Shape B (task #41) — system lines whose top-level
        // `content` string carries a `<command-name>` tag (CLI built-ins like
        // /doctor, /login mostly land here). Independent of the user-message
        // block below; see `extractCommandName`.
        if obj["type"] as? String == "system", let c = obj["content"] as? String,
           let name = Self.extractCommandName(c) {
            commandInvocations[name, default: 0] += 1
            // A `/model` line arms the deliberate-switch flag: the NEXT
            // assistant turn's model change is user-initiated, not a reroute.
            if name == "model" { sawModelCommandSinceTurn = true }
        }
        // Only REAL human prompts update lastUserMessage. Skip synthetic user
        // messages: `isMeta`, and the compaction continuation Claude Code injects
        // on auto-compact (`isCompactSummary`/`isVisibleInTranscriptOnly`, a giant
        // "This session is being continued…" blob that is NOT flagged isMeta).
        // Letting the summary win poisons any session-transport match that
        // fingerprints a session by its last submitted prompt.
        if obj["type"] as? String == "user", (obj["isMeta"] as? Bool) != true,
           (obj["isCompactSummary"] as? Bool) != true,
           (obj["isVisibleInTranscriptOnly"] as? Bool) != true,
           let text = Self.extractUserText(obj) {
            lastUserMessage = text
            considerHandle(text, rank: 1, userMessage: true)
        }
        // Slash-command census, Shape A (task #41) — user lines whose
        // message.content (a plain string, or the first `text` block when it's
        // an array) carries the raw `<command-name>` tag. Parsed independently
        // of `extractUserText`'s cleaned output: `cleanUserText` REWRITES the
        // tag into "/name args", it does not drop it, so relying on that output
        // would mean re-parsing a different (already-transformed) string.
        if obj["type"] as? String == "user", let message = obj["message"] as? [String: Any] {
            var raw: String?
            if let s = message["content"] as? String {
                raw = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                raw = blocks.first { ($0["type"] as? String) == "text" }?["text"] as? String
            }
            if let raw, let name = Self.extractCommandName(raw) {
                commandInvocations[name, default: 0] += 1
                // Same deliberate-switch arming as Shape B — `/model` lands in
                // either shape depending on CLI version.
                if name == "model" { sawModelCommandSinceTurn = true }
            }

            // N1 model-pin join: the parent Agent call records the requested
            // model on tool_use; its result records agentId + resolvedModel.
            // Preserve the completed leg so the child transcript can be joined
            // without re-reading the parent JSONL in the detector.
            if let blocks = message["content"] as? [[String: Any]],
               let result = obj["toolUseResult"] as? [String: Any] {
                for block in blocks where (block["type"] as? String) == "tool_result" {
                    guard let toolUseID = block["tool_use_id"] as? String,
                          let pending = pendingSubagentCalls.removeValue(forKey: toolUseID),
                          let agentID = (result["agentId"] as? String)
                              ?? (result["agent_id"] as? String),
                          !agentID.isEmpty else { continue }
                    guard !subagentInvocations.contains(where: { $0.agentID == agentID }) else { continue }
                    subagentInvocations.append(SubagentInvocation(
                        agentID: agentID,
                        agentType: (result["agentType"] as? String) ?? pending.agentType,
                        requestedModel: pending.requestedModel,
                        resolvedModel: result["resolvedModel"] as? String))
                }
            }
        }
        if obj["type"] as? String == "assistant", let m = obj["message"] as? [String: Any] {
            if let mm = m["model"] as? String {
                model = mm
                tiersSeen.insert(ModelTier(raw: mm))
                // Turn census (W5): consecutive streaming lines share message.id —
                // count a turn only when the id changes. Lines with no id (older
                // logs) each count, matching the usage dedup's synthetic-key rule.
                let mid = m["id"] as? String
                if mid == nil || mid != lastAssistantMessageID {
                    let norm = PricingCatalog.normalize(mm)
                    assistantTurnsByModel[norm, default: 0] += 1
                    // REROUTE RECEIPTS (spree #2): a turn on a DIFFERENT model
                    // than the previous turn mints a flip — positionally, so
                    // the `/model` flag decides deliberate-vs-silent inline.
                    // `<synthetic>` (API-error placeholder) is not a model:
                    // it neither flips nor consumes the flag.
                    if !norm.isEmpty, !norm.contains("synthetic") {
                        if let prev = lastTurnModel, prev != norm,
                           modelFlips.count < Self.maxStoredFlips {
                            modelFlips.append(ModelFlip(
                                fromModel: prev, toModel: norm,
                                timestamp: parseDate(obj["timestamp"] as? String),
                                day: localDayKey(fromTimestamp: obj["timestamp"] as? String) ?? "",
                                messageID: mid,
                                userInitiated: sawModelCommandSinceTurn))
                        }
                        lastTurnModel = norm
                        sawModelCommandSinceTurn = false
                    }
                }
                lastAssistantMessageID = mid
            }
            // Tool-call census: Skill (dead-skill ledger), Agent/Task
            // (orchestration signal), Edit/Write (touch signal). Same block walk
            // the transcript parser does, but counted, not rendered.
            if let blocks = m["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    toolCalls += 1
                    switch b["name"] as? String {
                    case "Skill":
                        if let input = b["input"] as? [String: Any],
                           let sk = (input["skill"] as? String), !sk.isEmpty {
                            skillInvocations[sk, default: 0] += 1
                        }
                    case "Agent", "Task":
                        agentCalls += 1
                        if let id = b["id"] as? String, pendingSubagentCalls[id] == nil {
                            let input = b["input"] as? [String: Any]
                            pendingSubagentCalls[id] = PendingSubagentCall(
                                agentType: (input?["subagent_type"] as? String)
                                    ?? (input?["agent_type"] as? String),
                                requestedModel: input?["model"] as? String)
                        }
                    case "Edit", "Write", "NotebookEdit", "MultiEdit":
                        fileEdits += 1
                        // CUSTOM ESTATE (W5): record WHICH file this model touched.
                        // `model` was set from this same message object above, so
                        // the attribution is the message's own model. Deduped in
                        // first-write order, capped per session.
                        if storedFilePaths < Self.maxStoredFilePaths,
                           let input = b["input"] as? [String: Any],
                           let path = (input["file_path"] as? String)
                               ?? (input["notebook_path"] as? String),
                           !path.isEmpty {
                            let key = PricingCatalog.normalize(model)
                            if !key.isEmpty, filesTouchedByModel[key]?.contains(path) != true {
                                filesTouchedByModel[key, default: []].append(path)
                                storedFilePaths += 1
                            }
                        }
                    default:
                        break
                    }
                }
            }
            if let u = m["usage"] as? [String: Any] {
                rawUsageBlocks += 1
                let inp = max(0, (u["input_tokens"] as? Int) ?? 0)
                let out = max(0, (u["output_tokens"] as? Int) ?? 0)
                let cw = max(0, (u["cache_creation_input_tokens"] as? Int) ?? 0)
                let cr = max(0, (u["cache_read_input_tokens"] as? Int) ?? 0)
                // The 5m/1h cache-write split: `usage.cache_creation.
                // ephemeral_1h_input_tokens` is the 1h slice billed at 2× (the
                // 5m remainder bills 1.25×). Absent on older transcripts → 0.
                let cw1h = min(cw, max(0, ((u["cache_creation"] as? [String: Any])?[
                    "ephemeral_1h_input_tokens"] as? Int) ?? 0))
                let pricingModes = [u["speed"], u["service_tier"]]
                    .compactMap { ($0 as? String)?.lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let usesUnsupportedPricingMode = pricingModes.contains { $0 != "standard" }
                let msgUsage = SessionUsage(
                    inputTokens: inp, outputTokens: out,
                    cacheCreateTokens: cw, cacheReadTokens: cr,
                    cacheCreate1hTokens: cw1h
                )
                // Copied/replayed transcript history can append a zeroed usage
                // placeholder for an earlier message after its real cumulative
                // row. It is not a billable chunk and must not erase the last
                // non-zero row for that message/request pair (CodexBar skips the
                // same shape before in-file dedup). Keep rawUsageBlocks honest,
                // but leave keyed usage and context weight untouched.
                guard msgUsage.total > 0 else { return }
                // Attribute THIS message's usage to the model that actually billed
                // it, not to whichever model happens to answer last in the file —
                // recorded as the NORMALIZED id the pricing catalog keys on.
                let msgModel = PricingCatalog.normalize(model)
                // Bucket by THIS message's own timestamp day (local) — falls back
                // to the last-seen timestamp if the line carries none.
                let dayKey = (localDayKey(fromTimestamp: obj["timestamp"] as? String)
                    ?? last.map(localDayKey(_:))) ?? ""
                // Dedup: Claude Code emits several streaming lines per assistant
                // message, each sharing message.id + requestId and carrying
                // CUMULATIVE usage. Keep the LAST (overwrite) so the final
                // cumulative chunk wins — summing them over-counted ~2.6x. Lines
                // missing either id are kept distinct (synthetic key).
                let key: String
                if let mid = m["id"] as? String, !mid.isEmpty,
                   let rid = obj["requestId"] as? String, !rid.isEmpty {
                    key = "\(mid):\(rid)"
                } else {
                    key = "#\(unkeyedSeq)"
                    unkeyedSeq += 1
                }
                usageByKey[key] = KeyedUsage(
                    usage: msgUsage, model: msgModel, day: dayKey,
                    usesUnsupportedPricingMode: usesUnsupportedPricingMode,
                    isSidechain: (obj["isSidechain"] as? Bool) == true)
                // context weight = what the MOST RECENT message resent (the "$20 hey"
                // metric). The last streaming chunk carries the full cumulative usage,
                // so the last line processed is the right one — set unconditionally.
                contextWeight = inp + cw + cr
            }
        }
    }

    /// Human-authored text from a `type: "user"` transcript line, or nil if this
    /// is a tool_result continuation (an automatic function-result turn, not
    /// something a person typed) or otherwise carries no real prompt text.
    /// `message.content` is either a plain string (a typed prompt) or an array
    /// of content blocks — only `text` blocks count; `tool_result` blocks are
    /// the auto-continuation wrapper and are skipped. Reuses the same cleanup
    /// (`<command-name>`/`system-reminder` stripping, etc.) the transcript
    /// viewer applies, so this is exactly "what the user would see as their
    /// prompt".
    static func extractUserText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String {
            return TranscriptParser.cleanUserText(s)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text", let t = block["text"] as? String else { return nil }
            return TranscriptParser.cleanUserText(t)
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: " ")
    }

    /// Snapshot into a SessionSummary. A trailing unterminated line is parsed
    /// provisionally (matching the original whole-file scan) without advancing
    /// the durable byte offset, so a later append can re-deliver it safely.
    public func summary(filePath: String,
                        excludingUsageKeys: Set<String> = []) -> SessionSummary {
        var snap = self
        if !snap.pending.isEmpty { snap.consume(line: snap.pending) }
        if !excludingUsageKeys.isEmpty {
            snap.usageByKey = snap.usageByKey.filter {
                !excludingUsageKeys.contains($0.key)
            }
        }
        let project = snap.cwd.isEmpty ? "—" : (snap.cwd as NSString).lastPathComponent
        // Subagent transcripts inherit the parent's sessionId, so `sid` alone is
        // NOT unique across files — duplicate Identifiable ids make SwiftUI
        // ForEach render one row N times. Suffix the agent file stem to keep
        // ids unique-per-file while preserving the parent-session prefix.
        var id = snap.sid
        if filePath.contains("/subagents/") {
            let stem = ((filePath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            id = "\(snap.sid)/\(stem)"
        }
        return SessionSummary(id: id, project: project, cwd: snap.cwd,
                              model: snap.model, lastActivity: snap.last,
                              messageCount: snap.count, usage: snap.usage,
                              contextWeight: snap.contextWeight, filePath: filePath,
                              lastUserMessage: snap.lastUserMessage,
                              name: snap.aiTitle,
                              handle: snap.derivedHandle ?? SessionHandles.untitled,
                              usageByTier: snap.usageByTier,
                              usageByDay: snap.usageByDay,
                              usageByModel: snap.usageByModel,
                              usageByModelDay: snap.usageByModelDay,
                              messagesByModelDay: snap.messagesByModelDay,
                              rawUsageBlocks: snap.rawUsageBlocks,
                              unsupportedPricingEntryCount: snap.unsupportedPricingEntryCount,
                              skillInvocations: snap.skillInvocations,
                              commandInvocations: snap.commandInvocations,
                              agentCalls: snap.agentCalls,
                              subagentInvocations: snap.subagentInvocations,
                              fileEdits: snap.fileEdits,
                              tiersSeen: snap.tiersSeen,
                              assistantTurnsByModel: snap.assistantTurnsByModel,
                              toolCalls: snap.toolCalls,
                              filesTouchedByModel: snap.filesTouchedByModel,
                              modelFlips: snap.modelFlips)
            // Price ONCE at build time (this runs in the parallel scan / cache
            // load, off-main) so no view body or store refresh ever re-walks
            // the per-slice pricing math on the main actor.
            .computingCostBundle()
    }

    /// File offset the next incremental read should start from.
    var resumeOffset: UInt64 { bytesIngested - UInt64(pending.count) }
}

// MARK: - Session sources + parser state

/// One explicitly bounded transcript source. Provider-specific acceptance and
/// parsing live at this seam; the index's stat/reuse/progress machinery stays
/// shared. Codex sources point at the sessions directory, never its parent.
public struct SessionSource: Sendable, Equatable {
    public let root: URL
    public let provider: Provider
    public let machineID: String
    let importManifestURL: URL?

    public init(root: URL, provider: Provider,
                machineID: String = Machine.localID,
                importManifestURL: URL? = nil) {
        self.root = root.standardizedFileURL
        self.provider = provider
        self.machineID = machineID
        self.importManifestURL = importManifestURL?.standardizedFileURL
    }

    public static func claude(root: URL,
                              machineID: String = Machine.localID) -> SessionSource {
        SessionSource(root: root, provider: .claude, machineID: machineID)
    }

    public static func codex(root: URL,
                             machineID: String = Machine.localID,
                             importManifestURL: URL? = nil) -> SessionSource {
        let manifest = importManifestURL
            ?? root.deletingLastPathComponent()
                .appendingPathComponent("external_agent_session_imports.json")
        return SessionSource(root: root, provider: .codex,
                             machineID: machineID,
                             importManifestURL: manifest)
    }

    func accepts(_ relativePath: String) -> Bool {
        switch provider {
        case .claude:
            return relativePath.hasSuffix(".jsonl")
        case .codex:
            let name = (relativePath as NSString).lastPathComponent
            return name.hasPrefix("rollout-")
                && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"))
        }
    }
}

/// Lightweight, provider-aware corpus presence for onboarding and empty-state
/// decisions. This checks only accepted regular files; it never parses a session.
public struct ProviderCorpusPresence: Sendable, Equatable {
    public let providers: Set<Provider>

    public init(providers: Set<Provider>) {
        self.providers = providers
    }

    public var isEmpty: Bool { providers.isEmpty }
    public var hasClaude: Bool { providers.contains(.claude) }
    public var hasCodex: Bool { providers.contains(.codex) }

    public func contains(_ provider: Provider) -> Bool {
        providers.contains(provider)
    }

    /// Convenience for the two approved local roots used by the default store.
    public static func detect(
        claudePaths: ClaudePaths = .process,
        codexPaths: CodexPaths = .process,
        fileManager: FileManager = .default
    ) -> ProviderCorpusPresence {
        detect(sources: [
            .claude(root: claudePaths.projects),
            .codex(root: codexPaths.sessions,
                   importManifestURL: codexPaths.externalAgentImportsJSON),
        ], fileManager: fileManager)
    }

    /// Fixture/frontend seam for any explicit set of provider roots.
    public static func detect(
        sources: [SessionSource],
        fileManager: FileManager = .default
    ) -> ProviderCorpusPresence {
        var present: Set<Provider> = []
        for source in sources where !present.contains(source.provider) {
            if containsAcceptedSession(in: source, fileManager: fileManager) {
                present.insert(source.provider)
            }
        }
        return ProviderCorpusPresence(providers: present)
    }

    private static func containsAcceptedSession(
        in source: SessionSource,
        fileManager: FileManager
    ) -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: source.root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }) else { return false }
        let rootPath = source.root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard source.accepts(relative),
                  SessionIndex.isSafeRegularFile(url, beneath: source.root) else {
                continue
            }
            return true
        }
        return false
    }
}

struct PreparedSessionSource: Sendable {
    let source: SessionSource
    let imports: CodexImportManifest

    init(_ source: SessionSource) {
        self.source = source
        imports = source.provider == .codex
            ? CodexImportManifest.load(from: source.importManifestURL)
            : CodexImportManifest()
    }
}

enum SessionParserState: Sendable, Codable {
    case claude(SessionAccumulator)
    case codex(CodexRolloutAccumulator)

    var resumeOffset: UInt64 {
        switch self {
        case .claude(let accumulator): return accumulator.resumeOffset
        case .codex(let accumulator): return accumulator.resumeOffset
        }
    }

    var codexImportIdentity: (
        sessionID: String,
        markedImported: Bool,
        contentHash: String?,
        sourcePath: String?
    )? {
        guard case .codex(let accumulator) = self else { return nil }
        return (
            accumulator.sid,
            accumulator.markedImported,
            accumulator.importedContentHash,
            accumulator.importedSourcePath)
    }

    var claudeUsageByKey: [String: SessionAccumulator.KeyedUsage]? {
        guard case .claude(let accumulator) = self else { return nil }
        return accumulator.usageByKey
    }

    mutating func resetPendingForTail(at offset: UInt64) {
        switch self {
        case .claude(var accumulator):
            accumulator.pending = Data()
            accumulator.bytesIngested = offset
            self = .claude(accumulator)
        case .codex(var accumulator):
            accumulator.pending = Data()
            accumulator.bytesIngested = offset
            self = .codex(accumulator)
        }
    }

    mutating func ingest(_ data: Data) {
        switch self {
        case .claude(var accumulator):
            accumulator.ingest(data)
            self = .claude(accumulator)
        case .codex(var accumulator):
            accumulator.ingest(data)
            self = .codex(accumulator)
        }
    }

    func summary(filePath: String, machineID: String,
                 excludingClaudeUsageKeys: Set<String> = []) -> SessionSummary {
        switch self {
        case .claude(let accumulator):
            let summary = accumulator.summary(
                filePath: filePath,
                excludingUsageKeys: excludingClaudeUsageKeys)
            return summary.machineID == machineID
                ? summary : summary.taggedWith(machineID)
        case .codex(let accumulator):
            return accumulator.summary(filePath: filePath, machineID: machineID)
        }
    }
}

// MARK: - Session index (incremental scan cache)

/// Launch-lifetime presentation stage for the session aggregate. Engine scan
/// progress intentionally starts on every refresh; presentation may only return
/// to the cold placeholder before this launch has ever produced a settled
/// aggregate. `liveRefreshing` is therefore an irreversible stage for the life
/// of a store, whether the engine is currently idle or refreshing in place.
public enum SessionScanPresentationState: Sendable, Equatable {
    case coldScanning
    case settling
    case liveRefreshing

    /// Populated aggregate views are mounted as soon as partial cold-scan data
    /// exists, and remain mounted for every later incremental refresh.
    public var rendersPopulatedContent: Bool { self != .coldScanning }
    public var showsColdScanningPlaceholder: Bool { self == .coldScanning }
    public var isProvisional: Bool { self != .liveRefreshing }
}

public enum SessionScanPresentationEvent: Sendable, Equatable {
    case scanStarted
    case aggregateAvailable
    case scanSettled
}

/// Pure transition reducer so the warm-rescan regression is exhaustively tested.
public enum SessionScanPresentationReducer {
    public static func reduce(_ state: SessionScanPresentationState,
                              event: SessionScanPresentationEvent) -> SessionScanPresentationState {
        switch (state, event) {
        case (.coldScanning, .aggregateAvailable):
            return .settling
        case (.coldScanning, .scanSettled), (.settling, .scanSettled):
            return .liveRefreshing
        case (.liveRefreshing, _):
            return .liveRefreshing
        default:
            return state
        }
    }
}

/// Public scan state consumed by the UI. `totalEstimate` is the number of
/// transcript-shaped paths found during enumeration; files can still disappear
/// while they are being parsed, so the denominator is deliberately labeled an
/// estimate. `scanned` counts attempted work, including failures.
public struct SessionScanProgress: Sendable, Equatable {
    public let scanned: Int
    public let totalEstimate: Int
    public let isInProgress: Bool

    public init(scanned: Int, totalEstimate: Int, isInProgress: Bool) {
        self.totalEstimate = max(0, totalEstimate)
        self.scanned = min(max(0, scanned), self.totalEstimate)
        self.isInProgress = isInProgress
    }

    public static let idle = SessionScanProgress(
        scanned: 0, totalEstimate: 0, isInProgress: false)
}

public struct SessionIndex: Sendable {
    struct Entry: Sendable {
        var size: UInt64
        var mtime: Date
        var acc: SessionParserState
        var provider: Provider
        var machineID: String
        var summary: SessionSummary
    }
    var entries: [String: Entry] = [:]   // absolute path → entry
    public init() {}

    public var summaries: [SessionSummary] { entries.values.map(\.summary) }

    /// One unit of parse work for the parallel scan.
    struct WorkItem: Sendable {
        let path: String
        let rel: String
        let size: UInt64
        let mtime: Date
        let old: Entry?
        let source: PreparedSessionSource
    }

    /// Rescan `dir`, reusing cached results for unchanged files and parsing only
    /// appended bytes for files that grew. Shrunk/replaced files reparse fully.
    ///
    /// Changed/new files are parsed **in parallel across all cores** — the corpus
    /// is embarrassingly parallel per-file — and `onProgress` (if given) receives
    /// monotonically-growing partial indexes every ~200 attempted files, so a UI
    /// can fill in while a cold scan of a multi-GB tree is still running. The
    /// callback is invoked serially in monotonic scanned-count order. It always
    /// receives an initial in-progress state and a final completed state, even
    /// for an empty/unreadable directory or when individual files fail to parse.
    public static func update(_ previous: SessionIndex, dir: URL,
                              onProgress: (@Sendable (SessionIndex, SessionScanProgress) -> Void)? = nil) -> SessionIndex {
        update(previous, sources: [.claude(root: dir)], onProgress: onProgress)
    }

    /// Rescan one provider source while preserving the legacy one-directory API
    /// above for fixtures and callers that intentionally scan Claude only.
    public static func update(
        _ previous: SessionIndex,
        source: SessionSource,
        onProgress: (@Sendable (SessionIndex, SessionScanProgress) -> Void)? = nil
    ) -> SessionIndex {
        update(previous, sources: [source], onProgress: onProgress)
    }

    /// Rescan all declared sources as one index. Each source is enumerated only
    /// beneath its explicit root and carries its parser/provider/machine tags.
    public static func update(
        _ previous: SessionIndex,
        sources: [SessionSource],
        onProgress: (@Sendable (SessionIndex, SessionScanProgress) -> Void)? = nil
    ) -> SessionIndex {
        let fm = FileManager.default
        let prepared = sources.map(PreparedSessionSource.init)
        guard !prepared.isEmpty else {
            let empty = SessionIndex()
            onProgress?(empty, SessionScanProgress(scanned: 0, totalEstimate: 0,
                                                    isInProgress: true))
            onProgress?(empty, SessionScanProgress(scanned: 0, totalEstimate: 0,
                                                    isInProgress: false))
            return empty
        }

        // Pass 1 — stat everything; unchanged files carry over for free.
        var reused = SessionIndex()
        var work: [WorkItem] = []
        for preparedSource in prepared {
            let source = preparedSource.source
            guard let files = try? fm.subpathsOfDirectory(atPath: source.root.path) else {
                continue
            }
            for rel in files where source.accepts(rel) {
                let url = source.root.appendingPathComponent(rel)
                if source.provider == .codex,
                   !isSafeRegularFile(url, beneath: source.root) {
                    continue
                }
                let path = url.path
                guard let attrs = try? fm.attributesOfItem(atPath: path) else {
                    // Preserve Claude's attempted-progress semantics when a file
                    // disappears between enumeration and stat. Codex paths are
                    // validated above and therefore simply disappear safely.
                    if source.provider == .claude {
                        work.append(WorkItem(path: path, rel: rel, size: 0,
                                             mtime: .distantPast, old: nil,
                                             source: preparedSource))
                    }
                    continue
                }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
                let old = previous.entries[path]
                let sameSource = old?.provider == source.provider
                    && old?.machineID == source.machineID
                if let old, sameSource, old.size == size, old.mtime == mtime,
                   !isExcludedImport(old.acc, by: preparedSource.imports) {
                    reused.entries[path] = old                // untouched — free
                } else {
                    work.append(WorkItem(path: path, rel: rel, size: size,
                                         mtime: mtime, old: sameSource ? old : nil,
                                         source: preparedSource))
                }
            }
        }
        let total = reused.entries.count + work.count
        onProgress?(reused, SessionScanProgress(scanned: reused.entries.count,
                                                totalEstimate: total,
                                                isInProgress: true))
        if work.isEmpty {
            var result = reused
            result.reconcileCrossFileUsage()
            onProgress?(result, SessionScanProgress(scanned: total,
                                                    totalEstimate: total,
                                                    isInProgress: false))
            return result
        }

        // Pass 2 — parse the changed/new files across all cores.
        let items = work
        let state = Locked((merged: reused, attempted: reused.entries.count, sinceEmit: 0))
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let entry = Self.parseOne(items[i])
            state.withLock { s in
                if let entry { s.merged.entries[items[i].path] = entry }
                s.attempted += 1
                s.sinceEmit += 1
                if onProgress != nil, s.sinceEmit >= 200 {
                    s.sinceEmit = 0
                    // Invoke under the scanner's tiny state lock so concurrently
                    // finishing workers cannot deliver progress out of order.
                    onProgress?(s.merged, SessionScanProgress(
                        scanned: s.attempted, totalEstimate: total,
                        isInProgress: true))
                }
            }
        }
        var result = state.withLock { $0.merged }
        result.reconcileCrossFileUsage()
        onProgress?(result, SessionScanProgress(scanned: total,
                                                totalEstimate: total,
                                                isInProgress: false))
        return result
    }

    /// Codex enumeration is stricter than the legacy Claude scanner: regular
    /// files only, no symlinks, and the fully resolved path must remain under
    /// the explicitly approved sessions root.
    fileprivate static func isSafeRegularFile(_ url: URL, beneath root: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    private static func isExcludedImport(
        _ state: SessionParserState,
        by manifest: CodexImportManifest
    ) -> Bool {
        guard let identity = state.codexImportIdentity else { return false }
        return manifest.excludes(sessionID: identity.sessionID,
                                 markedImported: identity.markedImported,
                                 contentHash: identity.contentHash,
                                 sourcePath: identity.sourcePath)
    }

    /// Claude can copy a prior conversation into another top-level transcript.
    /// The same stable message.id/requestId then exists in more than one file;
    /// per-file streaming dedup alone counts it twice. Match CodexBar's canonical
    /// choice: non-sidechain, then parent transcript, then lexicographic path.
    /// Accumulators retain every raw row for correct incremental appends; only
    /// materialized summaries exclude non-canonical copies.
    mutating func reconcileCrossFileUsage() {
        struct Candidate {
            let path: String
            let isSidechain: Bool

            var rank: (Int, Int, String) {
                (isSidechain ? 1 : 0,
                 path.contains("/subagents/") ? 1 : 0,
                 path)
            }
        }

        var winners: [String: Candidate] = [:]
        for path in entries.keys.sorted() {
            guard let entry = entries[path] else { continue }
            guard let usageByKey = entry.acc.claudeUsageByKey else { continue }
            for (key, usage) in usageByKey where !key.hasPrefix("#") {
                let namespacedKey = "\(entry.provider.rawValue)\u{1}\(entry.machineID)\u{1}\(key)"
                let candidate = Candidate(path: path, isSidechain: usage.isSidechain)
                if let current = winners[namespacedKey] {
                    if candidate.rank < current.rank { winners[namespacedKey] = candidate }
                } else {
                    winners[namespacedKey] = candidate
                }
            }
        }

        var exclusions: [String: Set<String>] = [:]
        for (path, entry) in entries {
            guard let usageByKey = entry.acc.claudeUsageByKey else { continue }
            for key in usageByKey.keys where !key.hasPrefix("#") {
                let namespacedKey = "\(entry.provider.rawValue)\u{1}\(entry.machineID)\u{1}\(key)"
                if winners[namespacedKey]?.path != path {
                    exclusions[path, default: []].insert(key)
                }
            }
        }
        for path in entries.keys {
            guard var entry = entries[path] else { continue }
            entry.summary = entry.acc.summary(
                filePath: path, machineID: entry.machineID,
                excludingClaudeUsageKeys: exclusions[path] ?? [])
            entries[path] = entry
        }
    }

    /// Parse a single changed/new file: incremental tail-read when it only grew,
    /// full reparse otherwise. Exactly the per-file logic the serial scan had.
    private static func parseOne(_ w: WorkItem) -> Entry? {
        let source = w.source.source
        let canTail = !w.path.hasSuffix(".jsonl.zst")
        if canTail, let old = w.old, w.size > old.size,
           old.acc.resumeOffset <= w.size,
           let fh = FileHandle(forReadingAtPath: w.path) {    // grew — parse the tail only
            var acc = old.acc
            do {
                try fh.seek(toOffset: acc.resumeOffset)
                acc.resetPendingForTail(at: acc.resumeOffset)
                let appended = try fh.readToEnd() ?? Data()
                try fh.close()
                acc.ingest(appended)
                guard !isExcludedImport(acc, by: w.source.imports) else { return nil }
                return Entry(
                    size: w.size, mtime: w.mtime, acc: acc,
                    provider: source.provider, machineID: source.machineID,
                    summary: acc.summary(filePath: w.path,
                                         machineID: source.machineID))
            } catch {
                try? fh.close()                               // fall through to full parse
            }
        }
        // new / shrunk / unreadable-incrementally — full parse
        let url = URL(fileURLWithPath: w.path)
        let data: Data?
        switch source.provider {
        case .claude:
            data = FileManager.default.contents(atPath: w.path)
        case .codex:
            data = CodexRolloutFile.data(at: url)
        }
        guard let data else { return nil }
        let name = defaultID(relativePath: w.rel)
        var acc: SessionParserState
        switch source.provider {
        case .claude:
            var claude = SessionAccumulator(defaultID: name)
            claude.ingest(data)
            acc = .claude(claude)
        case .codex:
            var codex = CodexRolloutAccumulator(defaultID: name)
            codex.ingest(data)
            acc = .codex(codex)
        }
        guard !isExcludedImport(acc, by: w.source.imports) else { return nil }
        return Entry(
            size: w.size, mtime: w.mtime, acc: acc,
            provider: source.provider, machineID: source.machineID,
            summary: acc.summary(filePath: w.path, machineID: source.machineID))
    }

    private static func defaultID(relativePath: String) -> String {
        let filename = (relativePath as NSString).lastPathComponent
        if filename.hasSuffix(".jsonl.zst") {
            return String(filename.dropLast(".jsonl.zst".count))
        }
        if filename.hasSuffix(".jsonl") {
            return String(filename.dropLast(".jsonl".count))
        }
        return filename
    }
}

// MARK: - Session store

@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [SessionSummary] = []
    /// Name sources outside the transcripts (live PID registry + /rename history).
    private let nameResolver: SessionNameResolver
    /// Codex's separate bounded MRU thread-name index. Kept provider-scoped when
    /// applied so an identical Claude/Codex transport id cannot cross-name rows.
    private let codexNameResolver: CodexSessionNameResolver
    private let paths: ClaudePaths
    @Published public private(set) var lastRefresh: Date = Date()
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var scanProgress: SessionScanProgress = .idle
    @Published public private(set) var scanPresentation: SessionScanPresentationState = .coldScanning
    /// Monotonic stamp, bumped on every real `sessions` assignment — lets
    /// derived-value caches (the attention-board memo) detect change with one
    /// Int compare instead of an array walk. Not @Published: it rides the
    /// publish the assignment itself already emits.
    public private(set) var revision = 0

    private var index = SessionIndex()
    private var refreshQueued = false
    private var triedCache = false
    /// Monotonic refresh generation — stale progress snapshots are dropped.
    private var refreshGen = 0
    /// Entry count of the largest snapshot applied in the current generation.
    private var appliedCount = 0
    /// Attempt count of the newest progress event in the current generation.
    private var appliedScanCount = 0

    /// Read-only remote mirrors merged into the fleet (Cross-Machine Fleet). Empty ⇒
    /// LOCAL-ONLY (the graceful-degradation default). Set by `AppServices` from the
    /// `MachineStore` after each sync; a mirror with no transcripts contributes
    /// nothing, so a configured-but-unsynced remote stays inert. Scanning a mirror is
    /// exactly the same parser over a dir that looks like a second `~/.claude/projects`.
    public var remoteSources: [RemoteSource] = []

    /// Local provider sources scanned into the shared incremental index. Tests
    /// and alternate frontends may replace this list with explicit fixtures.
    public var sources: [SessionSource]

    public init(paths: ClaudePaths = .process,
                codexPaths: CodexPaths = .process) {
        self.paths = paths
        self.nameResolver = SessionNameResolver(claudeDir: paths.root.path)
        self.codexNameResolver = CodexSessionNameResolver(
            indexURL: codexPaths.sessionIndexJSONL)
        self.sources = [
            .claude(root: paths.projects),
            .codex(root: codexPaths.sessions,
                   importManifestURL: codexPaths.externalAgentImportsJSON),
        ]
    }

    public var projectsDir: URL {
        paths.projects
    }

    public func refresh() { Task { await refreshNow() } }

    /// Refresh in three moves so the UI never sits on zeros:
    ///  1. warm-start: hydrate instantly from the on-disk index cache (once),
    ///  2. progressive: publish partial results while the parallel scan runs,
    ///  3. final: publish the complete index and persist it for the next launch.
    public func refreshNow() async {
        if isRefreshing { refreshQueued = true; return }
        isRefreshing = true
        appliedScanCount = 0
        scanPresentation = SessionScanPresentationReducer.reduce(
            scanPresentation, event: .scanStarted)
        scanProgress = SessionScanProgress(scanned: 0,
                                           totalEstimate: index.entries.count,
                                           isInProgress: true)
        refreshGen += 1
        let gen = refreshGen

        if !triedCache {
            triedCache = true
            let cacheURL = paths.sessionIndexCacheURL
            if let cached = await Task.detached(priority: .userInitiated, operation: {
                Self.loadIndexCache(from: cacheURL)
            }).value {
                index = cached
                apply(cached, gen: gen)
            }
        }

        let localSources = sources
        let snapshot = index
        let latestProgress = Locked(scanProgress)
        let result = await Task.detached(priority: .userInitiated) { [weak self] in
            SessionIndex.update(snapshot, sources: localSources) { [weak self] partial, progress in
                latestProgress.withLock { $0 = progress }
                Task { @MainActor [weak self] in
                    self?.apply(partial, progress: progress, gen: gen)
                }
            }
        }.value

        index = result
        appliedCount = result.entries.count
        // Merge in any read-only remote mirrors (Cross-Machine Fleet). The remote
        // scan + pure merge run off-main; if no remotes are configured/synced this is
        // a no-op and the fleet is LOCAL-ONLY. It NEVER blocks or throws — a missing
        // mirror dir simply contributes nothing.
        let localSummaries = result.summaries
        let srcs = remoteSources
        let merged: [SessionSummary] = srcs.isEmpty
            ? Self.sorted(localSummaries)
            : await Task.detached(priority: .userInitiated) {
                let remotes = Self.scanRemotes(srcs)
                return FleetMerge.merge(local: localSummaries, remotes: remotes)
            }.value
        // Compare-before-assign (W6 wave 4): a refresh that found nothing new
        // must not publish — a wholesale reassignment re-renders every session
        // list, drops hover states, and re-sorts rows for zero information.
        let named = Self.applyNames(
            Self.applyNames(merged, names: codexNameResolver.names(),
                            provider: .codex),
            names: nameResolver.names(), provider: .claude)
        if sessions != named {
            sessions = named
            revision += 1
        }
        lastRefresh = Date()
        let completed = latestProgress.withLock { $0 }
        scanProgress = SessionScanProgress(
            scanned: completed.scanned,
            totalEstimate: completed.totalEstimate,
            isInProgress: false)
        scanPresentation = SessionScanPresentationReducer.reduce(
            scanPresentation, event: .scanSettled)
        isRefreshing = false
        let cacheURL = paths.sessionIndexCacheURL
        Task.detached(priority: .utility) { Self.saveIndexCache(result, to: cacheURL) }
        if refreshQueued { refreshQueued = false; await refreshNow() }
    }

    /// Scan each remote mirror dir with the SAME incremental parser used for the
    /// local corpus, returning per-machine summaries (untagged — `FleetMerge` stamps
    /// the machine id). Absent/empty mirrors are skipped, so a down remote yields
    /// nothing and the fleet degrades to local-only. Pure I/O, off-main.
    public nonisolated static func scanRemotes(_ sources: [RemoteSource]) -> [(machine: Machine, sessions: [SessionSummary])] {
        let fm = FileManager.default
        return sources.compactMap { src in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let summaries = SessionIndex.update(SessionIndex(), dir: src.dir).summaries
            guard !summaries.isEmpty else { return nil }
            return (src.machine, summaries)
        }
    }

    // MARK: Cross-Machine Fleet accessors

    /// The machines that actually contributed a session to the current fleet — this
    /// Mac first, then any remote whose mirror produced sessions. Drives the Overview
    /// fleet-wide roll-up ("2 machines · N sessions · $X today").
    public var fleetMachines: [Machine] {
        var out = [Machine.local]
        let present = Set(sessions.map(\.machineID))
        for src in remoteSources where present.contains(src.machine.id) && src.machine.id != Machine.localID {
            out.append(src.machine)
        }
        return out
    }

    /// Fleet-wide roll-up, one row per contributing machine.
    public var machineRollups: [MachineRollup] { FleetMerge.rollups(sessions, machines: fleetMachines) }

    /// Distinct machines contributing sessions right now (≥1 = at least this Mac).
    public var machineCount: Int { fleetMachines.count }

    /// Sessions belonging to a given machine id.
    public func sessions(onMachine id: String) -> [SessionSummary] {
        sessions.filter { $0.machineID == id }
    }

    /// Apply a (possibly out-of-order) snapshot: only grow, only current generation.
    private func apply(_ partial: SessionIndex, gen: Int) {
        guard gen == refreshGen, partial.entries.count > appliedCount else { return }
        appliedCount = partial.entries.count
        scanPresentation = SessionScanPresentationReducer.reduce(
            scanPresentation, event: .aggregateAvailable)
        sessions = Self.applyNames(
            Self.applyNames(Self.sorted(partial.summaries),
                            names: codexNameResolver.names(), provider: .codex),
            names: nameResolver.names(), provider: .claude)
        revision += 1
    }

    /// Apply scanner counts independently from partial-session publication. A
    /// failed transcript still advances progress, and a changed file in a
    /// same-sized warm index can advance N/~M even when `entries.count` does not.
    private func apply(_ partial: SessionIndex, progress: SessionScanProgress,
                       gen: Int) {
        guard gen == refreshGen, isRefreshing,
              progress.scanned >= appliedScanCount else { return }
        appliedScanCount = progress.scanned
        scanProgress = SessionScanProgress(
            scanned: progress.scanned,
            totalEstimate: progress.totalEstimate,
            // The local index can finish before read-only remote mirrors merge;
            // the store stays provisional through that final phase.
            isInProgress: true)
        apply(partial, gen: gen)
    }

    /// Overlay the resolver's names (live registry / last rename) over each
    /// summary's transcript-sourced ai-title; nil-name summaries keep the base.
    nonisolated static func applyNames(_ list: [SessionSummary],
                                       names: [String: String],
                                       provider: Provider = .claude) -> [SessionSummary] {
        guard !names.isEmpty else { return list }
        return list.map { s in
            guard s.provider == provider,
                  let better = names[s.id], better != s.name else { return s }
            var copy = s
            copy = SessionSummary(id: s.id, provider: s.provider,
                                  project: s.project, cwd: s.cwd, model: s.model,
                                  lastActivity: s.lastActivity, messageCount: s.messageCount,
                                  usage: s.usage, contextWeight: s.contextWeight,
                                  filePath: s.filePath, lastUserMessage: s.lastUserMessage,
                                  name: better, handle: s.handle, usageByTier: s.usageByTier,
                                  usageByDay: s.usageByDay, usageByModel: s.usageByModel,
                                  usageByModelDay: s.usageByModelDay,
                                  messagesByModelDay: s.messagesByModelDay,
                                  rawUsageBlocks: s.rawUsageBlocks,
                                  unsupportedPricingEntryCount: s.unsupportedPricingEntryCount,
                                  skillInvocations: s.skillInvocations,
                                  commandInvocations: s.commandInvocations,
                                  agentCalls: s.agentCalls,
                                  subagentInvocations: s.subagentInvocations,
                                  fileEdits: s.fileEdits,
                                  tiersSeen: s.tiersSeen,
                                  assistantTurnsByModel: s.assistantTurnsByModel,
                                  toolCalls: s.toolCalls,
                                  filesTouchedByModel: s.filesTouchedByModel,
                                  modelFlips: s.modelFlips,
                                  machineID: s.machineID, costBundle: s.costBundle)
            return copy
        }
    }

    private nonisolated static func sorted(_ summaries: [SessionSummary]) -> [SessionSummary] {
        summaries.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    /// One-shot whole-directory scan (tests). Same aggregation as refresh().
    public nonisolated static func scan(_ dir: URL) -> [SessionSummary] {
        SessionIndex.update(SessionIndex(), dir: dir).summaries
    }

    /// Cache-backed scan (`--selfcheck`): identical output to `scan`, but reuses and
    /// re-primes the same on-disk index the GUI warm-starts from.
    public nonisolated static func cachedScan(
        _ dir: URL,
        cacheURL: URL = ClaudePaths.process.sessionIndexCacheURL,
        codexPaths: CodexPaths = .process
    ) -> [SessionSummary] {
        let paths = ClaudePaths.process
        let resolved = resolvedProjectsDirectory(dir, paths: paths)
        var sources: [SessionSource] = [.claude(root: resolved)]
        if resolved.standardizedFileURL == paths.projects.standardizedFileURL {
            sources.append(.codex(
                root: codexPaths.sessions,
                importManifestURL: codexPaths.externalAgentImportsJSON))
        }
        let idx = SessionIndex.update(
            loadIndexCache(from: cacheURL) ?? SessionIndex(),
            sources: sources)
        saveIndexCache(idx, to: cacheURL)
        return idx.summaries
    }

    /// CLI/selfcheck compatibility seam: their historical call site passes the
    /// literal default projects directory. A process override replaces only that
    /// default; an explicitly supplied fixture/custom directory remains explicit.
    public nonisolated static func resolvedProjectsDirectory(
        _ requested: URL,
        paths: ClaudePaths,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let legacyDefault = home.appendingPathComponent(".claude/projects")
            .standardizedFileURL
        return requested.standardizedFileURL == legacyDefault
            ? paths.projects : requested
    }

    // MARK: Index cache (instant warm launches)
    // The whole incremental index — per-file size/mtime/accumulator — serialized to
    // Application Support. Loading it makes launch paint real data in milliseconds;
    // the follow-up scan then only stats files and parses actual changes.

    private struct CacheEntry: Codable {
        var path: String
        var size: UInt64
        var mtime: Date
        var acc: SessionParserState
        var provider: Provider
        var machineID: String
    }
    private struct CacheFile: Codable {
        var version: Int
        var timeZoneIdentifier: String
        var entries: [CacheEntry]
    }
    // v2: SessionAccumulator gained `usageByTier` (per-message model attribution).
    // v3: gained the tool-call census (`skillInvocations`/`agentCalls`/`fileEdits`)
    // for the AUDIT pillar.
    // v4: gained `tiersSeen` (usage-independent model-tier set) so the subagent-
    // doctrine audit matches the `.message.model` signal. Bumping invalidates
    // older caches outright (version mismatch → `loadIndexCache` returns nil)
    // instead of reusing entries that would carry no audit data until their file
    // next changes — a one-time full reparse on first launch after the upgrade.
    // v5: gained a new stored accumulator field (since removed), so caches written
    // before it must re-scan; the version bump is retained to invalidate them.
    // v6: SessionSummary gained `machineID` (Cross-Machine Fleet). It is a MERGE-time
    // tag (`FleetMerge`), not a stored accumulator field, so cached local summaries
    // already default to "local" correctly — but we bump to guarantee no cache from
    // before the fleet layer is ever served, per the cross-machine build's cache rule.
    // v7: the accumulator now DEDUPES streaming assistant chunks — it stores
    // `usageByKey`/`unkeyedSeq` (keyed per message.id+requestId, last cumulative
    // chunk wins) in place of the old per-line-summed `usage`/`usageByTier` fields.
    // Every $ figure the old cache carried was ~2.6x too high (it summed cumulative
    // chunks), so the old shape MUST be invalidated → a one-time full reparse.
    // v8: per-MODEL pricing (W2) — `KeyedUsage` records the normalized model id
    // (was: tier) and `SessionUsage` gained the 1h cache-write slice
    // (`cacheCreate1hTokens`, billed 2× vs the 5m slice's 1.25×). Old entries
    // carry neither, so they must reparse or every model would price at its
    // tier fallback and 1h-heavy days would undercount.
    // v9: COST PROVENANCE (W3) — the accumulator stores `rawUsageBlocks` (the
    // raw usage-line count BEFORE the messageId:requestId dedup) so every
    // receipt can print its honest dedup note ("N raw → M unique,
    // last-chunk-wins"). Old caches lack the counter (synthesized Codable
    // would fail decoding, and a zero would lie), so they must reparse once.
    // v10: CUSTOM ESTATE (W5) — the accumulator stores the per-model file-path
    // capture (`filesTouchedByModel` + its `storedFilePaths` cap counter), the
    // per-model assistant TURN census (`assistantTurnsByModel` +
    // `lastAssistantMessageID`, the Opus-fallback denominator) and the total
    // `toolCalls` census (the Custom-vs-Opus shape bands). Old caches carry
    // none of these, so they must reparse once.
    // v11: task #41 — the accumulator stores `commandInvocations` (slash-command
    // census from <command-name> tags). Old caches lack the field (synthesized
    // Codable decode fails) and every dead-skill number they'd produce is the
    // undercount this version fixes → one-time full reparse.
    // v12: SessionAccumulator gained `aiTitle` (session-name display) — synthesized
    // Codable would decode old caches to nil anyway, but the version ladder rule is
    // every stored-field change bumps, so staleness is loud, never silent.
    // v13: REROUTE RECEIPTS (spree #2) — the accumulator stores `modelFlips`
    // (positional mid-session model changes with the deliberate-/model flag
    // decided inline) plus `lastTurnModel`/`sawModelCommandSinceTurn`. Old
    // caches carry no positional flip evidence, so they must reparse once or
    // every receipt would read "clean" while the corpus wasn't.
    // v14: usage entries retain unsupported speed/service-tier evidence, and
    // the file records the local time-zone identifier. A zone change invalidates
    // every materialized day key even when transcript size+mtime are unchanged.
    // v15: SessionAccumulator caches the human session handle + its source rank.
    // Old entries would otherwise fall back to a UUID, so every transcript gets
    // one intentional reparse to derive its ai-title/summary/first-prompt handle.
    // v16: N1 model-pin evidence — pending Agent call declarations and completed
    // parent→subagent invocation joins (agentId/requested/resolved model).
    // v17: keyed usage retains `isSidechain`, and final indexes reconcile the
    // same message.id/requestId copied across transcript files to one canonical
    // row. Old caches cannot choose that winner without a one-time reparse.
    // v18: SessionSummary gained `provider`; cached entries now retain their
    // provider/parser/machine source so Claude and Codex can share one index.
    // v19: CodexRolloutAccumulator retains counter-reset epochs and its latest
    // provider-native attention signal. Old entries cannot recover either fact
    // without replaying their rollout once.
    // v20: gpt usage re-tiers out of .other, and Codex accumulators retain their
    // first genuine user prompt for title fallback. Cached summaries carry the
    // old tier-keyed usage/cost bundle and no prompt, so every Codex rollout must
    // replay once rather than preserving anonymous Other / Untitled rows.
    private nonisolated static let cacheVersion = 20

    public nonisolated static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trifola/session-index.json")
    }

    public nonisolated static func loadIndexCache(
        from url: URL = defaultCacheURL,
        timeZone: TimeZone = .current
    ) -> SessionIndex? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == cacheVersion,
              file.timeZoneIdentifier == timeZone.identifier,
              !file.entries.isEmpty else { return nil }
        var idx = SessionIndex()
        for e in file.entries {
            idx.entries[e.path] = SessionIndex.Entry(
                size: e.size, mtime: e.mtime, acc: e.acc,
                provider: e.provider, machineID: e.machineID,
                summary: e.acc.summary(filePath: e.path,
                                       machineID: e.machineID))
        }
        idx.reconcileCrossFileUsage()
        return idx
    }

    public nonisolated static func saveIndexCache(
        _ index: SessionIndex,
        to url: URL = defaultCacheURL,
        timeZone: TimeZone = .current
    ) {
        let file = CacheFile(version: cacheVersion, timeZoneIdentifier: timeZone.identifier,
                             entries: index.entries.map {
            CacheEntry(path: $0.key, size: $0.value.size, mtime: $0.value.mtime,
                       acc: $0.value.acc, provider: $0.value.provider,
                       machineID: $0.value.machineID)
        })
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public var totalUsage: SessionUsage { sessions.reduce(SessionUsage()) { $0 + $1.usage } }
    public var activeSessions: [SessionSummary] { sessions.filter { $0.isActive } }
    public var totalCost: Double { sessions.reduce(0) { $0 + $1.cost } }
    /// Net cache savings priced at the per-model rate that ACTUALLY billed each
    /// slice: read discounts minus 5m/1h write premiums.
    public var totalCacheSavings: Double {
        sessions.reduce(0) { $0 + $1.cacheSavingsDollars }
    }

    /// Entries explicitly marked fast/batch (or another non-standard mode).
    /// Totals currently use standard cards; another lane may surface this count.
    public var unsupportedPricingEntryCount: Int {
        sessions.reduce(0) { $0 + $1.unsupportedPricingEntryCount }
    }

    /// Spend split by model tier (the "silent Opus routing" panel).
    public var tierStats: [TierStat] { Self.aggregateTiers(sessions) }

    /// Exact model ids, separated by provider and sorted for the Spend table.
    public var topModelsByID: [ModelSpendStat] {
        Self.aggregateModelsByID(sessions)
    }

    /// Per-tick burn-governor memo: the sidebar footer AND the Overview each
    /// build the governor per body pass with the same (sessions, now) inputs —
    /// memoizing on (revision, now, window) halves that to one build per tick.
    private var burnCache: (rev: Int, now: Date, window: Int, governor: BurnGovernor)?

    /// The credit-era burn governor (VISION 2.5) over the current summaries —
    /// per-day API-equiv burn + a recent-run-rate month projection. Pure
    /// aggregation, no index re-scan; `now` lets the caller share the app's tick
    /// (callers passing the same heartbeat `now` share one build).
    public func burnGovernor(now: Date = Date(), window: Int = 30) -> BurnGovernor {
        if let c = burnCache, c.rev == revision, c.now == now, c.window == window {
            return c.governor
        }
        let governor = BurnGovernor(sessions: sessions, now: now, window: window)
        burnCache = (revision, now, window, governor)
        return governor
    }

    /// Per-tier rollup. Each session is counted once (under its dominant
    /// tier) for the `sessions` column, but tokens/cost are attributed to
    /// whichever tier actually billed them — a session that's 97% Opus and 3%
    /// Custom must not dump its whole pile onto one tier's row. Cost is priced
    /// per MODEL via the catalog (W2); the tier is only the display grouping.
    public nonisolated static func aggregateTiers(_ sessions: [SessionSummary]) -> [TierStat] {
        var map: [ModelTier: TierStat] = [:]
        for s in sessions {
            var dominant = map[s.tier] ?? TierStat(tier: s.tier, tokens: 0, cost: 0, sessions: 0)
            dominant.sessions += 1
            map[s.tier] = dominant
            for (tier, u) in s.perTierUsage {
                var st = map[tier] ?? TierStat(tier: tier, tokens: 0, cost: 0, sessions: 0)
                st.tokens += u.billedInput + u.outputTokens
                map[tier] = st
            }
            for (tier, c) in s.perTierCostMap {
                var st = map[tier] ?? TierStat(tier: tier, tokens: 0, cost: 0, sessions: 0)
                st.cost += c
                map[tier] = st
            }
        }
        return map.values.sorted { $0.cost > $1.cost }
    }

    /// Provider-aware, exact-model rollup. Real summaries take the finest
    /// `(local day, model id)` slices, so date-era pricing is identical to the
    /// session headline. The older `usageByModel` fallback still preserves the
    /// model id and prices it on the summary's activity day; synthetic summaries
    /// fall back once more to their last model.
    ///
    /// Ordering is total and stable: dollars descending, then provider and model
    /// ascending. Iterating dictionary keys in sorted order also makes the
    /// floating-point fold reproducible across launches.
    public nonisolated static func aggregateModelsByID(
        _ sessions: [SessionSummary],
        catalog: PricingCatalog = .current
    ) -> [ModelSpendStat] {
        struct Key: Hashable {
            let provider: Provider
            let model: String
        }
        struct Aggregate {
            var usage = SessionUsage()
            var cost = 0.0
            var sessions = 0
        }

        var aggregates: [Key: Aggregate] = [:]
        let orderedSessions = sessions.sorted {
            ($0.provider.rawValue, $0.machineID, $0.id, $0.filePath)
                < ($1.provider.rawValue, $1.machineID, $1.id, $1.filePath)
        }

        for session in orderedSessions {
            var contributed = Set<Key>()

            func add(rawModel: String?, day: String?, usage: SessionUsage) {
                guard usage.total > 0 else { return }
                let normalized = PricingCatalog.normalize(rawModel)
                let model = normalized.isEmpty ? "<unknown>" : normalized
                let key = Key(provider: session.provider, model: model)
                var aggregate = aggregates[key] ?? Aggregate()
                aggregate.usage = aggregate.usage + usage
                aggregate.cost += usage.cost(
                    rate: catalog.resolvedRate(model: rawModel, onDay: day))
                aggregates[key] = aggregate
                contributed.insert(key)
            }

            if !session.usageByModelDay.isEmpty {
                for day in session.usageByModelDay.keys.sorted() {
                    let byModel = session.usageByModelDay[day] ?? [:]
                    for model in byModel.keys.sorted() {
                        if let usage = byModel[model] {
                            add(rawModel: model, day: day, usage: usage)
                        }
                    }
                }
            } else if !session.usageByModel.isEmpty {
                let day = session.lastActivity.map(localDayKey)
                for model in session.usageByModel.keys.sorted() {
                    if let usage = session.usageByModel[model] {
                        add(rawModel: model, day: day, usage: usage)
                    }
                }
            } else {
                add(rawModel: session.model,
                    day: session.lastActivity.map(localDayKey),
                    usage: session.usage)
            }

            for key in contributed {
                aggregates[key]?.sessions += 1
            }
        }

        return aggregates.map { key, value in
            ModelSpendStat(provider: key.provider, model: key.model,
                           usage: value.usage, cost: value.cost,
                           sessions: value.sessions)
        }.sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            if $0.provider != $1.provider {
                return $0.provider.rawValue < $1.provider.rawValue
            }
            return $0.model < $1.model
        }
    }

    /// Sessions carrying a heavy context right now — the "$20 hey" risk list.
    /// Subagent transcripts are excluded: their spend is real but nobody sends
    /// another message into them, so they carry no next-message risk.
    public var contextHeavy: [SessionSummary] {
        sessions.filter { $0.isContextHeavy && !$0.isSubagent }
            .sorted { $0.contextWeight > $1.contextWeight }
    }

    /// Spend rolled up by project (cwd basename), most expensive first.
    public var projectSpend: [(project: String, cost: Double, sessions: Int)] {
        var map: [String: (Double, Int)] = [:]
        for s in sessions {
            let v = map[s.project] ?? (0, 0)
            map[s.project] = (v.0 + s.cost, v.1 + 1)
        }
        return map.map { (project: $0.key, cost: $0.value.0, sessions: $0.value.1) }
            .sorted { $0.cost > $1.cost }
    }

    /// Sessions-per-hour activity histogram for the trailing `hours` hours (oldest first).
    public nonisolated static func activityHistogram(_ sessions: [SessionSummary], hours: Int, now: Date = Date()) -> [Int] {
        var buckets = [Int](repeating: 0, count: hours)
        for s in sessions {
            guard let d = s.lastActivity else { continue }
            let age = now.timeIntervalSince(d)
            guard age >= 0, age < Double(hours) * 3600 else { continue }
            buckets[hours - 1 - Int(age / 3600)] += 1
        }
        return buckets
    }
}

// MARK: - Routing audit (live version of the fleet audit)

@MainActor
public final class RoutingAudit: ObservableObject {
    @Published public private(set) var defaultModel: String = "—"
    @Published public private(set) var flags: [RoutingFlag] = []

    private let settingsFile: URL

    public init(paths: ClaudePaths = .process) {
        self.settingsFile = paths.settingsJSON
    }

    public func refresh(sessions: [SessionSummary]) async {
        let file = settingsFile
        let result = await Task.detached(priority: .utility) {
            let def = Self.defaultModel(at: file)
            return (def, Self.computeFlags(defaultModel: def, sessions: sessions))
        }.value
        let def = result.0
        if defaultModel != def { defaultModel = def }
        let computed = result.1
        if flags != computed { flags = computed }
    }

    private nonisolated static func defaultModel(at file: URL) -> String {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["model"] as? String else { return "—" }
        return model
    }

    public nonisolated static func computeFlags(defaultModel def: String,
                                                sessions: [SessionSummary]) -> [RoutingFlag] {
        var f: [RoutingFlag] = []
        // Unexpected Opus routing — the #1 pain point from the research.
        // Per-tier attribution: a mixed-model session's non-Opus share must not
        // get counted as Opus spend just because Opus happens to be dominant.
        let total = sessions.reduce(0.0) { $0 + $1.cost }
        let opus = sessions.reduce(0.0) { $0 + ($1.perTierCostMap[.opus] ?? 0) }
        if total > 0, opus / total > 0.5 {
            f.append(RoutingFlag(level: .warn,
                title: "Opus is \(Int(opus / total * 100))% of the all-time API-rate estimate",
                detail: "Over half of recorded usage was priced at public Opus API rates; this is not your bill. A long-lived session can keep using Opus after you expected another model, so review its /model default."))
        }
        return f
    }
}
