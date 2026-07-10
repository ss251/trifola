import Foundation
import Testing
@testable import TrifolaKit

// Spree #3 — OAUTH QUOTA WINDOWS (W7, plan 04).
// These tests pin the read-only credential contract (root key `claudeAiOauth`,
// `expiresAt` in epoch MILLISECONDS, mcpOAuth-only payloads are not a login),
// the decoder's two-generation tolerance (legacy windows + the newer scoped
// `limits[]`), the §D mapper rule (weekly_scoped only, slug-dedupe, `is_active`
// deliberately NOT a filter), Retry-After parsing, and — non-negotiable — that
// no description path can ever leak a token value.

private let seededToken = "sk-test-SECRET-DO-NOT-PRINT"

private func credsJSON(expiresAtMS: Double? = 1783500000000,
                       token: String = seededToken) -> Data {
    var payload: [String: Any] = ["accessToken": token, "refreshToken": "sk-test-refresh",
                                  "scopes": ["user:inference"], "subscriptionType": "max"]
    if let expiresAtMS { payload["expiresAt"] = expiresAtMS }
    return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": payload])
}

@Suite("Claude quota — credentials parsing (read-only)")
struct ClaudeQuotaCredentialTests {

    @Test("claudeAiOauth wrapper parses; expiresAt is epoch ms")
    func parseHappyPath() {
        let creds = ClaudeCredentialReader.parse(credsJSON())
        #expect(creds != nil)
        #expect(creds?.accessToken == seededToken)
        #expect(creds?.expiresAt == Date(timeIntervalSince1970: 1_783_500_000))
        #expect(creds?.subscriptionType == "max")
    }

    @Test("missing claudeAiOauth root → nil")
    func missingRoot() {
        let data = try! JSONSerialization.data(withJSONObject: ["accessToken": seededToken])
        #expect(ClaudeCredentialReader.parse(data) == nil)
    }

    @Test("mcpOAuth-only payload is not a login → nil")
    func mcpOnly() {
        let data = try! JSONSerialization.data(
            withJSONObject: ["mcpOAuth": ["someServer": ["accessToken": "sk-test-mcp"]]])
        #expect(ClaudeCredentialReader.parse(data) == nil)
    }

    @Test("whitespace-padded token is trimmed")
    func trimsToken() {
        let creds = ClaudeCredentialReader.parse(credsJSON(token: "  \(seededToken)\n"))
        #expect(creds?.accessToken == seededToken)
    }

    @Test("empty token → nil; garbage → nil (never a crash)")
    func rejectsEmptyAndGarbage() {
        #expect(ClaudeCredentialReader.parse(credsJSON(token: "   ")) == nil)
        #expect(ClaudeCredentialReader.parse(Data()) == nil)
        #expect(ClaudeCredentialReader.parse(Data("not json at all".utf8)) == nil)
    }

    @Test("no expiresAt → not expired (endpoint 401 handles the rest)")
    func noExpiry() {
        let creds = ClaudeCredentialReader.parse(credsJSON(expiresAtMS: nil))
        #expect(creds != nil)
        #expect(creds?.isExpired == false)
    }

    @Test("past expiresAt reads expired")
    func expired() {
        let creds = ClaudeCredentialReader.parse(credsJSON(expiresAtMS: 1_000_000_000_000))
        #expect(creds?.isExpired == true)
    }
}

@Suite("Claude quota — usage decoder (§D mapper)")
struct ClaudeQuotaDecoderTests {

    // The exact plan-04 fixture: legacy windows + scoped limits with a
    // duplicate Ghost entry (is_active true/false) and a session_scoped entry.
    private let fullFixture = Data("""
    {"five_hour":{"utilization":42.5,"resets_at":"2026-07-07T10:00:00Z"},
     "seven_day":{"utilization":89.0,"resets_at":"2026-07-08T02:29:00Z"},
     "limits":[
       {"kind":"weekly_scoped","group":"weekly","percent":58.0,"resets_at":"2026-07-08T02:29:00Z","is_active":false,
        "scope":{"model":{"id":"claude-ghost-5","display_name":"Ghost"}}},
       {"kind":"weekly_scoped","group":"weekly","percent":58.0,"resets_at":"2026-07-08T02:29:00Z","is_active":true,
        "scope":{"model":{"id":"claude-ghost-5","display_name":"Ghost"}}},
       {"kind":"session_scoped","group":"session","percent":10.0,"resets_at":null,"scope":null}]}
    """.utf8)

    @Test("full fixture: windows + exactly one deduped scoped Ghost row")
    func fullFixtureDecodes() throws {
        let snap = try #require(OAuthUsageDecoder.snapshot(from: fullFixture, now: Date()))
        #expect(snap.fiveHour?.title == "Session (5h)")
        #expect(snap.fiveHour?.usedPercent == 42.5)
        #expect(snap.fiveHour?.resetsAt == parseDate("2026-07-07T10:00:00Z"))
        #expect(snap.weekly?.title == "Weekly (all models)")
        #expect(snap.weekly?.usedPercent == 89.0)
        // §D: session_scoped filtered out; the two Ghost entries dedupe by slug
        // to ONE row; is_active:false is NOT a filter (enforceable scoped
        // limits report false).
        #expect(snap.scoped.count == 1)
        #expect(snap.scoped.first?.title == "Ghost only")
        #expect(snap.scoped.first?.usedPercent == 58.0)
        #expect(snap.windows.count == 3)
        #expect(snap.isEmpty == false)
    }

    @Test("fractional-seconds resets_at parses")
    func fractionalSeconds() throws {
        let data = Data(#"{"five_hour":{"utilization":10.0,"resets_at":"2026-07-08T02:29:00.123Z"}}"#.utf8)
        let snap = try #require(OAuthUsageDecoder.snapshot(from: data, now: Date()))
        #expect(snap.fiveHour?.resetsAt != nil)
    }

    @Test("legacy-only response: scoped empty, windows present")
    func legacyOnly() throws {
        let data = Data(#"{"five_hour":{"utilization":42.5,"resets_at":"2026-07-07T10:00:00Z"},"seven_day":{"utilization":89.0,"resets_at":null}}"#.utf8)
        let snap = try #require(OAuthUsageDecoder.snapshot(from: data, now: Date()))
        #expect(snap.scoped.isEmpty)
        #expect(snap.fiveHour != nil)
        #expect(snap.weekly != nil)
        #expect(snap.weekly?.resetsAt == nil)
    }

    @Test("scoped entry falls back to model id when display_name is empty")
    func scopedNameFallback() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":12.0,"resets_at":null,"is_active":false,"scope":{"model":{"id":"claude-opus-4-8","display_name":"  "}}}]}"#.utf8)
        let snap = try #require(OAuthUsageDecoder.snapshot(from: data, now: Date()))
        #expect(snap.scoped.first?.title == "claude-opus-4-8 only")
    }

    @Test("scoped entry with no model name at all is dropped")
    func scopedNameRequired() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":12.0,"resets_at":null,"is_active":true,"scope":null}]}"#.utf8)
        let snap = try #require(OAuthUsageDecoder.snapshot(from: data, now: Date()))
        #expect(snap.scoped.isEmpty)
    }

    @Test("garbage / empty data → nil, never a crash")
    func garbage() {
        #expect(OAuthUsageDecoder.snapshot(from: Data(), now: Date()) == nil)
        #expect(OAuthUsageDecoder.snapshot(from: Data("<!doctype html>".utf8), now: Date()) == nil)
        #expect(OAuthUsageDecoder.snapshot(from: Data(#"[1,2,3]"#.utf8), now: Date()) == nil)
    }

    @Test("valid-but-empty payload → empty snapshot (caller decides)")
    func emptyPayload() throws {
        let snap = try #require(OAuthUsageDecoder.snapshot(from: Data("{}".utf8), now: Date()))
        #expect(snap.isEmpty)
    }
}

@Suite("Claude quota — Retry-After parsing")
struct ClaudeQuotaRetryAfterTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test("delta-seconds")
    func seconds() {
        #expect(ClaudeQuotaFetcher.retryAfterDate("120", now: now) == now.addingTimeInterval(120))
    }

    @Test("HTTP-date")
    func httpDate() {
        let date = ClaudeQuotaFetcher.retryAfterDate("Tue, 07 Jul 2026 10:00:00 GMT", now: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "GMT")!
        let c = cal.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(c.year == 2026 && c.month == 7 && c.day == 7 && c.hour == 10)
    }

    @Test("absent / unparsable → now + 300s default")
    func fallback() {
        #expect(ClaudeQuotaFetcher.retryAfterDate(nil, now: now) == now.addingTimeInterval(300))
        #expect(ClaudeQuotaFetcher.retryAfterDate("soonish", now: now) == now.addingTimeInterval(300))
        #expect(ClaudeQuotaFetcher.retryAfterDate("-5", now: now) == now.addingTimeInterval(300))
    }
}

@Suite("Claude quota — SECURITY: nothing printable carries the token")
struct ClaudeQuotaRedactionTests {

    @Test("credential descriptions are redacted")
    func credentialRedaction() throws {
        let creds = try #require(ClaudeCredentialReader.parse(credsJSON()))
        for desc in [String(describing: creds), String(reflecting: creds), "\(creds)"] {
            #expect(!desc.contains(seededToken))
            #expect(!desc.contains("sk-test"))
            #expect(desc.contains("<redacted>"))
        }
    }

    @Test("every error case describes without payloads")
    func errorRedaction() {
        let cases: [ClaudeQuotaError] = [
            .noCredentials("no credentials found (file + keychain)"),
            .expired, .unauthorized,
            .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_780_000_000)),
            .server(503),
            .network("URLError -1009 offline"),
            .badPayload,
        ]
        for c in cases {
            let desc = String(describing: c) + QuotaStore.describe(c)
            #expect(!desc.contains(seededToken))
            #expect(!desc.contains("Bearer"))
        }
    }

    @Test("terminal quota states use calm exact copy")
    func terminalStatusCopy() {
        let signedOut = "Signed out — run claude once to sign in, then Retry."
        #expect(QuotaStore.describe(.expired) == signedOut)
        #expect(QuotaStore.describe(.unauthorized) == signedOut)

        let unavailable = "Plan quota unavailable — the usage endpoint didn't answer. Costs and attention don't need it."
        #expect(QuotaStore.describe(.network("secret-free diagnostic")) == unavailable)
        #expect(QuotaStore.describe(.server(503)) == unavailable)
        #expect(QuotaStore.describe(.badPayload) == unavailable)
        #expect(!signedOut.contains("(any prompt)"))
        #expect(!signedOut.contains("then Refresh"))
    }

    @Test("public decode seam matches the internal decoder exactly")
    func publicSeamMatchesInternal() throws {
        // QuotaSnapshot.decode is the ONE public seam over OAuthUsageDecoder
        // (the selfcheck replays payloads through it). It must be a pure
        // passthrough: identical snapshot on good data, nil on garbage.
        let now = Date(timeIntervalSince1970: 1_783_500_000)
        let payload = Data("""
        {"five_hour":{"utilization":42.5,"resets_at":"2026-07-07T10:00:00Z"},
         "seven_day":{"utilization":89.0,"resets_at":"2026-07-08T02:29:00Z"},
         "limits":[{"kind":"weekly_scoped","group":"weekly","percent":76.0,"is_active":false,
           "scope":{"model":{"id":"claude-ghost-5","display_name":"Ghost"}}}]}
        """.utf8)
        let viaSeam = try #require(QuotaSnapshot.decode(payload, now: now))
        let direct = try #require(OAuthUsageDecoder.snapshot(from: payload, now: now))
        #expect(viaSeam == direct)
        #expect(QuotaSnapshot.decode(Data("<!doctype html>".utf8), now: now) == nil)
        #expect(QuotaSnapshot.decode(Data("{}".utf8), now: now)?.isEmpty == true)
    }
}
