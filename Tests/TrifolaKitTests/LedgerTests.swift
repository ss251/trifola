import Foundation
import Testing
@testable import TrifolaKit

// THE DREAMING LEDGER (v1 · Lessons) is the capstone — its whole claim is that a
// finding deterministically becomes an ACTIONABLE candidate fix. So the tests pin
// the three load-bearing behaviors: the finding→lesson MAPPING (which detector
// fires on which finding, and — just as important — when it stays quiet), the
// CANDIDATE-EDIT TEXT generation (the copy-able hunk carries the exact doctrine +
// computed fields), and the lesson-state PERSISTENCE round-trip (dismiss/keep/apply
// survives a reload, and the append-only trail is written) — all over synthetic
// fixtures that never move with ~/.claude.

// MARK: - Fixtures

private extension AuditReport {
    /// A report with dead skills (L-002) + a cache-miss leak (L-003) + a
    /// mismatch (L-004).
    static func withFindings() -> AuditReport {
        let ledger = SkillLedger(
            catalogCount: 110, distinctFired: 22, firedInCatalog: 15, deadCount: 95,
            deadPromptTaxTokens: 41_800, sessionCount: 2691, fired: [],
            dead: [SkillLedgerEntry(name: "log-parser", invocations: 0, sessionsTouched: 0,
                                    lastFired: nil, inCatalog: true, descriptionTokens: 980),
                   SkillLedgerEntry(name: "env-linter", invocations: 0, sessionsTouched: 0,
                                    lastFired: nil, inCatalog: true, descriptionTokens: 910)])
        let cacheMiss = [CacheMissFinding(id: "cm1", project: "webapp", shortID: "b1f0c2a9",
                                          filePath: "/p/webapp.jsonl", tier: .opus, leakDollars: 41.30,
                                          firstTouchDollars: 13.20,
                                          cacheHitRate: 0.34, billedInput: 3_050_000, cacheReadTokens: 1_600_000,
                                          contextWeight: 262_000, isSubagent: false)]
        let mismatches = [MismatchCandidate(id: "m1", project: "toolbar-app", shortID: "44c1e0a7",
                                            filePath: "/p/term.jsonl", tier: .opus, cost: 12.40,
                                            estOverspend: 9.80, messageCount: 22, fileEdits: 1, agentCalls: 0)]
        return AuditReport(cacheMiss: cacheMiss, totalLeakDollars: 214.60,
                           totalFirstTouchDollars: 96.40, skillLedger: ledger, mismatches: mismatches,
                           totalMismatchOverspend: 28.30, mismatchCount: 17)
    }
}

private func kinds(_ lessons: [Lesson]) -> Set<LessonKind> { Set(lessons.map(\.kind)) }

// MARK: - Finding → lesson mapping (the core claim)

@Suite("Ledger — finding→lesson mapping")
struct LedgerMappingTests {

    @Test func noLessonsOnACleanReport() {
        // No findings at all → no lesson (the empty state is the point).
        let clean = AuditReport(cacheMiss: [], totalLeakDollars: 0, totalFirstTouchDollars: 0,
                                skillLedger: .empty, mismatches: [],
                                totalMismatchOverspend: 0, mismatchCount: 0)
        let lessons = LessonMiner.mint(report: clean, catalog: [], settings: ClaudeSettings())
        #expect(lessons.isEmpty)                            // nothing to distill
    }

    @Test func effortFurnaceFiresOnlyAboveDoctrine() {
        let quiet = LessonMiner.mint(report: .empty, catalog: [],
                                     settings: ClaudeSettings(model: "opus", effort: .high))
        #expect(!kinds(quiet).contains(.effortFurnace))     // High is the doctrine default → quiet

        let furnace = LessonMiner.mint(report: .empty, catalog: [],
                                       settings: ClaudeSettings(model: "opus", effort: .xhigh, effortRaw: "xhigh"))
        #expect(kinds(furnace).contains(.effortFurnace))    // xhigh is a furnace → fires
        let max = LessonMiner.mint(report: .empty, catalog: [],
                                   settings: ClaudeSettings(model: "opus", effort: .max, effortRaw: "max"))
        #expect(kinds(max).contains(.effortFurnace))
    }

    @Test func deadSkillCacheMissAndMismatchFireFromTheirFindings() {
        let lessons = LessonMiner.mint(report: .withFindings(), catalog: [], settings: ClaudeSettings())
        #expect(kinds(lessons).contains(.deadSkillArchive))
        #expect(kinds(lessons).contains(.cacheMissDiscipline))
        #expect(kinds(lessons).contains(.rightSizing))
    }

    @Test func cacheMissStaysQuietBelowThreshold() {
        // A few pennies of leak must NOT nag (strict thresholds → common empty state).
        let cm = CacheMissFinding(id: "x", project: "p", shortID: "s", filePath: "",
                                  tier: .opus, leakDollars: 0.20, firstTouchDollars: 0.05,
                                  cacheHitRate: 0.9,
                                  billedInput: 1000, cacheReadTokens: 9000, contextWeight: 0, isSubagent: false)
        let r = AuditReport(cacheMiss: [cm], totalLeakDollars: 0.20, totalFirstTouchDollars: 0.05,
                            skillLedger: .empty, mismatches: [],
                            totalMismatchOverspend: 0, mismatchCount: 0)
        let lessons = LessonMiner.mint(report: r, catalog: [], settings: ClaudeSettings())
        #expect(!kinds(lessons).contains(.cacheMissDiscipline))
    }
}

// MARK: - Candidate-edit text generation (the flywheel's payload)

@Suite("Ledger — candidate-edit text")
struct LedgerCandidateTests {

    @Test func effortFurnaceEditIsABeforeAfterSettingsSnippet() {
        let lessons = LessonMiner.mint(report: .empty, catalog: [],
                                       settings: ClaudeSettings(model: "opus", effort: .xhigh, effortRaw: "xhigh"))
        let fix = lessons.first { $0.kind == .effortFurnace }!.candidate
        #expect(fix.action == .copySettings)
        #expect(fix.beforeText == "\"effortLevel\": \"xhigh\"")
        #expect(fix.afterText == "\"effortLevel\": \"high\"")
        #expect(fix.copyText.contains("/config"))          // applied by the human, never by the app
    }

    @Test func deadSkillEditNamesTheSkillsAndTheTax() {
        let lessons = LessonMiner.mint(report: .withFindings(), catalog: [], settings: ClaudeSettings())
        let fix = lessons.first { $0.kind == .deadSkillArchive }!.candidate
        #expect(fix.copyText.contains("log-parser"))
        #expect(fix.copyText.contains("you move")) // "the app names them, you move them"
    }

    @Test func deadSkillRevealTargetsResolveFromTheCatalog() {
        let catalog = [Skill(id: "log-parser", name: "log-parser", description: "d",
                             version: nil, triggers: [], allowedTools: [], hasManifest: true,
                             wordCount: 1, fileCount: 1, modified: Date(),
                             path: "/skills/log-parser/SKILL.md", source: .user)]
        let lessons = LessonMiner.mint(report: .withFindings(), catalog: catalog, settings: ClaudeSettings())
        let fix = lessons.first { $0.kind == .deadSkillArchive }!.candidate
        #expect(fix.revealTargets.contains { $0.path == "/skills/log-parser/SKILL.md" })
    }

    @Test func zeroScannedSessionsInventNoPromptTax() throws {
        let dead = SkillLedgerEntry(name: "unused", invocations: 0, sessionsTouched: 0,
                                    lastFired: nil, inCatalog: true, descriptionTokens: 1_000)
        let ledger = SkillLedger(catalogCount: 1, distinctFired: 0, firedInCatalog: 0,
                                 deadCount: 1, deadPromptTaxTokens: 1_000,
                                 sessionCount: 0, fired: [], dead: [dead])
        let report = AuditReport(cacheMiss: [], totalLeakDollars: 0,
                                 totalFirstTouchDollars: 0, skillLedger: ledger,
                                 mismatches: [], totalMismatchOverspend: 0,
                                 mismatchCount: 0)
        let lesson = try #require(LessonMiner.deadSkillArchive(report, catalog: []))
        #expect(lesson.impact == 0)
    }
}

// MARK: - settings.json reader

@Suite("Ledger — settings reader")
struct LedgerSettingsTests {

    @Test func readsModelAndEffortLevel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try #"{"model":"opus[1m]","effortLevel":"xhigh"}"#.write(to: url, atomically: true, encoding: .utf8)

        let s = ClaudeSettings.load(url)
        #expect(s.model == "opus[1m]")
        #expect(s.effort == .xhigh)
        #expect(s.effortRaw == "xhigh")
    }

    @Test func missingFileDegradesToDoctrineDefault() {
        let s = ClaudeSettings.load(URL(fileURLWithPath: "/no/such/settings.json"))
        #expect(s.effort == .doctrineDefault)               // never a crash, never fabricated
        #expect(!s.effort.isFurnace)
    }
}

// MARK: - Lesson-state persistence round-trip (never ~/.claude)

@Suite("Ledger — state persistence")
struct LedgerPersistenceTests {

    private func tempRepo() -> LedgerRepository {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-state-\(UUID().uuidString)")
        return LedgerRepository(directory: dir)
    }

    @Test func dismissKeepApplyRoundTrips() {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo.directory) }

        repo.record(lessonID: "L-002", kind: .deadSkillArchive, status: .dismissed)
        repo.record(lessonID: "L-003", kind: .cacheMissDiscipline, status: .kept)
        repo.record(lessonID: "L-001", kind: .rightSizing, status: .applied, appliedMetric: 78)

        // Reload through a FRESH repository → state survived the disk round-trip.
        let reloaded = LedgerRepository(directory: repo.directory).loadStates()
        #expect(reloaded["L-002"]?.status == .dismissed)
        #expect(reloaded["L-003"]?.status == .kept)
        #expect(reloaded["L-001"]?.status == .applied)
        #expect(reloaded["L-001"]?.appliedMetric == 78)
        #expect(reloaded["L-001"]?.appliedAt != nil)         // the verification anchor
    }

    @Test func appendOnlyArtifactTrailGrows() throws {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo.directory) }
        repo.record(lessonID: "L-001", kind: .rightSizing, status: .kept)
        repo.record(lessonID: "L-001", kind: .rightSizing, status: .applied, appliedMetric: 78)

        let trail = repo.directory.appendingPathComponent("artifacts.jsonl")
        let text = try String(contentsOf: trail, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)                            // both verdicts recorded, append-only
        #expect(text.contains("\"applied\""))
    }

    @Test func dreamLogRoundTrips() {
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo.directory) }
        #expect(repo.lastDream() == nil)                     // never dreamed
        repo.recordDream(DreamResult(trigger: .manual, sessionsScanned: 5248, lessonsMinted: 4, durationMs: 41))
        repo.recordDream(DreamResult(trigger: .onLaunch, sessionsScanned: 5300, lessonsMinted: 3, durationMs: 12))
        let last = repo.lastDream()
        #expect(last?.trigger == .onLaunch)                  // tail = most recent
        #expect(last?.lessonsMinted == 3)
    }
}

// MARK: - Verification annotation (audit stops being a report)

@Suite("Ledger — verification annotation")
struct LedgerVerificationTests {

    @Test func appliedWithFallingMetricReadsAsTaking() {
        // Applied when the count was 29; the current mint sees 17 → "−12 since".
        let l = LessonMiner.rightSizing(.withFindings())!    // metricValue == 17
        let st = LessonState(status: .applied, appliedAt: Date(), appliedMetric: 29)
        let adj = AdjudicatedLesson(lesson: l, state: st)
        let v = adj.verification!
        #expect(v.contains("−12"))
        #expect(v.contains("taking"))
    }

    @Test func appliedWithRisingMetricReadsAsMaybeNotTaken() {
        let l = LessonMiner.rightSizing(.withFindings())!    // metricValue == 17
        let st = LessonState(status: .applied, appliedAt: Date(), appliedMetric: 9)
        let adj = AdjudicatedLesson(lesson: l, state: st)
        #expect(adj.verification!.contains("+8"))
        #expect(adj.verification!.contains("may not have taken"))
    }

    @Test func pendingLessonHasNoVerification() {
        let l = LessonMiner.rightSizing(.withFindings())!
        #expect(AdjudicatedLesson(lesson: l, state: nil).verification == nil)
    }
}
