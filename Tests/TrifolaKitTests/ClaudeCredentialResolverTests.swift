import Foundation
import Testing
@testable import TrifolaKit

private func credential(expiringAt expiry: Date) -> ClaudeOAuthCredentials {
    ClaudeOAuthCredentials(accessToken: UUID().uuidString,
                           expiresAt: expiry,
                           subscriptionType: nil)
}

private func quotaSnapshot(at date: Date) -> QuotaSnapshot {
    QuotaSnapshot(fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 25, resetsAt: nil),
                  weekly: nil, scoped: [], fetchedAt: date)
}

@Suite("Claude quota — candidate credential resolution")
struct ClaudeCredentialResolverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("expired file plus valid keychain selects keychain")
    func expiredFileFallsThroughBeforeFetch() async throws {
        let candidates = ClaudeCredentialReader.candidates(
            now: now,
            file: .credential(credential(expiringAt: now.addingTimeInterval(-60))),
            keychain: .credential(credential(expiringAt: now.addingTimeInterval(3_600))))

        #expect(candidates.ordered.map(\.source) == [.keychain])
        let resolved = await ClaudeQuotaResolver.resolve(candidates: candidates) { candidate in
            #expect(candidate.source == .keychain)
            return .success(quotaSnapshot(at: self.now))
        }

        let value = try #require(resolved.success)
        #expect(value.source == .keychain)
    }

    @Test("file 401 falls through to valid keychain")
    func unauthorizedFileFallsThrough() async throws {
        let candidates = ClaudeCredentialReader.candidates(
            now: now,
            file: .credential(credential(expiringAt: now.addingTimeInterval(1_800))),
            keychain: .credential(credential(expiringAt: now.addingTimeInterval(3_600))))

        let resolved = await ClaudeQuotaResolver.resolve(candidates: candidates) { candidate in
            candidate.source == .file
                ? .failure(.unauthorized)
                : .success(quotaSnapshot(at: self.now))
        }

        let value = try #require(resolved.success)
        #expect(value.source == .keychain)
    }

    @Test("both expired reports all credentials expired")
    func bothExpiredAreDistinguished() async {
        let candidates = ClaudeCredentialReader.candidates(
            now: now,
            file: .credential(credential(expiringAt: now.addingTimeInterval(-120))),
            keychain: .credential(credential(expiringAt: now.addingTimeInterval(-60))))

        #expect(candidates.ordered.isEmpty)
        #expect(candidates.failureWhenExhausted == .allExpired)
        let resolved = await ClaudeQuotaResolver.resolve(candidates: candidates) { _ in
            Issue.record("expired credentials must never be fetched")
            return .failure(.unauthorized)
        }
        #expect(resolved.failure.map(QuotaStore.describe)?.contains("all credentials expired") == true)
    }

    @Test("keychain denial is not reported as missing credentials")
    func deniedKeychainIsDistinct() async {
        // These explicit outcomes are the injected Keychain fake. This suite
        // never calls loadCandidates() or the real `security` command.
        let denied = ClaudeCredentialReader.candidates(now: now, file: .missing, keychain: .denied)
        let missing = ClaudeCredentialReader.candidates(now: now, file: .missing, keychain: .missing)

        #expect(denied.failureWhenExhausted == .keychainDenied)
        #expect(missing.failureWhenExhausted == .noCredentials)

        let resolved = await ClaudeQuotaResolver.resolve(candidates: denied) { _ in
            Issue.record("no credential candidate should be fetched")
            return .failure(.unauthorized)
        }
        #expect(resolved.failure.map(QuotaStore.describe)?.contains("keychain access denied") == true)
        #expect(resolved.failure.map(QuotaStore.describe)?.contains("no credentials found") == false)
    }

    @Test("CLAUDE_CONFIG_DIR overrides the MCP config root")
    func configDirectoryOverride() {
        let home = URL(fileURLWithPath: "/tmp/trifola-home", isDirectory: true)
        let overridden = ClaudeCredentialReader.configDirectory(
            home: home,
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/trifola-config"])
        let fallback = ClaudeCredentialReader.configDirectory(home: home, environment: [:])

        #expect(overridden.path == "/tmp/trifola-config")
        #expect(fallback.path == "/tmp/trifola-home/.claude")
    }
}

private extension Result where Success == ResolvedQuota, Failure == ClaudeQuotaError {
    var success: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
