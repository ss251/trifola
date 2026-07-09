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
    public var isExpired: Bool { (expiresAt ?? .distantFuture) <= Date() }
}

extension ClaudeOAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let expiry = expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        return "ClaudeOAuthCredentials(token: <redacted>, expiresAt: \(expiry))"
    }
    public var debugDescription: String { description }
}

public enum ClaudeCredentialSource: String, Sendable { case file, keychain }

public enum ClaudeCredentialReader {

    /// Where Claude Code keeps the JSON on disk (same payload as the keychain item).
    public static func credentialsFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/.credentials.json")
    }

    /// file → keychain (`security` CLI). Returns nil when neither source yields
    /// a parsable login. The `security` CLI is used instead of Security.framework
    /// because an unsigned dev binary re-triggers keychain ACL prompts on every
    /// rebuild via `SecItemCopyMatching`; the subprocess-probe pattern is already
    /// established in this repo (Probes.swift).
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (creds: ClaudeOAuthCredentials, source: ClaudeCredentialSource)? {
        if let data = try? Data(contentsOf: credentialsFileURL(home: home)),
           let creds = parse(data) {
            return (creds, .file)
        }
        if let (status, out) = ProbePrimitives.runCommand(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
           status == 0, let creds = parse(out) {
            return (creds, .keychain)
        }
        return nil
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

        // Credential read = file I/O + a possible `security` subprocess — off main.
        guard let (creds, src) = await Task.detached(priority: .utility, operation: {
            ClaudeCredentialReader.load()
        }).value else {
            source = nil
            status = "unavailable — no credentials found (file + keychain)"
            return
        }
        source = src
        guard !creds.isExpired else {
            // Never attempt recovery ourselves (SECURITY §4).
            status = "token expired — run `claude` (any prompt) to re-authenticate, then Refresh"
            return
        }

        switch await ClaudeQuotaFetcher.fetch(creds: creds) {
        case .success(let snap):
            snapshot = snap
            status = snap.isEmpty ? "endpoint returned no windows (schema drift?)" : "ok · \(src.rawValue)"
        case .failure(let err):
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
        case .noCredentials(let reason): return "unavailable — \(reason)"
        case .expired: return "token expired — run `claude` (any prompt) to re-authenticate, then Refresh"
        case .unauthorized: return "unauthorized — run `claude` (any prompt) to re-authenticate, then Refresh"
        case .rateLimited(let after):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            let until = f.string(from: after ?? Date().addingTimeInterval(300))
            return "rate-limited — cooling down until \(until)"
        case .server(let code): return "usage endpoint returned \(code) — will retry on the next refresh"
        case .network(let reason): return "offline or unreachable — \(reason)"
        case .badPayload: return "unreadable response — the endpoint's shape may have changed"
        }
    }
}
