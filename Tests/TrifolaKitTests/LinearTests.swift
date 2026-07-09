import Foundation
import Testing
@testable import TrifolaKit

// The Linear one-way exporter is verified LIVE by the user (they paste their own
// personal key). Here we assert everything that must be right BEFORE a key exists:
// the exact projectCreate/projectUpdate/projectUpdateCreate/projectCancel GraphQL
// strings + their variables (human name + plain-words description + targetDate ISO
// + teamId), the SYNC-ELIGIBILITY RULE (only confirmed records sync — an unconfirmed
// parse is a finding and stays local), the stale-mapping CLEANUP (cancel + prune,
// graceful on denial), the reader-first update body, the state mapping, the raw
// (no-"Bearer") auth header, and the exporter's create-then-update idempotency —
// all through a MOCK transport + keychain, no key and no network.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}()
private func day(_ y: Int, _ mo: Int, _ d: Int, _ hh: Int = 12, _ mm: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: hh, minute: mm, second: 0))!
}

// MARK: - Mocks (record requests, return canned data — no live key/network)

private struct MockTransport: LinearTransport {
    let recorded: Locked<[GraphQLRequest]>
    let keys: Locked<[String]>
    let respond: @Sendable (GraphQLRequest) throws -> Data

    init(recorded: Locked<[GraphQLRequest]> = .init([]), keys: Locked<[String]> = .init([]),
         respond: @escaping @Sendable (GraphQLRequest) throws -> Data) {
        self.recorded = recorded
        self.keys = keys
        self.respond = respond
    }

    func send(_ request: GraphQLRequest, key: String) async throws -> Data {
        recorded.withLock { $0.append(request) }
        keys.withLock { $0.append(key) }
        return try respond(request)
    }

    var queries: [String] { recorded.withLock { $0.map(\.query) } }
    var bodies: [String] { recorded.withLock { $0.map { String(data: $0.httpBody(), encoding: .utf8) ?? "" } } }
}

private struct InMemoryKeychain: LinearKeychain {
    let box: Locked<String?>
    init(_ key: String? = nil) { box = .init(key) }
    func readKey() -> String? { box.withLock { $0 } }
    @discardableResult func writeKey(_ key: String) -> Bool { box.withLock { $0 = key }; return true }
    @discardableResult func deleteKey() -> Bool { box.withLock { $0 = nil }; return true }
}

/// Canned Linear responses keyed by which mutation the query carries. A cancel is a
/// projectUpdate whose input is `{state:"canceled"}` — distinguished by the body.
private func linearResponder(_ request: GraphQLRequest) throws -> Data {
    let q = request.query
    let json: String
    if q.contains("projectCreate(") {
        json = #"{"data":{"projectCreate":{"success":true,"project":{"id":"proj_1","url":"https://linear.app/x/project/proj_1"}}}}"#
    } else if q.contains("mutation ProjectUpdate(") {
        json = #"{"data":{"projectUpdate":{"success":true,"project":{"id":"proj_1","url":"https://linear.app/x/project/proj_1"}}}}"#
    } else if q.contains("projectUpdateCreate(") {
        json = #"{"data":{"projectUpdateCreate":{"success":true,"projectUpdate":{"id":"pu_1"}}}}"#
    } else if q.contains("teams") {
        json = #"{"data":{"teams":{"nodes":[{"id":"team_1","name":"Engineering"},{"id":"team_2","name":"Growth"}]}}}"#
    } else {
        json = #"{"data":{}}"#
    }
    return Data(json.utf8)
}

private func card(_ key: String, deadline: Date, now: Date, cost: Double = 14, sessions: Int = 6,
                  last: Date? = nil, shipped: Bool = false, platform: String? = nil,
                  confirmed: Bool = true, kind: DeadlineKind = .hackathon,
                  file: String = "MEMORY.md", line: Int = 47,
                  origin: DeadlineSource.Origin = .parsed) -> DeadlineCard {
    let rec = DeadlineRecord(projectKey: key, deadline: deadline, kind: kind,
                             source: DeadlineSource(file: file, line: line, raw: key,
                                                    confirmed: confirmed, origin: origin),
                             shipped: shipped, platform: platform)
    let act = ProjectActivity(project: key, lastActivity: last, cost: cost, sessionCount: sessions,
                              machineID: Machine.localID, isLive: false, blocked: false)
    return DeadlineCard(record: rec, activity: act, now: now)
}

// MARK: - The exact GraphQL builders

@Suite("Linear GraphQL builders")
struct LinearBuilderTests {

    @Test func teamsQueryIsExact() {
        let r = LinearGraphQL.teams()
        #expect(r.query == "query Teams { teams { nodes { id name } } }")
        #expect(r.variables == .null)
        #expect(String(data: r.httpBody(), encoding: .utf8) ==
                #"{"query":"query Teams { teams { nodes { id name } } }","variables":null}"#)
    }

    @Test func projectCreateStringAndVariablesAreExact() {
        let r = LinearGraphQL.projectCreate(
            name: "Alpha Hackathon",
            description: "Hackathon due July 13, 2026. Source: MEMORY.md line 47.",
            targetDate: "2026-07-13", teamId: "team_1", state: "started")
        #expect(r.query == "mutation ProjectCreate($input: ProjectCreateInput!) { projectCreate(input: $input) { success project { id url } } }")
        #expect(r.variables == .object(["input": .object([
            "name": .string("Alpha Hackathon"),
            "description": .string("Hackathon due July 13, 2026. Source: MEMORY.md line 47."),
            "targetDate": .string("2026-07-13"),
            "teamIds": .array([.string("team_1")]),
            "state": .string("started"),
        ])]))
        // canonical body, sorted keys
        #expect(String(data: r.httpBody(), encoding: .utf8) ==
                #"{"query":"mutation ProjectCreate($input: ProjectCreateInput!) { projectCreate(input: $input) { success project { id url } } }","variables":{"input":{"description":"Hackathon due July 13, 2026. Source: MEMORY.md line 47.","name":"Alpha Hackathon","state":"started","targetDate":"2026-07-13","teamIds":["team_1"]}}}"#)
    }

    @Test func projectUpdateStringAndVariablesAreExact() {
        let r = LinearGraphQL.projectUpdate(
            id: "proj_1",
            description: "Hackathon due July 13, 2026. Source: MEMORY.md line 47.",
            targetDate: "2026-07-13", state: "completed")
        #expect(r.query == "mutation ProjectUpdate($id: String!, $input: ProjectUpdateInput!) { projectUpdate(id: $id, input: $input) { success project { id url } } }")
        #expect(r.variables == .object([
            "id": .string("proj_1"),
            "input": .object([
                "description": .string("Hackathon due July 13, 2026. Source: MEMORY.md line 47."),
                "targetDate": .string("2026-07-13"),
                "state": .string("completed"),
            ]),
        ]))
    }

    @Test func projectCancelReusesProjectUpdateWithCanceledStateOnly() {
        let r = LinearGraphQL.projectCancel(id: "proj_9")
        #expect(r.query == LinearGraphQL.projectUpdateMutation)
        #expect(r.variables == .object([
            "id": .string("proj_9"),
            "input": .object(["state": .string("canceled")]),
        ]))
    }

    @Test func projectUpdateCreateStringAndVariablesAreExact() {
        let body = "On track — last worked 2 hours ago. 3 days left before the deadline. $14 of estimated Claude usage across 6 sessions."
        let r = LinearGraphQL.projectUpdateCreate(projectId: "proj_1", body: body)
        #expect(r.query == "mutation ProjectUpdateCreate($input: ProjectUpdateCreateInput!) { projectUpdateCreate(input: $input) { success projectUpdate { id } } }")
        #expect(r.variables == .object(["input": .object([
            "projectId": .string("proj_1"),
            "body": .string(body),
        ])]))
    }

    @Test func authHeaderIsRawKeyWithNoBearerPrefix() {
        let h = LinearGraphQL.authorizationHeader(key: "lin_api_xxx")
        #expect(h.name == "Authorization")
        #expect(h.value == "lin_api_xxx")          // NO "Bearer " — personal keys are raw
        #expect(!h.value.hasPrefix("Bearer"))
    }
}

// MARK: - Formatting (what a person reads when they open Linear)

@Suite("Linear formatting")
struct LinearFormatTests {

    @Test func targetDateIsUTCCalendarDate() {
        #expect(LinearFormat.targetDate(day(2026, 7, 13, 23, 59)) == "2026-07-13")
        // A late-UTC instant stays on its own day (no off-by-one).
        #expect(LinearFormat.targetDate(day(2026, 1, 5, 0, 0)) == "2026-01-05")
    }

    @Test func stateMapsHonestly() {
        #expect(LinearFormat.state(for: .onTrack) == "started")
        #expect(LinearFormat.state(for: .atRisk) == "started")
        #expect(LinearFormat.state(for: .stalled) == "started")
        #expect(LinearFormat.state(for: .overdue) == "started")   // Linear has no "missed"
        #expect(LinearFormat.state(for: .shipped) == "completed")
    }

    @Test func projectNameIsTheRealNameNeverAMonoSlug() {
        #expect(LinearFormat.projectName(projectKey: "alpha-hackathon") == "Alpha Hackathon")
        #expect(LinearFormat.projectName(projectKey: "my-app") == "My App")
        #expect(LinearFormat.projectName(projectKey: "multihopper") == "Multihopper")
        #expect(LinearFormat.projectName(projectKey: "growth_engine") == "Growth Engine")
        // Existing capitals inside a word survive.
        #expect(LinearFormat.projectName(projectKey: "gpu-Prover") == "Gpu Prover")
    }

    @Test func plainDurationSpeaksInWords() {
        #expect(LinearFormat.plainDuration(52 * 60) == "52 minutes")
        #expect(LinearFormat.plainDuration(60) == "1 minute")
        #expect(LinearFormat.plainDuration(30) == "1 minute")          // floor, never "0 minutes"
        #expect(LinearFormat.plainDuration(2 * 3600) == "2 hours")
        #expect(LinearFormat.plainDuration(86400) == "1 day")
        #expect(LinearFormat.plainDuration(3 * 86400) == "3 days")
    }

    @Test func descriptionIsOneClearSentenceWithDateAndCitation() {
        let now = day(2026, 7, 10)
        let withPlatform = card("alpha-hackathon", deadline: day(2026, 7, 13), now: now,
                                platform: "Slack Agent Builder Challenge")
        #expect(LinearFormat.projectDescription(withPlatform) ==
                "Hackathon due July 13, 2026 — Slack Agent Builder Challenge. Source: MEMORY.md line 47.")

        let bare = card("multihopper", deadline: day(2026, 7, 10), now: now, kind: .bounty, line: 91)
        #expect(LinearFormat.projectDescription(bare) ==
                "Bounty due July 10, 2026. Source: MEMORY.md line 91.")
    }

    @Test func descriptionCitesManualAndOverrideOrigins() {
        let now = day(2026, 7, 10)
        let manual = card("webapp", deadline: day(2026, 7, 19), now: now, origin: .manual)
        #expect(LinearFormat.projectDescription(manual) ==
                "Hackathon due July 19, 2026. Set by hand in Claude Mission Control.")

        let override = card("webapp", deadline: day(2026, 7, 19), now: now, kind: .gate,
                            file: "deadlines.toml", line: 0, origin: .override)
        #expect(LinearFormat.projectDescription(override) ==
                "Gate due July 19, 2026. Source: deadlines.toml.")
    }

    @Test func updateBodyLeadsWithStatusThenDeadlineThenSpend() {
        let now = day(2026, 7, 10, 12, 0)
        let c = card("slack", deadline: day(2026, 7, 13, 12, 0), now: now,
                     cost: 14, sessions: 6, last: day(2026, 7, 10, 10, 0))   // idle 2h, runway 3d
        #expect(LinearFormat.updateBody(c) ==
                "On track — last worked 2 hours ago. 3 days left before the deadline. $14 of estimated Claude usage across 6 sessions.")
    }

    @Test func updateBodyHandlesUntouchedAndOverdue() {
        let now = day(2026, 7, 20, 12, 0)
        let c = card("late", deadline: day(2026, 7, 17, 12, 0), now: now, cost: 3, sessions: 1, last: nil)
        #expect(LinearFormat.updateBody(c) ==
                "Overdue — not worked on yet. The deadline passed 3 days ago. $3.00 of estimated Claude usage across 1 session.")
    }

    @Test func updateBodyForShippedIsShort() {
        let now = day(2026, 7, 10, 12, 0)
        let c = card("done", deadline: day(2026, 7, 1), now: now, cost: 22, sessions: 7,
                     last: day(2026, 7, 1), shipped: true)
        #expect(LinearFormat.updateBody(c) ==
                "Shipped. $22 of estimated Claude usage across 7 sessions.")
    }

    @Test func updateBodyNeverEmitsJargonOrISOTimestamps() {
        let now = day(2026, 7, 10, 12, 0)
        let cards = [
            card("a", deadline: day(2026, 7, 13), now: now, last: day(2026, 7, 10, 10, 0)),
            card("b", deadline: day(2026, 7, 1), now: now, last: nil),
            card("c", deadline: day(2026, 7, 1), now: now, shipped: true),
        ]
        for c in cards {
            let body = LinearFormat.updateBody(c)
            #expect(!body.lowercased().contains("jeopardy"))
            #expect(!body.contains(" · "))                                  // no telemetry soup
            #expect(body.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil)
        }
    }
}

// MARK: - The eligibility rule (a parse is a FINDING, not a deadline)

@Suite("Linear sync eligibility")
struct LinearEligibilityTests {
    private let now = day(2026, 7, 10)

    @Test func onlyConfirmedRecordsAreSyncable() {
        #expect(LinearEligibility.isSyncable(card("a", deadline: day(2026, 7, 13), now: now, confirmed: true)))
        #expect(!LinearEligibility.isSyncable(card("b", deadline: day(2026, 7, 13), now: now, confirmed: false)))
    }

    @Test func manualOverrideAndSeededOriginsAreConfirmedByConstruction() {
        // The rule keys on source.confirmed, which every non-parse origin sets.
        for origin in [DeadlineSource.Origin.manual, .override, .seeded] {
            let c = card("x", deadline: day(2026, 7, 13), now: now, confirmed: true, origin: origin)
            #expect(LinearEligibility.isSyncable(c))
        }
    }
}

// MARK: - Response parsing

@Suite("Linear response parsing")
struct LinearResponseTests {
    @Test func parsesProjectID() throws {
        let data = Data(#"{"data":{"projectCreate":{"project":{"id":"proj_9"}}}}"#.utf8)
        #expect(try LinearResponse.projectID(from: data, field: "projectCreate") == "proj_9")
    }
    @Test func parsesProjectURLForThePanelLinks() throws {
        let data = Data(#"{"data":{"projectCreate":{"project":{"id":"proj_9","url":"https://linear.app/x/project/proj_9"}}}}"#.utf8)
        let p = try LinearResponse.project(from: data, field: "projectCreate")
        #expect(p.id == "proj_9")
        #expect(p.url == "https://linear.app/x/project/proj_9")
    }
    @Test func missingURLIsNilNotAnError() throws {
        let data = Data(#"{"data":{"projectUpdate":{"project":{"id":"proj_9"}}}}"#.utf8)
        let p = try LinearResponse.project(from: data, field: "projectUpdate")
        #expect(p.url == nil)
    }
    @Test func parsesTeams() throws {
        let data = Data(#"{"data":{"teams":{"nodes":[{"id":"t1","name":"Eng"},{"id":"t2","name":"Growth"}]}}}"#.utf8)
        let teams = try LinearResponse.teams(from: data)
        #expect(teams == [LinearTeam(id: "t1", name: "Eng"), LinearTeam(id: "t2", name: "Growth")])
    }
    @Test func surfacesAuthError() {
        let data = Data(#"{"errors":[{"message":"Authentication required"}]}"#.utf8)
        #expect(throws: LinearError.auth) { _ = try LinearResponse.teams(from: data) }
    }
    @Test func surfacesGenericGraphQLError() {
        let data = Data(#"{"errors":[{"message":"Field is invalid"}]}"#.utf8)
        #expect(throws: LinearError.graphQL("Field is invalid")) { _ = try LinearResponse.projectID(from: data, field: "projectCreate") }
    }
}

// MARK: - The idempotent decision

@Suite("Linear upsert decision")
struct LinearDecisionTests {
    @Test func noMappingCreates() { #expect(LinearSync.decide(mappedID: nil) == .create) }
    @Test func emptyMappingCreates() { #expect(LinearSync.decide(mappedID: "") == .create) }
    @Test func mappedUpdatesInPlace() { #expect(LinearSync.decide(mappedID: "proj_1") == .update(id: "proj_1")) }
}

// MARK: - The exporter (eligibility, idempotency, cleanup — mock transport + keychain)

@Suite("Linear exporter")
struct LinearExporterTests {
    private let now = day(2026, 7, 10, 12, 0)

    @Test func firstSyncCreatesThenUpdatesInPlace() async throws {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("lin_key"), teamID: "team_1")
        let c = card("slack", deadline: day(2026, 7, 13, 12, 0), now: now, last: day(2026, 7, 10, 10, 0))

        // First sync — no mapping → projectCreate + projectUpdateCreate.
        let r1 = try await exporter.upsert([c], map: [:], now: now)
        #expect(r1.created == ["slack"])
        #expect(r1.updated.isEmpty)
        #expect(r1.map["slack"] == "proj_1")
        #expect(transport.queries.contains { $0.contains("projectCreate(") })
        #expect(transport.queries.contains { $0.contains("projectUpdateCreate(") })
        #expect(!transport.queries.contains { $0.contains("projectUpdate(") && !$0.contains("projectUpdateCreate(") })

        // Second sync — carry the map forward → projectUpdate, NEVER a second create.
        let transport2 = MockTransport(respond: linearResponder)
        let exporter2 = LinearExporter(transport: transport2, keychain: InMemoryKeychain("lin_key"), teamID: "team_1")
        let r2 = try await exporter2.upsert([c], map: r1.map, now: now)
        #expect(r2.updated == ["slack"])
        #expect(r2.created.isEmpty)
        #expect(r2.map["slack"] == "proj_1")                                  // idempotent — same id
        #expect(!transport2.queries.contains { $0.contains("projectCreate(") })  // no duplicate project
        #expect(transport2.queries.contains { $0.contains("mutation ProjectUpdate(") })
    }

    @Test func unconfirmedFindingsNeverLeaveTheMachine() async throws {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("k"), teamID: "team_1")
        let confirmed = card("webapp", deadline: day(2026, 7, 19), now: now, confirmed: true)
        let finding = card("scratch-notes", deadline: day(2026, 7, 14), now: now, confirmed: false)

        let r = try await exporter.upsert([confirmed, finding], map: [:], now: now)
        #expect(r.created == ["webapp"])
        #expect(r.skipped == ["scratch-notes"])
        #expect(r.map["scratch-notes"] == nil)                    // never mapped, never pushed
        // No request body ever mentions the unconfirmed project.
        #expect(transport.bodies.allSatisfy { !$0.contains("scratch-notes") && !$0.contains("Scratch Notes") })
        // The report shows both outcomes.
        #expect(r.rows.contains(LinearSyncRow(projectKey: "webapp", name: "Webapp",
                                              url: "https://linear.app/x/project/proj_1", outcome: .created)))
        #expect(r.rows.contains(LinearSyncRow(projectKey: "scratch-notes", name: "Scratch Notes",
                                              url: nil, outcome: .skipped)))
    }

    @Test func allUnconfirmedMeansNothingIsPushed() async throws {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("k"), teamID: "team_1")
        let r = try await exporter.upsert([
            card("a", deadline: day(2026, 7, 13), now: now, confirmed: false),
            card("b", deadline: day(2026, 7, 14), now: now, confirmed: false),
        ], map: [:], now: now)
        #expect(transport.queries.isEmpty)                        // zero network traffic
        #expect(r.skipped == ["a", "b"])
        #expect(r.created.isEmpty && r.updated.isEmpty)
    }

    @Test func staleMappedProjectsAreCanceledAndPruned() async throws {
        // A past sync pushed junk: "scratch" is now unconfirmed locally, "gone" retracted
        // entirely. Both mapped ids get projectCancel and leave the map.
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("k"), teamID: "team_1")
        let scratch = card("scratch", deadline: day(2026, 7, 14), now: now, confirmed: false)
        let keep = card("webapp", deadline: day(2026, 7, 19), now: now, confirmed: true)

        let r = try await exporter.upsert([keep, scratch],
                                          map: ["webapp": "proj_1", "scratch": "proj_8", "gone": "proj_9"],
                                          now: now)
        #expect(r.updated == ["webapp"])
        #expect(r.canceled == ["gone", "scratch"])                // sorted, deterministic
        #expect(r.map == ["webapp": "proj_1"])                     // stale mappings pruned
        // The cancel really is `state: canceled` against the mapped ids.
        let cancels = transport.recorded.withLock { $0 }.filter {
            $0.variables.serialized().contains(#""state":"canceled""#)
        }
        #expect(cancels.count == 2)
        #expect(cancels.contains { $0.variables.serialized().contains(#""id":"proj_8""#) })
        #expect(cancels.contains { $0.variables.serialized().contains(#""id":"proj_9""#) })
        #expect(r.rows.contains { $0.projectKey == "scratch" && $0.outcome == .canceled })
        #expect(r.rows.contains { $0.projectKey == "gone" && $0.outcome == .canceled })
    }

    @Test func cancelDenialIsGracefulAndStillPrunesTheMapping() async throws {
        // Linear refuses the cancel (permissions) → no throw, the sync completes,
        // the mapping is pruned anyway (local truth already dropped the record).
        let transport = MockTransport { request in
            if request.variables.serialized().contains(#""state":"canceled""#) {
                throw LinearError.graphQL("You don't have permission to update this project")
            }
            return try linearResponder(request)
        }
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("k"), teamID: "team_1")
        let keep = card("webapp", deadline: day(2026, 7, 19), now: now, confirmed: true)

        let r = try await exporter.upsert([keep], map: ["webapp": "proj_1", "junk": "proj_8"], now: now)
        #expect(r.updated == ["webapp"])                           // the sync itself succeeded
        #expect(r.canceled.isEmpty)
        #expect(r.cancelDenied == ["junk"])
        #expect(r.map == ["webapp": "proj_1"])                     // pruned despite the denial
        #expect(r.rows.contains { $0.projectKey == "junk" && $0.outcome == .cancelDenied })
    }

    @Test func sendsTheRawKeyEverySend() async throws {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("lin_secret"), teamID: "team_1")
        _ = try await exporter.upsert([card("slack", deadline: day(2026, 7, 13), now: now)], map: [:], now: now)
        let usedKeys = transport.keys.withLock { $0 }
        #expect(usedKeys.allSatisfy { $0 == "lin_secret" })
        #expect(!usedKeys.isEmpty)
    }

    @Test func nameDescriptionTargetDateAndStateFlowIntoTheMutation() async throws {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("k"), teamID: "team_7")
        let shipped = card("ai-contest", deadline: day(2026, 7, 13), now: now, shipped: true,
                           platform: "OKX AI Genesis")
        _ = try await exporter.upsert([shipped], map: [:], now: now)
        let create = transport.recorded.withLock { $0 }.first { $0.query.contains("projectCreate(") }
        // name = the real name in words; description = kind + plain date + platform +
        // citation; targetDate = the deadline (UTC day); state = completed (shipped).
        #expect(create?.variables == .object(["input": .object([
            "name": .string("Ai Contest"),
            "description": .string("Hackathon due July 13, 2026 — OKX AI Genesis. Source: MEMORY.md line 47."),
            "targetDate": .string("2026-07-13"),
            "teamIds": .array([.string("team_7")]),
            "state": .string("completed"),
        ])]))
    }

    @Test func theHumanUpdateBodyIsWhatGetsPosted() async throws {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("k"), teamID: "team_1")
        let c = card("slack", deadline: day(2026, 7, 13, 12, 0), now: now,
                     cost: 14, sessions: 6, last: day(2026, 7, 10, 10, 0))
        _ = try await exporter.upsert([c], map: [:], now: now)
        let post = transport.recorded.withLock { $0 }.first { $0.query.contains("projectUpdateCreate(") }
        #expect(post?.variables == .object(["input": .object([
            "projectId": .string("proj_1"),
            "body": .string("On track — last worked 2 hours ago. 3 days left before the deadline. $14 of estimated Claude usage across 6 sessions."),
        ])]))
    }

    @Test func noKeyIsANoOpThatSurfacesCalmly() async {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain(nil), teamID: "team_1")
        await #expect(throws: LinearError.noKey) {
            _ = try await exporter.upsert([card("slack", deadline: day(2026, 7, 13), now: now)], map: [:], now: now)
        }
        #expect(transport.queries.isEmpty)   // never touched the network without a key
    }

    @Test func authErrorPropagatesNeverCrashes() async {
        let transport = MockTransport { _ in throw LinearError.auth }
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("bad_key"), teamID: "team_1")
        await #expect(throws: LinearError.auth) {
            _ = try await exporter.upsert([card("slack", deadline: day(2026, 7, 13), now: now)], map: [:], now: now)
        }
    }

    @Test func fetchTeamsForThePicker() async throws {
        let transport = MockTransport(respond: linearResponder)
        let exporter = LinearExporter(transport: transport, keychain: InMemoryKeychain("k"), teamID: "")
        let teams = try await exporter.fetchTeams()
        #expect(teams == [LinearTeam(id: "team_1", name: "Engineering"), LinearTeam(id: "team_2", name: "Growth")])
    }
}

// MARK: - Map + settings persistence (app-owned dir, never ~/.claude)

@Suite("Linear persistence")
struct LinearPersistenceTests {

    @Test func mapAndSettingsLiveUnderAppSupportNotDotClaude() {
        #expect(LinearMapStore.defaultURL.path.contains("Application Support/Trifola/linear-map.json"))
        #expect(!LinearMapStore.defaultURL.path.contains("/.claude/"))
        #expect(LinearSettingsStore.defaultURL.path.contains("Application Support/Trifola/linear.json"))
    }

    @Test func mapRoundTrips() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-linmap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LinearMapStore(url: tmp)
        #expect(store.save(["slack": "proj_1", "webapp": "proj_2"]) == true)
        #expect(store.load() == ["slack": "proj_1", "webapp": "proj_2"])
    }

    @Test func settingsRoundTrip() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-linset-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LinearSettingsStore(url: tmp)
        #expect(store.save(LinearSettings(teamID: "team_1", teamName: "Engineering", backgroundSync: true)) == true)
        let back = store.load()
        #expect(back.teamID == "team_1")
        #expect(back.teamName == "Engineering")
        #expect(back.backgroundSync == true)
    }
}
