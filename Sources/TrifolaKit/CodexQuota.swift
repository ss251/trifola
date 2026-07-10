import Foundation

/// Minimal provider seam for quota snapshots. Implementations own their trust
/// boundary; the Codex implementation below performs local rollout reads only.
public protocol QuotaProvider: Sendable {
    var provider: Provider { get }
    func snapshot() async -> Result<QuotaSnapshot, QuotaProviderFailure>
}

public enum QuotaProviderFailure: Error, Sendable, Equatable {
    case noRollouts
    case noRateLimits
}

/// Reads the freshest persisted Codex rate-limit event. It accepts only an
/// explicit sessions root, performs no network request, and launches no Codex
/// process.
public struct CodexQuotaProvider: QuotaProvider {
    public let provider: Provider = .codex
    public let sessionsRoot: URL
    private let clock: @Sendable () -> Date

    public init(sessionsRoot: URL = CodexPaths.process.sessions,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
        self.clock = now
    }

    public func snapshot() async -> Result<QuotaSnapshot, QuotaProviderFailure> {
        let files = Self.rolloutFiles(beneath: sessionsRoot)
        guard !files.isEmpty else { return .failure(.noRollouts) }
        for file in files {
            guard let data = CodexRolloutFile.data(at: file.url) else { continue }
            var accumulator = CodexRolloutAccumulator(defaultID: file.url.lastPathComponent)
            accumulator.ingest(data)
            if let limits = accumulator.latestRateLimits {
                return .success(limits.snapshot(now: clock()))
            }
        }
        return .failure(.noRateLimits)
    }

    private struct RolloutFile {
        let url: URL
        let modifiedAt: Date
    }

    /// Newest files first. Symlinks and paths resolving outside the approved
    /// sessions root are rejected before any bytes are read.
    private static func rolloutFiles(beneath root: URL) -> [RolloutFile] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var result: [RolloutFile] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"),
                  name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else {
                continue
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(resolvedRoot + "/") else { continue }
            result.append(RolloutFile(
                url: resolved,
                modifiedAt: values.contentModificationDate ?? .distantPast))
        }
        return result.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.url.path > $1.url.path
        }
    }
}
