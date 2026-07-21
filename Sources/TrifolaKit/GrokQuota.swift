import Foundation

// MARK: - Grok SuperGrok plan usage (network, consent-gated)
// Wire format derived from CodexBar (MIT, © Peter Steinberger).
//
// SuperGrok plan used-% and reset are NOT in any local file — they come from
// grok.com's gRPC-web billing endpoint, authenticated with the OAuth token in
// ~/.grok/auth.json. Mirrors ClaudeQuota: read-only credential, one POST behind
// a per-provider consent flag, injectable HTTP transport for tests, honest
// error taxonomy. NEVER log, print, or persist the bearer token.

// MARK: Credentials (READ-ONLY)

/// Parsed SuperGrok / session credentials. Deliberately not Codable and not
/// printable: description redacts the token so it cannot leak through logs or
/// test failure output.
public struct GrokQuotaCredentials: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let email: String?
    public let scope: String

    public init(accessToken: String, expiresAt: Date?, email: String?, scope: String) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.email = email
        self.scope = scope
    }

    public var isExpired: Bool { isExpired(at: Date()) }

    public func isExpired(at date: Date) -> Bool {
        (expiresAt ?? .distantFuture) <= date
    }
}

extension GrokQuotaCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let expiry = expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        return "GrokQuotaCredentials(token: <redacted>, expiresAt: \(expiry), scope: \(scope))"
    }
    public var debugDescription: String { description }
}

public enum GrokQuotaCredentialReader {

    /// Top-level OIDC scope used by `grok login` for SuperGrok subscribers.
    public static let oidcScopePrefix = "https://auth.x.ai::"
    /// Legacy/session scope used by older `grok login` flows.
    public static let legacySessionScope = "https://accounts.x.ai/sign-in"

    public static func configDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        GrokPaths.resolve(home: home, environment: environment).root
    }

    public static func authFileURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDirectory(home: home, environment: environment)
            .appendingPathComponent("auth.json")
    }

    /// Read auth.json from disk. Missing/unreadable → nil (caller maps to
    /// `.noCredentials`). Never throws the token.
    ///
    /// - Parameter configDirectory: The Grok config root (e.g. `~/.grok`),
    ///   not the user home. Prefer `GrokPaths.process.root` in production.
    public static func load(
        configDirectory: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GrokQuotaCredentials? {
        let root = configDirectory
            ?? self.configDirectory(home: home, environment: environment)
        let url = root.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Pure: parse the auth.json map keyed by scope URL. Prefer OIDC/SuperGrok
    /// (`https://auth.x.ai::…`), fall back to legacy session scope
    /// (`https://accounts.x.ai/sign-in` or any `/sign-in`). Only entries with a
    /// non-empty `key` are accepted.
    public static func parse(_ data: Data) -> GrokQuotaCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (scope, entry) = selectPreferredEntry(in: root),
              let rawKey = entry["key"] as? String else { return nil }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return GrokQuotaCredentials(
            accessToken: key,
            expiresAt: parseDate(entry["expires_at"]),
            email: (entry["email"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            scope: scope)
    }

    static func selectPreferredEntry(
        in root: [String: Any]
    ) -> (scope: String, entry: [String: Any])? {
        var oidcCandidate: (String, [String: Any])?
        var legacyCandidate: (String, [String: Any])?
        for (scope, value) in root {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if scope.hasPrefix(oidcScopePrefix) {
                oidcCandidate = (scope, entry)
            } else if scope == legacySessionScope || scope.contains("/sign-in") {
                legacyCandidate = (scope, entry)
            }
        }
        return oidcCandidate ?? legacyCandidate
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

// MARK: Error taxonomy

/// Reasons, never payloads: no case carries response bodies or token bytes.
public enum GrokQuotaError: Error, Equatable, Sendable {
    case noCredentials
    case expired
    case unauthorized
    case network(String)
    case badPayload
}

// MARK: Injectable HTTP transport

/// One-method seam so unit tests stub responses with no live network.
public protocol GrokQuotaHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GrokQuotaHTTPTransport {}

// MARK: gRPC-web + protobuf parser (pure, fixture-tested)

/// Parsed SuperGrok plan usage: used-% + optional reset.
public struct GrokBillingUsage: Sendable, Equatable {
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Single SuperGrok plan window — no five-hour window Grok doesn't have.
    public func asQuotaSnapshot(now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: nil,
            weekly: QuotaWindow(title: "SuperGrok",
                                usedPercent: usedPercent,
                                resetsAt: resetsAt),
            scoped: [],
            fetchedAt: now)
    }
}

enum GrokQuotaParser {

    /// Split length-prefixed gRPC-web frames; parse trailers for grpc-status;
    /// scan protobuf field paths for used-% and reset.
    static func parse(_ data: Data, now: Date = Date()) -> Result<GrokBillingUsage, GrokQuotaError> {
        if let trailerError = grpcStatusError(from: grpcWebTrailerFields(from: data)) {
            return .failure(trailerError)
        }

        var payloads = grpcWebDataFrames(from: data)
        if payloads.isEmpty, looksLikeProtobufPayload(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { return .failure(.badPayload) }

        var scan = ProtobufScan()
        for payload in payloads {
            scan.merge(scanProtobuf(payload, depth: 0))
        }

        let parsedPercent = scan.fixed32Fields
            .filter { field in
                field.path.last == 1
                    && field.value.isFinite
                    && field.value >= 0
                    && field.value <= 100
            }
            .min { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                return lhs.order < rhs.order
            }
            .map { Double($0.value) }

        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            guard raw >= 1_700_000_000, raw <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
        }
        let futureResetFields = resetFields.filter { $0.date > now }
        let reset = futureResetFields
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min()
            ?? futureResetFields.map(\.date).min()

        let hasUsagePeriod = scan.varintFields.contains { field in
            field.path.starts(with: [1, 6])
                || (field.path == [1, 8, 1] && (field.value == 1 || field.value == 2))
        }
        let noUsageYet = parsedPercent == nil
            && scan.fixed32Fields.isEmpty
            && reset != nil
            && hasUsagePeriod

        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else {
            return .failure(.badPayload)
        }
        return .success(GrokBillingUsage(usedPercent: percent, resetsAt: reset))
    }

    // MARK: frames + trailers

    static func grpcWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index < bytes.count {
            guard index + 5 <= bytes.count else { break }
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return [] }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    static func grpcWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0,
               let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    static func grpcStatusError(from fields: [String: String]) -> GrokQuotaError? {
        guard let rawStatus = fields["grpc-status"],
              let status = Int(rawStatus),
              status != 0
        else { return nil }
        let message = fields["grpc-message"] ?? ""
        if isAuthenticationFailure(status: status, message: message) {
            return .unauthorized
        }
        if status == 4 || message.localizedCaseInsensitiveContains("timeout")
            || message.localizedCaseInsensitiveContains("deadline") {
            return .network("grpc-status \(status)")
        }
        return .badPayload
    }

    static func isAuthenticationFailure(status: Int, message: String) -> Bool {
        if status == 16 { return true }
        guard status == 7 else { return false }
        let lower = message.lowercased()
        return lower.contains("bad-credentials")
            || lower.contains("unauthenticated")
            || (lower.contains("oauth2") && lower.contains("could not be validated"))
            || (lower.contains("access token")
                && (lower.contains("invalid")
                    || lower.contains("expired")
                    || lower.contains("could not be validated")))
    }

    static func looksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0
            && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    // MARK: protobuf scan

    private struct ProtobufScan {
        struct Fixed32Field {
            var path: [UInt64]
            var value: Float
            var order: Int
        }
        struct VarintField {
            var path: [UInt64]
            var value: UInt64
        }
        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: ProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func scanProtobuf(_ data: Data, depth: Int) -> ProtobufScan {
        scanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (scan: ProtobufScan, order: Int) {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = readVarint(bytes, index: &index) {
                    scan.varintFields.append(
                        ProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = scanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder)
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(ProtobufScan.Fixed32Field(
                    path: fieldPath,
                    value: Float(bitPattern: bitPattern),
                    order: nextOrder))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }
        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

// MARK: Fetcher (the ONE network call)

public enum GrokQuotaFetcher {

    public static let endpoint = URL(
        string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// POST empty gRPC-web frame with the Bearer token from auth.json.
    /// Injectable transport so tests never hit the network. One retry on
    /// timeout / 408/502/503/504 / grpc-status 4/deadline.
    public static func fetch(
        creds: GrokQuotaCredentials,
        transport: any GrokQuotaHTTPTransport = URLSession.shared,
        endpoint: URL = endpoint,
        now: Date = Date()
    ) async -> Result<QuotaSnapshot, GrokQuotaError> {
        if creds.isExpired(at: now) { return .failure(.expired) }

        switch await fetchOnce(creds: creds, transport: transport,
                               endpoint: endpoint, now: now) {
        case .success(let snap):
            return .success(snap)
        case .failure(let error) where shouldRetry(error):
            return await fetchOnce(creds: creds, transport: transport,
                                   endpoint: endpoint, now: now)
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func fetchOnce(
        creds: GrokQuotaCredentials,
        transport: any GrokQuotaHTTPTransport,
        endpoint: URL,
        now: Date
    ) async -> Result<QuotaSnapshot, GrokQuotaError> {
        var request = URLRequest(url: endpoint, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("Trifola", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            return .failure(.network(String(String(describing: error).prefix(120))))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.network("non-HTTP response"))
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            return .failure(.unauthorized)
        case 408, 502, 503, 504:
            return .failure(.network("HTTP \(http.statusCode)"))
        default:
            return .failure(.network("HTTP \(http.statusCode)"))
        }

        // Header-level grpc-status (some gateways surface it before the body).
        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            let normalized = String(describing: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalized.hasPrefix("grpc-") else { continue }
            headerFields[normalized] = String(describing: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .removingPercentEncoding ?? ""
        }
        if let headerError = GrokQuotaParser.grpcStatusError(from: headerFields) {
            return .failure(headerError)
        }

        switch GrokQuotaParser.parse(data, now: now) {
        case .success(let usage):
            return .success(usage.asQuotaSnapshot(now: now))
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func shouldRetry(_ error: GrokQuotaError) -> Bool {
        switch error {
        case .network(let message):
            let lower = message.lowercased()
            return lower.contains("timeout")
                || lower.contains("deadline")
                || lower.contains("408")
                || lower.contains("502")
                || lower.contains("503")
                || lower.contains("504")
                || lower.contains("grpc-status 4")
                || lower.contains("timed out")
                || lower.contains("connection lost")
        case .noCredentials, .expired, .unauthorized, .badPayload:
            return false
        }
    }

    /// One calm sentence per failure — reasons, never payloads or nags.
    public static func describe(_ error: GrokQuotaError) -> String {
        switch error {
        case .noCredentials:
            return "Grok plan usage needs a signed-in xAI session — run `grok login`."
        case .expired, .unauthorized:
            return "Grok rejected the saved credentials — run `grok login` to refresh."
        case .network:
            return "Grok plan usage endpoint didn't answer. Costs and attention don't need it."
        case .badPayload:
            return "Couldn't read Grok plan usage."
        }
    }
}

// MARK: private helpers

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
