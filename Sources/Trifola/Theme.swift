import SwiftUI
import AppKit
import TrifolaKit

// MARK: - Design tokens
// Matches CodexBar (~/Developer/CodexBar): semantic system colors only, system
// font at semantic sizes, 20pt gutters, 6/12pt rhythm, 6pt capsule bars,
// hairline dividers instead of boxed cards. Everything adapts light/dark
// automatically. See docs/CODEXBAR_DESIGN.md.

enum Theme {
    // Text — semantic system colors, never hardcoded neutrals.
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)

    // Selection cascade (CodexBar MenuHighlightStyle): background flips to the
    // system selection color and every text run flips to the selection text.
    static let selectionBG = Color(nsColor: .selectedContentBackgroundColor)
    static let selectionText = Color(nsColor: .selectedMenuItemTextColor)
    static let accent = Color(nsColor: .controlAccentColor)

    // Status dots — system semantic status colors, auto-adapting, applied
    // ONLY to dots and short warning text runs. Never to bar fills or chrome.
    static let green = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemYellow)
    static let red = Color(nsColor: .systemRed)

    // Progress bars — 6pt capsule, track at tertiary 22% (CodexBar UsageProgressBar).
    static let barHeight: CGFloat = 6
    static let progressTrack = Color(nsColor: .tertiaryLabelColor).opacity(0.22)

    // Layout (CodexBar UsageMenuCardLayout): 20pt gutters, 6/12pt rhythm.
    static let gutter: CGFloat = 20
    static let rhythm: CGFloat = 6
    static let sectionGap: CGFloat = 12
    static let radius: CGFloat = 8

    // Millimeter layer — stop freehanding (POLISH C7). One inset, one block gap,
    // fixed evidence-table column metrics so every table reads as the same grammar.
    static let rowInsets = EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
    static let blockGap: CGFloat = 16          // between sections inside a screen
    static let rankBarWidth: CGFloat = 120     // the evidence rank column
    static let valueColWidth: CGFloat = 76     // primary right-aligned value column
    static let subValueColWidth: CGFloat = 56  // secondary value column
    static let microColWidth: CGFloat = 40     // counts (×N, session counts)
    static let radiusRow: CGFloat = 6          // hover rows + inner code blocks
    // radius (8) stays for containers, cards, callouts, the strip.
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
        case .user: return Color(red: 0.76, green: 0.62, blue: 0.29)   // muted amber (user-defined tier)
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
    /// The three honest menu-bar states — legible at a hallway glance.
    /// quiet = hollow ring · running = dot-in-ring · needsYou = filled dot + ring.
    enum MarkState { case quiet, running, needsYou }

    @MainActor static func applyDockIcon() {
        NSApplication.shared.applicationIconImage = dockIcon()
    }

    /// The mark alone, on a transparent canvas, in one `color`. `template` marks it
    /// as a menu-bar template so the system tints it for light/dark + selection.
    static func markImage(size: CGFloat, state: MarkState = .needsYou,
                          color: NSColor = .black, template: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setStroke(); color.setFill()
            // Ring: a concentric hollow circle, stroke ≈ 12% of the glyph.
            let lw = max(1, size * 0.12)
            let ringRect = rect.insetBy(dx: lw / 2 + size * 0.06, dy: lw / 2 + size * 0.06)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = lw
            ring.stroke()
            // Center dot: absent when quiet, small while running, full when it needs you.
            if state != .quiet {
                let d = state == .needsYou ? size * 0.34 : size * 0.22
                let dot = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
                NSBezierPath(ovalIn: dot).fill()
            }
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
            // The mark, drawn to the dock spec: filled core Ø150, concentric ring
            // Ø240 / 16pt stroke, both white 0.92 — the door light, not a borrowed ⌘.
            let white = NSColor.white.withAlphaComponent(0.92)
            white.setStroke(); white.setFill()
            let ringD: CGFloat = 240, ringLW: CGFloat = 16, coreD: CGFloat = 150
            let ringRect = NSRect(x: rect.midX - ringD / 2, y: rect.midY - ringD / 2, width: ringD, height: ringD)
            let ring = NSBezierPath(ovalIn: ringRect); ring.lineWidth = ringLW; ring.stroke()
            let coreRect = NSRect(x: rect.midX - coreD / 2, y: rect.midY - coreD / 2, width: coreD, height: coreD)
            NSBezierPath(ovalIn: coreRect).fill()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let rim = NSBezierPath(roundedRect: inset.insetBy(dx: 1, dy: 1), xRadius: 107, yRadius: 107)
            rim.lineWidth = 2
            rim.stroke()
            return true
        }
    }
}
