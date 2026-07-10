import Foundation
import Testing
@testable import TrifolaKit

@Suite("Adaptive refresh policy")
struct AdaptiveRefreshPolicyTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func input(
        ageSeconds: TimeInterval?,
        lowPowerModeEnabled: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal
    ) -> AdaptiveRefreshPolicy.Input {
        AdaptiveRefreshPolicy.Input(
            now: Self.referenceNow,
            lastMenuOpenAt: ageSeconds.map { Self.referenceNow.addingTimeInterval(-$0) },
            powerState: AdaptiveRefreshPolicy.PowerState(
                lowPowerModeEnabled: lowPowerModeEnabled,
                thermalState: thermalState))
    }

    @Test(arguments: [
        (-600.0, AdaptiveRefreshPolicy.Reason.recentInteraction, 120),
        (0.0, .recentInteraction, 120),
        (299.0, .recentInteraction, 120),
        (300.0, .recentInteraction, 120),
        (301.0, .warm, 300),
        (3_599.0, .warm, 300),
        (3_600.0, .warm, 300),
        (3_601.0, .idle, 900),
        (14_399.0, .idle, 900),
        (14_400.0, .longIdle, 1_800),
        (100_000.0, .longIdle, 1_800),
    ])
    func menuOpenRecencyCoversEveryTierAndBoundary(
        ageSeconds: TimeInterval,
        expectedReason: AdaptiveRefreshPolicy.Reason,
        expectedDelaySeconds: Int
    ) {
        let decision = AdaptiveRefreshPolicy.nextDelay(for: input(ageSeconds: ageSeconds))
        #expect(decision.reason == expectedReason)
        #expect(decision.delay == .seconds(expectedDelaySeconds))
    }

    @Test func noMenuHistoryIsLongIdle() {
        let decision = AdaptiveRefreshPolicy.nextDelay(for: input(ageSeconds: nil))
        #expect(decision == .init(delay: .seconds(30 * 60), reason: .longIdle))
    }

    @Test func lowPowerWinsOverRecentInteraction() {
        let decision = AdaptiveRefreshPolicy.nextDelay(
            for: input(ageSeconds: 0, lowPowerModeEnabled: true))
        #expect(decision == .init(delay: .seconds(30 * 60), reason: .constrained))
    }

    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func seriousAndCriticalThermalStatesAreConstrained(
        thermalState: ProcessInfo.ThermalState
    ) {
        let decision = AdaptiveRefreshPolicy.nextDelay(
            for: input(ageSeconds: 0, thermalState: thermalState))
        #expect(decision == .init(delay: .seconds(30 * 60), reason: .constrained))
    }

    @Test(arguments: [ProcessInfo.ThermalState.nominal, .fair])
    func nominalAndFairThermalStatesUseTheRecencyTier(
        thermalState: ProcessInfo.ThermalState
    ) {
        let decision = AdaptiveRefreshPolicy.nextDelay(
            for: input(ageSeconds: 0, thermalState: thermalState))
        #expect(decision == .init(delay: .seconds(2 * 60), reason: .recentInteraction))
    }

    @Test func everyInputCombinationStaysWithinTwoToThirtyMinutes() {
        let ages: [TimeInterval?] = [
            nil, -1_000_000, -600, 0, 300, 301, 3_600, 3_601, 14_399, 14_400, 1_000_000,
        ]
        for age in ages {
            for lowPowerModeEnabled in [false, true] {
                for thermalState in ProcessInfo.ThermalState.allPolicyCases {
                    let decision = AdaptiveRefreshPolicy.nextDelay(for: input(
                        ageSeconds: age,
                        lowPowerModeEnabled: lowPowerModeEnabled,
                        thermalState: thermalState))
                    #expect(decision.delay >= .seconds(2 * 60))
                    #expect(decision.delay <= .seconds(30 * 60))
                }
            }
        }
    }
}

private extension ProcessInfo.ThermalState {
    static let allPolicyCases: [ProcessInfo.ThermalState] = [
        .nominal, .fair, .serious, .critical,
    ]
}

@Suite("Provider refresh budget")
struct ProviderRefreshBudgetTests {
    @Test func concurrentTriggersCoalesceIntoOneProviderBatch() async {
        let coordinator = ProviderRefreshCoordinator()
        let starts = Locked(0)
        let active = Locked(0)
        let maximumActive = Locked(0)
        let gate = AsyncGate()
        let probes = [
            ProviderRefreshProbe(id: "claude.quota") {
                starts.withLock { $0 += 1 }
                let nowActive = active.withLock { value in
                    value += 1
                    return value
                }
                maximumActive.withLock { $0 = max($0, nowActive) }
                await gate.wait()
                active.withLock { $0 -= 1 }
            },
        ]

        let tasks = (0..<24).map { _ in
            Task { await coordinator.refresh(probes) }
        }
        while starts.withLock({ $0 }) == 0 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        gate.open()
        for task in tasks { _ = await task.value }

        #expect(starts.withLock { $0 } == 1)
        #expect(maximumActive.withLock { $0 } == 1)
    }

    @Test func hardCeilingSkipsOverflowWithoutStartingIt() async {
        let coordinator = ProviderRefreshCoordinator()
        let starts = Locked<[String]>([])
        let requested = (0..<(ProviderRefreshCoordinator.hardProbeCeiling + 3)).map { index in
            ProviderRefreshProbe(id: "probe-\(index)") {
                starts.withLock { $0.append("probe-\(index)") }
            }
        }

        let result = await coordinator.refresh(requested)

        #expect(starts.withLock { $0.count } == ProviderRefreshCoordinator.hardProbeCeiling)
        #expect(result.executedProbeIDs.count == ProviderRefreshCoordinator.hardProbeCeiling)
        let overflow = ProviderRefreshCoordinator.hardProbeCeiling...(ProviderRefreshCoordinator.hardProbeCeiling + 2)
        #expect(result.skippedProbeIDs == overflow.map { "probe-\($0)" })
    }

    @Test func distinctConcurrentPathsSerializeInsteadOfDroppingWork() async {
        let coordinator = ProviderRefreshCoordinator()
        let order = Locked<[String]>([])
        let gate = AsyncGate()
        let first = Task {
            await coordinator.refresh([ProviderRefreshProbe(id: "quota") {
                order.withLock { $0.append("quota-start") }
                await gate.wait()
                order.withLock { $0.append("quota-end") }
            }])
        }
        while order.withLock({ $0.isEmpty }) { await Task.yield() }
        let second = Task {
            await coordinator.refresh([ProviderRefreshProbe(id: "machine") {
                order.withLock { $0.append("machine") }
            }])
        }
        try? await Task.sleep(for: .milliseconds(20))
        gate.open()
        _ = await first.value
        _ = await second.value

        #expect(order.withLock { $0 } == ["quota-start", "quota-end", "machine"])
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    nonisolated func open() {
        Task { await openIsolated() }
    }

    private func openIsolated() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
