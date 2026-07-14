import SwiftUI
import AppKit
import TrifolaKit

extension NSColor {
    /// A two-appearance semantic color. Keeping the appearance decision in
    /// AppKit means the same token resolves correctly in windows and in the
    /// headless ImageRenderer harness.
    static func dyn(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Design tokens
// Warm, quiet, three-plane composition. Saturation is reserved for a decision,
// a selected small filter, or an honest state marker; data is graphite by default.

enum Theme {
    // Ground and text. Dark mode follows the measured Notion/Codex warmth;
    // light mode keeps macOS semantic ground and true label contrast.
    static let surfaceWindow = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 247 / 255, green: 246 / 255, blue: 243 / 255, alpha: 1),
        dark: NSColor(srgbRed: 25 / 255, green: 25 / 255, blue: 24 / 255, alpha: 1)))
    static let surfaceSidebar = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 242 / 255, green: 241 / 255, blue: 237 / 255, alpha: 1),
        dark: NSColor(srgbRed: 25 / 255, green: 25 / 255, blue: 24 / 255, alpha: 1)))
    static let ink = Color(nsColor: .dyn(
        light: .labelColor,
        dark: NSColor(srgbRed: 237 / 255, green: 236 / 255, blue: 233 / 255, alpha: 1)))
    static let muted = Color(nsColor: .dyn(
        light: .secondaryLabelColor,
        dark: NSColor(srgbRed: 163 / 255, green: 160 / 255, blue: 154 / 255, alpha: 1)))
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)

    // Large-area selection is a luminance step, never an accent billboard.
    static let selectionBG = Color(nsColor: .dyn(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.08)))
    static let selectionText = ink
    static let accent = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 38 / 255, green: 111 / 255, blue: 96 / 255, alpha: 1),
        dark: NSColor(srgbRed: 66 / 255, green: 153 / 255, blue: 132 / 255, alpha: 1)))
    /// A deliberately provider-neutral model hue for the Codex tier. This is a
    /// slate-teal data color, not OpenAI green and not Trifola's action accent;
    /// it appears only in small model marks alongside the existing tier hues.
    // Steel-blue, deliberately DISTINCT from Haiku's cyan-teal (73,163,176):
    // the original slate-teal was near-identical to it, making the tier legend
    // and split bar ambiguous (owner catch, 2026-07-13).
    static let codexModel = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 62 / 255, green: 92 / 255, blue: 148 / 255, alpha: 1),
        dark: NSColor(srgbRed: 124 / 255, green: 152 / 255, blue: 205 / 255, alpha: 1)))
    static let graphite = muted

    // Elevation. Every stroked surface is paired with a fill; open tables and
    // narration stay directly on the window ground.
    static let cardFill = Color(nsColor: .dyn(
        light: NSColor.white.withAlphaComponent(0.52),
        dark: NSColor.white.withAlphaComponent(0.045)))
    static let cardSolidFill = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 250 / 255, green: 249 / 255, blue: 247 / 255, alpha: 1),
        dark: NSColor(srgbRed: 38 / 255, green: 38 / 255, blue: 36 / 255, alpha: 1)))
    static let cardHighContrastFill = Color(nsColor: .dyn(
        light: .white,
        dark: NSColor(srgbRed: 12 / 255, green: 12 / 255, blue: 12 / 255, alpha: 1)))
    static let cardStroke = Color(nsColor: .dyn(
        light: NSColor.black.withAlphaComponent(0.095),
        dark: NSColor.white.withAlphaComponent(0.085)))
    static let codeFill = Color(nsColor: .dyn(
        light: NSColor.black.withAlphaComponent(0.03),
        dark: NSColor.white.withAlphaComponent(0.04)))

    // Attention pills are the only state-hued fills. The surrounding row/chip
    // stays neutral so the fully saturated 6pt dot remains the signal.
    static let blockedFill = Color(nsColor: .dyn(
        light: NSColor.systemRed.withAlphaComponent(0.10),
        dark: NSColor.systemRed.withAlphaComponent(0.15)))
    static let blockedText = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 163 / 255, green: 44 / 255, blue: 38 / 255, alpha: 1),
        dark: NSColor(srgbRed: 242 / 255, green: 199 / 255, blue: 196 / 255, alpha: 1)))
    static let waitingFill = Color(nsColor: .dyn(
        light: NSColor.systemYellow.withAlphaComponent(0.18),
        dark: NSColor.systemYellow.withAlphaComponent(0.12)))
    static let waitingText = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 125 / 255, green: 98 / 255, blue: 14 / 255, alpha: 1),
        dark: NSColor(srgbRed: 239 / 255, green: 228 / 255, blue: 176 / 255, alpha: 1)))

    // State may tint a row only as a barely-there interruption. The Door Light
    // remains the saturated signal; these washes exist solely to help a blocked
    // or waiting seat interrupt a dense scan without turning the board colorful.
    static let blockedRowFill = Color(nsColor: .dyn(
        light: NSColor.systemRed.withAlphaComponent(0.045),
        dark: NSColor.systemRed.withAlphaComponent(0.055)))
    static let waitingRowFill = Color(nsColor: .dyn(
        light: NSColor.systemYellow.withAlphaComponent(0.055),
        dark: NSColor.systemYellow.withAlphaComponent(0.035)))
    static let hoverFill = Color(nsColor: .dyn(
        light: NSColor.black.withAlphaComponent(0.045),
        dark: NSColor.white.withAlphaComponent(0.055)))
    // Keyboard focus is navigation chrome, not fleet state. Use the platform's
    // blue focus indicator instead of deriving it from Trifola's teal accent or
    // the green Door Light status family.
    static let keyboardFocusRing = Color(nsColor: .keyboardFocusIndicatorColor)

    // Status dots — system semantic status colors, auto-adapting, applied
    // ONLY to dots and short warning text runs. Never to bar fills or chrome.
    static let green = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 31 / 255, green: 154 / 255, blue: 86 / 255, alpha: 1),
        dark: .systemGreen))
    static let amber = Color(nsColor: .dyn(
        light: NSColor(srgbRed: 184 / 255, green: 126 / 255, blue: 0, alpha: 1),
        dark: .systemYellow))
    static let red = Color(nsColor: .systemRed)

    // MARK: Type
    // A native macOS scale with a real jump between orientation, reading, and
    // measurement. Large numeric roles use rounded SF forms + tabular figures;
    // prose stays in the platform face for legibility and Dynamic Type behavior.
    enum Typography {
        static let screenTitle = Font.system(size: 30, weight: .bold)
        static let display = Font.system(size: 42, weight: .semibold, design: .rounded)
        static let heroNumber = Font.system(size: 50, weight: .semibold, design: .rounded)
        static let metric = Font.system(size: 27, weight: .semibold, design: .rounded)
        static let supportingMetric = Font.system(size: 21, weight: .semibold, design: .rounded)
        static let section = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let metadata = Font.system(size: 11, weight: .regular)
        static let metadataMedium = Font.system(size: 11, weight: .medium)
        static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let monoMedium = Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    // Progress bars — 6pt capsule, track at tertiary 22% (CodexBar UsageProgressBar).
    static let barHeight: CGFloat = 6
    static let progressTrack = Color(nsColor: .tertiaryLabelColor).opacity(0.22)

    // One spacing/radius scale. Screen code maps to these values instead of
    // inventing a neighboring rhythm.
    static let micro: CGFloat = 4
    static let intraCell: CGFloat = 8
    static let gutter: CGFloat = 24
    static let rhythm: CGFloat = 6
    static let sectionGap: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let codePadding: CGFloat = 10
    static let hairlineWidth: CGFloat = 1
    static let keyboardFocusRingWidth: CGFloat = 2
    static let toggleKnobInset: CGFloat = 1.5
    static let sparkRadius: CGFloat = 1.5
    static let rowVerticalInset: CGFloat = 5
    static let compactControlVerticalInset: CGFloat = 3
    static let controlHorizontalInset: CGFloat = 11
    static let toastVerticalInset: CGFloat = 7
    static let liveGaugeBottomInset: CGFloat = 9
    static let paletteFieldVerticalInset: CGFloat = 13
    static let overlayEmptyVerticalInset: CGFloat = 18
    static let paneInset: CGFloat = 16
    static let paletteTopInset: CGFloat = 96
    static let renderInset: CGFloat = 28
    static let radiusInline: CGFloat = 4
    static let radiusRow: CGFloat = 6
    static let radiusCard: CGFloat = 10
    static let radiusOverlay: CGFloat = 14
    static let radius: CGFloat = radiusCard

    // Millimeter layer — stop freehanding (POLISH C7). One inset, one block gap,
    // fixed evidence-table column metrics so every table reads as the same grammar.
    static let rowInsets = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    static let blockGap: CGFloat = 24          // between sections inside a screen
    static let rankBarWidth: CGFloat = 120     // the evidence rank column
    static let valueColWidth: CGFloat = 76     // primary right-aligned value column
    static let subValueColWidth: CGFloat = 56  // secondary value column
    static let microColWidth: CGFloat = 40     // counts (×N, session counts)
    static let iconGutter: CGFloat = 14
    static let compactRowHeight: CGFloat = 30
    static let sessionRowHeight: CGFloat = 36

    // MARK: Layout
    // Window and instrument geometry belong here so screens compose from one
    // grid instead of carrying private neighboring numbers.
    enum Layout {
        static let sidebarWidth: CGFloat = 248
        static let minimumWindowWidth: CGFloat = 1120
        static let minimumWindowHeight: CGFloat = 720
        static let defaultWindowWidth: CGFloat = 1440
        static let defaultWindowHeight: CGFloat = 900
        /// Data-heavy screens use a wider, still bounded theatre. At very wide
        /// window sizes the remaining canvas becomes deliberate margin rather
        /// than stretching tables and plots into long scan paths.
        static let contentMaxWidth: CGFloat = 1280
        static let proseMaxWidth: CGFloat = 700
        static let sessionsSplitMaxWidth: CGFloat = 1420
        static let sessionsListMinWidth: CGFloat = 460
        static let sessionsListIdealWidth: CGFloat = 520
        static let sessionsListMaxWidth: CGFloat = 560
        static let sessionsListFraction: CGFloat = 0.38
        static let sessionsInspectorMaxWidth: CGFloat = 840
        static let sessionsCollapseWidth: CGFloat = 980
        static let transcriptMeasure: CGFloat = 760
        static let headerHeight: CGFloat = 72
        static let screenTopInset: CGFloat = 18
        static let screenBottomInset: CGFloat = 30
        static let statBandMinHeight: CGFloat = 112
        static let chartHeight: CGFloat = 88
        static let chartAxisWidth: CGFloat = 42
        static let compactHitHeight: CGFloat = 28
        static let semanticRailWidth: CGFloat = 3
        static let menuWidth: CGFloat = 320
    }

    // MARK: Motion
    // Frequency decides the token. Call sites never invent curves or durations:
    // ambient feedback uses quick/roll, occasional navigation and layout changes
    // use nav/move/exit, and one-shot explanatory surfaces use reveal/draw/echo.
    private static let motionReviewScale: Double = {
        ProcessInfo.processInfo.environment["TRIFOLA_MOTION_SLOW"] == nil ? 1 : 4
    }()

    enum Motion {
        enum DrawKind { case continuous, bar }

        private static func easeOutStrong(_ duration: TimeInterval) -> Animation {
            .timingCurve(0.23, 1, 0.32, 1,
                         duration: duration * Theme.motionReviewScale)
        }

        static let quick = Animation.easeOut(duration: 0.12 * Theme.motionReviewScale)
        static let roll = easeOutStrong(0.18)
        static let move = Animation.spring(duration: 0.30 * Theme.motionReviewScale, bounce: 0)
        static let exit = Animation.easeOut(duration: 0.16 * Theme.motionReviewScale)
        static let ceremony = Animation.easeOut(duration: 0.30 * Theme.motionReviewScale)
        static let nav = easeOutStrong(0.20)
        static let reveal = easeOutStrong(0.30)
        static let echo = easeOutStrong(0.40)

        /// The draw family is one explanatory token with geometry-specific timing:
        /// continuous paths/gauges use 500ms in-out; discrete bars use 400ms
        /// ease-out so each staggered column lands decisively.
        static func draw(_ kind: DrawKind = .continuous) -> Animation {
            switch kind {
            case .continuous:
                return .timingCurve(0.77, 0, 0.175, 1,
                                    duration: 0.50 * Theme.motionReviewScale)
            case .bar:
                return easeOutStrong(0.40)
            }
        }

        /// Pointer-down is intentionally faster than release. Keeping the 100ms
        /// value here preserves the no-freehanded-duration law at call sites.
        static func press(_ isPressed: Bool) -> Animation {
            isPressed ? easeOutStrong(0.10) : quick
        }

        static let revealStep: TimeInterval = 0.04
        static func delay(_ seconds: TimeInterval) -> TimeInterval {
            seconds * Theme.motionReviewScale
        }

        /// Keeps the environment read launch-scoped rather than re-reading it at
        /// every animated surface.
        static func prepareForLaunch() { _ = Theme.motionReviewScale }
    }

    /// Used only to keep a mid-draw Door Light flip on its current trim pass;
    /// this is timing metadata, not a fifth animation token.
    static var ceremonyInterval: TimeInterval { 0.30 * motionReviewScale }

    /// Reduce Motion uses one quiet, non-spatial fade and never inherits the ×4
    /// review multiplier, so accessibility transitions remain at or below 200ms.
    static func motion(_ token: Animation, reduceMotion: Bool,
                       reducedDuration: TimeInterval = 0.16) -> Animation {
        reduceMotion ? .easeOut(duration: reducedDuration) : token
    }
}

// MARK: - Reduce Motion

private struct DoorLightReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct DoorLightReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct DoorLightIncreaseContrastOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Render-only override; production always falls through to the system's
    /// accessibilityReduceMotion value.
    var doorLightReduceMotionOverride: Bool? {
        get { self[DoorLightReduceMotionOverrideKey.self] }
        set { self[DoorLightReduceMotionOverrideKey.self] = newValue }
    }

    /// Render-only perceptual-accessibility overrides. Production falls
    /// through to the corresponding system environment values.
    var doorLightReduceTransparencyOverride: Bool? {
        get { self[DoorLightReduceTransparencyOverrideKey.self] }
        set { self[DoorLightReduceTransparencyOverrideKey.self] = newValue }
    }

    var doorLightIncreaseContrastOverride: Bool? {
        get { self[DoorLightIncreaseContrastOverrideKey.self] }
        set { self[DoorLightIncreaseContrastOverrideKey.self] = newValue }
    }
}

private struct ReorderMotion<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil
                          : Theme.motion(Theme.Motion.move, reduceMotion: false),
                          value: value)
    }
}

private struct ValueMotion<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value
    let delay: TimeInterval

    func body(content: Content) -> some View {
        content.animation(
            Theme.motion(animation, reduceMotion: reduceMotion)
                .delay(reduceMotion ? 0 : Theme.Motion.delay(delay)),
            value: value)
    }
}

private struct PressedMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPressed: Bool
    let visual: TapFocusVisual

    func body(content: Content) -> some View {
        content
            .background { pressWash.opacity(isPressed ? 1 : 0) }
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.96 : 1))
            .opacity(reduceMotion && isPressed ? 0.82 : 1)
            .animation(Theme.motion(Theme.Motion.press(isPressed),
                                    reduceMotion: reduceMotion),
                       value: isPressed)
    }

    @ViewBuilder private var pressWash: some View {
        let wash = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
            .opacity(0.5)
        switch visual {
        case .row:
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(wash)
        case .card:
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(wash)
        case .capsule:
            Capsule().fill(wash)
        case .none:
            Color.clear
        }
    }
}

private struct DoorLightValueMotion<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.doorLightReduceMotionOverride) private var reduceMotionOverride
    let value: Value
    let delay: TimeInterval

    func body(content: Content) -> some View {
        let motionReduced = reduceMotionOverride ?? reduceMotion
        content.animation(
            motionReduced ? nil
            : Theme.motion(Theme.Motion.ceremony, reduceMotion: false)
                .delay(Theme.Motion.delay(delay)),
            value: value)
    }
}

private struct LiveNumericTransition<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content.monospacedDigit()
        } else {
            content
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Theme.motion(Theme.Motion.roll, reduceMotion: false), value: value)
        }
    }
}

private struct RowMotionTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let insertion = (reduceMotion
            ? AnyTransition.opacity
            : AnyTransition.opacity.combined(with: .offset(y: 6)))
            .animation(Theme.motion(Theme.Motion.move, reduceMotion: reduceMotion))
        let removal = AnyTransition.opacity.animation(
            Theme.motion(Theme.Motion.exit, reduceMotion: reduceMotion))
        content.transition(.asymmetric(insertion: insertion, removal: removal))
    }
}

private struct MotionTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let edge: Edge

    func body(content: Content) -> some View {
        let spatial: AnyTransition = switch edge {
        case .top: .offset(y: -6)
        case .bottom: .offset(y: 6)
        case .leading: .offset(x: -6)
        case .trailing: .offset(x: 6)
        }
        let transition = reduceMotion
            ? AnyTransition.opacity.animation(
                Theme.motion(Theme.Motion.exit, reduceMotion: true))
            : spatial.combined(with: .opacity).animation(
                Theme.motion(Theme.Motion.move, reduceMotion: false))
        content.transition(transition)
    }
}

private struct ToastTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let insertion = (reduceMotion
            ? AnyTransition.opacity
            : AnyTransition.opacity.combined(with: .offset(y: 12)))
            .animation(Theme.motion(Theme.Motion.move, reduceMotion: reduceMotion))
        let removal = (reduceMotion
            ? AnyTransition.opacity
            : AnyTransition.opacity.combined(with: .offset(y: 12)))
            .animation(Theme.motion(Theme.Motion.exit, reduceMotion: reduceMotion))
        content.transition(.asymmetric(insertion: insertion, removal: removal))
    }
}

private struct SectionTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let enabled: Bool

    func body(content: Content) -> some View {
        let transition: AnyTransition
        if !enabled {
            transition = .identity
        } else {
        let insertion = (reduceMotion
            ? AnyTransition.opacity
            : AnyTransition.opacity.combined(with: .offset(y: 8)))
            .animation(Theme.motion(Theme.Motion.nav, reduceMotion: reduceMotion))
        let removal = AnyTransition.opacity.animation(
            Theme.motion(Theme.Motion.exit, reduceMotion: reduceMotion))
            transition = .asymmetric(insertion: insertion, removal: removal)
        }
        return content.transition(transition)
    }
}

private struct SidebarSelectionTravel: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let namespace: Namespace.ID

    @ViewBuilder func body(content: Content) -> some View {
        if reduceMotion {
            content.transition(.opacity.animation(
                Theme.motion(Theme.Motion.exit, reduceMotion: true)))
        } else {
            content.matchedGeometryEffect(id: "sidebar-selection", in: namespace)
        }
    }
}

private struct DisclosureChevron: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(reduceMotion ? nil
                       : Theme.motion(Theme.Motion.nav, reduceMotion: false),
                       value: isExpanded)
    }
}

private struct TranscriptLineTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion
            ? .identity
            : .opacity.animation(Theme.motion(Theme.Motion.quick, reduceMotion: false)))
    }
}

// MARK: - One-shot reveal helpers

private struct SectionFirstAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct RevealBlockIndexKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct LaunchFirstAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct RevealRegistryKey: EnvironmentKey {
    static let defaultValue: Reveal.Registry? = nil
}

extension EnvironmentValues {
    var sectionFirstAppearance: Bool {
        get { self[SectionFirstAppearanceKey.self] }
        set { self[SectionFirstAppearanceKey.self] = newValue }
    }
    var revealBlockIndex: Int {
        get { self[RevealBlockIndexKey.self] }
        set { self[RevealBlockIndexKey.self] = newValue }
    }
    var launchFirstAppearance: Bool {
        get { self[LaunchFirstAppearanceKey.self] }
        set { self[LaunchFirstAppearanceKey.self] = newValue }
    }
    var revealRegistry: Reveal.Registry? {
        get { self[RevealRegistryKey.self] }
        set { self[RevealRegistryKey.self] = newValue }
    }
}

/// The only namespace permitted to use fire-and-forget animation.
/// Every helper here is one-shot, decorative, and leaves hit testing live.
enum Reveal {
    enum LaunchGroup: Hashable {
        case rail, header, content

        var delay: TimeInterval {
            switch self {
            case .rail: return 0
            case .header: return 0.06
            case .content: return 0.12
            }
        }
    }

    @MainActor final class Registry {
        private var claimedAt: [LaunchGroup: Date] = [:]
        private var closedAt: Date?

        func claim(_ group: LaunchGroup, now: Date = Date()) -> Bool {
            if let closedAt, now.timeIntervalSince(closedAt) >= 30 * 60 {
                claimedAt.removeAll()
                self.closedAt = nil
            }
            // Custom split screens can have multiple peers in one launch group
            // (Sessions list + inspector; Fleet strip + bays). Peers mounting in
            // the same render turn share the beat; later screens never replay it.
            if let claimed = claimedAt[group] {
                return now.timeIntervalSince(claimed) <= 0.05
            }
            claimedAt[group] = now
            return true
        }

        func windowDidClose(at date: Date = Date()) {
            closedAt = date
        }
    }

    struct LaunchModifier: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.revealRegistry) private var registry
        @State private var visible = false
        @State private var playsFirstAppearance = false
        let group: LaunchGroup

        func body(content: Content) -> some View {
            let shown = registry == nil || visible
            content
                .opacity(shown ? 1 : 0)
                .offset(y: reduceMotion || shown ? 0 : 6)
                .environment(\.launchFirstAppearance, playsFirstAppearance)
                .onAppear {
                    guard let registry else { visible = true; return }
                    let shouldPlay = registry.claim(group)
                    playsFirstAppearance = shouldPlay
                    guard shouldPlay else { visible = true; return }
                    var reset = Transaction()
                    reset.disablesAnimations = true
                    withTransaction(reset) { visible = false }
                    withAnimation(
                        Theme.motion(Theme.Motion.reveal,
                                     reduceMotion: reduceMotion,
                                     reducedDuration: 0.20)
                            .delay(reduceMotion ? 0 : Theme.Motion.delay(group.delay))) {
                        visible = true
                    }
                }
        }
    }

    struct BlockModifier: ViewModifier {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.sectionFirstAppearance) private var firstAppearance
        @State private var visible = false
        @State private var started = false
        let index: Int

        func body(content: Content) -> some View {
            let shown = !firstAppearance || visible
            content
                .opacity(shown ? 1 : 0)
                .offset(y: firstAppearance && !reduceMotion && !shown ? 6 : 0)
                .environment(\.revealBlockIndex, index)
                .onAppear {
                    guard firstAppearance else { visible = true; return }
                    guard !started else { return }
                    started = true
                    let rawDelay = min(TimeInterval(index) * Theme.Motion.revealStep, 0.32)
                    Task { @MainActor in
                        // Escape the navigation transaction: first-appearance
                        // reveals play for keyboard/programmatic origins too.
                        await Task.yield()
                        withAnimation(
                            Theme.motion(Theme.Motion.reveal, reduceMotion: reduceMotion)
                                .delay(reduceMotion ? 0 : Theme.Motion.delay(rawDelay))) {
                            visible = true
                        }
                    }
                }
        }
    }

    struct StaggeredContent<Content: View>: View {
        @ViewBuilder let content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                Group(subviews: content()) { subviews in
                    ForEach(Array(subviews.indices.enumerated()), id: \.offset) { ordinal, index in
                        subviews[index].modifier(BlockModifier(index: ordinal))
                    }
                }
            }
        }
    }

    /// Production scrolling counterpart. The subview grammar is identical to
    /// StaggeredContent, but rows below the viewport are not laid out during a
    /// navigation transaction. Headless renders keep using the eager variant.
    struct LazyStaggeredContent<Content: View>: View {
        @ViewBuilder let content: () -> Content

        var body: some View {
            LazyVStack(alignment: .leading, spacing: Theme.blockGap) {
                Group(subviews: content()) { subviews in
                    ForEach(Array(subviews.indices.enumerated()), id: \.offset) { ordinal, index in
                        subviews[index].modifier(BlockModifier(index: ordinal))
                    }
                }
            }
        }
    }

    /// Supplies an animation-owned 0→1 geometry value exactly once for the
    /// section's first appearance. Reduce Motion always receives complete
    /// geometry; the enclosing block supplies its 160ms opacity fade.
    struct Progress<Content: View>: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.sectionFirstAppearance) private var firstAppearance
        @Environment(\.revealBlockIndex) private var blockIndex
        @State private var progress: CGFloat = 0
        @State private var started = false
        let animation: Animation
        let extraDelay: TimeInterval
        let itemIndex: Int
        @ViewBuilder let content: (CGFloat) -> Content

        init(animation: Animation = Theme.Motion.draw(),
             extraDelay: TimeInterval = 0.08,
             itemIndex: Int = 0,
             @ViewBuilder content: @escaping (CGFloat) -> Content) {
            self.animation = animation
            self.extraDelay = extraDelay
            self.itemIndex = itemIndex
            self.content = content
        }

        var body: some View {
            let geometry = (!firstAppearance || reduceMotion) ? 1 : progress
            content(geometry)
                .onAppear {
                    guard firstAppearance, !reduceMotion else { progress = 1; return }
                    guard !started else { return }
                    started = true
                    let blockDelay = min(TimeInterval(blockIndex) * Theme.Motion.revealStep, 0.32)
                    let itemDelay = min(TimeInterval(itemIndex), 10) * 0.03
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(
                            Theme.motion(animation, reduceMotion: false)
                                .delay(Theme.Motion.delay(blockDelay + extraDelay + itemDelay))) {
                            progress = 1
                        }
                    }
                }
        }
    }
}

extension View {
    /// The app-standard membership/reorder animation, disabled for Reduce Motion.
    func reorderMotion<Value: Equatable>(value: Value) -> some View {
        modifier(ReorderMotion(value: value))
    }

    /// A value-keyed use of an app motion token. Reduce Motion is
    /// resolved here, never as a raw conditional at the call site.
    func motion<Value: Equatable>(_ animation: Animation, value: Value,
                                  delay: TimeInterval = 0) -> some View {
        modifier(ValueMotion(animation: animation, value: value, delay: delay))
    }

    /// Door Light ceremony routing also honors the render harness override.
    func doorLightMotion<Value: Equatable>(value: Value,
                                           delay: TimeInterval = 0) -> some View {
        modifier(DoorLightValueMotion(value: value, delay: delay))
    }

    /// Pointer-down feedback crosses the perceptibility threshold immediately;
    /// Reduce Motion replaces scale with the same 160ms wash/opacity response.
    func pressedMotion(isPressed: Bool, visual: TapFocusVisual) -> some View {
        modifier(PressedMotion(isPressed: isPressed, visual: visual))
    }

    /// Ambient live numerals: tabular glyphs + a quick numeric roll only when the
    /// displayed value changes. Reduce Motion gets a plain, stable swap.
    func liveNumericTransition<Value: Equatable>(value: Value) -> some View {
        modifier(LiveNumericTransition(value: value))
    }

    /// Occasional membership changes: opacity plus container height on entry,
    /// opacity-led exit. Reduce Motion keeps only the <=200ms opacity transition.
    func motionRowTransition() -> some View {
        modifier(RowMotionTransition())
    }

    /// A spatial reveal in normal mode and a non-vestibular fade in Reduce Motion.
    func motionTransition(edge: Edge) -> some View {
        modifier(MotionTransition(edge: edge))
    }

    func toastTransition() -> some View {
        modifier(ToastTransition())
    }

    func sectionTransition(enabled: Bool = true) -> some View {
        modifier(SectionTransition(enabled: enabled))
    }

    func sidebarSelectionTravel(in namespace: Namespace.ID) -> some View {
        modifier(SidebarSelectionTravel(namespace: namespace))
    }

    func disclosureChevron(isExpanded: Bool) -> some View {
        modifier(DisclosureChevron(isExpanded: isExpanded))
    }

    func transcriptLineTransition() -> some View {
        modifier(TranscriptLineTransition())
    }

    func launchReveal(_ group: Reveal.LaunchGroup) -> some View {
        modifier(Reveal.LaunchModifier(group: group))
    }

    func sectionRevealBlock(index: Int) -> some View {
        modifier(Reveal.BlockModifier(index: index))
    }

    func sectionFirstAppearance(_ firstAppearance: Bool) -> some View {
        environment(\.sectionFirstAppearance, firstAppearance)
    }
}

// MARK: - Model tier accents
// One muted brand hue per tier, applied narrowly (a dot, a progress fill).
// Mirrors CodexBar's provider colors — Claude's terracotta for Opus, and
// equally muted hues for the rest. Never used on panels or chrome.

extension ModelTier {
    var color: Color {
        switch self {
        case .opus: return Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255) // Claude terracotta
        case .sonnet: return Color(red: 70 / 255, green: 180 / 255, blue: 130 / 255) // muted green
        case .haiku: return Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255) // muted blue
        case .codex: return Theme.codexModel
        case .user: return Color(red: 0.58, green: 0.52, blue: 0.79)   // muted amber (user-defined tier)
        case .other: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Attention state color
// Reuses the existing semantic status hues — red/amber/green plus a faint dot for
// idle. The color IS the signal (CodexBar status-dot discipline); no new palette.

extension AttentionState {
    var color: Color {
        switch self {
        case .blocked: return Theme.red
        case .waiting: return Theme.amber
        case .running: return Theme.green
        case .idle:    return Theme.faint
        }
    }
}

// MARK: - Vibrant window background
// The whole window sits on the system under-window material — real vibrancy,
// not an opaque fill. Light and dark come for free.

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Window chrome
// Hidden titlebar over the vibrant surface; the window itself stays a stock
// macOS window (opaque, system background) so materials sample correctly.

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.identifier = MainWindowPresenter.windowIdentifier
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
