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
                    .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
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
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        TapButton(focusVisual: .capsule, action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.medium))
                Text(name).font(.caption)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.intraCell)
            .padding(.vertical, Theme.micro)
            .frame(minHeight: Theme.Layout.compactHitHeight)
            .background {
                Capsule().fill(hovering && isEnabled ? Theme.cardStroke : Theme.cardFill)
                Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
        .onHover { hovering = isEnabled && $0 }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { hovering = false }
        }
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
            .font(Theme.Typography.section)
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
            .font(Theme.Typography.bodyMedium)
            .foregroundStyle(Theme.ink)
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Typography.metadataMedium)
            .foregroundStyle(Theme.muted)
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
        let clamped = Double(min(CGFloat(1), max(CGFloat(0), trim)))
        path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * clamped),
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
    /// Brand lockups keep a neutral ring; the core alone carries live state color.
    var coreUsesState = true
    /// The masthead spends color only on its core, including during pulse/echo
    /// phases. Smaller operational marks retain their state-colored effects.
    var stateEffectsUseColor = true
    /// Menu-bar marks opt out; every in-window mark may spend the one-shot draw
    /// supplied by its launch/section reveal context.
    var firstAppearanceDraw = true
    var revealIndex: Int? = nil

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.doorLightReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.sectionFirstAppearance) private var sectionFirstAppearance
    @Environment(\.launchFirstAppearance) private var launchFirstAppearance
    @Environment(\.revealBlockIndex) private var revealBlockIndex
    @State private var ringTrim: CGFloat = 1
    @State private var coreRevealOpacity: Double = 1
    @State private var echoProgress: CGFloat = 1
    @State private var ceremonyDelay: TimeInterval = 0
    @State private var didDrawFirstAppearance = false
    @State private var ceremonyEndsAt = Date.distantPast

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
    private var stateEffectColor: Color {
        stateEffectsUseColor ? (state?.color ?? effectiveRing) : effectiveRing
    }
    private var showsCore: Bool {
        filled && state != .idle
    }

    var body: some View {
        TimelineView(AnimationTimelineSchedule(
            minimumInterval: 1 / 30,
            paused: motionReduced || (state != .running && state != .blocked))) { context in
            let coreOpacity = runningOpacity(at: context.date)
            let pulse = blockedPulse(at: context.date)
            ZStack {
                Circle()
                    .stroke(stateEffectColor.opacity(0.35),
                            lineWidth: effectiveRingWidth)
                    .scaleEffect(1 + 0.35 * echoProgress)
                    .opacity(0.35 * (1 - echoProgress))
                    .motion(Theme.Motion.echo, value: echoProgress)
                if pulse > 0 {
                    DoorLightRing(trim: 1,
                                  inset: effectiveRingWidth / 2 - pulse / max(displayScale, 1))
                        .stroke(stateEffectColor.opacity(0.35 * (1 - pulse)),
                                lineWidth: effectiveRingWidth)
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
                        .opacity(coreOpacity * coreRevealOpacity)
                        // A state identity replaces the old core with the new
                        // hue, so the ceremony is a true cross-fade rather than
                        // an interpolated color pass through a muddy midpoint.
                        .id(state)
                        .transition(.opacity.animation(
                            Theme.motion(Theme.Motion.ceremony,
                                         reduceMotion: motionReduced)))
                        .motion(Theme.Motion.ceremony,
                                value: coreRevealOpacity,
                                delay: ceremonyDelay)
                }
            }
            .doorLightMotion(value: state)
        }
        .frame(width: size, height: size)
        .opacity(active ? 1 : 0.45)
        .onChange(of: state) { oldState, newState in
            playStateCeremony(from: oldState, to: newState)
        }
        .onChange(of: firstAppearanceActive, initial: true) { _, active in
            if active { playFirstAppearance() }
        }
        .doorLightMotion(value: ringTrim, delay: ceremonyDelay)
        .accessibilityHidden(true)
    }

    private var firstAppearanceActive: Bool {
        firstAppearanceDraw && (sectionFirstAppearance || launchFirstAppearance)
    }

    private var firstAppearanceDelay: TimeInterval {
        let index = revealIndex ?? revealBlockIndex
        return TimeInterval(min(max(index, 0), 5)) * Theme.Motion.revealStep
    }

    private func playFirstAppearance() {
        guard !didDrawFirstAppearance else { return }
        didDrawFirstAppearance = true
        ceremonyDelay = motionReduced ? 0 : firstAppearanceDelay

        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            ringTrim = motionReduced ? 1 : 0
            coreRevealOpacity = 0
        }
        ceremonyEndsAt = Date().addingTimeInterval(
            Theme.Motion.delay(firstAppearanceDelay) + Theme.ceremonyInterval)
        Task { @MainActor in
            await Task.yield()
            ringTrim = 1
            coreRevealOpacity = 1
        }
    }

    private func playStateCeremony(from oldState: DoorLightState?,
                                   to newState: DoorLightState?) {
        ceremonyDelay = 0
        if !motionReduced,
           oldState != newState,
           newState == .blocked || newState == .waiting {
            var echoReset = Transaction()
            echoReset.disablesAnimations = true
            withTransaction(echoReset) { echoProgress = 0 }
            Task { @MainActor in
                await Task.yield()
                echoProgress = 1
            }
        }

        guard !motionReduced else { ringTrim = 1; return }
        // A second state flip during the draw keeps the current presentation
        // value moving toward 1; it never snaps back to zero. A settled ring
        // starts the next ceremony blank, then draws clockwise on the next
        // update so the reset and the value-keyed animation cannot coalesce.
        let now = Date()
        guard now >= ceremonyEndsAt else { return }
        ceremonyEndsAt = now.addingTimeInterval(Theme.ceremonyInterval)
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { ringTrim = 0 }
        Task { @MainActor in
            await Task.yield()
            ringTrim = 1
        }
    }

    private func runningOpacity(at date: Date) -> Double {
        guard !motionReduced, state == .running else { return 1 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: AppBrand.AmbientPhase.runningPeriod)
        return 0.925 + 0.075 * sin(2 * .pi * phase / AppBrand.AmbientPhase.runningPeriod)
    }

    /// One device-pixel echo at the start of each eight-second blocked interval.
    private func blockedPulse(at date: Date) -> CGFloat {
        guard !motionReduced, state == .blocked else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: AppBrand.AmbientPhase.blockedPeriod)
        guard phase < AppBrand.AmbientPhase.blockedPulseDuration else { return 0 }
        return CGFloat(phase / AppBrand.AmbientPhase.blockedPulseDuration)
    }

    private var motionReduced: Bool { reduceMotionOverride ?? reduceMotion }
}

/// Shared geometry and the AppKit raster adapter for the menu bar, Dock and app
/// icon. SwiftUI and AppKit consume the same outer diameter, stroke and core ratio.
enum AppBrand {
    enum Geometry {
        static let coreRatio: CGFloat = 0.5

        // The icon composition is authored once on a 512-point reference
        // canvas. Every raster size (Dock, .icns masters and documentation
        // artwork) scales these values through this geometry rather than
        // recreating a look-alike in a render-only path.
        static let iconReferenceSize: CGFloat = 512
        static let iconTileInset: CGFloat = 40
        static let iconTileCornerRadius: CGFloat = 108
        static let iconRimInset: CGFloat = 1
        static let iconRimLineWidth: CGFloat = 2

        // Brand-identity geometry is intentionally separate from the functional
        // 8-point Door Light above. The identity may evolve without weakening
        // the operational state atom used throughout the product.
        static let identityMarkDiameter: CGFloat = 344
        static let identityLobeOrbitRatio: CGFloat = 0.145
        static let identityLobeRadiusRatio: CGFloat = 0.29
        static let identityApertureRadiusRatio: CGFloat = 0.145
        static let identityCoreRadiusRatio: CGFloat = 0.072
        static let identityOpticalYOffsetRatio: CGFloat = 0.012

        static let thresholdMarkDiameter: CGFloat = 304
        static let thresholdHaloWidth: CGFloat = 24
        static let thresholdGapDegrees: CGFloat = 38
        static let thresholdCoreDiameter: CGFloat = 112

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

        static func iconScale(in rect: CGRect) -> CGFloat {
            min(rect.width, rect.height) / iconReferenceSize
        }

        static func scaledIconValue(_ value: CGFloat, in rect: CGRect) -> CGFloat {
            value * iconScale(in: rect)
        }
    }

    enum AmbientPhase {
        static let runningPeriod: TimeInterval = 2.4
        static let blockedPeriod: TimeInterval = 8
        static let blockedPulseDuration: TimeInterval = 0.30
    }

    enum MarkState { case quiet, running, needsYou }

    enum Palette {
        static var tileTop: NSColor {
            NSColor(srgbRed: 39 / 255, green: 48 / 255, blue: 45 / 255, alpha: 1)
        }
        static var tileBottom: NSColor {
            NSColor(srgbRed: 19 / 255, green: 22 / 255, blue: 21 / 255, alpha: 1)
        }
        static var mark: NSColor {
            NSColor(srgbRed: 247 / 255, green: 246 / 255, blue: 242 / 255, alpha: 1)
        }
        /// A brand teal, deliberately distinct from the live green Door Light.
        static var staticCore: NSColor {
            NSColor(srgbRed: 66 / 255, green: 153 / 255, blue: 132 / 255, alpha: 1)
        }
    }

    /// The three required launch-study directions. Only `trefoilAperture` is
    /// used by the shipped identity; the other two remain available solely to
    /// make the decision artifact reproducible from code.
    enum IdentityConcept: CaseIterable {
        case thresholdLight
        case noduleCut
        case trefoilAperture
    }

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

    /// Draw the shared Door Light into any AppKit raster context. Callers may
    /// supply a scaled line width for large artwork; normal UI marks retain the
    /// display-scale-aware one/device-pixel treatment.
    static func drawMark(in rect: NSRect, state: MarkState, color: NSColor,
                         displayScale: CGFloat = 2, lineWidth: CGFloat? = nil) {
        let lineWidth = lineWidth ?? Geometry.ringWidth(displayScale: displayScale)
        let ringColor = color.withAlphaComponent(color.alphaComponent * 0.35)
        ringColor.setStroke()
        let ring = NSBezierPath(ovalIn: Geometry.ringRect(in: rect, lineWidth: lineWidth))
        ring.lineWidth = lineWidth
        ring.stroke()
        guard state != .quiet else { return }
        color.setFill()
        NSBezierPath(ovalIn: Geometry.coreRect(in: rect)).fill()
    }

    /// Draw the selected three-lobed identity shell around the existing Door
    /// Light core. A transparency layer makes the aperture a genuine knockout,
    /// so the mark stays correct over gradients and in template images.
    static func drawBrandMark(
        in rect: NSRect,
        state: MarkState = .needsYou,
        color: NSColor,
        coreColor: NSColor? = nil
    ) {
        drawTrefoilAperture(in: rect, state: state, color: color,
                           coreColor: coreColor ?? color)
    }

    static func brandMarkImage(
        size: CGFloat,
        state: MarkState = .needsYou,
        color: NSColor = .black,
        coreColor: NSColor? = nil,
        template: Bool = false
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawBrandMark(in: rect, state: state, color: color,
                          coreColor: coreColor ?? color)
            return true
        }
        image.isTemplate = template
        return image
    }

    static func markImage(size: CGFloat, state: MarkState = .needsYou,
                          color: NSColor = .black, template: Bool = false) -> NSImage {
        brandMarkImage(size: size, state: state, color: color, template: template)
    }

    /// Code-drawn concept seam used by `--render-logo`. Each direction is
    /// normalized to its destination rect and shares the same Door Light core.
    static func drawConceptMark(
        _ concept: IdentityConcept,
        in rect: NSRect,
        state: MarkState = .needsYou,
        color: NSColor,
        coreColor: NSColor
    ) {
        switch concept {
        case .thresholdLight:
            drawThresholdLight(in: rect, state: state, color: color,
                               coreColor: coreColor)
        case .noduleCut:
            drawNoduleCut(in: rect, state: state, color: color,
                          coreColor: coreColor)
        case .trefoilAperture:
            drawTrefoilAperture(in: rect, state: state, color: color,
                                coreColor: coreColor)
        }
    }

    private static func drawThresholdLight(
        in rect: NSRect,
        state: MarkState,
        color: NSColor,
        coreColor: NSColor
    ) {
        let diameter = min(rect.width, rect.height)
        let lineWidth = max(1, diameter * Geometry.thresholdHaloWidth
                            / Geometry.thresholdMarkDiameter)
        let radius = (diameter - lineWidth) / 2
        let gap = diameter <= 32 ? CGFloat(44) : Geometry.thresholdGapDegrees
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY),
                      radius: radius,
                      startAngle: -90 + gap / 2,
                      endAngle: 270 - gap / 2)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
        guard state != .quiet else { return }
        let coreDiameter = diameter * Geometry.thresholdCoreDiameter
            / Geometry.thresholdMarkDiameter
        let opticalOffset = diameter > 32 ? diameter * 0.02 : 0
        coreColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.midX - coreDiameter / 2,
                                    y: rect.midY - coreDiameter / 2 + opticalOffset,
                                    width: coreDiameter, height: coreDiameter)).fill()
    }

    private static func drawTrefoilAperture(
        in rect: NSRect,
        state: MarkState,
        color: NSColor,
        coreColor: NSColor
    ) {
        let diameter = min(rect.width, rect.height)
        let center = NSPoint(
            x: rect.midX,
            y: rect.midY + diameter * Geometry.identityOpticalYOffsetRatio)
        let orbit = diameter * Geometry.identityLobeOrbitRatio
        let lobeRadius = diameter * Geometry.identityLobeRadiusRatio
        let apertureRadius = diameter * Geometry.identityApertureRadiusRatio
        let coreStateScale: CGFloat = state == .running ? 0.58 : 1
        let coreRadius = diameter * Geometry.identityCoreRadiusRatio * coreStateScale

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        color.setFill()
        for degrees in [90.0, 210.0, 330.0] {
            let radians = CGFloat(degrees) * .pi / 180
            let lobeCenter = NSPoint(x: center.x + cos(radians) * orbit,
                                     y: center.y + sin(radians) * orbit)
            NSBezierPath(ovalIn: NSRect(x: lobeCenter.x - lobeRadius,
                                        y: lobeCenter.y - lobeRadius,
                                        width: lobeRadius * 2,
                                        height: lobeRadius * 2)).fill()
        }
        context.setBlendMode(.clear)
        NSBezierPath(ovalIn: NSRect(x: center.x - apertureRadius,
                                    y: center.y - apertureRadius,
                                    width: apertureRadius * 2,
                                    height: apertureRadius * 2)).fill()
        if state != .quiet {
            context.setBlendMode(.normal)
            coreColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - coreRadius,
                                        y: center.y - coreRadius,
                                        width: coreRadius * 2,
                                        height: coreRadius * 2)).fill()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func drawNoduleCut(
        in rect: NSRect,
        state: MarkState,
        color: NSColor,
        coreColor: NSColor
    ) {
        let normalizedAnchors: [CGPoint] = [
            CGPoint(x: 0.48, y: 0.06), CGPoint(x: 0.72, y: 0.13),
            CGPoint(x: 0.90, y: 0.31), CGPoint(x: 0.88, y: 0.55),
            CGPoint(x: 0.81, y: 0.74), CGPoint(x: 0.58, y: 0.91),
            CGPoint(x: 0.34, y: 0.87), CGPoint(x: 0.12, y: 0.72),
            CGPoint(x: 0.08, y: 0.45), CGPoint(x: 0.22, y: 0.19),
        ]
        let anchors = normalizedAnchors.map { point in
            CGPoint(x: rect.minX + point.x * rect.width,
                    y: rect.minY + point.y * rect.height)
        }
        let contour = NSBezierPath()
        contour.move(to: anchors[0])
        let tension: CGFloat = 0.72
        for index in anchors.indices {
            let p0 = anchors[(index - 1 + anchors.count) % anchors.count]
            let p1 = anchors[index]
            let p2 = anchors[(index + 1) % anchors.count]
            let p3 = anchors[(index + 2) % anchors.count]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) * tension / 6,
                             y: p1.y + (p2.y - p0.y) * tension / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) * tension / 6,
                             y: p2.y - (p3.y - p1.y) * tension / 6)
            contour.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        contour.close()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        color.setFill()
        contour.fill()

        context.setBlendMode(.clear)
        let bore = NSBezierPath()
        bore.move(to: NSPoint(x: rect.minX + rect.width * 0.13,
                              y: rect.minY + rect.height * 0.69))
        bore.line(to: NSPoint(x: rect.minX + rect.width * 0.50,
                              y: rect.minY + rect.height * 0.50))
        bore.lineWidth = max(1, rect.width * 0.105)
        bore.lineCapStyle = .round
        bore.stroke()
        let target = NSPoint(x: rect.minX + rect.width * 0.57,
                             y: rect.minY + rect.height * 0.46)
        let aperture = rect.width * 0.29
        NSBezierPath(ovalIn: NSRect(x: target.x - aperture / 2,
                                    y: target.y - aperture / 2,
                                    width: aperture, height: aperture)).fill()
        if state != .quiet {
            context.setBlendMode(.normal)
            let core = rect.width * 0.13
            coreColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: target.x - core / 2,
                                        y: target.y - core / 2,
                                        width: core, height: core)).fill()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Paint the canonical app-icon composition in an arbitrary destination
    /// rect. This is the single source used by the runtime Dock icon and the
    /// headless icon/banner export path.
    static func drawAppIcon(in rect: NSRect) {
        let scale = Geometry.iconScale(in: rect)
        let tileInset = Geometry.scaledIconValue(Geometry.iconTileInset, in: rect)
        let tileRadius = Geometry.scaledIconValue(Geometry.iconTileCornerRadius, in: rect)
        let inset = rect.insetBy(dx: tileInset, dy: tileInset)
        let tile = NSBezierPath(roundedRect: inset, xRadius: tileRadius, yRadius: tileRadius)
        NSGradient(colors: [Palette.tileTop, Palette.tileBottom])?
            .draw(in: tile, angle: -90)

        if rect.width >= 64 {
            let glow = NSGradient(starting: Palette.staticCore.withAlphaComponent(0.16),
                                  ending: NSColor.clear)
            glow?.draw(in: tileRectForGlow(tileRect: inset),
                       relativeCenterPosition: NSPoint(x: 0, y: 0.08))
        }

        let markDiameter = Geometry.scaledIconValue(Geometry.identityMarkDiameter, in: rect)
        let markRect = NSRect(x: rect.midX - markDiameter / 2,
                              y: rect.midY - markDiameter / 2,
                              width: markDiameter, height: markDiameter)

        NSGraphicsContext.saveGraphicsState()
        if rect.width >= 64 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 12 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
            shadow.set()
        }
        drawBrandMark(in: markRect, state: .needsYou,
                      color: Palette.mark,
                      coreColor: Palette.staticCore)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(rect.width >= 32 ? 0.10 : 0).setStroke()
        let rimInset = Geometry.scaledIconValue(Geometry.iconRimInset, in: rect)
        let rim = NSBezierPath(roundedRect: inset.insetBy(dx: rimInset, dy: rimInset),
                               xRadius: max(0, tileRadius - rimInset),
                               yRadius: max(0, tileRadius - rimInset))
        rim.lineWidth = max(0.5,
                            Geometry.scaledIconValue(Geometry.iconRimLineWidth, in: rect))
        rim.stroke()
    }

    private static func tileRectForGlow(tileRect: NSRect) -> NSRect {
        tileRect.insetBy(dx: tileRect.width * 0.08, dy: tileRect.height * 0.08)
    }

    static func appIcon(size: CGFloat = Geometry.iconReferenceSize) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawAppIcon(in: rect)
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

/// Product-identity mark for mastheads and empty states. Operational rows keep
/// using `SeatMark`; only this shell changes, while its center still speaks the
/// established Door Light state language.
struct BrandMark: View {
    var state: DoorLightState? = nil
    var size: CGFloat = 24

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: AppBrand.brandMarkImage(
            size: size,
            state: appKitState,
            color: shellColor,
            coreColor: coreColor))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var appKitState: AppBrand.MarkState {
        switch state {
        case .none: return .needsYou
        case .some(.idle): return .quiet
        case .some(.running): return .running
        case .some(.waiting), .some(.blocked): return .needsYou
        }
    }

    private var shellColor: NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 237 / 255, green: 236 / 255, blue: 233 / 255, alpha: 1)
            : NSColor(srgbRed: 26 / 255, green: 27 / 255, blue: 25 / 255, alpha: 1)
    }

    private var coreColor: NSColor {
        guard let state else { return AppBrand.Palette.staticCore }
        switch state {
        case .idle: return shellColor
        case .running:
            return colorScheme == .dark
                ? .systemGreen
                : NSColor(srgbRed: 31 / 255, green: 154 / 255, blue: 86 / 255, alpha: 1)
        case .waiting: return .systemYellow
        case .blocked: return .systemRed
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

// MARK: - Provider badge
// Provider is provenance, not status. Keep it graphite and compact: the glyph
// distinguishes runtimes in dense rows while the inspector/table spells out the
// label. No provider gets a branded or semantic status color.

struct ProviderBadge: View {
    let provider: Provider
    var compact = false

    private var symbol: String {
        switch provider {
        case .claude: return "text.bubble"
        case .codex: return "terminal"
        }
    }

    var body: some View {
        if compact {
            Image(systemName: symbol)
                .font(Theme.Typography.metadataMedium)
                .foregroundStyle(Theme.muted)
                .frame(width: Theme.iconGutter, height: Theme.iconGutter)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(provider.label) provider")
                .help("\(provider.label) session")
        } else {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(Theme.Typography.metadataMedium)
                    .foregroundStyle(Theme.muted)
                Text(provider.label)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Theme.rowVerticalInset)
            .padding(.vertical, Theme.micro / 2)
            .background {
                Capsule().fill(Theme.cardFill)
                Capsule().strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.label) provider")
            .help("\(provider.label) session")
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
                .foregroundStyle(Theme.muted)
            Text(status.indicator)
                .font(.caption2)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }
}

// MARK: - Stat tile
// Caption label over a headline value — hierarchy from the type scale alone.
// Lives inside StatRow, which separates tiles with hairlines instead of boxes.

struct StatTile: View {
    enum Emphasis { case hero, standard, supporting }

    let label: String
    let value: String
    var sub: String? = nil
    var valueColor: Color = Theme.ink
    var icon: String? = nil
    var live = false
    var emphasis: Emphasis = .standard

    private var valueFont: Font {
        switch emphasis {
        case .hero: Theme.Typography.heroNumber
        case .standard: Theme.Typography.metric
        case .supporting: Theme.Typography.supportingMetric
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if live { Circle().fill(Theme.green).frame(width: 6, height: 6) }
                Text(label)
                    .font(Theme.Typography.metadataMedium)
                    .foregroundStyle(Theme.muted)
            }
            Text(value)
                .font(valueFont)
                .foregroundStyle(valueColor)
                .monospacedDigit()
                .liveNumericTransition(value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sub {
                Text(sub)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
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
        .padding(.horizontal, Theme.cardPadding + Theme.micro)
        .padding(.vertical, Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Theme.Layout.statBandMinHeight, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
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
                    ForEach(Array(stats.enumerated()), id: \.element.id) { index, st in
                        Reveal.Progress(animation: Theme.Motion.draw(.bar),
                                        itemIndex: index) { progress in
                            Capsule()
                                .fill(st.tier.color)
                                .frame(width: max(
                                    3,
                                    (geo.size.width - CGFloat(stats.count - 1) * 2)
                                        * st.cost / total * progress))
                        }
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
                            .liveNumericTransition(value: fmtUSD(st.cost))
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
                Reveal.Progress(animation: Theme.Motion.draw(.bar),
                                itemIndex: index) { progress in
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
                    .frame(height: max(2, height * v * progress))
                }
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
enum TapInteractionEvidenceOverride { case hover, pressed }

private struct TapFocusEvidenceOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct TapInteractionEvidenceOverrideKey: EnvironmentKey {
    static let defaultValue: TapInteractionEvidenceOverride? = nil
}

extension EnvironmentValues {
    /// Headless evidence only. Production is always driven by the physical-input
    /// monitor plus `@FocusState`.
    var tapFocusEvidenceOverride: Bool? {
        get { self[TapFocusEvidenceOverrideKey.self] }
        set { self[TapFocusEvidenceOverrideKey.self] = newValue }
    }


    /// Headless evidence only; physical pointer gestures own this state in the
    /// live app. Keeping the override at the primitive proves the real control
    /// rather than a render-only reconstruction.
    var tapInteractionEvidenceOverride: TapInteractionEvidenceOverride? {
        get { self[TapInteractionEvidenceOverrideKey.self] }
        set { self[TapInteractionEvidenceOverrideKey.self] = newValue }
    }
}

/// The last physical input source. SwiftUI may keep a custom control focused
/// after a click, so `@FocusState` alone cannot decide whether its halo belongs
/// on screen. The local monitor changes only on modality transitions, keeping
/// all shared controls in sync without publishing every mouse event.
@MainActor
final class InputModalityMonitor: ObservableObject {
    enum Modality { case pointer, keyboard }

    static let shared = InputModalityMonitor()
    @Published private(set) var modality: Modality = .pointer
    private var eventMonitor: Any?

    private init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let modality: Modality = switch event.type {
            case .keyDown: .keyboard
            default: .pointer
            }
            Task { @MainActor [weak self] in self?.record(modality) }
            return event
        }
    }

    func record(_ newValue: Modality) {
        guard modality != newValue else { return }
        modality = newValue
    }
}

/// Shared geometry for the actual keyboard halo and its evidence render.
struct TapFocusOutline: View {
    let visual: TapFocusVisual

    @ViewBuilder var body: some View {
        switch visual {
        case .row:
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .strokeBorder(Theme.keyboardFocusRing,
                              lineWidth: Theme.keyboardFocusRingWidth)
        case .card:
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.keyboardFocusRing,
                              lineWidth: Theme.keyboardFocusRingWidth)
        case .capsule:
            Capsule().strokeBorder(Theme.keyboardFocusRing,
                                   lineWidth: Theme.keyboardFocusRingWidth)
        case .none:
            Color.clear
        }
    }
}

struct TapButton<Label: View>: View {
    var shortcut: KeyboardShortcut? = nil
    var focusVisual: TapFocusVisual = .row
    var keyboardAction: (() -> Void)? = nil
    var pressFeedback = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var isPressed = false
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @ObservedObject private var inputModality = InputModalityMonitor.shared
    @Environment(\.tapFocusEvidenceOverride) private var focusEvidenceOverride
    @Environment(\.tapInteractionEvidenceOverride) private var interactionEvidenceOverride

    private var showsKeyboardFocus: Bool {
        if let focusEvidenceOverride { return focusEvidenceOverride && isEnabled }
        return isFocused && isEnabled && inputModality.modality == .keyboard
    }


    private var showsHover: Bool {
        interactionEvidenceOverride == .hover || isHovering
    }

    private var showsPress: Bool {
        interactionEvidenceOverride == .pressed || isPressed
    }

    private func performKeyboardAction() {
        inputModality.record(.keyboard)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { (keyboardAction ?? action)() }
    }

    init(shortcut: KeyboardShortcut? = nil,
         focusVisual: TapFocusVisual = .row,
         keyboardAction: (() -> Void)? = nil,
         pressFeedback: Bool = true,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.shortcut = shortcut
        self.focusVisual = focusVisual
        self.keyboardAction = keyboardAction
        self.pressFeedback = pressFeedback
        self.action = action
        self.label = label
    }

    var body: some View {
        label()
            .frame(minWidth: Theme.Layout.compactHitHeight,
                   minHeight: Theme.Layout.compactHitHeight)
            .contentShape(Rectangle())
            .pressedMotion(isPressed: pressFeedback && showsPress, visual: focusVisual)
            .onTapGesture {
                inputModality.record(.pointer)
                if isEnabled { action() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        if isEnabled { pressed = true }
                    }
            )
            .focusable(isEnabled)
            .focused($isFocused)
            .focusEffectDisabled()
            .background {
                if (showsKeyboardFocus || showsHover) && isEnabled {
                    let wash = Theme.hoverFill
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
            .overlay {
                if showsKeyboardFocus {
                    TapFocusOutline(visual: focusVisual)
                }
            }
            .motion(Theme.Motion.quick, value: showsHover)
            .onHover { isHovering = $0 }
            .onKeyPress(.return) {
                guard isEnabled else { return .ignored }
                performKeyboardAction()
                return .handled
            }
            .onKeyPress(.space) {
                guard isEnabled else { return .ignored }
                performKeyboardAction()
                return .handled
            }
            .background {
                if let shortcut {
                    Button("", action: performKeyboardAction)
                        .buttonStyle(.link)          // verified immune
                        .keyboardShortcut(shortcut)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityRespondsToUserInteraction(true, isEnabled: isEnabled)
            .accessibilityAction {
                guard isEnabled else { return }
                performKeyboardAction()
            }
            .opacity(isEnabled ? 1 : 0.45)
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
                .frame(minHeight: Theme.Layout.compactHitHeight)
                .background {
                    Capsule().fill(Theme.cardFill)
                    Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
        }
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
    @GestureState private var isPressed = false
    @State private var hovering = false
    @FocusState private var isFocused: Bool
    @ObservedObject private var inputModality = InputModalityMonitor.shared
    @Environment(\.tapFocusEvidenceOverride) private var focusEvidenceOverride
    @Environment(\.tapInteractionEvidenceOverride) private var interactionEvidenceOverride

    private var showsKeyboardFocus: Bool {
        if let focusEvidenceOverride { return focusEvidenceOverride && isEnabled }
        return isFocused && isEnabled && inputModality.modality == .keyboard
    }


    private var showsHover: Bool {
        interactionEvidenceOverride == .hover || hovering
    }

    private var showsPress: Bool {
        interactionEvidenceOverride == .pressed || isPressed
    }

    private func performKeyboardAction() {
        inputModality.record(.keyboard)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { action() }
    }

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
            .frame(minHeight: Theme.Layout.compactHitHeight)
            .background {
                Capsule().fill(tint)
                Capsule().strokeBorder(Color.black.opacity(0.20), lineWidth: 0.5)
                Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    .mask(alignment: .top) {
                        Rectangle().frame(height: size == .large ? 13 : 9)
                    }
            }
            .overlay {
                if showsKeyboardFocus {
                    TapFocusOutline(visual: .capsule)
                }
            }
            .brightness((showsHover || showsKeyboardFocus) && isEnabled ? 0.06 : 0)
            .motion(Theme.Motion.quick, value: showsHover)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .pressedMotion(isPressed: showsPress && isEnabled, visual: .capsule)
            .onTapGesture {
                inputModality.record(.pointer)
                if isEnabled { action() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        if isEnabled { pressed = true }
                    }
            )
            .onHover { h in hovering = h }
            .focusable(isEnabled)
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard isEnabled else { return .ignored }
                performKeyboardAction()
                return .handled
            }
            .onKeyPress(.space) {
                guard isEnabled else { return .ignored }
                performKeyboardAction()
                return .handled
            }
            .background {
                if let shortcut {
                    Button("", action: performKeyboardAction)
                        .buttonStyle(.link)          // verified immune
                        .keyboardShortcut(shortcut)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityRespondsToUserInteraction(true, isEnabled: isEnabled)
            .accessibilityAction {
                guard isEnabled else { return }
                performKeyboardAction()
            }
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

    init(isOn: Binding<Bool>, mini: Bool = false,
         @ViewBuilder label: @escaping () -> L) {
        self._isOn = isOn
        self.mini = mini
        self.label = label
    }

    private var trackW: CGFloat { mini ? 26 : 38 }
    private var trackH: CGFloat { mini ? 15 : 22 }

    private var flip: () -> Void { { isOn.toggle() } }

    var body: some View {
        TapButton(focusVisual: .capsule, action: flip) {
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
            .frame(minHeight: Theme.Layout.compactHitHeight)
            .contentShape(Rectangle())
        }
        .motion(Theme.Motion.quick, value: isOn)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
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
                .frame(minHeight: Theme.Layout.compactHitHeight)
                .background {
                    if isOn {
                        Capsule().fill(Theme.selectionBG)
                    } else {
                        Capsule().fill(Theme.cardFill)
                        Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? "Selected" : "Not selected")
    }
}

// MARK: - Hoverable row container
// Hover uses the system's unemphasized selection color — the native list feel.

struct HoverRow<Content: View>: View {
    var radius: CGFloat = 6
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        TapButton(focusVisual: .row, action: action) {
            content()
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
            return Text(caption).font(.caption2).foregroundStyle(Theme.muted)
                + Text(" · \(id)").font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.faint)
        }
        return Text(caption).font(.caption2).foregroundStyle(Theme.muted)
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
                    .liveNumericTransition(value: label)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.faint)
                    .disclosureChevron(isExpanded: isExpanded)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Theme.micro)
        }
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
                    .liveNumericTransition(value: label)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.faint)
                    .disclosureChevron(isExpanded: isExpanded)
            }
            .padding(.horizontal, Theme.codePadding)
            .padding(.vertical, Theme.micro)
            .background {
                Capsule().fill(Theme.cardFill)
                Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
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
    var state: DoorLightState = .idle
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.sectionGap) {
            BrandMark(state: state, size: 26)
            Text(title)
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: maxWidth)
            if let actionTitle, let action {
                QuietTapButton(actionTitle, size: .regular, action: action)
            }
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
    static let topInset = Theme.Layout.screenTopInset
    static let bottomInset = Theme.Layout.screenBottomInset
    static let maxWidth = Theme.Layout.contentMaxWidth
    static let proseMaxWidth = Theme.Layout.proseMaxWidth
    static let headerHeight = Theme.Layout.headerHeight
}

struct ScreenScaffold<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    /// An earned one-word epithet worn beside the title (POLISH C4) — coined in a
    /// doc first, worn in the app second. Same treatment Fleet's "the floor" uses.
    var epithet: String? = nil
    /// The canvas policy is supplied by the screen; prose is bounded again at
    /// the text site. Most dashboards use the shared data-theatre width.
    var maxWidth = ScreenScaffoldMetrics.maxWidth
    /// Production screens scroll; bounded headless compositions opt out so
    /// ImageRenderer realizes the exact shared chrome and content eagerly.
    var scrolls = true
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    @ViewBuilder
    var body: some View {
        if scrolls {
            ScrollView { lazyScaffoldBody }
                .scrollIndicators(.never)
        } else {
            scaffoldBody
        }
    }

    private var scaffoldBody: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            scaffoldHeader
            Reveal.StaggeredContent { content() }
                .launchReveal(.content)
        }
        .screenScaffoldFrame(maxWidth: maxWidth)
    }

    private var lazyScaffoldBody: some View {
        LazyVStack(alignment: .leading, spacing: Theme.blockGap) {
            scaffoldHeader
            // ViewBuilder already makes each supplied section a direct lazy
            // child. Enumerating them again through Group(subviews:) created a
            // stateful reveal modifier per section even though navigation no
            // longer supplies sectionFirstAppearance; it added mount/layout
            // work without a visible animation.
            content()
                .launchReveal(.content)
        }
        .screenScaffoldFrame(maxWidth: maxWidth)
    }

    private var scaffoldHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(Theme.Typography.screenTitle)
                            .tracking(-0.55)
                            .foregroundStyle(Theme.ink)
                        if let epithet {
                            Text(epithet)
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text(subtitle)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: ScreenScaffoldMetrics.proseMaxWidth,
                               alignment: .leading)
                }
                Spacer()
                trailing()
            }
            .frame(height: ScreenScaffoldMetrics.headerHeight, alignment: .top)
            Divider()
        }
        .launchReveal(.header)
    }
}

extension View {
    func centeredContentColumn(maxWidth: CGFloat = ScreenScaffoldMetrics.maxWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    func screenScaffoldFrame(maxWidth: CGFloat = ScreenScaffoldMetrics.maxWidth) -> some View {
        padding(.horizontal, Theme.gutter)
            .padding(.bottom, ScreenScaffoldMetrics.bottomInset)
            .padding(.top, ScreenScaffoldMetrics.topInset)
            .centeredContentColumn(maxWidth: maxWidth)
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String, epithet: String? = nil,
         maxWidth: CGFloat = ScreenScaffoldMetrics.maxWidth, scrolls: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, epithet: epithet,
                  maxWidth: maxWidth, scrolls: scrolls,
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
        .toastTransition()
    }
}
