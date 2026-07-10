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
        light: .windowBackgroundColor,
        dark: NSColor(srgbRed: 25 / 255, green: 25 / 255, blue: 24 / 255, alpha: 1)))
    static let surfaceSidebar = Color(nsColor: .dyn(
        light: .windowBackgroundColor,
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
    static let graphite = muted

    // Elevation. Every stroked surface is paired with a fill; open tables and
    // narration stay directly on the window ground.
    static let cardFill = Color(nsColor: .dyn(
        light: NSColor.black.withAlphaComponent(0.035),
        dark: NSColor.white.withAlphaComponent(0.06)))
    static let cardStroke = Color(nsColor: .dyn(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.09)))
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

    // Status dots — system semantic status colors, auto-adapting, applied
    // ONLY to dots and short warning text runs. Never to bar fills or chrome.
    static let green = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemYellow)
    static let red = Color(nsColor: .systemRed)

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
    static let blockGap: CGFloat = 20          // between sections inside a screen
    static let rankBarWidth: CGFloat = 120     // the evidence rank column
    static let valueColWidth: CGFloat = 76     // primary right-aligned value column
    static let subValueColWidth: CGFloat = 56  // secondary value column
    static let microColWidth: CGFloat = 40     // counts (×N, session counts)
    static let iconGutter: CGFloat = 14
    static let compactRowHeight: CGFloat = 30
    static let sessionRowHeight: CGFloat = 36
}

// MARK: - Reduce Motion

private struct DoorLightReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Render-only override; production always falls through to the system's
    /// accessibilityReduceMotion value.
    var doorLightReduceMotionOverride: Bool? {
        get { self[DoorLightReduceMotionOverrideKey.self] }
        set { self[DoorLightReduceMotionOverrideKey.self] = newValue }
    }
}

private struct ReorderMotion<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
    }
}

private struct MotionTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let edge: Edge

    func body(content: Content) -> some View {
        content.transition(reduceMotion
            ? .opacity
            : .move(edge: edge).combined(with: .opacity))
    }
}

extension View {
    /// The app-standard membership/reorder animation, disabled for Reduce Motion.
    func reorderMotion<Value: Equatable>(value: Value) -> some View {
        modifier(ReorderMotion(value: value))
    }

    /// A spatial reveal in normal mode and a non-vestibular fade in Reduce Motion.
    func motionTransition(edge: Edge) -> some View {
        modifier(MotionTransition(edge: edge))
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
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
