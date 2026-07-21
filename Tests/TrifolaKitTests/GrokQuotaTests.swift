import Foundation
import Testing
@testable import TrifolaKit

// Grok SuperGrok plan usage — credential parse, gRPC-web/protobuf fixtures,
// error taxonomy, injectable transport. NO live network.

private let seededToken = "xai-test-SECRET-DO-NOT-PRINT"

// MARK: - credential fixtures

private func authJSON(
    oidcKey: String? = seededToken,
    legacyKey: String? = nil,
    expiresAt: String? = "2030-01-01T00:00:00.123Z",
    email: String? = "user@example.com"
) -> Data {
    var root: [String: Any] = [:]
    if let oidcKey {
        var entry: [String: Any] = ["key": oidcKey]
        if let expiresAt { entry["expires_at"] = expiresAt }
        if let email { entry["email"] = email }
        entry["refresh_token"] = "refresh-secret-not-printed"
        entry["auth_mode"] = "oidc"
        root["https://auth.x.ai::client"] = entry
    }
    if let legacyKey {
        var entry: [String: Any] = ["key": legacyKey]
        if let expiresAt { entry["expires_at"] = expiresAt }
        root["https://accounts.x.ai/sign-in"] = entry
    }
    return try! JSONSerialization.data(withJSONObject: root)
}

// MARK: - synthetic gRPC-web / protobuf builders

private enum GrokFixture {
    static func protobufPayload(usedPercent: Float, resetEpoch: UInt64) -> Data {
        var data = Data()
        data.append(0x0D) // field 1, fixed32
        var percentBits = usedPercent.bitPattern.littleEndian
        withUnsafeBytes(of: &percentBits) { data.append(contentsOf: $0) }
        data.append(0x10) // field 2, varint
        data.append(contentsOf: varint(resetEpoch))
        return data
    }

    static func grpcFrame(_ payload: Data, flags: UInt8 = 0x00) -> Data {
        var data = Data([flags])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func trailerFrame(status: Int, message: String = "") -> Data {
        var text = "grpc-status:\(status)\r\n"
        if !message.isEmpty {
            text += "grpc-message:\(message)\r\n"
        }
        let body = Data(text.utf8)
        return grpcFrame(body, flags: 0x80)
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }

    /// Nested no-usage-yet shape: path starts [1,6] varint + future reset at
    /// path [1,5,1], no fixed32 percent.
    static func noUsageYetPayload(resetEpoch: UInt64) -> Data {
        // field 1 (length-delimited) containing:
        //   field 5 (length-delimited) containing field 1 varint = reset
        //   field 6 varint = 1  (usage-period marker)
        var inner5 = Data()
        inner5.append(0x08) // field 1 varint
        inner5.append(contentsOf: varint(resetEpoch))

        var inner1 = Data()
        inner1.append(0x2A) // field 5, length-delimited
        inner1.append(UInt8(inner5.count))
        inner1.append(inner5)
        inner1.append(0x30) // field 6 varint
        inner1.append(0x01)

        var payload = Data()
        payload.append(0x0A) // field 1, length-delimited
        payload.append(UInt8(inner1.count))
        payload.append(inner1)
        return payload
    }
}

// MARK: - stub transport

private struct StubGrokTransport: GrokQuotaHTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private func httpResponse(
    status: Int,
    url: URL = GrokQuotaFetcher.endpoint
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
}

// MARK: - credential tests

@Suite("Grok quota — credentials parsing (read-only)")
struct GrokQuotaCredentialTests {

    @Test("OIDC SuperGrok scope is preferred over legacy session")
    func prefersOIDC() {
        let data = authJSON(oidcKey: seededToken, legacyKey: "legacy-token")
        let creds = GrokQuotaCredentialReader.parse(data)
        #expect(creds != nil)
        #expect(creds?.accessToken == seededToken)
        #expect(creds?.scope.hasPrefix(GrokQuotaCredentialReader.oidcScopePrefix) == true)
        #expect(creds?.email == "user@example.com")
    }

    @Test("legacy session scope used when OIDC key is empty or missing")
    func fallsBackToLegacy() {
        // empty OIDC key must not shadow a healthy legacy entry
        let root: [String: Any] = [
            "https://auth.x.ai::client": ["key": ""],
            "https://accounts.x.ai/sign-in": [
                "key": "legacy-live",
                "expires_at": "2030-06-01T00:00:00Z",
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: root)
        let creds = GrokQuotaCredentialReader.parse(data)
        #expect(creds?.accessToken == "legacy-live")
        #expect(creds?.scope == GrokQuotaCredentialReader.legacySessionScope)

        let onlyLegacy = authJSON(oidcKey: nil, legacyKey: "only-legacy")
        #expect(GrokQuotaCredentialReader.parse(onlyLegacy)?.accessToken == "only-legacy")
    }

    @Test("missing auth.json / empty key / garbage → nil")
    func missingAndEmpty() {
        #expect(GrokQuotaCredentialReader.parse(Data()) == nil)
        #expect(GrokQuotaCredentialReader.parse(Data("not json".utf8)) == nil)
        #expect(GrokQuotaCredentialReader.parse(authJSON(oidcKey: "   ")) == nil)
        #expect(GrokQuotaCredentialReader.parse(
            try! JSONSerialization.data(withJSONObject: ["other": ["key": "x"]])) == nil)
    }

    @Test("fractional-seconds expires_at parses; past expiry is expired")
    func expiry() {
        let live = GrokQuotaCredentialReader.parse(
            authJSON(expiresAt: "2030-01-01T12:34:56.789Z"))
        #expect(live?.isExpired == false)
        #expect(live?.expiresAt != nil)

        let past = GrokQuotaCredentialReader.parse(
            authJSON(expiresAt: "2020-01-01T00:00:00Z"))
        #expect(past?.isExpired == true)
    }

    @Test("description never leaks the token")
    func redactedDescription() {
        let creds = GrokQuotaCredentialReader.parse(authJSON())!
        #expect(!creds.description.contains(seededToken))
        #expect(creds.description.contains("<redacted>"))
        #expect(!creds.debugDescription.contains(seededToken))
    }

    @Test("load from configDirectory reads auth.json")
    func loadFromDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-grok-auth-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try authJSON().write(to: root.appendingPathComponent("auth.json"))
        let creds = GrokQuotaCredentialReader.load(configDirectory: root)
        #expect(creds?.accessToken == seededToken)

        let missing = GrokQuotaCredentialReader.load(
            configDirectory: root.appendingPathComponent("nope"))
        #expect(missing == nil)
    }
}

// MARK: - parser tests

@Suite("Grok quota — gRPC-web / protobuf parser")
struct GrokQuotaParserTests {

    @Test("synthetic billing frame: exact used-% and reset")
    func happyPathFrame() throws {
        let reset: UInt64 = 1_800_000_000
        let payload = GrokFixture.protobufPayload(usedPercent: 42.5, resetEpoch: reset)
        let data = GrokFixture.grpcFrame(payload)
        let usage = try GrokQuotaParser.parse(
            data, now: Date(timeIntervalSince1970: 1_799_000_000)).get()
        #expect(usage.usedPercent == 42.5)
        #expect(usage.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    @Test("no-usage-yet shape with usage-period marker → usedPercent 0")
    func noUsageYet() throws {
        let reset: UInt64 = 1_802_000_000
        let data = GrokFixture.grpcFrame(GrokFixture.noUsageYetPayload(resetEpoch: reset))
        let usage = try GrokQuotaParser.parse(
            data, now: Date(timeIntervalSince1970: 1_800_000_000)).get()
        #expect(usage.usedPercent == 0)
        #expect(usage.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    @Test("non-zero grpc-status trailer → error (auth maps to unauthorized)")
    func grpcStatusTrailer() {
        let payload = GrokFixture.protobufPayload(usedPercent: 10, resetEpoch: 1_800_000_001)
        var data = GrokFixture.grpcFrame(payload)
        data.append(GrokFixture.trailerFrame(status: 16, message: "unauthenticated"))
        let result = GrokQuotaParser.parse(data)
        guard case .failure(.unauthorized) = result else {
            Issue.record("expected unauthorized for grpc-status 16, got \(result)")
            return
        }

        var badPayload = GrokFixture.grpcFrame(payload)
        badPayload.append(GrokFixture.trailerFrame(status: 13, message: "internal"))
        guard case .failure(.badPayload) = GrokQuotaParser.parse(badPayload) else {
            Issue.record("expected badPayload for non-auth grpc error")
            return
        }
    }

    @Test("reset-only without percent or no-usage-yet marker → badPayload")
    func resetOnlyFails() {
        var payload = Data()
        payload.append(0x10)
        payload.append(contentsOf: GrokFixture.varint(1_800_000_001))
        let result = GrokQuotaParser.parse(GrokFixture.grpcFrame(payload))
        guard case .failure(.badPayload) = result else {
            Issue.record("expected badPayload, got \(result)")
            return
        }
    }

    @Test("asQuotaSnapshot puts SuperGrok on the weekly slot")
    func snapshotShape() {
        let usage = GrokBillingUsage(
            usedPercent: 33,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
        let now = Date(timeIntervalSince1970: 1_799_000_000)
        let snap = usage.asQuotaSnapshot(now: now)
        #expect(snap.fiveHour == nil)
        #expect(snap.weekly?.title == "SuperGrok")
        #expect(snap.weekly?.usedPercent == 33)
        #expect(snap.windows.count == 1)
        #expect(snap.fetchedAt == now)
    }
}

// MARK: - fetcher + taxonomy

@Suite("Grok quota — fetcher (stub transport) + error taxonomy")
struct GrokQuotaFetcherTests {

    private var liveCreds: GrokQuotaCredentials {
        GrokQuotaCredentials(
            accessToken: seededToken,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            email: "user@example.com",
            scope: "https://auth.x.ai::client")
    }

    @Test("successful stubbed response builds SuperGrok snapshot")
    func fetchOK() async {
        let reset: UInt64 = 1_800_000_000
        let body = GrokFixture.grpcFrame(
            GrokFixture.protobufPayload(usedPercent: 55.5, resetEpoch: reset))
        let transport = StubGrokTransport { request in
            #expect(request.httpMethod == "POST")
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(auth.hasPrefix("Bearer "))
            // Token must never appear in any non-header path we inspect for secrets.
            #expect(request.httpBody == Data([0x00, 0x00, 0x00, 0x00, 0x00]))
            #expect(request.value(forHTTPHeaderField: "Content-Type")
                    == "application/grpc-web+proto")
            return (body, httpResponse(status: 200))
        }
        let result = await GrokQuotaFetcher.fetch(
            creds: liveCreds,
            transport: transport,
            now: Date(timeIntervalSince1970: 1_799_000_000))
        switch result {
        case .success(let snap):
            #expect(snap.weekly?.title == "SuperGrok")
            #expect(snap.weekly?.usedPercent == 55.5)
            #expect(snap.weekly?.resetsAt
                    == Date(timeIntervalSince1970: TimeInterval(reset)))
        case .failure(let err):
            Issue.record("unexpected failure: \(err)")
        }
    }

    @Test("expired creds fail before network")
    func expiredNoNetwork() async {
        let expired = GrokQuotaCredentials(
            accessToken: seededToken,
            expiresAt: Date(timeIntervalSince1970: 1_000_000_000),
            email: nil,
            scope: "https://auth.x.ai::client")
        let calls = Locked(0)
        let transport = StubGrokTransport { _ in
            calls.withLock { $0 += 1 }
            return (Data(), httpResponse(status: 200))
        }
        let result = await GrokQuotaFetcher.fetch(
            creds: expired,
            transport: transport,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(calls.withLock { $0 } == 0)
        guard case .failure(.expired) = result else {
            Issue.record("expected expired, got \(result)")
            return
        }
    }

    @Test("HTTP 401 → unauthorized")
    func unauthorized() async {
        let transport = StubGrokTransport { _ in
            (Data(), httpResponse(status: 401))
        }
        let result = await GrokQuotaFetcher.fetch(
            creds: liveCreds, transport: transport,
            now: Date(timeIntervalSince1970: 1_799_000_000))
        guard case .failure(.unauthorized) = result else {
            Issue.record("expected unauthorized, got \(result)")
            return
        }
    }

    @Test("error taxonomy maps to calm sentences (no token)")
    func describe() {
        let cases: [(GrokQuotaError, String)] = [
            (.noCredentials,
             "Grok plan usage needs a signed-in xAI session — run `grok login`."),
            (.expired,
             "Grok rejected the saved credentials — run `grok login` to refresh."),
            (.unauthorized,
             "Grok rejected the saved credentials — run `grok login` to refresh."),
            (.network("timeout"),
             "Grok plan usage endpoint didn't answer. Costs and attention don't need it."),
            (.badPayload,
             "Couldn't read Grok plan usage."),
        ]
        for (error, expected) in cases {
            let line = GrokQuotaFetcher.describe(error)
            #expect(line == expected)
            #expect(!line.contains(seededToken))
            #expect(!line.contains("Bearer"))
        }
    }
}

// MARK: - Result helper

private extension Result where Failure == GrokQuotaError {
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
