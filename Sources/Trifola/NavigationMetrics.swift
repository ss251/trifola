import AppKit
import SwiftUI
import TrifolaKit
import os

/// Stable screen identifiers for navigation traces. Signpost interval names must
/// be static strings, so every destination is spelled out in the switches below
/// rather than interpolated into one dynamic name.
enum NavigationMetricScreen: String, CaseIterable, Sendable {
    case overview
    case live
    case fleet
    case deadlines
    case sessions
    case spend
    case audit
    case ledger
    case launch
    case stack
}

extension AppSection {
    var navigationMetricScreen: NavigationMetricScreen {
        switch self {
        case .overview: .overview
        case .live: .live
        case .fleet: .fleet
        case .deadlines: .deadlines
        case .sessions: .sessions
        case .spend: .spend
        case .audit: .audit
        case .ledger: .ledger
        case .launch: .launch
        case .stack: .stack
        }
    }
}

/// The two draw milestones in a navigation journey. The destination shell ends
/// the first-frame interval; the ready-content tree ends hydration. Warm
/// snapshots normally deliver both on the same display pass, while a cold
/// snapshot delivers the shell first and hydrated content later.
enum NavigationDrawMilestone: Equatable, Sendable {
    case firstFrame
    case hydratedContent
}

/// One click's paired signpost intervals. This is main-actor state because the
/// click and draw callbacks both originate in AppKit/SwiftUI. Optional interval
/// states make every end operation idempotent, which matters when SwiftUI asks a
/// representable to draw more than once.
@MainActor
final class NavigationMetricJourney {
    let screen: NavigationMetricScreen
    let generation: Int
    let cold: Bool

    fileprivate let startedNanoseconds: UInt64
    fileprivate var firstFrameState: OSSignpostIntervalState?
    fileprivate var hydrationState: OSSignpostIntervalState?

    fileprivate init(
        screen: NavigationMetricScreen,
        generation: Int,
        cold: Bool,
        startedNanoseconds: UInt64,
        firstFrameState: OSSignpostIntervalState,
        hydrationState: OSSignpostIntervalState
    ) {
        self.screen = screen
        self.generation = generation
        self.cold = cold
        self.startedNanoseconds = startedNanoseconds
        self.firstFrameState = firstFrameState
        self.hydrationState = hydrationState
    }
}

/// A projection-build interval may begin and end on a detached executor. The
/// modern os signpost state is Sendable, so the token can cross that boundary
/// without pinning projection work to the main actor.
struct NavigationProjectionMetric: Sendable {
    fileprivate let screen: NavigationMetricScreen
    fileprivate let generation: Int
    fileprivate let startedNanoseconds: UInt64
    fileprivate let state: OSSignpostIntervalState
}

/// Native points-of-interest instrumentation for the complete navigation path.
/// Instruments can enable these signposts without an environment flag. `MC_PERF`
/// also keeps the journey alive during terminal-only timing runs.
enum NavigationMetrics {
    private static let signposter = OSSignposter(
        subsystem: "com.ss251.trifola",
        category: "Navigation"
    )

    private struct LiveSampleKey: Hashable {
        let milestone: String
        let screen: NavigationMetricScreen
        let cold: Bool
    }

    @MainActor private static var liveSamples: [LiveSampleKey: [Double]] = [:]
    @MainActor private static var runLoopObserver: CFRunLoopObserver?
    @MainActor private static var runLoopTurnStarted: UInt64?

    private struct MainStretchJourney {
        let screen: NavigationMetricScreen
        let generation: Int
        let cold: Bool
        let startedNanoseconds: UInt64
        var maximumMilliseconds: Double
    }

    @MainActor private static var mainStretchJourney: MainStretchJourney?

    static var isEnabled: Bool {
        Perf.enabled
            || ProcessInfo.processInfo.environment["TRIFOLA_NAV_METRICS"] == "1"
            || signposter.isEnabled
    }

    /// The launch-only benchmark resets after refresh settles, then prints a
    /// compact distribution table after its cold pass and seven warm passes.
    /// Raw per-journey lines remain available for auditability.
    @MainActor
    static func resetLiveSamples() {
        liveSamples.removeAll(keepingCapacity: true)
    }

    @MainActor
    static func printLiveSummary() {
        for cold in [true, false] {
            for milestone in ["firstFrame", "hydrated", "mainStretch"] {
                for screen in NavigationMetricScreen.allCases {
                    let key = LiveSampleKey(
                        milestone: milestone, screen: screen, cold: cold)
                    guard let values = liveSamples[key], !values.isEmpty else { continue }
                    let sorted = values.sorted()
                    let middle = sorted.count / 2
                    let median = sorted.count.isMultiple(of: 2)
                        ? (sorted[middle - 1] + sorted[middle]) / 2
                        : sorted[middle]
                    let p95Index = min(
                        sorted.count - 1,
                        max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
                    let line = String(
                        format: "[nav-summary] milestone=%@ mode=%@ screen=%@ n=%d median=%.3f p95=%.3f max=%.3f\n",
                        milestone,
                        cold ? "cold" : "warm",
                        screen.rawValue,
                        sorted.count,
                        median,
                        sorted[p95Index],
                        sorted[sorted.count - 1])
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
        }
    }

    /// Start before the selection write. The caller retains the returned journey
    /// until the shell and hydrated-content probes have both drawn.
    @MainActor
    static func beginNavigation(
        to screen: NavigationMetricScreen,
        generation: Int,
        cold: Bool
    ) -> NavigationMetricJourney? {
        guard isEnabled else { return nil }

        let mode = cold ? "cold" : "warm"
        let firstFrame = signposter.beginInterval(
            "nav.click\u{2192}firstFrame",
            id: signposter.makeSignpostID(),
            "screen=\(screen.rawValue, privacy: .public) generation=\(generation) mode=\(mode, privacy: .public)"
        )
        let hydration = beginHydration(screen)
        let journey = NavigationMetricJourney(
            screen: screen,
            generation: generation,
            cold: cold,
            startedNanoseconds: DispatchTime.now().uptimeNanoseconds,
            firstFrameState: firstFrame,
            hydrationState: hydration
        )
        beginMainStretchTracking(journey)
        return journey
    }

    /// Ends at the destination shell's first AppKit draw pass.
    @MainActor
    @discardableResult
    static func endFirstFrame(_ journey: NavigationMetricJourney?) -> Double? {
        guard let journey, let state = journey.firstFrameState else { return nil }
        journey.firstFrameState = nil
        signposter.endInterval(
            "nav.click\u{2192}firstFrame",
            state,
            "screen=\(journey.screen.rawValue, privacy: .public) generation=\(journey.generation)"
        )
        let elapsed = elapsedMilliseconds(since: journey.startedNanoseconds)
        emitMeasurement("firstFrame", journey: journey, milliseconds: elapsed)
        return elapsed
    }

    /// Ends when ready content, not merely its published value, reaches a draw
    /// pass. This is the warm-content/cold-hydration acceptance metric.
    @MainActor
    @discardableResult
    static func endHydration(_ journey: NavigationMetricJourney?) -> Double? {
        guard let journey, let state = journey.hydrationState else { return nil }
        journey.hydrationState = nil
        endHydrationSignpost(journey.screen, state: state)
        let elapsed = elapsedMilliseconds(since: journey.startedNanoseconds)
        emitMeasurement("hydrated", journey: journey, milliseconds: elapsed)
        endMainStretchTracking(journey)
        return elapsed
    }

    /// Close any still-open intervals when a newer click supersedes a journey.
    /// Instruments then sees a bounded cancelled journey instead of an orphaned
    /// begin event.
    @MainActor
    static func cancel(_ journey: NavigationMetricJourney?) {
        guard let journey else { return }
        if let state = journey.firstFrameState {
            journey.firstFrameState = nil
            signposter.endInterval("nav.click\u{2192}firstFrame", state)
        }
        if let state = journey.hydrationState {
            journey.hydrationState = nil
            endHydrationSignpost(journey.screen, state: state)
        }
        if mainStretchJourney?.generation == journey.generation {
            mainStretchJourney = nil
        }
    }

    /// Wrap a store-owned snapshot build with this token inside the detached
    /// closure. The static per-screen interval name makes background placement
    /// and duration immediately visible in System Trace.
    static func beginProjection(
        _ screen: NavigationMetricScreen,
        generation: Int
    ) -> NavigationProjectionMetric? {
        guard isEnabled else { return nil }
        return NavigationProjectionMetric(
            screen: screen,
            generation: generation,
            startedNanoseconds: DispatchTime.now().uptimeNanoseconds,
            state: beginProjectionSignpost(screen)
        )
    }

    @discardableResult
    static func endProjection(_ metric: NavigationProjectionMetric?) -> Double? {
        guard let metric else { return nil }
        endProjectionSignpost(metric.screen, state: metric.state)
        let elapsed = elapsedMilliseconds(since: metric.startedNanoseconds)
        if Perf.enabled || ProcessInfo.processInfo.environment["TRIFOLA_NAV_METRICS"] == "1" {
            FileHandle.standardError.write(Data(String(
                format: "[nav-metric] projection screen=%@ generation=%d ms=%.3f\n",
                metric.screen.rawValue, metric.generation, elapsed).utf8))
        }
        return elapsed
    }

    @MainActor
    private static func emitMeasurement(
        _ milestone: String,
        journey: NavigationMetricJourney,
        milliseconds: Double
    ) {
        guard Perf.enabled
                || ProcessInfo.processInfo.environment["TRIFOLA_NAV_METRICS"] == "1"
        else { return }
        FileHandle.standardError.write(Data(String(
            format: "[nav-metric] %@ screen=%@ generation=%d mode=%@ ms=%.3f\n",
            milestone,
            journey.screen.rawValue,
            journey.generation,
            journey.cold ? "cold" : "warm",
            milliseconds).utf8))
        let key = LiveSampleKey(
            milestone: milestone,
            screen: journey.screen,
            cold: journey.cold)
        liveSamples[key, default: []].append(milliseconds)
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @MainActor
    private static func beginMainStretchTracking(
        _ journey: NavigationMetricJourney
    ) {
        installRunLoopObserverIfNeeded()
        mainStretchJourney = MainStretchJourney(
            screen: journey.screen,
            generation: journey.generation,
            cold: journey.cold,
            startedNanoseconds: journey.startedNanoseconds,
            maximumMilliseconds: 0)
    }

    @MainActor
    private static func endMainStretchTracking(
        _ journey: NavigationMetricJourney
    ) {
        guard var stretch = mainStretchJourney,
              stretch.generation == journey.generation else { return }
        recordCurrentRunLoopStretch(into: &stretch)
        mainStretchJourney = nil
        emitMeasurement(
            "mainStretch", journey: journey,
            milliseconds: stretch.maximumMilliseconds)
    }

    @MainActor
    private static func installRunLoopObserverIfNeeded() {
        guard runLoopObserver == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
        guard let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities,
            true,
            0,
            { _, activity in
                MainActor.assumeIsolated {
                    handleRunLoopActivity(activity)
                }
            }) else { return }
        runLoopObserver = observer
        CFRunLoopAddObserver(
            CFRunLoopGetMain(), observer, .commonModes)
    }

    @MainActor
    private static func handleRunLoopActivity(_ activity: CFRunLoopActivity) {
        if activity.contains(.afterWaiting) {
            runLoopTurnStarted = DispatchTime.now().uptimeNanoseconds
        }
        if activity.contains(.beforeWaiting) {
            if var stretch = mainStretchJourney {
                recordCurrentRunLoopStretch(into: &stretch)
                mainStretchJourney = stretch
            }
            runLoopTurnStarted = nil
        }
    }

    @MainActor
    private static func recordCurrentRunLoopStretch(
        into stretch: inout MainStretchJourney
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let turnStart = max(
            runLoopTurnStarted ?? stretch.startedNanoseconds,
            stretch.startedNanoseconds)
        guard now >= turnStart else { return }
        stretch.maximumMilliseconds = max(
            stretch.maximumMilliseconds,
            Double(now - turnStart) / 1_000_000)
    }

    private static func beginHydration(
        _ screen: NavigationMetricScreen
    ) -> OSSignpostIntervalState {
        switch screen {
        case .overview: signposter.beginInterval("hydrate.overview")
        case .live: signposter.beginInterval("hydrate.live")
        case .fleet: signposter.beginInterval("hydrate.fleet")
        case .deadlines: signposter.beginInterval("hydrate.deadlines")
        case .sessions: signposter.beginInterval("hydrate.sessions")
        case .spend: signposter.beginInterval("hydrate.spend")
        case .audit: signposter.beginInterval("hydrate.audit")
        case .ledger: signposter.beginInterval("hydrate.ledger")
        case .launch: signposter.beginInterval("hydrate.launch")
        case .stack: signposter.beginInterval("hydrate.stack")
        }
    }

    private static func endHydrationSignpost(
        _ screen: NavigationMetricScreen,
        state: OSSignpostIntervalState
    ) {
        switch screen {
        case .overview: signposter.endInterval("hydrate.overview", state)
        case .live: signposter.endInterval("hydrate.live", state)
        case .fleet: signposter.endInterval("hydrate.fleet", state)
        case .deadlines: signposter.endInterval("hydrate.deadlines", state)
        case .sessions: signposter.endInterval("hydrate.sessions", state)
        case .spend: signposter.endInterval("hydrate.spend", state)
        case .audit: signposter.endInterval("hydrate.audit", state)
        case .ledger: signposter.endInterval("hydrate.ledger", state)
        case .launch: signposter.endInterval("hydrate.launch", state)
        case .stack: signposter.endInterval("hydrate.stack", state)
        }
    }

    private static func beginProjectionSignpost(
        _ screen: NavigationMetricScreen
    ) -> OSSignpostIntervalState {
        switch screen {
        case .overview: signposter.beginInterval("projection.build.overview")
        case .live: signposter.beginInterval("projection.build.live")
        case .fleet: signposter.beginInterval("projection.build.fleet")
        case .deadlines: signposter.beginInterval("projection.build.deadlines")
        case .sessions: signposter.beginInterval("projection.build.sessions")
        case .spend: signposter.beginInterval("projection.build.spend")
        case .audit: signposter.beginInterval("projection.build.audit")
        case .ledger: signposter.beginInterval("projection.build.ledger")
        case .launch: signposter.beginInterval("projection.build.launch")
        case .stack: signposter.beginInterval("projection.build.stack")
        }
    }

    private static func endProjectionSignpost(
        _ screen: NavigationMetricScreen,
        state: OSSignpostIntervalState
    ) {
        switch screen {
        case .overview: signposter.endInterval("projection.build.overview", state)
        case .live: signposter.endInterval("projection.build.live", state)
        case .fleet: signposter.endInterval("projection.build.fleet", state)
        case .deadlines: signposter.endInterval("projection.build.deadlines", state)
        case .sessions: signposter.endInterval("projection.build.sessions", state)
        case .spend: signposter.endInterval("projection.build.spend", state)
        case .audit: signposter.endInterval("projection.build.audit", state)
        case .ledger: signposter.endInterval("projection.build.ledger", state)
        case .launch: signposter.endInterval("projection.build.launch", state)
        case .stack: signposter.endInterval("projection.build.stack", state)
        }
    }
}

/// A one-point transparent AppKit view whose first draw is later than SwiftUI's
/// `.onAppear`. A generation+milestone key makes the callback exactly-once even
/// when AppKit asks the view to redraw for unrelated window damage.
struct NavigationFirstDrawProbe: NSViewRepresentable {
    let generation: Int
    let milestone: NavigationDrawMilestone
    let journey: NavigationMetricJourney?
    var onDraw: @MainActor () -> Void = {}

    func makeNSView(context: Context) -> NavigationFirstDrawNSView {
        let view = NavigationFirstDrawNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NavigationFirstDrawNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NavigationFirstDrawNSView) {
        view.configure(
            generation: generation,
            milestone: milestone,
            journey: journey,
            onDraw: onDraw
        )
    }
}

@MainActor
final class NavigationFirstDrawNSView: NSView {
    private struct DrawKey: Equatable {
        let generation: Int
        let milestone: NavigationDrawMilestone
    }

    private var key: DrawKey?
    private var delivered: DrawKey?
    private weak var journey: NavigationMetricJourney?
    private var onDraw: (@MainActor () -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 1) }
    override var isOpaque: Bool { false }

    func configure(
        generation: Int,
        milestone: NavigationDrawMilestone,
        journey: NavigationMetricJourney?,
        onDraw: @escaping @MainActor () -> Void
    ) {
        let next = DrawKey(generation: generation, milestone: milestone)
        key = next
        self.journey = journey
        self.onDraw = onDraw
        if delivered != next {
            needsDisplay = true
            superview?.needsDisplay = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        guard let key, delivered != key else { return }
        delivered = key
        switch key.milestone {
        case .firstFrame:
            NavigationMetrics.endFirstFrame(journey)
        case .hydratedContent:
            NavigationMetrics.endHydration(journey)
        }
        onDraw?()
    }
}

extension View {
    /// Attach at the top level of a shell or ready-content tree. The 1pt probe is
    /// non-interactive and visually empty.
    func navigationFirstDrawProbe(
        generation: Int,
        milestone: NavigationDrawMilestone,
        journey: NavigationMetricJourney?,
        onDraw: @escaping @MainActor () -> Void = {}
    ) -> some View {
        background(alignment: .topLeading) {
            NavigationFirstDrawProbe(
                generation: generation,
                milestone: milestone,
                journey: journey,
                onDraw: onDraw
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
