import Foundation

/// Decides how long to wait before the next automatic provider-batch refresh.
/// Pure by construction: the clock and power signals arrive through `Input`.
/// Quota, latency, errors, provider identity, and content-change rates are
/// deliberately absent so the cadence remains deterministic and auditable.
public enum AdaptiveRefreshPolicy {
    public struct PowerState: Sendable, Equatable {
        public let lowPowerModeEnabled: Bool
        public let thermalState: ProcessInfo.ThermalState

        public init(lowPowerModeEnabled: Bool, thermalState: ProcessInfo.ThermalState) {
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.thermalState = thermalState
        }

        /// The impure system read belongs at the call site, never in the policy.
        public static var current: PowerState {
            PowerState(
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState)
        }
    }

    public struct Input: Sendable, Equatable {
        public let now: Date
        public let lastMenuOpenAt: Date?
        public let powerState: PowerState

        public init(now: Date, lastMenuOpenAt: Date?, powerState: PowerState) {
            self.now = now
            self.lastMenuOpenAt = lastMenuOpenAt
            self.powerState = powerState
        }
    }

    public enum Reason: String, Sendable, Equatable {
        case recentInteraction
        case warm
        case idle
        case longIdle
        case constrained
    }

    public struct Decision: Sendable, Equatable {
        public let delay: Duration
        public let reason: Reason

        public init(delay: Duration, reason: Reason) {
            self.delay = delay
            self.reason = reason
        }
    }

    private static let recentInteractionThreshold: TimeInterval = 5 * 60
    private static let warmThreshold: TimeInterval = 60 * 60
    private static let idleThreshold: TimeInterval = 4 * 60 * 60

    /// The exact bounded CodexBar cadence: 2m active, 5m warm, 15m idle,
    /// 30m long-idle or power-constrained.
    public static func nextDelay(for input: Input) -> Decision {
        if input.powerState.lowPowerModeEnabled || isConstrained(input.powerState.thermalState) {
            return Decision(delay: .seconds(30 * 60), reason: .constrained)
        }

        guard let lastMenuOpenAt = input.lastMenuOpenAt else {
            return Decision(delay: .seconds(30 * 60), reason: .longIdle)
        }

        // A future/clock-adjusted timestamp has a negative age and is recent.
        let age = input.now.timeIntervalSince(lastMenuOpenAt)
        if age <= recentInteractionThreshold {
            return Decision(delay: .seconds(2 * 60), reason: .recentInteraction)
        }
        if age <= warmThreshold {
            return Decision(delay: .seconds(5 * 60), reason: .warm)
        }
        if age < idleThreshold {
            return Decision(delay: .seconds(15 * 60), reason: .idle)
        }
        return Decision(delay: .seconds(30 * 60), reason: .longIdle)
    }

    private static func isConstrained(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }
}

/// One bounded unit in a provider refresh batch. The result is applied by the
/// owner of the probe; the coordinator owns only budget and concurrency.
public struct ProviderRefreshProbe: Sendable {
    public let id: String
    fileprivate let operation: @Sendable () async -> Void

    public init(id: String, operation: @escaping @Sendable () async -> Void) {
        self.id = id
        self.operation = operation
    }
}

public struct ProviderRefreshBatchResult: Sendable, Equatable {
    public let executedProbeIDs: [String]
    public let skippedProbeIDs: [String]

    public init(executedProbeIDs: [String], skippedProbeIDs: [String]) {
        self.executedProbeIDs = executedProbeIDs
        self.skippedProbeIDs = skippedProbeIDs
    }
}

/// Global single-flight for quota, machine, stack, and future provider probes.
/// Concurrent triggers await the batch already in flight instead of starting a
/// second batch. The explicit ceiling makes provider breadth a reviewed choice.
public actor ProviderRefreshCoordinator {
    /// Five existing stack probes + quota + the Claude/Codex adapter budget.
    /// Raising this number requires an explicit code change and test update.
    public static let hardProbeCeiling = 8
    public static let shared = ProviderRefreshCoordinator()

    private struct Flight: Sendable {
        let id: UUID
        let probeIDs: Set<String>
        let task: Task<ProviderRefreshBatchResult, Never>
    }

    private var inFlight: Flight?

    public init() {}

    public func refresh(_ requested: [ProviderRefreshProbe]) async -> ProviderRefreshBatchResult {
        if let flight = inFlight {
            let result = await flight.task.value
            if inFlight?.id == flight.id { inFlight = nil }
            let requestedIDs = Set(requested.prefix(Self.hardProbeCeiling).map(\.id))
            if requestedIDs.isSubset(of: flight.probeIDs) { return result }
            // A different refresh path arrived during the flight. Serialize one
            // follow-up batch instead of dropping it; identical triggers above
            // still coalesce to the existing task.
            return await refresh(requested)
        }

        let capped = Array(requested.prefix(Self.hardProbeCeiling))
        let skipped = Array(requested.dropFirst(Self.hardProbeCeiling)).map(\.id)
        let flightID = UUID()
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for probe in capped {
                    group.addTask { await probe.operation() }
                }
                await group.waitForAll()
            }
            return ProviderRefreshBatchResult(
                executedProbeIDs: capped.map(\.id),
                skippedProbeIDs: skipped)
        }
        inFlight = Flight(id: flightID, probeIDs: Set(capped.map(\.id)), task: task)
        let result = await task.value
        if inFlight?.id == flightID { inFlight = nil }
        return result
    }
}
