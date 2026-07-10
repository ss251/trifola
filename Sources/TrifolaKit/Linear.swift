import Foundation
import Security

// MARK: - THE LINEAR ONE-WAY EXPORTER (docs/DEADLINE_BOARD.md §8) — v1, opt-in
//
// Linear is a render target behind an adapter, never a dependency. The local board
// is fully useful with Linear off; pushing to Linear is a one-directional export for
// the subset of users who already live there. 1 hackathon = 1 Linear Project, keyed
// on a native `targetDate`, idempotent via a local {projectKey → linearProjectId} map.
//
// Every builder here is PURE — the exact projectCreate/projectUpdate/projectUpdateCreate
// GraphQL strings + variables, the idempotent-upsert DECISION, the sync-eligibility
// rule (CONFIRMED records only — an unconfirmed parse is a finding and stays local),
// the reader-first name/description/update-body, the stale-mapping cleanup, and the
// state mapping are all asserted in tests WITHOUT a live key or network. The
// Keychain and the HTTP transport sit behind protocols so the exporter is exercised
// with mocks; the live sync is verified by the user pasting their own key in-app.
//
// AUTH: a Linear PERSONAL API KEY, read from the macOS Keychain (service
// "com.ss251.trifola", account "linear-api-key") and sent in an
// `Authorization: <key>` header — NO "Bearer " prefix (personal keys are raw). The
// key is NEVER written to a file and NEVER logged.

// MARK: - Minimal ordered-serializing JSON value

/// A JSON tree with a deterministic, sorted-key serialization so the exact GraphQL
/// request body can be asserted byte-for-byte. Equatable so tests compare variable
/// trees directly.
public indirect enum JSONValue: Sendable, Equatable, Hashable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Canonical JSON — keys sorted, no incidental whitespace — deterministic across
    /// runs and machines.
    public func serialized() -> String {
        switch self {
        case .string(let s): return Self.encode(s)
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .null: return "null"
        case .array(let items): return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let map):
            let body = map.keys.sorted().map { k in
                Self.encode(k) + ":" + map[k]!.serialized()
            }.joined(separator: ",")
            return "{" + body + "}"
        }
    }

    private static func encode(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) }
                else { out.unicodeScalars.append(ch) }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - The GraphQL request (query + variables, one canonical body)

public struct GraphQLRequest: Sendable, Equatable {
    public let query: String
    public let variables: JSONValue    // an .object, or .null for a variable-less query

    public init(query: String, variables: JSONValue = .null) {
        self.query = query
        self.variables = variables
    }

    /// The exact wire body POSTed to Linear.
    public func httpBody() -> Data {
        let root = JSONValue.object(["query": .string(query), "variables": variables])
        return Data(root.serialized().utf8)
    }
}

// MARK: - The pure builders

public enum LinearGraphQL {
    public static let endpoint = URL(string: "https://api.linear.app/graphql")!

    /// The header rule, made testable: personal keys are RAW — no "Bearer " prefix.
    public static func authorizationHeader(key: String) -> (name: String, value: String) {
        ("Authorization", key)
    }

    // ---- teams (the team picker's source) ----
    public static let teamsQuery = "query Teams { teams { nodes { id name } } }"
    public static func teams() -> GraphQLRequest { GraphQLRequest(query: teamsQuery) }

    // ---- projectCreate (first sync) ----
    public static let projectCreateMutation =
        "mutation ProjectCreate($input: ProjectCreateInput!) { projectCreate(input: $input) { success project { id url } } }"
    public static func projectCreate(name: String, description: String, targetDate: String,
                                     teamId: String, state: String) -> GraphQLRequest {
        let input: JSONValue = .object([
            "name": .string(name),
            "description": .string(description),
            "targetDate": .string(targetDate),
            "teamIds": .array([.string(teamId)]),
            "state": .string(state),
        ])
        return GraphQLRequest(query: projectCreateMutation, variables: .object(["input": input]))
    }

    // ---- projectUpdate (every sync after) ----
    public static let projectUpdateMutation =
        "mutation ProjectUpdate($id: String!, $input: ProjectUpdateInput!) { projectUpdate(id: $id, input: $input) { success project { id url } } }"
    public static func projectUpdate(id: String, description: String, targetDate: String,
                                     state: String) -> GraphQLRequest {
        let input: JSONValue = .object([
            "description": .string(description),
            "targetDate": .string(targetDate),
            "state": .string(state),
        ])
        return GraphQLRequest(query: projectUpdateMutation,
                              variables: .object(["id": .string(id), "input": input]))
    }

    // ---- projectCancel (cleanup: a synced record that is no longer a confirmed
    //      deadline locally gets its Linear project marked canceled — same
    //      projectUpdate mutation, `state: canceled` only) ----
    public static func projectCancel(id: String) -> GraphQLRequest {
        GraphQLRequest(query: projectUpdateMutation,
                       variables: .object(["id": .string(id),
                                           "input": .object(["state": .string("canceled")])]))
    }

    // ---- projectUpdateCreate (the telemetry project update) ----
    public static let projectUpdateCreateMutation =
        "mutation ProjectUpdateCreate($input: ProjectUpdateCreateInput!) { projectUpdateCreate(input: $input) { success projectUpdate { id } } }"
    public static func projectUpdateCreate(projectId: String, body: String) -> GraphQLRequest {
        let input: JSONValue = .object([
            "projectId": .string(projectId),
            "body": .string(body),
        ])
        return GraphQLRequest(query: projectUpdateCreateMutation, variables: .object(["input": input]))
    }
}

// MARK: - Formatting (targetDate ISO · state map · reader-first name/description/update)
//
// Everything that lands in Linear is written for a PERSON opening Linear cold, not
// for this app's dense evidence grammar: the project gets its real name in words
// (never a mono slug), the description is one clear sentence (what it is, when it's
// due in plain English, where the date came from), and each sync posts a short
// status update in sentences — status first, deadline distance second, spend facts
// last. No "jeopardy 48.23", no raw ISO timestamps, no `·`-telemetry soup.

public enum LinearFormat {
    /// Linear's `targetDate` is a plain calendar date `YYYY-MM-DD` (UTC-normalized so
    /// it never drifts a day across time zones).
    public static func targetDate(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Card state → Linear lifecycle `state`, honestly: shipped → completed; everything
    /// in-progress (on-track / at-risk / stalled / overdue-unshipped) → started. Linear
    /// has no "missed", and faking `canceled` would lie (§8) — `canceled` is reserved
    /// for the cleanup lane (a record that stopped being a confirmed deadline here).
    public static func state(for s: DeadlineState) -> String {
        switch s {
        case .shipped: return "completed"
        case .onTrack, .atRisk, .stalled, .overdue: return "started"
        }
    }

    /// The Linear project's name — the project's real name in words. A repo slug like
    /// `alpha-hackathon` reads "Alpha Hackathon"; never the raw mono key.
    public static func projectName(projectKey: String) -> String {
        let words = projectKey.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        guard !words.isEmpty else { return projectKey }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The date in plain words — "July 13, 2026" — for sentences a person reads.
    public static func plainDate(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    /// A duration in plain words — "3 days" / "18 hours" / "52 minutes" — never the
    /// board's compact "3d".
    public static func plainDuration(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 3600 { let m = max(1, s / 60); return "\(m) minute\(m == 1 ? "" : "s")" }
        if s < 86400 { let h = s / 3600; return "\(h) hour\(h == 1 ? "" : "s")" }
        let d = s / 86400
        return "\(d) day\(d == 1 ? "" : "s")"
    }

    /// The project description: one clear sentence — what this is (hackathon / bounty
    /// / gate), the deadline in plain words, the platform context if the notes carried
    /// one — plus the source citation.
    /// "Hackathon due July 13, 2026 — OSS Plugin Challenge. Source: MEMORY.md line 47."
    public static func projectDescription(_ card: DeadlineCard) -> String {
        var first = "\(kindNoun(card.kind)) due \(plainDate(card.deadline))"
        if let p = card.platform?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            first += " — \(p)"
        }
        return first + ". " + citation(card.source)
    }

    static func kindNoun(_ kind: DeadlineKind) -> String {
        switch kind {
        case .hackathon: return "Hackathon"
        case .bounty: return "Bounty"
        case .gate: return "Gate"
        case .audit: return "Audit"
        case .other: return "Deadline"
        }
    }

    static func citation(_ source: DeadlineSource) -> String {
        switch source.origin {
        case .manual:
            return "Set by hand in Trifola."
        case .override:
            return "Source: \(source.file.isEmpty ? "deadlines.toml" : source.file)."
        case .parsed, .seeded:
            guard !source.file.isEmpty else { return "Tracked by Trifola." }
            let loc = source.line > 0 ? " line \(source.line)" : ""
            return "Source: \(source.file)\(loc)."
        }
    }

    static func statusLead(_ state: DeadlineState) -> String {
        switch state {
        case .onTrack: return "On track"
        case .atRisk:  return "At risk"
        case .stalled: return "Stalled"
        case .shipped: return "Shipped"
        case .overdue: return "Overdue"
        }
    }

    /// The per-sync project update — the one thing Linear can't compute, written as
    /// short sentences: status first, then the deadline distance, then the spend
    /// facts as a secondary line.
    /// "On track — last worked 2 hours ago. 3 days left before the deadline.
    ///  $14 of estimated Claude usage across 6 sessions."
    public static func updateBody(_ card: DeadlineCard) -> String {
        var sentences: [String] = []
        if card.state == .shipped {
            sentences.append("Shipped.")
        } else {
            if let last = card.lastActivity {
                sentences.append("\(statusLead(card.state)) — last worked \(plainDuration(card.now.timeIntervalSince(last))) ago.")
            } else {
                sentences.append("\(statusLead(card.state)) — not worked on yet.")
            }
            if card.runway >= 0 {
                sentences.append("\(plainDuration(card.runway)) left before the deadline.")
            } else {
                sentences.append("The deadline passed \(plainDuration(-card.runway)) ago.")
            }
        }
        if card.sessionCount > 0 {
            sentences.append("\(fmtUSD(card.cost)) of estimated Claude usage across \(card.sessionCount) session\(card.sessionCount == 1 ? "" : "s").")
        } else {
            sentences.append("No Claude sessions recorded yet.")
        }
        return sentences.joined(separator: " ")
    }
}

// MARK: - Sync eligibility (a parse is a FINDING, not a deadline)

/// Only a deadline the user has stood behind may leave the machine: confirmed
/// one-click, edited in-app, a `.toml` override, or a programmatic seed — all of
/// which set `source.confirmed`. An unconfirmed parse is a local finding behind its
/// "confirm?" affordance; it never syncs to Linear.
public enum LinearEligibility {
    public static func isSyncable(_ card: DeadlineCard) -> Bool { card.source.confirmed }
    public static func isSyncable(_ record: DeadlineRecord) -> Bool { record.source.confirmed }
}

// MARK: - The idempotent-upsert decision (pure)

public enum LinearUpsert: Sendable, Equatable {
    case create
    case update(id: String)
}

public enum LinearSync {
    /// no mapping → create; has a mapped id → update in place. This is what keeps every
    /// re-sync an upsert (never a duplicate project).
    public static func decide(mappedID: String?) -> LinearUpsert {
        if let id = mappedID, !id.isEmpty { return .update(id: id) }
        return .create
    }
}

// MARK: - Errors

public enum LinearError: Error, Sendable, Equatable {
    case noKey
    case auth
    case graphQL(String)
    case badResponse
}

// MARK: - Team

public struct LinearTeam: Sendable, Equatable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

// MARK: - Response parsing (exercised with mock transport data — no network)

public enum LinearResponse {
    /// data.<field>.project.{id,url} (projectCreate/projectUpdate). Surfaces GraphQL
    /// errors. The url feeds the panel's "synced → <project>" links.
    public static func project(from data: Data, field: String) throws -> (id: String, url: String?) {
        let obj = try root(data)
        guard let d = obj["data"] as? [String: Any],
              let node = d[field] as? [String: Any],
              let project = node["project"] as? [String: Any],
              let id = project["id"] as? String, !id.isEmpty else { throw LinearError.badResponse }
        return (id, project["url"] as? String)
    }

    /// data.<field>.project.id — the id-only convenience.
    public static func projectID(from data: Data, field: String) throws -> String {
        try project(from: data, field: field).id
    }

    /// data.teams.nodes[] → [LinearTeam].
    public static func teams(from data: Data) throws -> [LinearTeam] {
        let obj = try root(data)
        guard let d = obj["data"] as? [String: Any],
              let teams = d["teams"] as? [String: Any],
              let nodes = teams["nodes"] as? [[String: Any]] else { throw LinearError.badResponse }
        return nodes.compactMap { n in
            guard let id = n["id"] as? String, let name = n["name"] as? String else { return nil }
            return LinearTeam(id: id, name: name)
        }
    }

    private static func root(_ data: Data) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LinearError.badResponse
        }
        if let errors = obj["errors"] as? [[String: Any]], let first = errors.first {
            let msg = (first["message"] as? String) ?? "GraphQL error"
            if msg.lowercased().contains("authentication") || msg.lowercased().contains("unauthorized") {
                throw LinearError.auth
            }
            throw LinearError.graphQL(msg)
        }
        return obj
    }
}

// MARK: - Protocol seams (so the exporter is testable WITHOUT a live key/network)

public protocol LinearTransport: Sendable {
    /// POST one GraphQL request with the raw personal key in the Authorization header.
    func send(_ request: GraphQLRequest, key: String) async throws -> Data
}

public protocol LinearKeychain: Sendable {
    func readKey() -> String?
    /// Presence-only check — MUST be a protocol requirement (not just an extension
    /// default) so a concrete store's metadata-only override is dynamically
    /// dispatched even through a `LinearKeychain`-typed reference. Without this line
    /// `DeadlineScreen`'s `let keychain: LinearKeychain = KeychainLinearStore()`
    /// statically bound to the DECRYPTING extension default below → `readKey()` →
    /// SecItemCopyMatching decrypt → a SecurityAgent ACL prompt + a main-thread
    /// freeze at launch (the "buffering" the render-storm work was chasing).
    func keyPresent() -> Bool
    @discardableResult func writeKey(_ key: String) -> Bool
    @discardableResult func deleteKey() -> Bool
}

public extension LinearKeychain {
    /// Is a key present? The connection-state check needs a BOOLEAN, not the secret —
    /// and the real store must never DECRYPT the key just to answer it. `readKey()` used
    /// to back this and it decrypts (SecItemCopyMatching + kSecReturnData): a single
    /// launch-time call spent a full core inside Security's crypto and froze the UI in a
    /// "buffering" state (the render-storm's true cause). This default is fine for test
    /// mocks; `KeychainLinearStore` overrides it with a metadata-only existence check.
    func keyPresent() -> Bool {
        if let k = readKey() { return !k.isEmpty }
        return false
    }
}

// MARK: - Real transport (URLSession)

public struct URLSessionLinearTransport: LinearTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: GraphQLRequest, key: String) async throws -> Data {
        var req = URLRequest(url: LinearGraphQL.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let auth = LinearGraphQL.authorizationHeader(key: key)   // raw key — NO Bearer prefix
        req.setValue(auth.value, forHTTPHeaderField: auth.name)
        req.httpBody = request.httpBody()
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw LinearError.auth
        }
        return data
    }
}

// MARK: - Real Keychain (Security framework) — key never touches disk/logs

public struct KeychainLinearStore: LinearKeychain {
    public static let service = "com.ss251.trifola"
    public static let account = "linear-api-key"

    public init() {}

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    public func readKey() -> String? {
        // Headless entry points (`--mcp`, `--selfcheck`, `--render-*`) have no GUI to
        // click, so the legacy-file-keychain ACL challenge ("enter your login keychain
        // password") parks the process forever — it froze headless renders + CI. Skip
        // the read entirely there → nil ("Linear not connected"), which every caller
        // already degrades to gracefully. GUI launches read normally. (The deprecated
        // SecKeychainSetUserInteractionAllowed is unreliable on recent macOS, so this
        // is the durable guard.)
        let args = CommandLine.arguments
        if args.contains("--mcp") || args.contains("--selfcheck")
            || args.contains(where: { $0.hasPrefix("--render") }) {
            return nil
        }
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Presence-only check — queries ATTRIBUTES, never `kSecReturnData`, so it does NOT
    /// decrypt the stored key. This is ~100x cheaper than `readKey()` and needs no
    /// Keychain authorization (the ACL prompt is for the DATA, not metadata), so it
    /// neither burns CPU nor prompts. The connection-state check calls THIS, not readKey.
    public func keyPresent() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--mcp") || args.contains("--selfcheck")
            || args.contains(where: { $0.hasPrefix("--render") }) {
            return false
        }
        var q = baseQuery
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnAttributes as String] = true   // metadata only — NEVER the secret
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return status == errSecSuccess
    }

    @discardableResult
    public func writeKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        // Upsert: try update first, else add. Never log the value.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    public func deleteKey() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - The exporter

public protocol DeadlineExporter: Sendable {
    func upsert(_ boards: [DeadlineCard]) async throws
}

/// One row of the visible sync report — what happened to one project, so the panel
/// can SHOW the result instead of a silent status line.
public struct LinearSyncRow: Sendable, Equatable, Hashable, Identifiable {
    public enum Outcome: String, Sendable, Codable, Hashable {
        case created        // new Linear project
        case updated        // existing Linear project refreshed in place
        case skipped        // unconfirmed local finding — never left the machine
        case canceled       // stale mapped project marked canceled in Linear
        case cancelDenied   // cancel refused (permissions) — mapping pruned anyway
    }
    public var projectKey: String
    /// The human Linear project name ("Alpha Hackathon"), also used for skipped rows.
    public var name: String
    /// The Linear project URL when the API returned one (created/updated/canceled).
    public var url: String?
    public var outcome: Outcome
    public var id: String { projectKey + "·" + outcome.rawValue }

    public init(projectKey: String, name: String, url: String? = nil, outcome: Outcome) {
        self.projectKey = projectKey
        self.name = name
        self.url = url
        self.outcome = outcome
    }
}

/// The result of one sync pass — which projects were created vs updated in place,
/// which were held back (unconfirmed), which stale Linear projects were cleaned up,
/// the per-project report rows for the panel, and the new
/// {projectKey → linearProjectId} map to persist for idempotency.
public struct LinearSyncResult: Sendable, Equatable {
    public var created: [String]
    public var updated: [String]
    /// Unconfirmed findings that stayed local (the eligibility rule made visible).
    public var skipped: [String]
    /// Previously-synced projects whose local record is no longer a confirmed
    /// deadline — marked canceled in Linear, mapping pruned.
    public var canceled: [String]
    /// Cancel attempts Linear refused — the mapping is pruned anyway (local truth wins).
    public var cancelDenied: [String]
    public var rows: [LinearSyncRow]
    public var map: [String: String]

    public init(created: [String] = [], updated: [String] = [], skipped: [String] = [],
                canceled: [String] = [], cancelDenied: [String] = [],
                rows: [LinearSyncRow] = [], map: [String: String] = [:]) {
        self.created = created
        self.updated = updated
        self.skipped = skipped
        self.canceled = canceled
        self.cancelDenied = cancelDenied
        self.rows = rows
        self.map = map
    }
}

public struct LinearExporter: DeadlineExporter {
    public let transport: LinearTransport
    public let keychain: LinearKeychain
    public let teamID: String

    public init(transport: LinearTransport, keychain: LinearKeychain, teamID: String) {
        self.transport = transport
        self.keychain = keychain
        self.teamID = teamID
    }

    /// Fetch the user's teams for the picker (needs only the key, no team yet).
    public func fetchTeams() async throws -> [LinearTeam] {
        guard let key = keychain.readKey(), !key.isEmpty else { throw LinearError.noKey }
        let data = try await transport.send(LinearGraphQL.teams(), key: key)
        return try LinearResponse.teams(from: data)
    }

    /// One-way, idempotent sync of the board into Linear Projects, with the status
    /// posted as a project update. THE ELIGIBILITY RULE: only confirmed records
    /// (user-confirmed / edited / override / seeded) sync — an unconfirmed parse is
    /// a local finding and never leaves the machine. CLEANUP: a mapped project whose
    /// local record is now unconfirmed or retracted gets its Linear project marked
    /// canceled (graceful if Linear refuses) and its mapping pruned, so junk a past
    /// sync pushed actually disappears. Returns the new map + a visible report.
    public func upsert(_ cards: [DeadlineCard], map: [String: String],
                       now: Date = Date()) async throws -> LinearSyncResult {
        guard let apiKey = keychain.readKey(), !apiKey.isEmpty else { throw LinearError.noKey }
        var result = LinearSyncResult(map: map)
        let eligible = cards.filter { LinearEligibility.isSyncable($0) }
        let heldBack = cards.filter { !LinearEligibility.isSyncable($0) }

        for card in eligible {
            let mapped = result.map[card.projectKey]
            let target = LinearFormat.targetDate(card.deadline)
            let state = LinearFormat.state(for: card.state)
            let name = LinearFormat.projectName(projectKey: card.projectKey)
            let description = LinearFormat.projectDescription(card)
            let project: (id: String, url: String?)
            switch LinearSync.decide(mappedID: mapped) {
            case .create:
                let data = try await transport.send(
                    LinearGraphQL.projectCreate(name: name, description: description,
                                                targetDate: target, teamId: teamID, state: state),
                    key: apiKey)
                project = try LinearResponse.project(from: data, field: "projectCreate")
                result.created.append(card.projectKey)
                result.rows.append(LinearSyncRow(projectKey: card.projectKey, name: name,
                                                 url: project.url, outcome: .created))
            case .update(let id):
                let data = try await transport.send(
                    LinearGraphQL.projectUpdate(id: id, description: description,
                                                targetDate: target, state: state), key: apiKey)
                project = try LinearResponse.project(from: data, field: "projectUpdate")
                result.updated.append(card.projectKey)
                result.rows.append(LinearSyncRow(projectKey: card.projectKey, name: name,
                                                 url: project.url, outcome: .updated))
            }
            result.map[card.projectKey] = project.id
            // Post the status Linear can't compute — in sentences, not telemetry.
            _ = try await transport.send(
                LinearGraphQL.projectUpdateCreate(projectId: project.id, body: LinearFormat.updateBody(card)),
                key: apiKey)
        }

        // Cleanup: every mapped project with no confirmed local record behind it.
        let confirmedKeys = Set(eligible.map(\.projectKey))
        for (projKey, linearID) in map.sorted(by: { $0.key < $1.key }) where !confirmedKeys.contains(projKey) {
            let name = LinearFormat.projectName(projectKey: projKey)
            do {
                let data = try await transport.send(LinearGraphQL.projectCancel(id: linearID), key: apiKey)
                let project = try LinearResponse.project(from: data, field: "projectUpdate")
                result.canceled.append(projKey)
                result.rows.append(LinearSyncRow(projectKey: projKey, name: name,
                                                 url: project.url, outcome: .canceled))
            } catch {
                // Graceful: permissions (or anything else) may deny the cancel — the
                // mapping is pruned regardless, because local truth already dropped it.
                result.cancelDenied.append(projKey)
                result.rows.append(LinearSyncRow(projectKey: projKey, name: name,
                                                 url: nil, outcome: .cancelDenied))
            }
            result.map.removeValue(forKey: projKey)
        }

        for card in heldBack {
            result.skipped.append(card.projectKey)
            result.rows.append(LinearSyncRow(projectKey: card.projectKey,
                                             name: LinearFormat.projectName(projectKey: card.projectKey),
                                             url: nil, outcome: .skipped))
        }
        return result
    }

    /// `DeadlineExporter` conformance — the fire-and-forget shape.
    public func upsert(_ boards: [DeadlineCard]) async throws {
        _ = try await upsert(boards, map: [:], now: Date())
    }
}

// MARK: - Idempotency map + settings persistence (app-owned dir, never ~/.claude)

/// `~/Library/Application Support/Trifola/linear-map.json` —
/// {projectKey → linearProjectId}. Every sync is an upsert against this map, so
/// re-runs update in place and never duplicate a Linear project.
public struct LinearMapStore: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/linear-map.json")
    }

    public init(url: URL = LinearMapStore.defaultURL) { self.url = url }

    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    @discardableResult
    public func save(_ map: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(map).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}

/// The chosen team + the background-sync toggle — the app's own dir, never the key
/// (the key lives ONLY in the Keychain).
public struct LinearSettings: Sendable, Codable, Equatable {
    public var teamID: String?
    public var teamName: String?
    public var backgroundSync: Bool

    public init(teamID: String? = nil, teamName: String? = nil, backgroundSync: Bool = false) {
        self.teamID = teamID
        self.teamName = teamName
        self.backgroundSync = backgroundSync
    }
}

public struct LinearSettingsStore: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/linear.json")
    }

    public init(url: URL = LinearSettingsStore.defaultURL) { self.url = url }

    public func load() -> LinearSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(LinearSettings.self, from: data) else { return LinearSettings() }
        return s
    }

    @discardableResult
    public func save(_ settings: LinearSettings) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(settings).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
