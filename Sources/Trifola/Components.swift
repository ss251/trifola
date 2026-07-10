import SwiftUI
import AppKit
import TrifolaKit

// MARK: - Elevation primitives

/// The only raised content surface. Open tables and prose deliberately do not
/// use this; instruments, settings groups and compact evidence objects do.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    var fixedHeight: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: fixedHeight, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
    }
}

/// Code/config/command ground: quieter than a card and intentionally borderless.
struct CodeBlockSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(Theme.codePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.codeFill,
                        in: RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
    }
}

/// A destination-shaped inline citation. The artifact name is the invitation;
/// the action must land on that exact file, screen, terminal, or URL.
struct ArtifactPill: View {
    let icon: String
    let name: String
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        TapButton(focusVisual: .capsule, action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.medium))
                Text(name).font(.caption)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.intraCell)
            .padding(.vertical, Theme.micro)
            .background {
                Capsule().fill(hovering ? Theme.cardStroke : Theme.cardFill)
                Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
        .onHover { hovering = $0 }
        .help(help ?? name)
    }
}

/// The exact two-slot attention status treatment: Attention chips and attention
/// Sessions rows. Running/idle never receive this filled shape.
struct AttentionStatusPill: View {
    let state: AttentionState

    private var fill: Color { state == .blocked ? Theme.blockedFill : Theme.waitingFill }
    private var text: Color { state == .blocked ? Theme.blockedText : Theme.waitingText }

    var body: some View {
        Text(state == .blocked ? "Blocked" : "Waiting")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(text)
        .padding(.horizontal, Theme.intraCell)
        .frame(height: 20)
        .background(Capsule().fill(fill))
    }
}

// MARK: - Section header
// CodexBar-style: system body weight-medium, primary label. No uppercase, no
// tracking, no color.

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.ink)
    }
}

/// Sub-header hierarchy, exactly three levels (POLISH C3), all lowercase-as-written,
/// no tracking. Level 1 = `SectionLabel` (section titles). Level 2 = `ColumnLabel`
/// (sub-columns inside a section). Level 3 = `Eyebrow` (table eyebrows + column
/// captions). Any literal recreation of these fonts is drift — use these.

struct ColumnLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.ink)
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.faint)
    }
}

// MARK: - The Door Light — one ring-and-core atom at every density

enum DoorLightState: Hashable {
    case idle, running, waiting, blocked

    init(_ state: AttentionState) {
        switch state {
        case .idle: self = .idle
        case .running: self = .running
        case .waiting: self = .waiting
        case .blocked: self = .blocked
        }
    }

    var color: Color {
        switch self {
        case .idle: return Theme.ink
        case .running: return Theme.green
        case .waiting: return Theme.amber
        case .blocked: return Theme.red
        }
    }
}

/// A hand-drawn clockwise ring. `trim` animates from twelve o'clock, so a state
/// transition is visible as a 300ms draw rather than a generic cross-fade.
private struct DoorLightRing: Shape {
    var trim: CGFloat
    var inset: CGFloat = 0

    var animatableData: CGFloat {
        get { trim }
        set { trim = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = max(0, min(r.width, r.height) / 2)
        var path = Path()
        path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * min(1, max(0, trim))),
                    clockwise: false)
        return path
    }
}

struct SeatMark: View {
    var state: DoorLightState? = nil
    var fill: Color = Theme.green
    var ring: Color? = nil
    var size: CGFloat = 8
    var active = true
    var filled: Bool = true
    var ringWidth: CGFloat? = nil
    /// Retained for source compatibility; the Door Light is always ring-and-core.
    var gapped: Bool = true
    /// Lockups keep an ink core while their ring carries the fleet's worst state.
    var coreUsesState = true

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.doorLightReduceMotionOverride) private var reduceMotionOverride
    @State private var ringTrim: CGFloat = 1

    private var effectiveRingWidth: CGFloat {
        ringWidth ?? AppBrand.Geometry.ringWidth(displayScale: displayScale)
    }
    private var effectiveRing: Color {
        ring ?? Theme.ink.opacity(0.35)
    }
    private var coreColor: Color {
        if coreUsesState, let state { return state.color }
        return fill
    }
    private var showsCore: Bool {
        filled && state != .idle
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30,
                                paused: motionReduced || (state != .running && state != .blocked))) { context in
            let coreOpacity = runningOpacity(at: context.date)
            let pulse = blockedPulse(at: context.date)
            ZStack {
                if pulse > 0 {
                    DoorLightRing(trim: 1,
                                  inset: effectiveRingWidth / 2 - pulse / max(displayScale, 1))
                        .stroke(Theme.red.opacity(0.35 * (1 - pulse)), lineWidth: effectiveRingWidth)
                }
                DoorLightRing(trim: ringTrim, inset: effectiveRingWidth / 2)
                    .stroke(effectiveRing, lineWidth: effectiveRingWidth)
                if colorScheme == .light {
                    DoorLightRing(trim: ringTrim,
                                  inset: effectiveRingWidth + 0.25)
                        .stroke(Theme.surfaceWindow, lineWidth: 0.5)
                }
                if showsCore {
                    Circle()
                        .fill(coreColor)
                        .frame(width: size * AppBrand.Geometry.coreRatio,
                               height: size * AppBrand.Geometry.coreRatio)
                        .opacity(coreOpacity)
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(active ? 1 : 0.45)
        .onChange(of: state) { _, _ in
            guard !motionReduced else { ringTrim = 1; return }
            ringTrim = 0
            withAnimation(.easeOut(duration: 0.30)) { ringTrim = 1 }
        }
        .accessibilityHidden(true)
    }

    private func runningOpacity(at date: Date) -> Double {
        guard !motionReduced, state == .running else { return 1 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: AppBrand.Motion.runningPeriod)
        return 0.925 + 0.075 * sin(2 * .pi * phase / AppBrand.Motion.runningPeriod)
    }

    /// One device-pixel echo at the start of each eight-second blocked interval.
    private func blockedPulse(at date: Date) -> CGFloat {
        guard !motionReduced, state == .blocked else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: AppBrand.Motion.blockedPeriod)
        guard phase < AppBrand.Motion.blockedPulseDuration else { return 0 }
        return CGFloat(phase / AppBrand.Motion.blockedPulseDuration)
    }

    private var motionReduced: Bool { reduceMotionOverride ?? reduceMotion }
}

/// Shared geometry and the AppKit raster adapter for the menu bar, Dock and app
/// icon. SwiftUI and AppKit consume the same outer diameter, stroke and core ratio.
enum AppBrand {
    enum Geometry {
        static let coreRatio: CGFloat = 0.5

        static func ringWidth(displayScale: CGFloat) -> CGFloat {
            displayScale >= 2 ? 1.5 : 1
        }

        static func ringRect(in rect: CGRect, lineWidth: CGFloat) -> CGRect {
            rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        }

        static func coreRect(in rect: CGRect) -> CGRect {
            let d = min(rect.width, rect.height) * coreRatio
            return CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        }
    }

    enum Motion {
        static let runningPeriod: TimeInterval = 2.4
        static let blockedPeriod: TimeInterval = 8
        static let blockedPulseDuration: TimeInterval = 0.35
    }

    enum MarkState { case quiet, running, needsYou }

    @MainActor static func applyDockIcon() {
        NSApplication.shared.applicationIconImage = appIcon()
    }

    /// The Dock's BLOCKED badge is the same light plus its count, not a second
    /// OS-red lozenge vocabulary. Clearing the count restores the normal app icon.
    @MainActor static func updateDockBadge(blockedCount: Int) {
        if blockedCount > 0 {
            NSApp.dockTile.badgeLabel = nil
            NSApp.dockTile.contentView = DockBadgeView(count: blockedCount)
        } else {
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.badgeLabel = nil
        }
        NSApp.dockTile.display()
    }

    private static func drawMark(in rect: NSRect, state: MarkState, color: NSColor,
                                 displayScale: CGFloat = 2) {
        let lineWidth = Geometry.ringWidth(displayScale: displayScale)
        let ringColor = color.withAlphaComponent(color.alphaComponent * 0.35)
        ringColor.setStroke()
        let ring = NSBezierPath(ovalIn: Geometry.ringRect(in: rect, lineWidth: lineWidth))
        ring.lineWidth = lineWidth
        ring.stroke()
        guard state != .quiet else { return }
        color.setFill()
        NSBezierPath(ovalIn: Geometry.coreRect(in: rect)).fill()
    }

    static func markImage(size: CGFloat, state: MarkState = .needsYou,
                          color: NSColor = .black, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawMark(in: rect, state: state, color: color)
            return true
        }
        image.isTemplate = template
        return image
    }

    static func appIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let inset = rect.insetBy(dx: 40, dy: 40)
            let tile = NSBezierPath(roundedRect: inset, xRadius: 108, yRadius: 108)
            NSGradient(colors: [NSColor(srgbRed: 0.19, green: 0.31, blue: 0.29, alpha: 1),
                                NSColor(srgbRed: 0.09, green: 0.14, blue: 0.14, alpha: 1)])?
                .draw(in: tile, angle: -90)
            let markRect = NSRect(x: rect.midX - 160, y: rect.midY - 160,
                                  width: 320, height: 320)
            drawMark(in: markRect, state: .needsYou,
                     color: NSColor.white.withAlphaComponent(0.94), displayScale: 2)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let rim = NSBezierPath(roundedRect: inset.insetBy(dx: 1, dy: 1),
                                   xRadius: 107, yRadius: 107)
            rim.lineWidth = 2
            rim.stroke()
            return true
        }
    }

    /// Backward-compatible name used by the identity render.
    static func dockIcon() -> NSImage { appIcon() }

    private final class DockBadgeView: NSView {
        let count: Int

        init(count: Int) {
            self.count = count
            super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            AppBrand.appIcon().draw(in: bounds)

            let badge = NSRect(x: 72, y: 8, width: 48, height: 30)
            NSColor(srgbRed: 0.10, green: 0.11, blue: 0.11, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 15, yRadius: 15).fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            let border = NSBezierPath(roundedRect: badge.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 14.5, yRadius: 14.5)
            border.lineWidth = 1
            border.stroke()

            let mark = NSRect(x: badge.minX + 8, y: badge.midY - 7, width: 14, height: 14)
            AppBrand.drawMark(in: mark, state: .needsYou, color: .systemRed, displayScale: 2)
            let text = count > 9 ? "9+" : "\(count)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            NSAttributedString(string: text, attributes: attributes)
                .draw(at: NSPoint(x: badge.minX + 27, y: badge.minY + 8))
        }
    }
}

// MARK: - Tier badge
// Dot in the tier hue + caption text in secondary label. No capsule, no tint.

struct TierBadge: View {
    let tier: ModelTier
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tier.color).frame(width: 6, height: 6)
            Text(tier.label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Machine chip (Cross-Machine Fleet)
// A tiny label — not decoration — tagging which machine a session ran on: a laptop
// glyph + "Mac" for this machine, a desktop glyph + the host name for a remote
// ("workstation"). Faint for local (the implicit default), a touch more present for a
// remote so the fleet reads at a glance. Restraint: hairline capsule, caption2, no
// tint, no fill.

struct MachineChip: View {
    let machineID: String
    var compact = false

    private var isLocal: Bool { machineID == Machine.localID }
    private var label: String { isLocal ? "Mac" : machineID }
    private var symbol: String { isLocal ? "laptopcomputer" : "desktopcomputer" }
    private var tone: Color { isLocal ? Theme.faint : Theme.muted }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tone)
            if !compact {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(tone)
            }
        }
        .padding(.horizontal, compact ? Theme.micro : Theme.rowVerticalInset)
        .padding(.vertical, Theme.micro / 2)
        .background {
            Capsule().fill(Theme.cardFill)
            Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .help(isLocal ? "This Mac" : "Mirrored read-only from \(machineID) over Tailscale")
    }
}

// MARK: - Offline indicator (calm, never a nag)
// The muted one-line status a remote surfaces when it isn't contributing:
// "workstation offline — last synced 12m ago". Absence is information; rendered calm —
// never red, never a nag (Fleet Board doctrine).

struct RemoteStatusLine: View {
    let status: RemoteStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.isOnline ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.isOnline ? Theme.muted : Theme.faint)
            Text(status.indicator)
                .font(.caption2)
                .foregroundStyle(status.isOnline ? Theme.muted : Theme.faint)
                .lineLimit(1)
        }
    }
}

// MARK: - Stat tile
// Caption label over a headline value — hierarchy from the type scale alone.
// Lives inside StatRow, which separates tiles with hairlines instead of boxes.

struct StatTile: View {
    let label: String
    let value: String
    var sub: String? = nil
    var valueColor: Color = Theme.ink
    var icon: String? = nil
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if live { Circle().fill(Theme.green).frame(width: 6, height: 6) }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sub {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of stat tiles separated by 1px hairlines — the CodexBar answer to a
/// "stat card" strip.
struct StatRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.sectionGap) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 150, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }
}

// MARK: - Capsule progress bar
// The CodexBar bar: 6pt capsule, tertiary-at-22% track, flat single-color fill.

struct CapsuleBar: View {
    let fraction: Double        // 0…1
    var tint: Color = Theme.graphite
    var height: CGFloat = Theme.barHeight

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.progressTrack)
                if fraction > 0.004 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Context weight bar (the "$20 hey" gauge)

struct ContextBar: View {
    let weight: Int  // tokens resent per message
    var width: CGFloat = 72

    private var fraction: Double { min(1, Double(weight) / 400_000) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(fmtTokens(weight))
                .font(.caption2)
                .foregroundStyle(Theme.muted)
            // One accent, like every other gauge — the ≈$/msg caption carries
            // the warning; a wall of red bars is decoration, not information.
            CapsuleBar(fraction: fraction, tint: Theme.graphite)
                .frame(width: width)
        }
    }
}

// MARK: - Tier spend split bar
// Flat segments in the tier hues — no gradients, no shadows.

struct TierSplitBar: View {
    let stats: [TierStat]
    var height: CGFloat = Theme.barHeight

    private var total: Double { max(stats.reduce(0) { $0 + $1.cost }, 0.0001) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.intraCell) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(stats) { st in
                        Capsule()
                            .fill(st.tier.color)
                            .frame(width: max(3, (geo.size.width - CGFloat(stats.count - 1) * 2) * st.cost / total))
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: Theme.sectionGap) {
                ForEach(stats) { st in
                    HStack(spacing: Theme.micro) {
                        Rectangle().fill(st.tier.color).frame(width: 8, height: 3)
                        Text("\(st.tier.label) \(fmtUSD(st.cost))")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Bar strip (activity histogram sparkline)

struct BarStrip: View {
    let values: [Double]   // 0…1 normalized
    var color: Color = Theme.graphite
    var height: CGFloat = 34
    var currentIndex: Int? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, v in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(v > 0.02 ? color.opacity(0.85) : Theme.progressTrack)
                    if index == currentIndex {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: max(2, height * v))
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

// MARK: - Immune controls — the macOS-26 render-storm fix (do NOT regress)
// On macOS 26 Liquid Glass, a `Button` styled `.plain` or `.borderedProminent`
// — and any native `Toggle` — inside this app's scene self-oscillates SwiftUI's
// `glassEffectBackdropObserver` at ~99% CPU while the window is frontmost.
// Verified IMMUNE in this exact scene: `.bordered`, `.link`, and non-Button
// `.onTapGesture` views. These helpers are therefore the ONLY licensed
// tap/press/toggle primitives in this app. Re-introducing
// `.buttonStyle(.plain)`, `.buttonStyle(.borderedProminent)`, or `Toggle`
// brings the storm straight back (see handoffs/render-storm-fix.md).

/// The `.plain`-Button replacement: a label + tap gesture — no Button primitive,
/// so no glass control backdrop to oscillate. Accessibility still reads it as a
/// button. An optional keyboard shortcut is carried by a hidden zero-size
/// `.link`-styled Button (verified immune) so ⌘-shortcuts keep working.
enum TapFocusVisual { case row, card, capsule, none }

struct TapButton<Label: View>: View {
    var shortcut: KeyboardShortcut? = nil
    var focusVisual: TapFocusVisual = .row
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var isPressed = false
    @FocusState private var isFocused: Bool

    init(shortcut: KeyboardShortcut? = nil,
         focusVisual: TapFocusVisual = .row,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.shortcut = shortcut
        self.focusVisual = focusVisual
        self.action = action
        self.label = label
    }

    var body: some View {
        label()
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .onTapGesture { if isEnabled { action() } }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        if isEnabled { pressed = true }
                    }
            )
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .background {
                if isFocused && isEnabled {
                    let wash = Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5)
                    switch focusVisual {
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
            .onKeyPress(.return) {
                guard isEnabled else { return .ignored }
                action()
                return .handled
            }
            .background {
                if let shortcut {
                    Button("", action: action)
                        .buttonStyle(.link)          // verified immune
                        .keyboardShortcut(shortcut)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(.isButton)
    }
}

extension TapButton where Label == Text {
    init(_ title: String, shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void) {
        self.init(shortcut: shortcut, action: action) { Text(title) }
    }
}

/// The quiet bordered action used for secondary verbs. It has the visual weight
/// of a native small bordered button but is built on `TapButton`, so it never
/// opts back into system glass chrome or a stacked focus ring.
struct QuietTapButton<Label: View>: View {
    enum Size { case small, regular }

    var size: Size = .small
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled

    init(size: Size = .small,
         shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.size = size
        self.shortcut = shortcut
        self.action = action
        self.label = label
    }

    var body: some View {
        TapButton(shortcut: shortcut, focusVisual: .capsule, action: action) {
            label()
                .font(size == .small ? .caption.weight(.medium) : .body.weight(.medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, size == .small ? Theme.intraCell : Theme.codePadding)
                .padding(.vertical, size == .small ? Theme.micro : Theme.rhythm)
                .background {
                    Capsule().fill(Theme.cardFill)
                    Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension QuietTapButton where Label == Text {
    init(_ title: String, size: Size = .small,
         shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void) {
        self.init(size: size, shortcut: shortcut, action: action) { Text(title) }
    }
}

/// The `.borderedProminent` replacement: the accent-filled capsule, white
/// label, hover brightening — drawn with shapes, no Button primitive.
struct ProminentTapButton<Label: View>: View {
    enum Size { case small, regular, large }
    var size: Size = .regular
    var tint: Color = Theme.accent
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @FocusState private var isFocused: Bool

    init(size: Size = .regular, tint: Color = Theme.accent,
         shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.size = size
        self.tint = tint
        self.shortcut = shortcut
        self.action = action
        self.label = label
    }

    private var font: Font {
        switch size {
        case .small: return .caption.weight(.medium)
        case .regular: return .body.weight(.medium)
        case .large: return .body.weight(.semibold)
        }
    }
    private var hPad: CGFloat {
        size == .small ? Theme.intraCell
            : (size == .large ? Theme.paneInset : Theme.controlHorizontalInset)
    }
    private var vPad: CGFloat {
        size == .small ? Theme.compactControlVerticalInset
            : (size == .large ? Theme.intraCell : Theme.rowVerticalInset)
    }

    var body: some View {
        label()
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background {
                Capsule().fill(tint)
                Capsule().strokeBorder(Color.black.opacity(0.20), lineWidth: 0.5)
                Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: size == .large ? 13 : 9)
                    }
            }
            .brightness((hovering || isFocused) && isEnabled ? 0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { action() } }
            .onHover { h in hovering = h }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard isEnabled else { return .ignored }
                action()
                return .handled
            }
            .background {
                if let shortcut {
                    Button("", action: action)
                        .buttonStyle(.link)          // verified immune
                        .keyboardShortcut(shortcut)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(.isButton)
    }
}

extension ProminentTapButton where Label == Text {
    init(_ title: String, size: Size = .regular, tint: Color = Theme.accent,
         shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.init(size: size, tint: tint, shortcut: shortcut, action: action) { Text(title) }
    }
}

/// The native-`Toggle` replacement (native `Toggle` has NO immune style): a
/// tappable capsule + knob drawn with shapes, matching `.switch` / `.mini`,
/// with an optional leading label like a labeled `.switch` Toggle.
struct TapToggle<L: View>: View {
    @Binding var isOn: Bool
    var mini = false
    @ViewBuilder let label: () -> L
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    init(isOn: Binding<Bool>, mini: Bool = false,
         @ViewBuilder label: @escaping () -> L) {
        self._isOn = isOn
        self.mini = mini
        self.label = label
    }

    private var trackW: CGFloat { mini ? 26 : 38 }
    private var trackH: CGFloat { mini ? 15 : 22 }

    private var flip: () -> Void {
        { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }
    }

    var body: some View {
        HStack(spacing: 8) {
            label()
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.graphite
                               : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                Circle()
                    .fill(.white)
                    .padding(Theme.toggleKnobInset)
            }
            .frame(width: trackW, height: trackH)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { flip() } }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .brightness(isFocused && isEnabled ? 0.06 : 0)
        .onKeyPress(.return) {
            guard isEnabled else { return .ignored }
            flip()
            return .handled
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

extension TapToggle where L == EmptyView {
    init(isOn: Binding<Bool>, mini: Bool = false) {
        self.init(isOn: isOn, mini: mini) { EmptyView() }
    }
}

extension TapToggle where L == Text {
    init(_ title: String, isOn: Binding<Bool>, mini: Bool = false) {
        self.init(isOn: isOn, mini: mini) { Text(title) }
    }
}

// MARK: - Filter chip
// Multi-select filters use the quiet selection cascade; a screen may have many
// active facets, so spending accent on each would recreate a saturation wall.

struct FilterChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        TapButton(focusVisual: .capsule, action: action) {
            Text(label)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Theme.selectionText : Theme.muted)
                .padding(.horizontal, Theme.codePadding)
                .padding(.vertical, Theme.micro)
                .background {
                    if isOn {
                        Capsule().fill(Theme.selectionBG)
                    } else {
                        Capsule().fill(Theme.cardFill)
                        Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                }
        }
    }
}

// MARK: - Hoverable row container
// Hover uses the system's unemphasized selection color — the native list feel.

struct HoverRow<Content: View>: View {
    var radius: CGFloat = 6
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        TapButton(action: action) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(hovering
                      ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.6)
                      : .clear)
        )
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }
}

// MARK: - The evidence grammar (the app's tell) — POLISH C1 / II.B
// The app's most repeated shape and its signature: identity → rank → value →
// destination, where the click ALWAYS lands on the artifact (transcript / file /
// URL), never a detail popover of itself. The rank bar never lies about scale —
// always normalized to the table's own top value, always `Theme.rankBarWidth`,
// track always visible (the track is the denominator made visible). Every table
// earns an `Eyebrow` and a denominator caption.

/// The canonical clickable evidence row. Leading identity block, a ranking bar,
/// trailing value cell(s), an optional trailing nav glyph. HoverRow gives the
/// native selection-hover feel; no hairline (the hover wash is the boundary).
struct EvidenceRow<Leading: View, Trailing: View>: View {
    let barFraction: Double            // 0…1 against the table's top value
    var barTint: Color = Theme.graphite
    var navGlyph: String? = nil
    /// Reserve the 14pt nav gutter even when this row has no glyph — sibling rows
    /// carry one and the columns must line up. The gutter stays EMPTY: an em-dash
    /// placeholder reads as "no data", not "no navigation" (UI_GRIND LDG-4).
    var reservesNavGutter: Bool = false
    let action: () -> Void             // ALWAYS lands on the artifact
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HoverRow(radius: Theme.radiusRow, action: action) {
            HStack(spacing: Theme.sectionGap) {
                leading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                CapsuleBar(fraction: barFraction, tint: barTint)
                    .frame(width: Theme.rankBarWidth)
                trailing()
                if let navGlyph {
                    Image(systemName: navGlyph)
                        .font(.caption2.weight(.medium)).foregroundStyle(Theme.faint).frame(width: Theme.iconGutter)
                } else if reservesNavGutter {
                    Color.clear.frame(width: Theme.iconGutter, height: 1)
                }
            }
            .padding(Theme.rowInsets)
        }
    }
}

/// The caption header row required above every evidence table — the column names
/// over the fixed metrics, so the columns line up with the row cells below.
struct EvidenceColumns: View {
    let leading: String
    let columns: [(title: String, width: CGFloat, align: Alignment)]
    /// Reserve the trailing nav-glyph gutter so the header aligns with rows that
    /// carry one.
    var hasNavGlyph: Bool = false

    var body: some View {
        HStack(spacing: Theme.sectionGap) {
            Eyebrow(leading).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                Eyebrow(c.title).frame(width: c.width, alignment: c.align)
            }
            if hasNavGlyph { Color.clear.frame(width: Theme.iconGutter) }
        }
        .padding(.horizontal, Theme.intraCell)
    }
}

/// The leading identity cell — the door light (state fill + 1pt tier ring, the
/// same `SeatMark` the Floor/strip/palette wear — UI_GRIND §2.1: one atom), a
/// project name (sans, what the app says), and a caption whose disk-truth run (a
/// short session id) renders mono, the rest sans (POLISH II.C).
struct IdentityCell: View {
    let project: String
    /// The disk-truth run rendered mono (a short session / parent id). Optional.
    var id: String? = nil
    let caption: String
    var tier: ModelTier? = nil
    /// Live state when the row is backed by a live session; nil (historical /
    /// evidence rows) renders the faint stateless fill — never a tier-colored
    /// disc, which read as an alarm in the app's own dot language.
    var state: AttentionState? = nil

    var body: some View {
        HStack(spacing: 8) {
            SeatMark(state: state.map(DoorLightState.init) ?? .idle, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(project)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                captionText
                    .lineLimit(1)
            }
        }
    }

    private var captionText: Text {
        if let id {
            return Text(caption).font(.caption2).foregroundStyle(Theme.faint)
                + Text(" · \(id)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.faint)
        }
        return Text(caption).font(.caption2).foregroundStyle(Theme.faint)
    }
}

/// A section-level empty / "nothing to report" line — one calm shape (POLISH C6:
/// screen-level empty = `EmptyState`; section-level empty = `LeanRow`).
struct LeanRow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, Theme.micro / 2)
    }
}

/// The single disclosure grammar used for hidden subagents, snoozed attention,
/// and low-priority audit overflow.
struct MutedDisclosureRow: View {
    let label: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        TapButton(action: action) {
            HStack(spacing: Theme.intraCell) {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.micro)
        }
        .reorderMotion(value: isExpanded)
    }
}

/// Compact disclosure for suppressed attention. Unlike the open disclosure row
/// used beneath tables, this must remain a findable chip in the attention flow.
struct MutedDisclosurePill: View {
    let label: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        TapButton(focusVisual: .capsule, action: action) {
            HStack(spacing: Theme.intraCell) {
                Image(systemName: "bell.slash")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.faint)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, Theme.codePadding)
            .padding(.vertical, Theme.micro)
            .background {
                Capsule().fill(Theme.cardFill)
                Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
        .reorderMotion(value: isExpanded)
    }
}

// MARK: - Callout panel
// The container stays neutral. Its contents may spend `tone` on a compact icon
// or action, but a large wash would turn evidence into a decorative status wall.

struct CalloutPanel<Content: View>: View {
    let tone: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
    }
}

// MARK: - Flow layout
// Wraps its children onto as many lines as needed — used by the attention strip
// so every chip stays visible (a horizontal scroll would hide the ones that
// matter most). macOS 15's Layout protocol; no third-party dependency.

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                widest = max(widest, x - spacing)
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: maxW.isFinite ? min(maxW, widest) : max(widest, 0),
                      height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.width, x > 0 {
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            sv.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                     anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = Theme.faint
    var maxWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: Theme.sectionGap) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: maxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.gutter)
    }
}

// MARK: - Flag row (routing audit)

struct FlagRow: View {
    let flag: RoutingFlag

    private var color: Color {
        switch flag.level {
        case .ok: return Theme.green
        case .info: return Theme.muted
        case .warn: return Theme.amber
        }
    }
    private var icon: String {
        switch flag.level {
        case .ok: return "checkmark.circle"
        case .info: return "info.circle"
        case .warn: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, Theme.hairlineWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(flag.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Screen scaffold (shared page chrome)
// 20pt gutters, headline-scale title, hairline under the header.

enum ScreenScaffoldMetrics {
    static let topInset: CGFloat = 18
    static let bottomInset: CGFloat = 28
    static let maxWidth: CGFloat = 1040
    static let proseMaxWidth: CGFloat = 720
    static let headerHeight: CGFloat = 70
}

struct ScreenScaffold<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    /// An earned one-word epithet worn beside the title (POLISH C4) — coined in a
    /// doc first, worn in the app second. Same treatment Fleet's "the floor" uses.
    var epithet: String? = nil
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 28, weight: .bold))
                                .tracking(-0.4)
                                .foregroundStyle(Theme.ink)
                            if let epithet {
                                Text(epithet)
                                    .font(.caption)
                                    .foregroundStyle(Theme.faint)
                            }
                        }
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    trailing()
                }
                .frame(minHeight: ScreenScaffoldMetrics.headerHeight, alignment: .top)
                Divider()
                content()
            }
            .screenScaffoldFrame()
        }
        .scrollIndicators(.never)
    }
}

extension View {
    func centeredContentColumn(maxWidth: CGFloat = ScreenScaffoldMetrics.maxWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    func screenScaffoldFrame() -> some View {
        padding(.horizontal, Theme.gutter)
            .padding(.bottom, ScreenScaffoldMetrics.bottomInset)
            .padding(.top, ScreenScaffoldMetrics.topInset)
            .centeredContentColumn()
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String, epithet: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, epithet: epithet,
                  trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Toast

struct Toast: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, Theme.sectionGap)
        .padding(.vertical, Theme.toastVerticalInset)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .motionTransition(edge: .bottom)
    }
}
