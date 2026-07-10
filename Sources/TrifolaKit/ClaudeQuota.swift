import Foundation

// MARK: - OAuth quota windows (W7, plan 04) — the REAL rate-limit state
// Everything else in this app is an API-equiv *estimate*; the OAuth usage
// endpoint returns the actual plan windows the user lives by (the 5h session
// window, the weekly window, and the model-scoped weeklies incl. Custom). This
// file is the whole feature's data layer: read the Claude Code credential
// READ-ONLY, one GET, pure decoding, a throttled store.
//
// SECURITY (plan 04, non-negotiable):
// - The credential is read, never written/refreshed/rotated/deleted. The
//   refresh flow is deliberately NOT ported — Claude Code rotates refresh
//   tokens and owns that lifecycle; this app never mutates ~/.claude or the
//   CLI's keychain item.
// - No token value ever reaches a print, a description, an error payload, or
//   a test fixture. Errors carry reasons, never payloads.

// MARK: Credentials (READ-ONLY)

/// The parsed `claudeAiOauth` payload. Deliberately NOT Codable and NOT
/// printable: `description`/`debugDescription` are overridden so the token can
/// never leak through string interpolation, logs, or test failure output.
public struct ClaudeOAuthCredentials: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Expired means "the CLI must re-auth"; absent expiry is treated as live
    /// (the endpoint will 401 if it is not — that path has its own message).
    public var isExpired: Bool { isExpired(at: Date()) }

    public func isExpired(at date: Date) -> Bool {
        (expiresAt ?? .distantFuture) <= date
    }
}

extension ClaudeOAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let expiry = expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        return "ClaudeOAuthCredentials(token: <redacted>, expiresAt: \(expiry))"
    }
    public var debugDescription: String { description }
}

public enum ClaudeCredentialSource: String, Sendable, Hashable { case file, keychain }

/// A source read is explicit so access denial cannot collapse into "missing".
/// The payload is deliberately the non-printable credential type, never raw data.
public enum ClaudeCredentialReadResult: Sendable {
    case credential(ClaudeOAuthCredentials)
    case missing
    case denied
}

public enum ClaudeCredentialFailure: Sendable, Equatable {
    case allExpired
    case keychainDenied
    case noCredentials

    fileprivate var quotaError: ClaudeQuotaError {
        switch self {
        case .allExpired:
            return .expired
        case .keychainDenied:
            return .noCredentials("keychain access denied; no other usable credentials")
        case .noCredentials:
            return .noCredentials("no credentials found (file + keychain)")
        }
    }
}

public struct ClaudeCredentialCandidate: Sendable {
    public let credentials: ClaudeOAuthCredentials
    public let source: ClaudeCredentialSource
}

public struct ClaudeCredentialCandidates: Sendable {
    public let ordered: [ClaudeCredentialCandidate]
    public let failureWhenExhausted: ClaudeCredentialFailure
}

public enum ClaudeCredentialReader {

    public static func configDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Where Claude Code keeps the JSON on disk (same payload as the keychain item).
    public static func credentialsFileURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDirectory(home: home, environment: environment).appendingPathComponent(".credentials.json")
    }

    /// Pure candidate construction. Both source outcomes are supplied independently;
    /// expired credentials are removed before ordering. Source preference wins first,
    /// then the newest expiry wins within a source.
    public static func candidates(
        now: Date,
        preferredSources: [ClaudeCredentialSource] = [.file, .keychain],
        file: ClaudeCredentialReadResult,
        keychain: ClaudeCredentialReadResult
    ) -> ClaudeCredentialCandidates {
        let reads: [(ClaudeCredentialSource, ClaudeCredentialReadResult)] = [
            (.file, file), (.keychain, keychain),
        ]
        var sawCredential = false
        var live: [ClaudeCredentialCandidate] = []
        for (source, result) in reads {
            guard case .credential(let credentials) = result else { continue }
            sawCredential = true
            guard !credentials.isExpired(at: now) else { continue }
            live.append(ClaudeCredentialCandidate(credentials: credentials, source: source))
        }

        let rank = Dictionary(uniqueKeysWithValues: preferredSources.enumerated().map { ($0.element, $0.offset) })
        live.sort { lhs, rhs in
            let leftRank = rank[lhs.source] ?? Int.max
            let rightRank = rank[rhs.source] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return (lhs.credentials.expiresAt ?? .distantFuture)
                > (rhs.credentials.expiresAt ?? .distantFuture)
        }

        let failure: ClaudeCredentialFailure
        if case .denied = keychain {
            failure = .keychainDenied
        } else if sawCredential && live.isEmpty {
            failure = .allExpired
        } else {
            failure = .noCredentials
        }
        return ClaudeCredentialCandidates(ordered: live, failureWhenExhausted: failure)
    }

    /// Read file AND Keychain independently, then pass both through the pure
    /// candidate constructor. `security` exit 44 is Keychain item-not-found;
    /// launch failures, timeouts, and every other failure remain access denied.
    public static func loadCandidates(
        configDirectory: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        keychainTimeout: TimeInterval? = nil
    ) -> ClaudeCredentialCandidates {
        let root = configDirectory ?? self.configDirectory(home: home, environment: environment)
        let fileURL = root.appendingPathComponent(".credentials.json")
        let file: ClaudeCredentialReadResult
        if let data = try? Data(contentsOf: fileURL), let credentials = parse(data) {
            file = .credential(credentials)
        } else {
            file = .missing
        }

        let keychain: ClaudeCredentialReadResult
        if let result = ProbePrimitives.runCommand(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: keychainTimeout
        ) {
            if result.status == 0, let credentials = parse(result.stdout) {
                keychain = .credential(credentials)
            } else if result.status == 44 {
                keychain = .missing
            } else {
                keychain = .denied
            }
        } else {
            keychain = .denied
        }

        return candidates(now: now, file: file, keychain: keychain)
    }

    /// Pure: parse the credential JSON. Root key `claudeAiOauth` (a payload with
    /// only `mcpOAuth` is not a login); `expiresAt` is epoch MILLISECONDS.
    /// Whitespace-padded tokens are trimmed; an empty token is not a login.
    public static func parse(_ data: Data) -> ClaudeOAuthCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["claudeAiOauth"] as? [String: Any],
              let rawToken = payload["accessToken"] as? String else { return nil }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        // epoch ms → Date (divide by 1000); tolerate Int or Double encodings.
        let expiresAt = (payload["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeOAuthCredentials(accessToken: token,
                                      expiresAt: expiresAt,
                                      subscriptionType: payload["subscriptionType"] as? String)
    }
}

// MARK: Response models (mirror CodexBar's contract — plan 04 §D)

/// One plan rate-limit window, already humanized: "Session (5h)" /
/// "Weekly (all models)" / "Custom only". `usedPercent` is percent USED (0…100+,
/// passed through from the endpoint's `utilization`/`percent` as-is).
public struct QuotaWindow: Sendable, Equatable {
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(title: String, usedPercent: Double, resetsAt: Date?) {
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Shared display rounding for every quota surface. Alert thresholds keep
    /// comparing the raw value; only rendered text uses this integer.
    public var roundedUsedPercent: Int { Int(usedPercent.rounded()) }
}

public struct QuotaSnapshot: Sendable, Equatable {
    public let fiveHour: QuotaWindow?
    public let weekly: QuotaWindow?
    /// Model-scoped weekly windows (Custom/Opus/…), mapper rule §D: entries with
    /// `group == "weekly" && kind == "weekly_scoped"`, finite percent, non-empty
    /// model name; deduped by lowercased slug. `is_active` is intentionally NOT
    /// a filter — observed enforceable scoped limits report false.
    public let scoped: [QuotaWindow]
    public let fetchedAt: Date

    public init(fiveHour: QuotaWindow?, weekly: QuotaWindow?, scoped: [QuotaWindow], fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.scoped = scoped
        self.fetchedAt = fetchedAt
    }

    /// Rows in render order: fiveHour → weekly → scoped[].
    public var windows: [QuotaWindow] { [fiveHour, weekly].compactMap { $0 } + scoped }
    public var isEmpty: Bool { windows.isEmpty }

    /// The ONE public seam over the internal decoder — same code path the
    /// fetcher's 200 branch takes, exposed so the selfcheck can replay real
    /// payload shapes without a network call. nil on undecodable data, never
    /// a crash.
    public static func decode(_ data: Data, now: Date) -> QuotaSnapshot? {
        OAuthUsageDecoder.snapshot(from: data, now: now)
    }
}

/// Pure, fixture-tested decoding of the usage response. Two generations are
/// tolerated: legacy top-level windows (`five_hour`, `seven_day`) and the newer
/// flat `limits[]` array with model scopes. Unknown windows (`extra_usage`,
/// Daily-Routines kinds) decode-tolerate and are not rendered (plan 04 out-of-scope).
enum OAuthUsageDecoder {

    private struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    private struct ScopeModel: Decodable {
        let id: String?
        let display_name: String?
    }
    private struct Scope: Decodable { let model: ScopeModel? }
    private struct Limit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resets_at: String?
        let is_active: Bool?
        let scope: Scope?
    }
    private struct Top: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    /// nil on undecodable data — NEVER a crash. An all-empty-but-valid payload
    /// returns an empty snapshot; callers decide what emptiness means.
    static func snapshot(from data: Data, now: Date) -> QuotaSnapshot? {
        guard let top = try? JSONDecoder().decode(Top.self, from: data) else { return nil }

        func window(_ w: Window?, title: String) -> QuotaWindow? {
            guard let w, let used = w.utilization, used.isFinite else { return nil }
            return QuotaWindow(title: title, usedPercent: used, resetsAt: parseDate(w.resets_at))
        }

        // Scoped weeklies (§D). Dedupe by lowercased slug, first entry wins;
        // `is_active` deliberately ignored.
        var seenSlugs = Set<String>()
        var scoped: [QuotaWindow] = []
        for limit in top.limits ?? [] {
            guard limit.group == "weekly", limit.kind == "weekly_scoped",
                  let percent = limit.percent, percent.isFinite else { continue }
            let display = limit.scope?.model?.display_name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = limit.scope?.model?.id?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = [display, id].compactMap({ $0 }).first(where: { !$0.isEmpty })
            else { continue }
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            guard seenSlugs.insert(slug).inserted else { continue }
            scoped.append(QuotaWindow(title: "\(name) only", usedPercent: percent,
                                      resetsAt: parseDate(limit.resets_at)))
        }

        return QuotaSnapshot(fiveHour: window(top.five_hour, title: "Session (5h)"),
                             weekly: window(top.seven_day, title: "Weekly (all models)"),
                             scoped: scoped,
                             fetchedAt: now)
    }
}

// MARK: Fetcher (the ONE network call)

/// Reasons, never payloads: no case carries response bodies or token bytes.
public enum ClaudeQuotaError: Error, Equatable, Sendable {
    case noCredentials(String)
    case expired
    case unauthorized
    case rateLimited(retryAfter: Date?)
    case server(Int)
    case network(String)
    case badPayload
}

public enum ClaudeQuotaFetcher {

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The single GET (plan 04 §C). 30s timeout; 200 → decode, 401 →
    /// unauthorized, 429 → rateLimited with the parsed `Retry-After`
    /// (5-minute default), anything else → server(status).
    public static func fetch(creds: ClaudeOAuthCredentials,
                             userAgentVersion: String = "2.1.0") async -> Result<QuotaSnapshot, ClaudeQuotaError> {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            // URLError descriptions carry hosts + codes, never request headers.
            return .failure(.network(String(String(describing: error).prefix(120))))
        }
        guard let http = resp as? HTTPURLResponse else {
            return .failure(.network("non-HTTP response"))
        }
        switch http.statusCode {
        case 200:
            guard let snap = OAuthUsageDecoder.snapshot(from: data, now: Date()) else {
                return .failure(.badPayload)
            }
            return .success(snap)
        case 401:
            return .failure(.unauthorized)
        case 429:
            let after = retryAfterDate(http.value(forHTTPHeaderField: "Retry-After"), now: Date())
            return .failure(.rateLimited(retryAfter: after))
        default:
            return .failure(.server(http.statusCode))
        }
    }

    /// `Retry-After` per RFC 9110: delta-seconds, else an HTTP-date, else the
    /// 5-minute default cooldown. Pure + tested.
    static func retryAfterDate(_ header: String?, now: Date) -> Date {
        let fallback = now.addingTimeInterval(300)
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return fallback
        }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = f.date(from: header) { return date }
        return fallback
    }
}

// MARK: Candidate resolver (shared by GUI + MCP)

public struct ResolvedQuota: Sendable {
    public let snapshot: QuotaSnapshot
    public let source: ClaudeCredentialSource
}

public enum ClaudeQuotaResolver {
    public static func resolve(
        candidates: ClaudeCredentialCandidates,
        fetch: @escaping @Sendable (ClaudeCredentialCandidate) async
            -> Result<QuotaSnapshot, ClaudeQuotaError> = {
                await ClaudeQuotaFetcher.fetch(creds: $0.credentials)
            }
    ) async -> Result<ResolvedQuota, ClaudeQuotaError> {
        guard !candidates.ordered.isEmpty else {
            return .failure(candidates.failureWhenExhausted.quotaError)
        }

        var sawUnauthorized = false
        for candidate in candidates.ordered {
            switch await fetch(candidate) {
            case .success(let snapshot):
                return .success(ResolvedQuota(snapshot: snapshot, source: candidate.source))
            case .failure(.unauthorized):
                sawUnauthorized = true
                continue
            case .failure(let error):
                return .failure(error)
            }
        }

        if candidates.failureWhenExhausted == .keychainDenied {
            return .failure(ClaudeCredentialFailure.keychainDenied.quotaError)
        }
        return .failure(sawUnauthorized ? .unauthorized : candidates.failureWhenExhausted.quotaError)
    }
}

// MARK: Store

/// Owns the snapshot + one honest status line. Throttled: refresh is a no-op
/// while the snapshot is younger than `minInterval` or a 429 cooldown is
/// pending, so the FSEvents-driven refreshAll() calls stay cheap. No timers of
/// its own — refreshAll drives it (plan 04 out-of-scope: polling).
@MainActor
public final class QuotaStore: ObservableObject {
    @Published public private(set) var snapshot: QuotaSnapshot?
    @Published public private(set) var status: String = "not fetched yet"
    @Published public private(set) var source: ClaudeCredentialSource?

    private var cooldownUntil: Date?
    private var inFlight = false

    public init() {}

    public func refresh(minInterval: TimeInterval = 300) async {
        let now = Date()
        if inFlight { return }
        if let snap = snapshot, now.timeIntervalSince(snap.fetchedAt) < minInterval { return }
        if let cool = cooldownUntil, now < cool { return }
        inFlight = true
        defer { inFlight = false }

        // File I/O + Keychain subprocess stay off-main. The same candidate
        // resolver drives MCP, including expiry filtering and 401 fallback.
        let candidates = await Task.detached(priority: .utility, operation: {
            ClaudeCredentialReader.loadCandidates()
        }).value
        switch await ClaudeQuotaResolver.resolve(candidates: candidates) {
        case .success(let resolved):
            source = resolved.source
            snapshot = resolved.snapshot
            status = resolved.snapshot.isEmpty
                ? "endpoint returned no windows (schema drift?)"
                : "ok · \(resolved.source.rawValue)"
        case .failure(let err):
            source = nil
            status = Self.describe(err)
            if case .rateLimited(let after) = err {
                cooldownUntil = after ?? Date().addingTimeInterval(300)
            }
        }
    }

    /// One calm sentence per failure — reasons, never payloads or nags.
    /// Pure (no store state) — nonisolated so the selfcheck + tests can call it.
    public nonisolated static func describe(_ error: ClaudeQuotaError) -> String {
        switch error {
        case .noCredentials(let reason):
            if reason.contains("keychain access denied") {
                return "Keychain access was denied — Trifola works fully without plan quota."
            }
            return "No Claude credentials were found — Trifola works fully without plan quota."
        case .expired, .unauthorized:
            return "Signed out — run claude once to sign in, then Retry."
        case .rateLimited(let after):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            let until = f.string(from: after ?? Date().addingTimeInterval(300))
            return "rate-limited — cooling down until \(until)"
        case .server, .network, .badPayload:
            return "Plan quota unavailable — the usage endpoint didn't answer. Costs and attention don't need it."
        }
    }
}
