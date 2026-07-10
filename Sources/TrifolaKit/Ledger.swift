import Foundation
import Combine

// MARK: - THE DREAMING LEDGER (v1 · Lessons)
// The capstone / moat. The AUDIT screen shows FINDINGS (what's wasted). The Ledger
// turns each finding into an ACTIONABLE CANDIDATE FIX — a concrete, copy-able edit
// or action a human approves. That transformation IS the flywheel.
//
// Doctrine (docs/DREAMING_LEDGER.md):
//  • Deterministic mining — arithmetic over the shipped AuditReport + settings.
//    ZERO model calls. Every artifact is reproducible from cited findings and a
//    versioned detector; a skeptic can re-derive it.
//  • The app NEVER writes ~/.claude — not even approved bytes. Lessons flow to the
//    CLIPBOARD; the human is the actuator. Dismiss/keep/apply state lives in the
//    app's OWN dir (~/Library/Application Support/Trifola/ledger).
//  • Lessons are lint rules for your workflow: a finite, versioned detector set,
//    each producing a templated candidate edit with computed fields.
//  • Strict thresholds → the empty state is the COMMON state (the trust engine).
//  • Honest triggers: manual "Dream now" + on-launch recompute is v1. No fake
//    overnight compute.
//
// Detector taxonomy (v1), numbered per the build brief:
//  L-001 model-pin       ← SubagentRollup / fleetCustomSubagents  (THE headline)
//  L-002 dead-skill       ← SkillLedger.dead
//  L-003 cache-miss disc.  ← CacheMissFinding leaders
//  L-004 right-sizing      ← MismatchCandidate
//  L-005 effort furnace    ← settings.json effortLevel

// MARK: - settings.json reader (model + effort)

/// Provider tag on a declared routing-policy source. Claude is parsed today;
/// Codex is an explicit seam for N3 rather than a later parallel type hierarchy.
public enum DeclaredPolicySource: String, Sendable, Codable, Hashable {
    case claude
    case codex
}

/// One parseable declared model policy and the file that declared it.
/// `selector` is "session-default", "*", a lane such as "execute", or an
/// exact subagent type.
public struct DeclaredRoutingPolicy: Sendable, Codable, Hashable {
    public let source: DeclaredPolicySource
    public let model: String
    public let selector: String
    public let filePath: String

    public init(source: DeclaredPolicySource, model: String,
                selector: String = "session-default", filePath: String) {
        self.source = source
        self.model = model
        self.selector = selector
        self.filePath = filePath
    }
}

/// The two persisted-default facts the Ledger reads from `~/.claude/settings.json`
/// (read-only, like everything else the app touches under ~/.claude).
public struct ClaudeSettings: Sendable, Equatable {
    public let model: String
    public let effort: EffortLevel
    /// Raw effort string as written on disk (so a value outside the known enum
    /// still surfaces honestly instead of being silently normalized).
    public let effortRaw: String
    /// Provider-tagged routing declarations: settings.json default plus narrow,
    /// parseable CLAUDE.md subagent pins.
    public let declaredPolicies: [DeclaredRoutingPolicy]

    public init(model: String = "—", effort: EffortLevel = .doctrineDefault,
                effortRaw: String? = nil,
                declaredPolicies: [DeclaredRoutingPolicy]? = nil) {
        self.model = model
        self.effort = effort
        self.effortRaw = effortRaw ?? effort.rawValue
        if let declaredPolicies {
            self.declaredPolicies = declaredPolicies
        } else if model != "—", !model.isEmpty {
            self.declaredPolicies = [DeclaredRoutingPolicy(
                source: .claude, model: model, selector: "session-default",
                filePath: Self.defaultURL.path)]
        } else {
            self.declaredPolicies = []
        }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    public static var defaultClaudeMDURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/CLAUDE.md")
    }

    /// Read model + effortLevel. Missing file / keys degrade to the doctrine
    /// default — never a crash, never a fabricated value.
    public static func load(
        _ url: URL = defaultURL,
        claudeMDURLs: [URL]? = nil
    ) -> ClaudeSettings {
        let obj: [String: Any] = FileManager.default.contents(atPath: url.path)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let model = (obj["model"] as? String) ?? "—"
        let raw = obj["effortLevel"] as? String
        let effort = raw.flatMap(EffortLevel.init(rawValue:)) ?? .doctrineDefault
        var policies: [DeclaredRoutingPolicy] = []
        if model != "—", !model.isEmpty {
            policies.append(DeclaredRoutingPolicy(
                source: .claude, model: model, selector: "session-default",
                filePath: url.path))
        }
        for claudeMDURL in claudeMDURLs ?? [defaultClaudeMDURL] {
            guard let text = try? String(contentsOf: claudeMDURL, encoding: .utf8) else { continue }
            policies.append(contentsOf: parseClaudeMDPolicies(text, filePath: claudeMDURL.path))
        }
        return ClaudeSettings(model: model, effort: effort, effortRaw: raw ?? effort.rawValue,
                              declaredPolicies: policies)
    }

    /// Parse only explicit, one-line subagent model declarations. Generic
    /// `model:` examples and prose such as "use a cheaper model" stay ignored.
    public static func parseClaudeMDPolicies(
        _ text: String,
        filePath: String
    ) -> [DeclaredRoutingPolicy] {
        var out: [DeclaredRoutingPolicy] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let captures = regexCaptures(
                #"(?i)\bsubagent(?:\s+([A-Za-z0-9_.-]+))?\s+(?:pin\s+)?model\s*:\s*([A-Za-z0-9_.\-\[\]]+)"#,
                in: line) {
                out.append(DeclaredRoutingPolicy(
                    source: .claude, model: captures[1],
                    selector: captures[0].isEmpty ? "*" : captures[0],
                    filePath: filePath))
                continue
            }
            if line.range(of: #"(?i)\bdefault\s+pins?\s*:"#,
                          options: .regularExpression) != nil {
                for captures in regexAllCaptures(
                    #"([A-Za-z0-9_.\-\[\]]+)\s*\(([^)]+)\)"#, in: line) {
                    let selectors = captures[1].split(whereSeparator: { $0 == "/" || $0 == "," })
                    for selector in selectors {
                        out.append(DeclaredRoutingPolicy(
                            source: .claude, model: captures[0], selector: String(selector),
                            filePath: filePath))
                    }
                }
            }
        }
        return out
    }

    /// Most-specific declared policy for a subagent leg.
    public func policy(forSubagentType agentType: String?) -> DeclaredRoutingPolicy? {
        let type = agentType?.lowercased() ?? ""
        let specific = declaredPolicies.filter { $0.selector != "session-default" }
            .sorted { policyScore($0.selector, agentType: type) < policyScore($1.selector, agentType: type) }
            .first { policyScore($0.selector, agentType: type) < Int.max }
        return specific ?? declaredPolicies.first { $0.selector == "session-default" }
    }

    private func policyScore(_ selector: String, agentType: String) -> Int {
        let selector = selector.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !agentType.isEmpty, selector == agentType { return 0 }
        if selector == "*" || selector == "all" || selector == "subagents" { return 2 }
        if selector == "execute" {
            let reasoningWords = ["review", "reason", "architect", "plan"]
            return reasoningWords.contains(where: agentType.contains) ? Int.max : 1
        }
        if selector == "reason" || selector == "review" {
            return agentType.contains(selector) ? 1 : Int.max
        }
        return Int.max
    }

    /// Capture groups only (not the full match); unmatched optional groups are "".
    private static func regexCaptures(_ pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return "" }
            return String(line[swiftRange])
        }
    }

    private static func regexAllCaptures(_ pattern: String, in line: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(
            in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
        return matches.map { match in
            (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: line) else { return "" }
                return String(line[swiftRange])
            }
        }
    }
}

// MARK: - Lesson kind (the finite detector taxonomy)

public enum LessonKind: String, Sendable, Codable, CaseIterable {
    case modelPin           // L-001
    case deadSkillArchive   // L-002
    case cacheMissDiscipline // L-003
    case rightSizing        // L-004
    case effortFurnace      // L-005

    /// Stable ledger code — also the lesson's persistence id (v1 mints at most one
    /// lesson per kind, so the code is a stable fingerprint for dismiss/keep state).
    public var code: String {
        switch self {
        case .modelPin: return "L-001"
        case .deadSkillArchive: return "L-002"
        case .cacheMissDiscipline: return "L-003"
        case .rightSizing: return "L-004"
        case .effortFurnace: return "L-005"
        }
    }

    public var title: String {
        switch self {
        case .modelPin: return "Pin inherited subagent models"
        case .deadSkillArchive: return "Unused skills — archive candidates"
        case .cacheMissDiscipline: return "Cache-miss discipline"
        case .rightSizing: return "Model right-sizing"
        case .effortFurnace: return "High-effort default"
        }
    }

    /// Stable semantic priority; dollar impact breaks ties within a detector.
    /// The routing fix is the headline, then direct-dollar findings, then hygiene.
    var priority: Int {
        switch self {
        case .modelPin: return 0
        case .cacheMissDiscipline: return 1
        case .rightSizing: return 2
        case .deadSkillArchive: return 3
        case .effortFurnace: return 4
        }
    }
}

// MARK: - Candidate fix (the flywheel: finding → an action the human takes)

/// How the human actuates a lesson. Text candidates go to the CLIPBOARD; reveal
/// candidates open Finder. The app never writes the target itself.
public enum CandidateAction: String, Sendable, Codable {
    case copyEdit      // paste into a CLAUDE.md / workflow script
    case copyHabit     // a plain-language habit line
    case copySettings  // a settings.json value, applied via /config
    case copyReview    // a routing note to review
}

/// A file/skill the lesson points at for Reveal-in-Finder ("the app names them,
/// you move them").
public struct RevealTarget: Identifiable, Sendable, Codable, Hashable {
    public var id: String { path.isEmpty ? label : path }
    public let label: String
    public let detail: String
    public let path: String
    public init(label: String, detail: String, path: String) {
        self.label = label; self.detail = detail; self.path = path
    }
}

/// The concrete, approvable fix minted from a finding. This is the whole point:
/// not "here is what's wasted" but "here is the exact edit that stops it — you
/// apply it."
public struct CandidateFix: Sendable, Codable, Hashable {
    public let action: CandidateAction
    /// One-line description of what approving does.
    public let summary: String
    /// The exact text placed on the clipboard on [Copy]. Always present (even a
    /// reveal-list lesson copies its named list).
    public let copyText: String
    /// Button label ("Copy edit" / "Copy habit" / …).
    public let copyLabel: String
    /// Diff-styled hunk for the card (before → after). Optional: habit/review
    /// candidates have no before/after, only the copyText.
    public let beforeText: String?
    public let afterText: String?
    /// Files to Reveal-in-Finder (dead-skill folders, the pin's target sites).
    public let revealTargets: [RevealTarget]
    /// The honesty caveat printed on the card (e.g. "cache expiry is partly
    /// unavoidable", "the app names them, you move them").
    public let note: String

    public init(action: CandidateAction, summary: String, copyText: String,
                copyLabel: String, beforeText: String? = nil, afterText: String? = nil,
                revealTargets: [RevealTarget] = [], note: String) {
        self.action = action; self.summary = summary; self.copyText = copyText
        self.copyLabel = copyLabel; self.beforeText = beforeText; self.afterText = afterText
        self.revealTargets = revealTargets; self.note = note
    }
}

// MARK: - Evidence (findings-as-evidence, one click from the transcript)

public enum EvidenceNav: String, Sendable, Codable { case inspect, reveal, none }

/// One evidence row: the audit screen's findings-as-evidence grammar, reused. The
/// number that earns the lesson, with its source one click away.
public struct LessonEvidence: Identifiable, Sendable, Codable, Hashable {
    public var id: String { label + navPath + detail }
    public let label: String       // project / session
    public let detail: String      // the numbers
    public let value: String       // trailing $ / count
    public let barFraction: Double // ranking bar (0…1)
    public let navPath: String     // transcript path (inspect) or file (reveal)
    public let nav: EvidenceNav

    public init(label: String, detail: String, value: String, barFraction: Double,
                navPath: String, nav: EvidenceNav) {
        self.label = label; self.detail = detail; self.value = value
        self.barFraction = barFraction; self.navPath = navPath; self.nav = nav
    }
}

// MARK: - Lesson (a minted artifact)

public struct Lesson: Identifiable, Sendable, Codable, Hashable {
    public var id: String { kind.code }
    public let kind: LessonKind
    /// The headline metric ("78 runs", "95/110 skills") — also the verification
    /// anchor: the next dream compares this number to the number at apply time.
    public let metricValue: Double
    public let metricLabel: String
    /// One-line why.
    public let why: String
    public let evidence: [LessonEvidence]
    public let candidate: CandidateFix
    public let detectorVersion: String
    /// Dollar impact used to rank tier-1 lessons (labeled estimate). L-001 leads
    /// regardless via `kind.priority`.
    public let impact: Double

    public init(kind: LessonKind, metricValue: Double, metricLabel: String, why: String,
                evidence: [LessonEvidence], candidate: CandidateFix,
                detectorVersion: String = "detector v1", impact: Double) {
        self.kind = kind; self.metricValue = metricValue; self.metricLabel = metricLabel
        self.why = why; self.evidence = evidence; self.candidate = candidate
        self.detectorVersion = detectorVersion; self.impact = impact
    }

    /// Queue rank: model-pin first (closed loop), then by dollar impact desc.
    var rank: (Int, Double) { (kind.priority, -impact) }
}

/// One silent-inheritance mismatch, already priced as actual minus the same
/// usage repriced at the declared model's catalog rate.
public struct ModelPinMismatch: Identifiable, Sendable, Hashable {
    public var id: String { sessionID }
    public let provider: DeclaredPolicySource
    public let sessionID: String
    public let project: String
    public let agentType: String?
    public let declaredModel: String
    public let resolvedModel: String
    public let deltaDollars: Double
    public let filePath: String
    public let targetPath: String

    public init(provider: DeclaredPolicySource, sessionID: String, project: String,
                agentType: String?, declaredModel: String, resolvedModel: String,
                deltaDollars: Double, filePath: String, targetPath: String) {
        self.provider = provider
        self.sessionID = sessionID
        self.project = project
        self.agentType = agentType
        self.declaredModel = declaredModel
        self.resolvedModel = resolvedModel
        self.deltaDollars = deltaDollars
        self.filePath = filePath
        self.targetPath = targetPath
    }
}

// MARK: - Lesson state (dismiss / keep / apply — persisted, NEVER ~/.claude)

public enum LessonStatus: String, Sendable, Codable {
    case pending    // in the queue, awaiting adjudication
    case kept       // acknowledged, stays visible
    case dismissed  // a dismissed pattern is never re-proposed (fingerprint memory)
    case applied    // the human copied/applied the edit — the verification anchor
}

/// The persisted verdict on a lesson. `appliedMetric` snapshots the headline
/// number at the moment of apply so the NEXT dream can annotate "was 78, now 80
/// (+2 since)" — the moment audit stops being a report. Deterministic arithmetic,
/// no date-partitioning of raw sessions required.
public struct LessonState: Sendable, Codable, Hashable {
    public var status: LessonStatus
    public var updatedAt: Date
    public var appliedAt: Date?
    public var appliedMetric: Double?
    public var detectorVersion: String

    public init(status: LessonStatus, updatedAt: Date = Date(), appliedAt: Date? = nil,
                appliedMetric: Double? = nil, detectorVersion: String = "detector v1") {
        self.status = status; self.updatedAt = updatedAt; self.appliedAt = appliedAt
        self.appliedMetric = appliedMetric; self.detectorVersion = detectorVersion
    }
}

/// A lesson merged with its persisted state — what the UI actually renders. Keeps
/// the pure `Lesson` (mint output) separate from the adjudication (persistence).
public struct AdjudicatedLesson: Identifiable, Sendable {
    public var id: String { lesson.id }
    public let lesson: Lesson
    public let state: LessonState?

    public init(lesson: Lesson, state: LessonState?) {
        self.lesson = lesson; self.state = state
    }

    public var status: LessonStatus { state?.status ?? .pending }
    public var isPending: Bool { let s = status; return s == .pending || s == .kept }

    /// The verification annotation — "the moment audit stops being a report."
    /// Only present once the lesson has been applied and its headline metric was
    /// snapshotted. Correlation, never causation ("since", never "because").
    public var verification: String? {
        guard status == .applied, let at = state?.appliedAt else { return nil }
        let when = Self.dateFmt.string(from: at)
        guard let was = state?.appliedMetric else {
            return "applied \(when) · verified on the next dream"
        }
        let now = lesson.metricValue
        let delta = now - was
        if delta <= 0 {
            let held = Int(was - now)
            return held > 0
                ? "applied \(when) · was \(fmtMetric(was)), now \(fmtMetric(now)) (−\(held) since — the edit is taking)"
                : "applied \(when) · \(fmtMetric(now)) — holding at zero new since"
        }
        return "applied \(when) · was \(fmtMetric(was)), now \(fmtMetric(now)) (+\(Int(delta)) since — the edit may not have taken)"
    }

    private func fmtMetric(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
}

// MARK: - The miner (the deterministic detector set)

public enum LessonMiner {
    /// Thresholds are the anti-slop mechanism — strict + visible. Below these the
    /// empty state ("workflow is lean") shows, which is the trust engine.
    public static let cacheMissMinDollars = 1.0
    public static let pendingCap = 7   // docs §5 — a queue you clear in one coffee

    /// Mint every firing lesson from the shipped audit findings + settings. Pure:
    /// same inputs → same lessons, so a skeptic re-derives them. `catalog` is used
    /// only to resolve dead-skill folder paths for Reveal-in-Finder.
    public static func mint(report: AuditReport, catalog: [Skill],
                            settings: ClaudeSettings,
                            sessions: [SessionSummary] = [],
                            now: Date = Date()) -> [Lesson] {
        var out: [Lesson] = []
        let modelLegs = sessions.isEmpty
            ? report.subagentModelLegs
            : AuditReport.subagentModelLegs(sessions)
        if let l = modelPin(legs: modelLegs, settings: settings) { out.append(l) }
        if let l = deadSkillArchive(report, catalog: catalog) { out.append(l) }
        if let l = cacheMissDiscipline(report) { out.append(l) }
        if let l = rightSizing(report) { out.append(l) }
        if let l = effortFurnace(settings) { out.append(l) }
        out.sort { $0.rank < $1.rank }
        return out
    }

    // MARK: L-001 — model pin (THE headline)

    /// Compare declared routing policy to resolved child-session legs. Only
    /// silent inheritance is eligible: an explicit Agent `model` override is a
    /// deliberate choice and is excluded even when it differs from policy.
    public static func modelPinMismatches(
        sessions: [SessionSummary],
        settings: ClaudeSettings,
        limit: Int = 12,
        fallbackDay: String? = nil
    ) -> (top: [ModelPinMismatch], total: Double, count: Int) {
        modelPinMismatches(
            legs: AuditReport.subagentModelLegs(sessions), settings: settings,
            limit: limit, fallbackDay: fallbackDay)
    }

    public static func modelPinMismatches(
        legs: [SubagentModelLeg],
        settings: ClaudeSettings,
        limit: Int = 12,
        fallbackDay: String? = nil
    ) -> (top: [ModelPinMismatch], total: Double, count: Int) {
        var mismatches: [ModelPinMismatch] = []
        var total = 0.0

        for leg in legs {
            guard !leg.hasExplicitModelOverride,
                  let policy = settings.policy(forSubagentType: leg.agentType),
                  !modelsMatch(declared: policy.model, resolved: leg.resolvedModel)
            else { continue }

            let repriced = repricedCost(leg, at: policy.model, fallbackDay: fallbackDay)
            let delta = max(0, leg.actualCost - repriced)
            guard delta > 0 else { continue }
            total += delta
            mismatches.append(ModelPinMismatch(
                provider: policy.source,
                sessionID: leg.sessionID,
                project: leg.project,
                agentType: leg.agentType,
                declaredModel: policy.model,
                resolvedModel: leg.resolvedModel,
                deltaDollars: delta,
                filePath: leg.filePath,
                targetPath: targetPath(policy: policy, leg: leg)))
        }

        mismatches.sort {
            $0.deltaDollars != $1.deltaDollars
                ? $0.deltaDollars > $1.deltaDollars
                : $0.sessionID < $1.sessionID
        }
        return (Array(mismatches.prefix(limit)), total, mismatches.count)
    }

    static func modelPin(sessions: [SessionSummary], settings: ClaudeSettings,
                         fallbackDay: String? = nil) -> Lesson? {
        modelPin(
            legs: AuditReport.subagentModelLegs(sessions), settings: settings,
            fallbackDay: fallbackDay)
    }

    static func modelPin(legs: [SubagentModelLeg], settings: ClaudeSettings,
                         fallbackDay: String? = nil) -> Lesson? {
        let result = modelPinMismatches(
            legs: legs, settings: settings, fallbackDay: fallbackDay)
        guard result.count > 0, let lead = result.top.first else { return nil }
        let top = max(lead.deltaDollars, 0.0001)
        let evidence = result.top.prefix(6).map { mismatch in
            LessonEvidence(
                label: mismatch.project,
                detail: "\(mismatch.agentType ?? "subagent") · declared \(mismatch.declaredModel) → resolved \(mismatch.resolvedModel)",
                value: "≈\(fmtUSD(mismatch.deltaDollars))",
                barFraction: mismatch.deltaDollars / top,
                navPath: mismatch.filePath,
                nav: mismatch.filePath.isEmpty ? .none : .inspect)
        }
        let edit = "model: \(lead.declaredModel)"
        let targetLabel = (lead.targetPath as NSString).lastPathComponent
        let candidate = CandidateFix(
            action: .copyEdit,
            summary: "Pin the inherited subagent to the declared model in \(targetLabel).",
            copyText: edit,
            copyLabel: "Copy edit",
            beforeText: "model: inherit",
            afterText: edit,
            revealTargets: [RevealTarget(
                label: targetLabel, detail: edit, path: lead.targetPath)],
            note: "Candidate only — Trifola never writes routing files. Explicit Agent model overrides are excluded.")
        return Lesson(
            kind: .modelPin,
            metricValue: Double(result.count),
            metricLabel: "\(result.count) silent inherits",
            why: "\(result.count) subagent legs resolved above declared policy — ≈\(fmtUSD(result.total)) API-rate difference when repriced at the declared model.",
            evidence: Array(evidence),
            candidate: candidate,
            detectorVersion: "detector v1.1",
            impact: result.total)
    }

    private static func modelsMatch(declared: String, resolved: String) -> Bool {
        let declaredNormalized = PricingCatalog.normalize(declared)
        let resolvedNormalized = PricingCatalog.normalize(resolved)
        if declaredNormalized == resolvedNormalized { return true }
        // Bare policy aliases intentionally match the resolved family.
        if ["opus", "sonnet", "haiku"].contains(declaredNormalized) {
            return ModelTier(raw: declaredNormalized) == ModelTier(raw: resolvedNormalized)
        }
        return false
    }

    private static func repricedCost(
        _ leg: SubagentModelLeg,
        at declaredModel: String,
        fallbackDay: String?
    ) -> Double {
        let catalog = PricingCatalog.current
        let pricedModel: String = switch PricingCatalog.normalize(declaredModel) {
        case "opus": "claude-opus-4-8"
        case "sonnet": "claude-sonnet-5"
        case "haiku": "claude-haiku-4-5"
        default: declaredModel
        }
        if !leg.usageByModelDay.isEmpty {
            return leg.usageByModelDay.reduce(0) { total, daySlice in
                total + daySlice.value.values.reduce(0) {
                    $0 + $1.cost(rate: catalog.resolvedRate(
                        model: pricedModel, onDay: daySlice.key))
                }
            }
        }
        return leg.usage.cost(rate: catalog.resolvedRate(
            model: pricedModel, onDay: fallbackDay))
    }

    private static func targetPath(
        policy: DeclaredRoutingPolicy,
        leg: SubagentModelLeg
    ) -> String {
        // `model:` is valid custom-agent frontmatter, not a standalone settings
        // or CLAUDE.md edit. Point at the concrete project agent definition when
        // its type is known; only fall back to the policy source without a type.
        guard let agentType = leg.agentType, !agentType.isEmpty else {
            return policy.filePath
        }
        let safeType = agentType.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
        }
        let root = leg.cwd.isEmpty
            ? (policy.filePath as NSString).deletingLastPathComponent
            : leg.cwd
        return (root as NSString).appendingPathComponent(
            ".claude/agents/\(String(safeType)).md")
    }

    // MARK: L-002 — dead-skill archive

    static func deadSkillArchive(_ report: AuditReport, catalog: [Skill]) -> Lesson? {
        let ledger = report.skillLedger
        guard ledger.deadCount > 0, !ledger.dead.isEmpty else { return nil }

        // name → SKILL.md path, for Reveal-in-Finder.
        var pathByName: [String: String] = [:]
        for s in catalog { pathByName[s.name] = s.path; pathByName[s.id] = s.path }

        let topDead = Array(ledger.dead.prefix(12))
        let maxTax = max(topDead.first?.descriptionTokens ?? 1, 1)
        let evidence = topDead.prefix(6).map { e -> LessonEvidence in
            let p = pathByName[e.name] ?? ""
            return LessonEvidence(
                label: e.name,
                detail: "never explicitly invoked",
                value: "≈\(fmtTokens(e.descriptionTokens)) prompt tokens",
                barFraction: Double(e.descriptionTokens) / Double(maxTax),
                navPath: p,
                nav: p.isEmpty ? .none : .reveal)
        }

        let listLines = topDead.map {
            "  \($0.name.padding(toLength: 26, withPad: " ", startingAt: 0)) ≈\(fmtTokens($0.descriptionTokens)) prompt tokens"
        }.joined(separator: "\n")
        let copyText = """
        Archive candidates — catalog skills never explicitly invoked, largest prompt footprint first.
        The app NAMES them; you move the folders (it never edits ~/.claude).

        \(listLines)

        Prompt tokens removed if archived: ≈\(fmtTokens(ledger.deadPromptTaxTokens)) description tokens \
        that rides every one of ~\(ledger.sessionCount) sessions' system prompt.
        """
        let revealTargets = topDead.prefix(8).compactMap { e -> RevealTarget? in
            guard let p = pathByName[e.name], !p.isEmpty else { return nil }
            return RevealTarget(label: e.name, detail: "≈\(fmtTokens(e.descriptionTokens)) prompt tokens", path: p)
        }
        let candidate = CandidateFix(
            action: .copyEdit,
            summary: "Copy the priced archive list; Reveal each in Finder and move it out of the catalog.",
            copyText: copyText,
            copyLabel: "Copy list",
            revealTargets: revealTargets,
            note: "The app names them — you move them. Explicit Skill-tool calls only; auto-loaded skills are undercounted, so review before archiving.")

        // Recurring tax: the dead descriptions ride EVERY session's system prompt —
        // but as CACHED content, so the honest per-session rate is cache-READ
        // (input × 0.10) of a representative mid-tier model, NOT raw input and NOT the
        // top tier. Pricing it at raw Opus input × every session overstated it ~10× —
        // exactly the "your math is wrong" failure a cost tool dies from. The dead-skill
        // COUNT is the headline; this dollar figure stays deliberately conservative.
        let taxDollars = Double(ledger.deadPromptTaxTokens) / 1_000_000
            * (ModelTier.sonnet.rates.inp * 0.10) * Double(ledger.sessionCount)
        return Lesson(
            kind: .deadSkillArchive,
            metricValue: Double(ledger.deadCount),
            metricLabel: "\(ledger.deadCount)/\(ledger.catalogCount) skills",
            why: "\(ledger.deadCount) of \(ledger.catalogCount) catalog skills were never explicitly invoked, yet their descriptions ride every session's prompt (≈\(fmtTokens(ledger.deadPromptTaxTokens)) prompt tokens).",
            evidence: Array(evidence),
            candidate: candidate,
            impact: taxDollars)
    }

    // MARK: L-003 — cache-miss discipline

    static func cacheMissDiscipline(_ report: AuditReport) -> Lesson? {
        let total = report.totalLeakDollars
        guard total >= cacheMissMinDollars, !report.cacheMiss.isEmpty else { return nil }
        let leaders = Array(report.cacheMiss.prefix(6))
        let top = max(leaders.first?.leakDollars ?? 1, 0.0001)
        let evidence = leaders.map { f in
            LessonEvidence(
                label: f.project,
                detail: "\(f.handle) · \(fmtPct(f.cacheHitRate)) cached · \(fmtTokens(f.billedInput)) billed input tokens",
                value: fmtUSD(f.leakDollars),
                barFraction: f.leakDollars / top,
                navPath: f.filePath,
                nav: f.filePath.isEmpty ? .none : .inspect)
        }
        let leadNames = leaders.prefix(3)
            .map { "\($0.project) (\(fmtUSD($0.leakDollars)) · \(fmtPct($0.cacheHitRate)) cached)" }
            .joined(separator: ", ")
        let copyText = """
        Context-hygiene habit: these sessions re-sent the most context as fresh \
        input above the warm-cache price (\(fmtUSD(total)) at public API rates; \
        necessary cache setup is excluded). Before a long idle or a \
        task switch, /compact the heavy ones so the next message bills at the ~10% \
        cache-read rate, not fresh input.

        Heaviest: \(leadNames).

        (Cache expiry from idle > 5 min, /compact, and task switches is partly \
        unavoidable — this trims the avoidable slice, it does not claim all of it was waste.)
        """
        let candidate = CandidateFix(
            action: .copyHabit,
            summary: "A context-hygiene habit — /compact heavy sessions before long idles.",
            copyText: copyText,
            copyLabel: "Copy habit",
            note: "Cache expiry is partly unavoidable; the hit-rate column is the honest denominator.")
        return Lesson(
            kind: .cacheMissDiscipline,
            metricValue: total,
            metricLabel: fmtUSD(total),
            why: "\(fmtUSD(total)) is the API-rate difference for context re-sent as fresh input above the warm-cache price; it is not your bill. A warm cache costs about 10% of fresh input, and necessary cache setup is excluded.",
            evidence: evidence,
            candidate: candidate,
            impact: total)
    }

    // MARK: L-004 — right-sizing

    static func rightSizing(_ report: AuditReport) -> Lesson? {
        guard report.mismatchCount > 0, !report.mismatches.isEmpty else { return nil }
        let cands = Array(report.mismatches.prefix(6))
        let top = max(cands.first?.estOverspend ?? 1, 0.0001)
        let evidence = cands.map { c in
            LessonEvidence(
                label: c.project,
                detail: "\(c.handle) · \(c.tier.label) · \(c.messageCount) msgs · \(c.fileEdits) edits · 0 agents",
                value: "≈\(fmtUSD(c.estOverspend))",
                barFraction: c.estOverspend / top,
                navPath: c.filePath,
                nav: c.filePath.isEmpty ? .none : .inspect)
        }
        let list = cands.prefix(3)
            .map { "\($0.project) (\(fmtUSD($0.cost)) API estimate; ≈\(fmtUSD($0.estOverspend)) price difference)" }
            .joined(separator: ", ")
        let copyText = """
        Right-sizing review (heuristic, NOT a verdict): these frontier sessions have a \
        cheap-model shape — few messages, no Agent fan-out, ≤1 file edit — yet billed on \
        Opus. Review whether the task shape warranted the frontier; route \
        similar shapes → Sonnet next time.

        Candidates: \(list).

        Price difference = API-rate cost minus the same tokens repriced at Sonnet. \
        Right-sizing is a per-task judgment — this is evidence to review, not a rule.
        """
        let candidate = CandidateFix(
            action: .copyReview,
            summary: "A labeled-heuristic review list — frontier sessions shaped like Sonnet-tier work.",
            copyText: copyText,
            copyLabel: "Copy review",
            note: "Heuristic, never a verdict — transcript shape is a signal, not proof.")
        return Lesson(
            kind: .rightSizing,
            metricValue: Double(report.mismatchCount),
            metricLabel: "\(report.mismatchCount) candidates",
            why: "\(report.mismatchCount) frontier sessions look like cheaper-model work (few turns, no fan-out) — ≈\(fmtUSD(report.totalMismatchOverspend)) price difference at API rates.",
            evidence: evidence,
            candidate: candidate,
            impact: report.totalMismatchOverspend)
    }

    // MARK: L-005 — effort furnace

    static func effortFurnace(_ settings: ClaudeSettings) -> Lesson? {
        guard settings.effort.isFurnace else { return nil }
        let before = "\"effortLevel\": \"\(settings.effortRaw)\""
        let after  = "\"effortLevel\": \"\(EffortLevel.doctrineDefault.rawValue)\""
        let copyText = """
        High-effort default: settings.json persists effortLevel = "\(settings.effortRaw)" — above the \
        recommended High default. xhigh/max asks the model to spend more compute on every session. \
        Reconsider the persisted default. The app never writes settings — apply via /config \
        or edit settings.json yourself.

          - \(before)
          + \(after)
        """
        let candidate = CandidateFix(
            action: .copySettings,
            summary: "Lower the persisted effort default to High so routine sessions do not request extra compute.",
            copyText: copyText,
            copyLabel: "Copy settings",
            beforeText: before,
            afterText: after,
            note: "The app never writes settings.json — apply this via /config. xhigh/max requests extra compute on every session.")
        return Lesson(
            kind: .effortFurnace,
            metricValue: 1,
            metricLabel: settings.effort.label,
            why: "settings.json persists effortLevel = \(settings.effortRaw), above the recommended High default, so every session requests extra compute.",
            evidence: [LessonEvidence(
                label: "~/.claude/settings.json",
                detail: "persisted default · effortLevel = \(settings.effortRaw)",
                value: settings.effort.label,
                barFraction: 1.0,
                navPath: ClaudeSettings.defaultURL.path,
                nav: .reveal)],
            candidate: candidate,
            impact: 0)
    }
}

// MARK: - The dream pass (deterministic recompute; honest triggers)

/// The trigger that ran a pass — printed on the card / dream line so the UI never
/// implies fake overnight compute (docs §3).
public enum DreamTrigger: String, Sendable, Codable {
    case manual    // "Dream now" button
    case onLaunch  // on-launch delta recompute
    public var label: String { self == .manual ? "Dream now" : "on launch" }
}

/// One line in dreams.jsonl — when it ran, what it scanned, what it minted.
public struct DreamResult: Sendable, Codable, Hashable {
    public let ranAt: Date
    public let trigger: DreamTrigger
    public let sessionsScanned: Int
    public let lessonsMinted: Int
    public let durationMs: Int

    public init(ranAt: Date = Date(), trigger: DreamTrigger, sessionsScanned: Int,
                lessonsMinted: Int, durationMs: Int) {
        self.ranAt = ranAt; self.trigger = trigger; self.sessionsScanned = sessionsScanned
        self.lessonsMinted = lessonsMinted; self.durationMs = durationMs
    }
}

// MARK: - Persistence (the app's OWN dir — NEVER ~/.claude)

/// Reads/writes the ledger's own state beside the index cache. Pure file I/O over
/// Codable — no UI, no state — mirroring RecipeRepository. Directory is injectable
/// so the round-trip is unit-tested against a temp dir.
///
///   ~/Library/Application Support/Trifola/ledger/
///     lessons.json        (lessonID → LessonState — the adjudication)
///     artifacts.jsonl     (append-only audit trail: every verdict, timestamped)
///     dreams.jsonl        (one line per pass: scanned, minted, duration)
public struct LedgerRepository: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/ledger", isDirectory: true)
    }

    public init(directory: URL = LedgerRepository.defaultDirectory) {
        self.directory = directory
    }

    private var lessonsURL: URL { directory.appendingPathComponent("lessons.json") }
    private var artifactsURL: URL { directory.appendingPathComponent("artifacts.jsonl") }
    private var dreamsURL: URL { directory.appendingPathComponent("dreams.jsonl") }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    /// The full adjudication map: lessonID → state.
    public func loadStates() -> [String: LessonState] {
        guard let data = try? Data(contentsOf: lessonsURL),
              let map = try? Self.decoder.decode([String: LessonState].self, from: data) else { return [:] }
        return map
    }

    /// Record a verdict: update the map (lessons.json) AND append an immutable line
    /// to artifacts.jsonl. `appliedMetric` is the headline number snapshotted at
    /// apply time (the verification anchor). Returns the merged map.
    @discardableResult
    public func record(lessonID: String, kind: LessonKind, status: LessonStatus,
                       appliedMetric: Double? = nil, detectorVersion: String = "detector v1",
                       now: Date = Date()) -> [String: LessonState] {
        var states = loadStates()
        var state = states[lessonID] ?? LessonState(status: status, detectorVersion: detectorVersion)
        state.status = status
        state.updatedAt = now
        state.detectorVersion = detectorVersion
        if status == .applied {
            state.appliedAt = now
            if let m = appliedMetric { state.appliedMetric = m }
        }
        states[lessonID] = state
        try? ensureDir()
        if let data = try? Self.encoder.encode(states) {
            try? data.write(to: lessonsURL, options: .atomic)
        }
        appendArtifact(lessonID: lessonID, kind: kind, state: state)
        return states
    }

    private func appendArtifact(lessonID: String, kind: LessonKind, state: LessonState) {
        struct Line: Codable {
            let lessonID: String; let kind: String; let status: String
            let at: Date; let appliedMetric: Double?; let detectorVersion: String
        }
        let line = Line(lessonID: lessonID, kind: kind.rawValue, status: state.status.rawValue,
                        at: state.updatedAt, appliedMetric: state.appliedMetric,
                        detectorVersion: state.detectorVersion)
        guard let data = try? Self.encoder.encode(line) else { return }
        appendLine(data, to: artifactsURL)
    }

    /// Append one dream-pass line to dreams.jsonl.
    public func recordDream(_ result: DreamResult) {
        try? ensureDir()
        guard let data = try? Self.encoder.encode(result) else { return }
        appendLine(data, to: dreamsURL)
    }

    /// The most recent dream pass, decoded from the tail of dreams.jsonl.
    public func lastDream() -> DreamResult? {
        guard let text = try? String(contentsOf: dreamsURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8),
               let r = try? Self.decoder.decode(DreamResult.self, from: data) { return r }
        }
        return nil
    }

    private func appendLine(_ data: Data, to url: URL) {
        try? ensureDir()
        var payload = data
        payload.append(0x0A)
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Ledger store (app-side; owns the minted + adjudicated lessons)

@MainActor
public final class LedgerStore: ObservableObject {
    /// The freshly minted lessons (pure mint output), pre-merge.
    @Published public private(set) var lessons: [Lesson] = []
    /// The adjudication map (lessonID → state), loaded from disk.
    @Published public private(set) var states: [String: LessonState] = [:]
    /// The last dream pass (for the header dream line).
    @Published public private(set) var lastDream: DreamResult? = nil

    private let repo: LedgerRepository

    public init(repo: LedgerRepository = LedgerRepository()) {
        self.repo = repo
        self.states = repo.loadStates()
        self.lastDream = repo.lastDream()
    }

    /// Every lesson merged with its state.
    public var adjudicated: [AdjudicatedLesson] {
        lessons.map { AdjudicatedLesson(lesson: $0, state: states[$0.id]) }
    }

    /// The pending queue — dismissed lessons drop out; an applied lesson stays
    /// visible in its "applied?" state so the next dream can grade it (docs §4.2).
    /// Capped at 7 (docs §5: a queue you clear in one coffee).
    public var pending: [AdjudicatedLesson] {
        Array(adjudicated.filter { $0.status != .dismissed }.prefix(LessonMiner.pendingCap))
    }

    /// The append-only adjudicated ledger — every minted lesson carrying a recorded
    /// verdict (dismissed / applied / kept). "You can audit the auditor."
    public var history: [AdjudicatedLesson] {
        adjudicated.filter { $0.state != nil }
    }

    /// Silently re-mint from the fresh findings — keeps `lessons` + `states` truthful
    /// after any data refresh WITHOUT recording a dream-pass line. So the sidebar
    /// count and the queue reflect current findings even before a real pass runs.
    @discardableResult
    public func remint(report: AuditReport, catalog: [Skill], settings: ClaudeSettings,
                       sessions: [SessionSummary] = [], now: Date = Date()) -> [Lesson] {
        let minted = LessonMiner.mint(
            report: report, catalog: catalog, settings: settings,
            sessions: sessions, now: now)
        // Compare-before-assign (W6 wave 4): the silent remint runs on every data
        // refresh — identical lessons must not republish the Ledger screen.
        if lessons != minted { lessons = minted }
        let loaded = repo.loadStates()
        if states != loaded { states = loaded }
        return minted
    }

    /// Run the deterministic pass and RECORD it (dreams.jsonl + the header dream
    /// line). This is "Dream now" and the on-launch recompute — one path, so the
    /// button and the automatic pass produce identical artifacts. Honest trigger:
    /// the pass is deterministic arithmetic over the warm index, not fake overnight
    /// cognition.
    public func dream(report: AuditReport, catalog: [Skill], settings: ClaudeSettings,
                      sessions: [SessionSummary] = [], sessionsScanned: Int,
                      trigger: DreamTrigger, now: Date = Date()) {
        let t0 = Date()
        let minted = remint(
            report: report, catalog: catalog, settings: settings,
            sessions: sessions, now: now)
        let result = DreamResult(ranAt: now, trigger: trigger, sessionsScanned: sessionsScanned,
                                 lessonsMinted: minted.count,
                                 durationMs: Int(Date().timeIntervalSince(t0) * 1000))
        repo.recordDream(result)
        lastDream = result
    }

    public func dismiss(_ lesson: Lesson) {
        states = repo.record(lessonID: lesson.id, kind: lesson.kind, status: .dismissed)
    }

    public func keep(_ lesson: Lesson) {
        states = repo.record(lessonID: lesson.id, kind: lesson.kind, status: .kept)
    }

    /// Mark applied — snapshots the headline metric so the NEXT dream can grade the
    /// advice ("was 78, now …"). Called when the human copies the edit.
    public func markApplied(_ lesson: Lesson) {
        states = repo.record(lessonID: lesson.id, kind: lesson.kind, status: .applied,
                             appliedMetric: lesson.metricValue)
    }
}
