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
        light: .underPageBackgroundColor,
        dark: NSColor(srgbRed: 33 / 255, green: 33 / 255, blue: 32 / 255, alpha: 1)))
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
    static let accent = Color(nsColor: .controlAccentColor)
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

// MARK: - The door light — the app's identity mark (AppKit path)
// The signature (POLISH II.A): the session dot + its 1pt tier ring — the Fleet
// seat token — promoted to the app's face. Not a picture chosen to look good, but
// the app's own telemetry atom. Drawn in code (no asset pipeline). SwiftUI
// surfaces use `SeatMark`; the dock tile + the template menu-bar glyph share this
// AppKit path so it's one object at every distance.

enum AppBrand {
    enum Geometry {
        static let ringInsetRatio: CGFloat = 0.12
        static let ringWidthRatio: CGFloat = 0.12
        static let runningDotRatio: CGFloat = 0.22
        static let needsDotRatio: CGFloat = 0.34
    }
    /// The three honest menu-bar states — legible at a hallway glance.
    /// quiet = hollow ring · running = dot-in-ring · needsYou = filled dot + ring.
    enum MarkState { case quiet, running, needsYou }

    @MainActor static func applyDockIcon() {
        NSApplication.shared.applicationIconImage = dockIcon()
    }

    private static func drawMark(in rect: NSRect, state: MarkState, color: NSColor) {
        color.setStroke(); color.setFill()
        let size = min(rect.width, rect.height)
        let lw = max(1, size * Geometry.ringWidthRatio)
        let ringRect = rect.insetBy(dx: size * Geometry.ringInsetRatio,
                                    dy: size * Geometry.ringInsetRatio)
        let ring = NSBezierPath(ovalIn: ringRect)
        ring.lineWidth = lw
        ring.stroke()
        guard state != .quiet else { return }
        let d = state == .needsYou ? size * Geometry.needsDotRatio : size * Geometry.runningDotRatio
        let dot = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        NSBezierPath(ovalIn: dot).fill()
    }

    /// The mark alone, on a transparent canvas, in one `color`. `template` marks it
    /// as a menu-bar template so the system tints it for light/dark + selection.
    static func markImage(size: CGFloat, state: MarkState = .needsYou,
                          color: NSColor = .black, template: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawMark(in: rect, state: state, color: color)
            return true
        }
        img.isTemplate = template
        return img
    }

    static func dockIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let inset = rect.insetBy(dx: 40, dy: 40)
            let path = NSBezierPath(roundedRect: inset, xRadius: 108, yRadius: 108)
            NSGradient(colors: [NSColor(srgbRed: 0.32, green: 0.33, blue: 0.36, alpha: 1),
                                NSColor(srgbRed: 0.17, green: 0.18, blue: 0.20, alpha: 1)])?
                .draw(in: path, angle: -90)
            // Same normalized path as the 14pt/64pt lockups, centered inside
            // the graphite tile. Scale changes; geometry does not.
            let markRect = NSRect(x: rect.midX - 160, y: rect.midY - 160, width: 320, height: 320)
            drawMark(in: markRect, state: .needsYou, color: NSColor.white.withAlphaComponent(0.92))
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let rim = NSBezierPath(roundedRect: inset.insetBy(dx: 1, dy: 1), xRadius: 107, yRadius: 107)
            rim.lineWidth = 2
            rim.stroke()
            return true
        }
    }
}
