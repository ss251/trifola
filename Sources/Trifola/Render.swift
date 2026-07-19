import SwiftUI
import AppKit
import TrifolaKit

// MARK: - UX acceptance evidence (`--render-ux`)

@MainActor
enum UXEvidenceRender {
    static func run(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
        for dark in [false, true] {
            for keyboardFocus in [false, true] {
                let mode = keyboardFocus ? "keyboard" : "pointer"
                let theme = dark ? "dark" : "light"
                let url = root.appendingPathComponent("focus-\(mode)-\(theme).png")
                renderFocus(keyboardFocus: keyboardFocus, dark: dark, to: url)
            }
            let theme = dark ? "dark" : "light"
            renderStateLadder(
                dark: dark,
                to: root.appendingPathComponent("state-ladder-\(theme).png"))
            renderAccessibilitySpotcheck(
                dark: dark,
                to: root.appendingPathComponent("accessibility-\(theme).png"))
            renderProvisionalState(
                dark: dark,
                to: root.appendingPathComponent("provisional-\(theme).png"))
        }
    }

    private static func renderFocus(keyboardFocus: Bool, dark: Bool, to url: URL) {
        let content = FocusAcceptanceCard(keyboardFocus: keyboardFocus)
            .frame(width: 820, height: 360)
            .background(Theme.surfaceWindow)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.tapFocusEvidenceOverride, keyboardFocus)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let image = rendered,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    private static func renderStateLadder(dark: Bool, to url: URL) {
        let content = StateLadderAcceptanceCard()
            .frame(width: 1_080, height: 320)
            .background(Theme.surfaceWindow)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let image = rendered,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    private static func renderAccessibilitySpotcheck(dark: Bool, to url: URL) {
        let content = AccessibilityAcceptanceCard()
            .frame(width: 1_080, height: 440)
            .background(Theme.surfaceWindow)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.doorLightReduceMotionOverride, true)
            .environment(\.doorLightReduceTransparencyOverride, true)
            .environment(\.doorLightIncreaseContrastOverride, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua
                                                  : .accessibilityHighContrastAqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let image = rendered,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    private static func renderProvisionalState(dark: Bool, to url: URL) {
        let content = ScreenScaffold(
            title: "Live Now",
            subtitle: "Reading your sessions — 417 of ~7,041…",
            scrolls: false) {
                SessionReadingState(progress: SessionScanProgress(
                    scanned: 417, totalEstimate: 7_041, isInProgress: true))
            }
            .frame(width: 1_080, height: 520)
            .background(Theme.surfaceWindow)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.doorLightReduceMotionOverride, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let image = rendered,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }
}

private struct AccessibilityAcceptanceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            VStack(alignment: .leading, spacing: Theme.micro) {
                Text("Accessibility appearance and motion audit")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text("High-contrast appearance · adaptive material boundaries · Reduce Motion-aware primitives")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: Theme.gutter) {
                Card {
                    VStack(alignment: .leading, spacing: Theme.intraCell) {
                        SectionLabel("Semantic status")
                        HStack(spacing: Theme.intraCell) {
                            SeatMark(state: .blocked, size: 12)
                            Text("Blocked")
                                .font(Theme.Typography.bodyMedium)
                                .foregroundStyle(Theme.red)
                            Spacer()
                            AttentionStatusPill(state: .blocked)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.intraCell) {
                        SectionLabel("Controls remain distinct")
                        HStack(spacing: Theme.intraCell) {
                            FilterChip(label: "Selected", isOn: true, action: {})
                            FilterChip(label: "Available", isOn: false, action: {})
                            FilterChip(label: "Disabled", isOn: false, action: {})
                                .disabled(true)
                        }
                    }
                }
            }
            HStack(spacing: Theme.sectionGap) {
                Toast(text: "Session opened", semantics: .success)
                Toast(text: "Exact tab unavailable", semantics: .information,
                      actionLabel: "Open Settings", action: {})
                Toast(text: "Workspace targeting failed", semantics: .failure,
                      actionLabel: "Copy resume", action: {})
            }
            Text("High Contrast keeps semantic boundaries and disabled states distinct. Production material accents switch to opaque fills under Reduce Transparency. Motion modifiers read the system Reduce Motion environment; this still forces the Door Light's reduced path.")
                .font(Theme.Typography.metadataMedium)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: ScreenScaffoldMetrics.proseMaxWidth, alignment: .leading)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct StateLadderAcceptanceCard: View {
    private enum Sample: String, CaseIterable {
        case rest = "Rest"
        case hover = "Hover"
        case pressed = "Pressed"
        case focus = "Keyboard focus"
        case selected = "Selected"
        case disabled = "Disabled"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            VStack(alignment: .leading, spacing: Theme.micro) {
                Text("Shared control state ladder")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text("One production FilterChip primitive · pointer, keyboard, selection, and availability states")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
            }
            HStack(alignment: .top, spacing: Theme.sectionGap) {
                ForEach(Sample.allCases, id: \.self) { sample in
                    VStack(alignment: .leading, spacing: Theme.intraCell) {
                        Eyebrow(sample.rawValue)
                        FilterChip(label: "Top-level",
                                   isOn: sample == .selected,
                                   action: {})
                            .environment(
                                \.tapFocusEvidenceOverride,
                                sample == .focus ? Optional(true) : nil)
                            .environment(
                                \.tapInteractionEvidenceOverride,
                                interactionOverride(for: sample))
                            .disabled(sample == .disabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            Text("Keyboard focus and keyboard-triggered actions are instant; pointer hover and press use the shared frequent-control feedback.")
                .font(Theme.Typography.metadataMedium)
                .foregroundStyle(Theme.muted)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func interactionOverride(
        for sample: Sample
    ) -> TapInteractionEvidenceOverride? {
        switch sample {
        case .hover: return .hover
        case .pressed: return .pressed
        default: return nil
        }
    }
}

private struct FocusAcceptanceCard: View {
    let keyboardFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            VStack(alignment: .leading, spacing: Theme.micro) {
                Text(keyboardFocus ? "Tab focus" : "Pointer click")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text(keyboardFocus
                     ? "Keyboard-origin focus uses the macOS focus token."
                     : "Pointer-origin focus leaves no halo behind.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: 56) {
                VStack(alignment: .leading, spacing: Theme.intraCell) {
                    Eyebrow("Shared capsule control")
                    QuietTapButton(action: {}) {
                        Label("Open session", systemImage: "terminal")
                    }
                    .frame(width: 180, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: Theme.intraCell) {
                    Eyebrow("State green (semantic comparison)")
                    HStack(spacing: Theme.intraCell) {
                        SeatMark(state: .running, size: 12)
                        Text("Running Door Light")
                            .font(Theme.Typography.bodyMedium)
                            .foregroundStyle(Theme.green)
                    }
                    .frame(height: Theme.Layout.compactHitHeight)
                }
            }

            Divider()
            Text(keyboardFocus
                 ? "Visible ring: keyboard navigation only"
                 : "No ring: click, secondary click, or other pointer input")
                .font(Theme.Typography.metadataMedium)
                .foregroundStyle(Theme.muted)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The ONLY chrome a render may add (POLISH C11): a caption-scale, faint,
/// sentence-case annotation. Renders compose real shared pure views + this —
/// never a fabricated title2 header or a tracked-uppercase eyebrow, which is how
/// this app's real title grammar nearly got mis-graded.
struct RenderCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.faint)
    }
}

// MARK: - Release brand assets (`--render-icon`)

/// Headless release-artwork exporter. The iconset calls AppBrand.drawAppIcon
/// directly at every required pixel size; banner and social call the same
/// Trefoil Aperture geometry. There is no render-only reconstruction.
enum BrandAssetRender {
    enum RenderError: Error, CustomStringConvertible {
        case bitmap(width: Int, height: Int)
        case pngEncoding

        var description: String {
            switch self {
            case .bitmap(let width, let height):
                return "could not allocate \(width)×\(height) bitmap"
            case .pngEncoding:
                return "could not encode PNG"
            }
        }
    }

    /// Exports the complete macOS iconset plus the repository banner and social
    /// card. Destinations are explicit so the release pipeline stays deterministic.
    @MainActor
    static func run(
        iconsetDirectory: URL,
        bannerURL: URL,
        socialURL: URL
    ) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: iconsetDirectory,
                               withIntermediateDirectories: true)

        var outputs: [URL] = []
        for entry in BrandAssetManifest.iconset {
            let png = try renderPNG(width: entry.pixels, height: entry.pixels) { bounds in
                AppBrand.drawAppIcon(in: bounds)
            }
            let output = iconsetDirectory.appendingPathComponent(entry.filename)
            try png.write(to: output, options: .atomic)
            outputs.append(output)
        }

        try fm.createDirectory(at: bannerURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let banner = try renderPNG(width: BrandAssetManifest.bannerWidth,
                                   height: BrandAssetManifest.bannerHeight,
                                   draw: drawBanner)
        try banner.write(to: bannerURL, options: .atomic)
        outputs.append(bannerURL)

        try fm.createDirectory(at: socialURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let social = try renderPNG(width: BrandAssetManifest.socialWidth,
                                   height: BrandAssetManifest.socialHeight,
                                   draw: drawSocial)
        try social.write(to: socialURL, options: .atomic)
        outputs.append(socialURL)
        return outputs
    }

    static func renderPNG(
        width: Int,
        height: Int,
        draw: (NSRect) -> Void
    ) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.bitmap(width: width, height: height)
        }
        bitmap.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RenderError.bitmap(width: width, height: height)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = NSImageInterpolation.high
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor.clear.setFill()
        bounds.fill()
        draw(bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(
            using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw RenderError.pngEncoding
        }
        return png
    }

    /// Dark, warm and deliberately sparse: one Trefoil Aperture, one wordmark
    /// and the read-only promise. The static teal core is the sole saturated hue.
    static func drawBanner(in bounds: NSRect) {
        let warmGround = NSGradient(colors: [
            NSColor(srgbRed: 0.12, green: 0.11, blue: 0.09, alpha: 1),
            NSColor(srgbRed: 0.065, green: 0.067, blue: 0.062, alpha: 1),
        ])
        warmGround?.draw(in: bounds, angle: 0)

        let glow = NSGradient(starting: NSColor(srgbRed: 0.39, green: 0.55, blue: 0.42,
                                                 alpha: 0.12),
                              ending: NSColor.clear)
        glow?.draw(in: bounds.insetBy(dx: 70, dy: 24),
                   relativeCenterPosition: NSPoint(x: -0.58, y: 0))

        let ink = NSColor(srgbRed: 0.93, green: 0.88, blue: 0.78, alpha: 0.94)
        let mutedInk = ink.withAlphaComponent(0.52)
        let markRect = NSRect(x: 214, y: 112, width: 136, height: 136)

        AppBrand.drawBrandMark(in: markRect, state: .needsYou,
                               color: ink.withAlphaComponent(1),
                               coreColor: AppBrand.Palette.staticCore)

        let wordmark: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 78, weight: .semibold),
            .foregroundColor: ink,
            .kern: -1.4,
        ]
        NSAttributedString(string: "Trifola", attributes: wordmark)
            .draw(at: NSPoint(x: 404, y: 157))

        let subtitle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: mutedInk,
            .kern: 0.6,
        ]
        NSAttributedString(string: "local · read-only", attributes: subtitle)
            .draw(at: NSPoint(x: 409, y: 116))

        ink.withAlphaComponent(0.10).setStroke()
        let hairline = NSBezierPath()
        hairline.move(to: NSPoint(x: 84, y: 42))
        hairline.line(to: NSPoint(x: bounds.maxX - 84, y: 42))
        hairline.lineWidth = 1
        hairline.stroke()
    }

    static func drawSocial(in bounds: NSRect) {
        let ground = NSGradient(colors: [
            NSColor(srgbRed: 0.105, green: 0.098, blue: 0.082, alpha: 1),
            NSColor(srgbRed: 0.048, green: 0.052, blue: 0.048, alpha: 1),
        ])
        ground?.draw(in: bounds, angle: -8)

        let glow = NSGradient(starting: AppBrand.Palette.staticCore.withAlphaComponent(0.15),
                              ending: NSColor.clear)
        glow?.draw(in: NSRect(x: 22, y: 120, width: 520, height: 430),
                   relativeCenterPosition: NSPoint(x: -0.06, y: 0.04))

        let ink = NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1)
        let muted = ink.withAlphaComponent(0.58)
        AppBrand.drawBrandMark(in: NSRect(x: 108, y: 238, width: 190, height: 190),
                               state: .needsYou,
                               color: ink,
                               coreColor: AppBrand.Palette.staticCore)

        NSAttributedString(string: "Trifola", attributes: [
            .font: NSFont.systemFont(ofSize: 88, weight: .semibold),
            .foregroundColor: ink,
            .kern: -1.8,
        ]).draw(at: NSPoint(x: 370, y: 384))
        NSAttributedString(string: "LOCAL · READ-ONLY", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: muted,
            .kern: 2.6,
        ]).draw(at: NSPoint(x: 377, y: 349))

        let claim = "The command center for your coding-agent fleet —\nClaude Code and Codex"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        NSAttributedString(string: claim, attributes: [
            .font: NSFont.systemFont(ofSize: 33, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.88),
            .kern: -0.25,
            .paragraphStyle: paragraph,
        ]).draw(with: NSRect(x: 374, y: 190, width: 820, height: 130),
                options: [.usesLineFragmentOrigin, .usesFontLeading])

        ink.withAlphaComponent(0.11).setStroke()
        let hairline = NSBezierPath()
        hairline.move(to: NSPoint(x: 84, y: 76))
        hairline.line(to: NSPoint(x: bounds.maxX - 84, y: 76))
        hairline.lineWidth = 1
        hairline.stroke()
    }
}

// MARK: - Logo decision artifacts (`--render-logo`)

/// Reproducible 512-point concept studies. Each board contains the mark alone,
/// the Dock squircle, and the exact 16-pixel raster enlarged without smoothing.
enum LogoConceptRender {
    private struct Study {
        let concept: AppBrand.IdentityConcept
        let filename: String
        let title: String
        let note: String
    }

    private static let studies: [Study] = [
        .init(concept: .thresholdLight,
              filename: "concept-a-door-light.png",
              title: "A  THRESHOLD LIGHT",
              note: "The Door Light gains an open threshold and a confident halo."),
        .init(concept: .noduleCut,
              filename: "concept-b-truffle.png",
              title: "B  THE NODULE CUT",
              note: "A restrained truffle cross-section makes discovery the story."),
        .init(concept: .trefoilAperture,
              filename: "concept-c-trefoil.png",
              title: "C  TREFOIL APERTURE",
              note: "Three product surfaces converge around the Door Light core."),
    ]

    @MainActor
    static func run(directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        var outputs: [URL] = []
        for study in studies {
            let smallData = try BrandAssetRender.renderPNG(width: 16, height: 16) { bounds in
                drawConceptIcon(study.concept, in: bounds)
            }
            guard let smallImage = NSImage(data: smallData) else {
                throw BrandAssetRender.RenderError.pngEncoding
            }
            let board = try BrandAssetRender.renderPNG(width: 512, height: 512) { bounds in
                drawBoard(study, smallImage: smallImage, in: bounds)
            }
            let output = directory.appendingPathComponent(study.filename)
            try board.write(to: output, options: .atomic)
            outputs.append(output)
        }
        outputs.append(contentsOf: try renderChosenSystem(directory: directory))
        return outputs
    }

    @MainActor
    private static func renderChosenSystem(directory: URL) throws -> [URL] {
        var outputs: [URL] = []
        var iconImages: [Int: NSImage] = [:]
        let sizes = [1_024, 512, 256, 128, 64, 32, 16]
        for size in sizes {
            let data = try BrandAssetRender.renderPNG(width: size, height: size) { bounds in
                AppBrand.drawAppIcon(in: bounds)
            }
            let output = directory.appendingPathComponent("app-icon-\(size).png")
            try data.write(to: output, options: .atomic)
            outputs.append(output)
            guard let image = NSImage(data: data) else {
                throw BrandAssetRender.RenderError.pngEncoding
            }
            iconImages[size] = image
        }

        let ladder = try BrandAssetRender.renderPNG(width: 1_280, height: 420) { bounds in
            drawSquintLadder(images: iconImages, sizes: sizes, in: bounds)
        }
        let ladderURL = directory.appendingPathComponent("squint-ladder.png")
        try ladder.write(to: ladderURL, options: .atomic)
        outputs.append(ladderURL)

        for dark in [false, true] {
            let glyphs = try glyphImages(dark: dark)
            let board = try BrandAssetRender.renderPNG(width: 640, height: 280) { bounds in
                drawGlyphBoard(images: glyphs, dark: dark, in: bounds)
            }
            let output = directory.appendingPathComponent(
                dark ? "glyph-menubar-dark.png" : "glyph-menubar-light.png")
            try board.write(to: output, options: .atomic)
            outputs.append(output)
        }

        let lockup = try BrandAssetRender.renderPNG(width: 900, height: 300,
                                                    draw: drawWordmarkBoard)
        let lockupURL = directory.appendingPathComponent("wordmark-lockup.png")
        try lockup.write(to: lockupURL, options: .atomic)
        outputs.append(lockupURL)

        let banner = try BrandAssetRender.renderPNG(width: BrandAssetManifest.bannerWidth,
                                                    height: BrandAssetManifest.bannerHeight,
                                                    draw: BrandAssetRender.drawBanner)
        let bannerURL = directory.appendingPathComponent("banner-preview.png")
        try banner.write(to: bannerURL, options: .atomic)
        outputs.append(bannerURL)

        let social = try BrandAssetRender.renderPNG(width: BrandAssetManifest.socialWidth,
                                                    height: BrandAssetManifest.socialHeight,
                                                    draw: BrandAssetRender.drawSocial)
        let socialURL = directory.appendingPathComponent("social-preview.png")
        try social.write(to: socialURL, options: .atomic)
        outputs.append(socialURL)
        return outputs
    }

    private static func drawSquintLadder(
        images: [Int: NSImage],
        sizes: [Int],
        in bounds: NSRect
    ) {
        let paper = NSColor(srgbRed: 0.945, green: 0.935, blue: 0.90, alpha: 1)
        let ink = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.095, alpha: 1)
        paper.setFill()
        bounds.fill()
        NSAttributedString(string: "TREFOIL APERTURE · SQUINT LADDER", attributes: [
            .font: NSFont.systemFont(ofSize: 25, weight: .bold),
            .foregroundColor: ink,
            .kern: 0.6,
        ]).draw(at: NSPoint(x: 38, y: 365))
        NSAttributedString(
            string: "The same canonical icon raster, from the 1024 master to the true 16 px edge case.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.53),
            ]).draw(at: NSPoint(x: 39, y: 335))

        let slotWidth: CGFloat = 171
        for (index, size) in sizes.enumerated() {
            guard let icon = images[size] else { continue }
            let slotX = 38 + CGFloat(index) * slotWidth
            let previewSize: CGFloat = size >= 128 ? 132 : 112
            let preview = NSRect(x: slotX + (132 - previewSize) / 2,
                                 y: 145 + (132 - previewSize) / 2,
                                 width: previewSize, height: previewSize)
            NSGraphicsContext.current?.imageInterpolation = size <= 64 ? .none : .high
            icon.draw(in: preview,
                      from: NSRect(origin: .zero, size: icon.size),
                      operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.imageInterpolation = .high

            let label = "\(size) PX"
            NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(0.62),
                .kern: 0.7,
            ]).draw(at: NSPoint(x: slotX + 38, y: 111))

            if size <= 64 {
                icon.draw(in: NSRect(x: slotX + (CGFloat(132) - CGFloat(size)) / 2,
                                     y: 35, width: CGFloat(size), height: CGFloat(size)),
                          from: NSRect(origin: .zero, size: icon.size),
                          operation: .sourceOver, fraction: 1)
            } else {
                NSAttributedString(string: "preview", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ink.withAlphaComponent(0.35),
                ]).draw(at: NSPoint(x: slotX + 45, y: 51))
            }
        }
    }

    private static func glyphImages(dark: Bool) throws -> [NSImage] {
        let color = dark ? NSColor.white : NSColor.black
        var images: [NSImage] = []
        for state in [AppBrand.MarkState.quiet, .running, .needsYou] {
            let data = try BrandAssetRender.renderPNG(width: 18, height: 18) { bounds in
                AppBrand.drawBrandMark(in: bounds, state: state,
                                       color: color, coreColor: color)
            }
            guard let image = NSImage(data: data) else {
                throw BrandAssetRender.RenderError.pngEncoding
            }
            image.isTemplate = false
            images.append(image)
        }
        return images
    }

    private static func drawGlyphBoard(images: [NSImage], dark: Bool, in bounds: NSRect) {
        let ground = dark
            ? NSColor(srgbRed: 0.105, green: 0.105, blue: 0.10, alpha: 1)
            : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.925, alpha: 1)
        let ink = dark ? NSColor.white : NSColor.black.withAlphaComponent(0.86)
        ground.setFill()
        bounds.fill()
        NSAttributedString(string: dark ? "18 PX TEMPLATE · DARK" : "18 PX TEMPLATE · LIGHT",
                           attributes: [
                               .font: NSFont.systemFont(ofSize: 19, weight: .bold),
                               .foregroundColor: ink,
                               .kern: 0.8,
                           ]).draw(at: NSPoint(x: 28, y: 238))

        let labels = ["QUIET", "RUNNING", "NEEDS YOU"]
        for index in images.indices {
            let x = 76 + CGFloat(index) * 195
            images[index].draw(in: NSRect(x: x + 30, y: 171, width: 18, height: 18),
                               from: NSRect(origin: .zero, size: images[index].size),
                               operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.imageInterpolation = .none
            images[index].draw(in: NSRect(x: x, y: 53, width: 78, height: 78),
                               from: NSRect(origin: .zero, size: images[index].size),
                               operation: .sourceOver, fraction: 1)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSAttributedString(string: labels[index], attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: ink.withAlphaComponent(0.56),
                .kern: 1.0,
            ]).draw(at: NSPoint(x: x + 4, y: 28))
        }
    }

    private static func drawWordmarkBoard(in bounds: NSRect) {
        let ground = NSGradient(colors: [
            NSColor(srgbRed: 0.12, green: 0.11, blue: 0.09, alpha: 1),
            NSColor(srgbRed: 0.065, green: 0.067, blue: 0.062, alpha: 1),
        ])
        ground?.draw(in: bounds, angle: 0)
        let ink = NSColor(srgbRed: 0.93, green: 0.88, blue: 0.78, alpha: 0.96)
        AppBrand.drawBrandMark(in: NSRect(x: 92, y: 77, width: 146, height: 146),
                               state: .needsYou,
                               color: ink.withAlphaComponent(1),
                               coreColor: AppBrand.Palette.staticCore)
        NSAttributedString(string: "Trifola", attributes: [
            .font: NSFont.systemFont(ofSize: 82, weight: .semibold),
            .foregroundColor: ink,
            .kern: -1.6,
        ]).draw(at: NSPoint(x: 296, y: 132))
        NSAttributedString(string: "local · read-only", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.52),
            .kern: 0.65,
        ]).draw(at: NSPoint(x: 301, y: 94))
    }

    private static func drawBoard(_ study: Study, smallImage: NSImage, in bounds: NSRect) {
        let paper = NSColor(srgbRed: 0.945, green: 0.935, blue: 0.90, alpha: 1)
        paper.setFill()
        bounds.fill()

        let ink = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.095, alpha: 1)
        let muted = ink.withAlphaComponent(0.53)
        let hairline = ink.withAlphaComponent(0.10)
        let accent = NSColor(srgbRed: 0.258, green: 0.60, blue: 0.515, alpha: 1)

        NSAttributedString(string: study.title, attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: ink,
            .kern: 0.7,
        ]).draw(at: NSPoint(x: 32, y: 457))
        NSAttributedString(string: study.note, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: muted,
        ]).draw(at: NSPoint(x: 33, y: 426))

        hairline.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 32, y: 405))
        divider.line(to: NSPoint(x: 480, y: 405))
        divider.lineWidth = 1
        divider.stroke()

        AppBrand.drawConceptMark(study.concept,
                                 in: NSRect(x: 46, y: 218, width: 126, height: 126),
                                 color: ink, coreColor: accent)
        drawConceptIcon(study.concept,
                        in: NSRect(x: 198, y: 190, width: 184, height: 184))

        let pixelFrame = NSRect(x: 397, y: 236, width: 96, height: 96)
        NSColor.white.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: pixelFrame.insetBy(dx: -7, dy: -7),
                     xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        smallImage.draw(in: pixelFrame,
                        from: NSRect(origin: .zero, size: smallImage.size),
                        operation: .sourceOver, fraction: 1)
        smallImage.draw(in: NSRect(x: 437, y: 200, width: 16, height: 16),
                        from: NSRect(origin: .zero, size: smallImage.size),
                        operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.imageInterpolation = .high

        label("MARK ALONE", at: NSPoint(x: 54, y: 164), color: muted)
        label("DOCK SQUIRCLE", at: NSPoint(x: 226, y: 164), color: muted)
        label("16 PX × 6", at: NSPoint(x: 413, y: 164), color: muted)

        let footer = "One geometry · code-drawn · no imported artwork"
        NSAttributedString(string: footer, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: muted,
            .kern: 0.3,
        ]).draw(at: NSPoint(x: 32, y: 52))
        hairline.setStroke()
        let footline = NSBezierPath()
        footline.move(to: NSPoint(x: 32, y: 88))
        footline.line(to: NSPoint(x: 480, y: 88))
        footline.lineWidth = 1
        footline.stroke()
    }

    private static func label(_ string: String, at point: NSPoint, color: NSColor) {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color,
            .kern: 1.0,
        ]).draw(at: point)
    }

    private static func drawConceptIcon(
        _ concept: AppBrand.IdentityConcept,
        in rect: NSRect
    ) {
        let scale = min(rect.width, rect.height) / AppBrand.Geometry.iconReferenceSize
        let inset = AppBrand.Geometry.iconTileInset * scale
        let radius = AppBrand.Geometry.iconTileCornerRadius * scale
        let tileRect = rect.insetBy(dx: inset, dy: inset)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)
        NSGradient(colors: [
            NSColor(srgbRed: 0.153, green: 0.188, blue: 0.176, alpha: 1),
            NSColor(srgbRed: 0.075, green: 0.086, blue: 0.082, alpha: 1),
        ])?.draw(in: tile, angle: -90)
        NSColor.white.withAlphaComponent(rect.width >= 32 ? 0.10 : 0).setStroke()
        let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: max(0.5, scale),
                                                             dy: max(0.5, scale)),
                               xRadius: max(0, radius - scale),
                               yRadius: max(0, radius - scale))
        rim.lineWidth = max(0.5, scale * 1.2)
        rim.stroke()

        let referenceDiameter: CGFloat
        switch concept {
        case .thresholdLight: referenceDiameter = AppBrand.Geometry.thresholdMarkDiameter
        case .noduleCut: referenceDiameter = 306
        case .trefoilAperture: referenceDiameter = AppBrand.Geometry.identityMarkDiameter
        }
        let diameter = referenceDiameter * scale
        let markRect = NSRect(x: rect.midX - diameter / 2,
                              y: rect.midY - diameter / 2,
                              width: diameter, height: diameter)
        AppBrand.drawConceptMark(
            concept,
            in: markRect,
            color: NSColor(srgbRed: 0.965, green: 0.96, blue: 0.93, alpha: 1),
            coreColor: NSColor(srgbRed: 0.258, green: 0.60, blue: 0.515, alpha: 1))
    }
}

// Headless rasterization of the Attention Strip for visual verification. The
// snapshot harness needs a live window/Space/Screen-Recording; this path needs
// none of that — it renders the real SwiftUI component with ImageRenderer, and
// can show a BLOCKED case that is rare on live data. Used by `--render-attention`.

enum AttentionRender {

    private static func demoSession(_ id: String, _ project: String, _ tier: ModelTier) -> SessionSummary {
        let prompt = [
            "webapp": "Seed the local database and run the app",
            "mobile-app": "Fix the chat view layout",
            "api-gateway": "Run the gateway test suite",
            "ml-trainer": "Check the latest training run",
            "my-app": "Build the fleet board",
            "side-project": "Polish the onboarding flow",
            "notes-app": "Update the docs index",
            "toolbar-app": "Review the toolbar states",
        ][project]
        return SessionSummary(id: id, project: project, cwd: "/tmp/\(project)", model: tier.rawValue,
                              lastActivity: Date(), messageCount: 7,
                              usage: SessionUsage(inputTokens: 1000), contextWeight: 120_000,
                              filePath: "/tmp/\(project)/s.jsonl", lastUserMessage: prompt)
    }

    private static func board(_ specs: [(String, ModelTier, AttentionState, TimeInterval)]) -> AttentionBoard {
        var items = specs.enumerated().map { i, s in
            AttentionItem(session: demoSession("s\(i)", s.0, s.1), state: s.2, age: s.3)
        }
        items.sort { $0.state.sortRank != $1.state.sortRank ? $0.state.sortRank < $1.state.sortRank : $0.age < $1.age }
        var counts: [AttentionState: Int] = [:]
        for it in items { counts[it.state, default: 0] += 1 }
        return AttentionBoard(items: items, counts: counts)
    }

    /// The ask on a chip (UI_GRIND ATT-4): tool + detail for the sessions that
    /// need you. Keyed by the demo ids ("s0"… in spec order). gpu-prover carries
    /// NO signal — the chip stays bare (honest absence, not a fabricated ask).
    private static func askSignals() -> [String: AttentionSignals] {
        func sig(_ tool: String, _ detail: String) -> AttentionSignals {
            AttentionSignals(lastEventAt: Date(), lastToolName: tool, lastToolDetail: detail)
        }
        return [
            "s0": sig("Bash", "approval · bun run dev"),
            "s1": sig("Edit", "acme-app/ChatView.swift"),
            "s2": sig("Bash", "bun test"),
        ]
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let busy = board([
            ("webapp", .opus, .blocked, 47),
            ("mobile-app", .opus, .blocked, 128),
            ("api-gateway", .sonnet, .waiting, 96),
            ("ml-trainer", .user, .waiting, 320),
            ("my-app", .opus, .running, 4),
            ("side-project", .sonnet, .running, 18),
            ("notes-app", .haiku, .idle, 1240),
            ("toolbar-app", .sonnet, .idle, 2100),
        ])
        let clear = board([
            ("my-app", .opus, .running, 6),
            ("webapp", .sonnet, .running, 22),
            ("notes-app", .haiku, .idle, 1400),
        ])

        let content = VStack(alignment: .leading, spacing: 20) {
            RenderCaption("Attention strip — sessions need you (2 blocked, 2 waiting)")
            AttentionStripView(board: busy, signals: askSignals()) { _ in }
            RenderCaption("Attention strip — all clear (no-nag doctrine)")
            AttentionStripView(board: clear) { _ in }
        }
        .padding(Theme.renderInset)
        .frame(width: 940, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        // ImageRenderer resolves SwiftUI `Color` against the environment scheme —
        // without this the dark pass rendered light (the harness lied; UI_GRIND ATT-1).
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.displayScale, 2)
        .environment(\.doorLightReduceMotionOverride, true)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        // NSColor semantic colors resolve against the *drawing* appearance, not the
        // SwiftUI colorScheme — force it so the dark pass actually renders dark.
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let img = rendered,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("RENDER: \(path)")
    }
}

// MARK: - Audit screen headless render
// `--render-audit` rasterizes the REAL Audit views (AuditContent + every finding
// table) with a representative seeded report so a populated screen shows — not an
// empty state. Same ImageRenderer + appearance-forcing path the Attention Strip
// added; snapshot.sh stays a secondary check.

enum AuditRender {

    static func seededReport() -> AuditReport {
        let now = Date()
        // Re-sent-context leaders — descending LEAK (fresh input above the warm
        // floor), first-touch cache-build shown separately, mixed tiers, one
        // subagent.
        let cacheMiss: [CacheMissFinding] = [
            .init(id: "a", project: "webapp", shortID: "b1f0c2a9", filePath: "",
                  tier: .opus, leakDollars: 27.90, firstTouchDollars: 13.40, cacheHitRate: 0.34,
                  billedInput: 3_050_000, cacheReadTokens: 1_600_000, contextWeight: 262_000, isSubagent: false,
                  handle: "Improve cache behavior", lastActivity: now.addingTimeInterval(-120)),
            .init(id: "b", project: "mobile-app", shortID: "77ad9e10", filePath: "",
                  tier: .opus, leakDollars: 15.10, firstTouchDollars: 7.70, cacheHitRate: 0.58,
                  billedInput: 1_680_000, cacheReadTokens: 2_300_000, contextWeight: 198_000, isSubagent: false,
                  handle: "Fix the chat view layout", lastActivity: now.addingTimeInterval(-600)),
            .init(id: "c", project: "data-pipeline", shortID: "0c31aa4d", filePath: "",
                  tier: .sonnet, leakDollars: 9.60, firstTouchDollars: 4.50, cacheHitRate: 0.41,
                  billedInput: 1_540_000, cacheReadTokens: 1_070_000, contextWeight: 141_000, isSubagent: false,
                  handle: "Rebuild the ingestion pipeline", lastActivity: now.addingTimeInterval(-1800)),
            .init(id: "d", project: "api-gateway", shortID: "e2290b7c", filePath: "",
                  tier: .sonnet, leakDollars: 5.70, firstTouchDollars: 2.90, cacheHitRate: 0.29,
                  billedInput: 3_180_000, cacheReadTokens: 1_300_000, contextWeight: 96_000, isSubagent: false,
                  handle: "Run the gateway tests", lastActivity: now.addingTimeInterval(-3600)),
            .init(id: "e", project: "ml-trainer", shortID: "51c7f3b2", filePath: "",
                  tier: .opus, leakDollars: 3.40, firstTouchDollars: 1.80, cacheHitRate: 0.72,
                  billedInput: 380_000, cacheReadTokens: 980_000, contextWeight: 62_000, isSubagent: true,
                  handle: "Inspect training metrics", lastActivity: now.addingTimeInterval(-7200)),
        ]

        // Skill ledger — the real 22 fired / 95 dead of 110, top invocations verbatim.
        func fired(_ n: String, _ c: Int, _ ago: TimeInterval, _ sess: Int, cat: Bool = true) -> SkillLedgerEntry {
            SkillLedgerEntry(name: n, invocations: c, sessionsTouched: sess,
                             lastFired: now.addingTimeInterval(-ago), inCatalog: cat, descriptionTokens: 0)
        }
        func dead(_ n: String, _ tok: Int) -> SkillLedgerEntry {
            SkillLedgerEntry(name: n, invocations: 0, sessionsTouched: 0, lastFired: nil,
                             inCatalog: true, descriptionTokens: tok)
        }
        let ledger = SkillLedger(
            catalogCount: 110, distinctFired: 22, firedInCatalog: 15,
            deadCount: 95, deadPromptTaxTokens: 41_800, sessionCount: 2691,
            fired: [
                fired("code-review", 20, 3600, 9, cat: false),
                fired("api-client", 11, 7200, 6),
                fired("update-config", 4, 90000, 3, cat: false),
                fired("schedule", 4, 40000, 2, cat: false),
                fired("frontend-design", 4, 120000, 3),
                fired("sql-tuner", 3, 200000, 2),
                fired("regex-builder", 3, 210000, 2),
                fired("design-review", 3, 250000, 2),
            ],
            dead: [
                dead("log-parser", 980), dead("env-linter", 910),
                dead("asset-bundler", 760), dead("datakit-export", 720),
                dead("react-native-architecture", 640), dead("html-minifier", 610),
                dead("mobile-app-ios", 560), dead("schema-migration", 540),
                dead("design-consultation", 520), dead("office-hours", 500),
                dead("plan-ceo-review", 470), dead("automated-e2e", 450),
            ])

        // Model-mismatch review candidates.
        let mismatches: [MismatchCandidate] = [
            .init(id: "m1", project: "toolbar-app", shortID: "44c1e0a7", filePath: "",
                  tier: .opus, cost: 12.40, estOverspend: 9.80, messageCount: 22, fileEdits: 1, agentCalls: 0,
                  handle: "Polish the toolbar", lastActivity: now.addingTimeInterval(-800)),
            .init(id: "m2", project: "side-project", shortID: "9b30fa22", filePath: "",
                  tier: .opus, cost: 9.10, estOverspend: 6.60, messageCount: 14, fileEdits: 0, agentCalls: 0,
                  handle: "Outline the launch notes", lastActivity: now.addingTimeInterval(-1600)),
            .init(id: "m3", project: "notes-app", shortID: "71ccb904", filePath: "",
                  tier: .opus, cost: 5.70, estOverspend: 4.30, messageCount: 31, fileEdits: 2, agentCalls: 0,
                  handle: "Update search behavior", lastActivity: now.addingTimeInterval(-3200)),
            .init(id: "m4", project: "cli-tool", shortID: "e0a7712d", filePath: "",
                  tier: .opus, cost: 3.20, estOverspend: 2.40, messageCount: 18, fileEdits: 1, agentCalls: 0,
                  handle: "Add command completion", lastActivity: now.addingTimeInterval(-6400)),
        ]

        return AuditReport(
            cacheMiss: cacheMiss, totalLeakDollars: 142.80,
            totalFirstTouchDollars: 71.80, skillLedger: ledger,
            mismatches: mismatches, totalMismatchOverspend: 28.30, mismatchCount: 17)
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        // No ScrollView — ImageRenderer cannot size an unbounded scroll view and
        // rasterizes it blank. Render the VStack directly at a fixed WIDTH and let
        // its height be intrinsic (the exact working shape AttentionRender uses).
        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Audit · evidence, not nags — the real AuditContent over a seeded report")
            AuditContent(report: seededReport(), onInspect: { _ in }, onReveal: { _ in })
        }
        .padding(Theme.renderInset)
        .frame(width: 1160, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        // Force the SwiftUI colorScheme too — ImageRenderer resolves `Color`
        // against the environment scheme, so the drawing-appearance override alone
        // leaves the dark pass looking light. Both together render true dark/light.
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.displayScale, 2)
        .environment(\.doorLightReduceMotionOverride, true)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let img = rendered,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("RENDER: \(path)")
    }
}

// MARK: - Fleet Board headless render (`--render-fleet`)
// Rasterizes the REAL Floor (`FleetFloor`) with seeded bays/tokens/states — a
// four-token swarm bay with nested subagents + a collision chip, a BLOCKED-STILL
// seat, a RUNNING one, and an idle ember bay — so the spatial layout can be
// Read + judged against the spec's five litmus tests without a window/Space.
// The heartbeat is MOTION (won't show in a still); this render is the
// frozen-frame test itself — the layout must read with zero animation.
// Arrival order is pre-seeded (in the live app the ledger fills in true
// arrival order over the day).

enum FleetRender {

    private static func sess(id: String, project: String, cwd: String, tier: ModelTier,
                             ageSecs: TimeInterval, cost: Double, edits: Int = 0,
                             quote: String? = nil,
                             subagentOf: String? = nil, now: Date) -> SessionSummary {
        let inp = Int(cost / max(tier.rates.inp, 0.001) * 1_000_000)
        let path = subagentOf == nil
            ? "\(cwd)/\(id).jsonl"
            : "\(cwd)/\(subagentOf!)/subagents/agent-\(id.split(separator: "/").last ?? "x").jsonl"
        return SessionSummary(
            id: id, project: project, cwd: cwd, model: tier.rawValue,
            lastActivity: now.addingTimeInterval(-ageSecs), messageCount: 12,
            usage: SessionUsage(inputTokens: inp), contextWeight: 120_000,
            filePath: path, lastUserMessage: quote, fileEdits: edits)
    }

    private static func sig(tool: String? = nil, detail: String = "",
                            kind: AttentionSignals.LastKind, stop: String? = nil,
                            dangling: Bool = false, hasPermissionGate: Bool = false,
                            ageSecs: TimeInterval, now: Date) -> AttentionSignals {
        let at = now.addingTimeInterval(-ageSecs)
        return AttentionSignals(
            lastEventAt: at, lastKind: kind, lastStopReason: stop,
            hasDanglingToolUse: dangling, danglingToolUseAt: dangling ? at : nil,
            lastToolActivityAt: (kind == .toolUse || kind == .toolResult) ? at : nil,
            lastToolName: tool, lastToolDetail: detail.isEmpty ? nil : detail,
            hasPermissionGate: hasPermissionGate)
    }

    static func seeded(now: Date) -> (board: FleetBoard, attention: AttentionBoard,
                                      signals: [String: AttentionSignals]) {
        let cmc = "/Users/dev/Developer/my-app"
        let webapp = "/Users/dev/Developer/webapp"
        let slack = "/Users/dev/Developer/alpha-hackathon"
        let dev = "/Users/dev/Developer"

        let customID = "0ed7bc81", opusID = "77b3f2a1"
        let subA = "\(opusID)/agent-a3c10a89", subB = "\(opusID)/agent-4be0c2d7"
        let webappID = "b5f4e5e5", slackID = "c91d22f0", devID = "9942ce11"

        let sessions: [SessionSummary] = [
            // The swarm bay — two mains editing (collision) + two nested subagents.
            sess(id: customID, project: "my-app", cwd: cmc, tier: .user,
                 ageSecs: 2, cost: 3.43, edits: 6, quote: "build the Fleet Board — the Floor", now: now),
            sess(id: opusID, project: "my-app", cwd: cmc, tier: .opus,
                 ageSecs: 46, cost: 616, edits: 9, quote: "wire the heartbeat into FileTailer", now: now),
            sess(id: subA, project: "my-app", cwd: cmc, tier: .opus,
                 ageSecs: 12, cost: 17, quote: "attention-strip build", subagentOf: opusID, now: now),
            sess(id: subB, project: "my-app", cwd: cmc, tier: .opus,
                 ageSecs: 60, cost: 6.13, quote: "run the test suite", subagentOf: opusID, now: now),
            // A BLOCKED-STILL seat — the alarm is the absence of motion.
            sess(id: webappID, project: "webapp", cwd: webapp, tier: .opus,
                 ageSecs: 250, cost: 3.67, edits: 1, quote: "seed db + bun run dev", now: now),
            // A second bay — a distinct running project.
            sess(id: slackID, project: "alpha-hackathon", cwd: slack, tier: .opus,
                 ageSecs: 30, cost: 12, edits: 2, quote: "provision the sandbox", now: now),
            // An idle bay — cooled to embers.
            sess(id: devID, project: "Developer", cwd: dev, tier: .haiku,
                 ageSecs: 44 * 60, cost: 1.20, quote: "docs index sync", now: now),
        ]

        let signals: [String: AttentionSignals] = [
            customID: sig(tool: "Write", detail: "docs/FLEET_BOARD.md", kind: .toolUse, ageSecs: 2, now: now),
            opusID: sig(tool: "Edit", detail: "Sources/Trifola/FleetScreen.swift", kind: .toolResult, ageSecs: 46, now: now),
            subA: sig(kind: .assistantText, stop: "tool_use", ageSecs: 12, now: now),
            subB: sig(tool: "Bash", detail: "swift test", kind: .toolUse, ageSecs: 60, now: now),
            webappID: sig(tool: "Bash", detail: "approval · bun run dev", kind: .toolUse,
                          dangling: true, hasPermissionGate: true, ageSecs: 250, now: now),
            slackID: sig(tool: "Bash", detail: "provision sandbox", kind: .toolResult, ageSecs: 30, now: now),
            devID: sig(tool: "Bash", detail: "docs index sync", kind: .toolResult, ageSecs: 44 * 60, now: now),
        ]

        // Pre-seed arrival order: swarm bay → webapp → slack → Developer, with the
        // Custom seat ahead of the Opus seat inside the swarm bay.
        var ledger = ArrivalLedger()
        for key in [cmc, customID, opusID, subA, subB, webapp, webappID, slack, slackID, dev, devID] {
            _ = ledger.claim(key)
        }
        let board = FleetBoard.build(sessions: sessions, signals: signals, now: now, arrival: ledger).board
        let attention = AttentionBoard.build(sessions: sessions, signals: signals, now: now)
        return (board, attention, signals)
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let (board, attention, signals) = seeded(now: now)
        let content = FleetFloor(board: board, attention: attention, signals: signals)
            .padding(Theme.renderInset)
            .frame(width: 1180, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.displayScale, 2)
            .environment(\.doorLightReduceMotionOverride, true)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let img = rendered, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8)); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("RENDER: \(path)")
    }
}

// MARK: - Dreaming Ledger headless render (`--render-ledger`)
// Rasterizes the REAL Ledger (LedgerContent + LessonCard) with seeded lessons so
// the flywheel — a finding turned into a copy-able candidate fix — is the visual
// truth. Reuses AuditRender.seededReport() so the numbers match the audit render
// exactly (78 Custom runs, 95/110 dead skills, $214.60 cache miss, 17 mismatches),
// plus an xhigh settings read so the effort-furnace lesson (L-005) fires. L-001 is
// shown APPLIED with its verification annotation ("was 80, now 78 — the edit is
// taking") so the closed loop reads. snapshot.sh is Space-broken; this is the
// verification path (Read the PNGs, judge them).

enum LedgerRender {

    /// A synthetic catalog mapping the seeded dead-skill names to plausible skill
    /// folder paths, so L-002's Reveal-in-Finder targets render.
    static func seededCatalog() -> [Skill] {
        let names = ["log-parser", "env-linter", "asset-bundler",
                     "datakit-export", "react-native-architecture", "html-minifier",
                     "mobile-app-ios", "design-consultation"]
        return names.map { n in
            Skill(id: n, name: n, description: "Seeded dead skill.", version: nil, triggers: [],
                  allowedTools: [], hasManifest: true, wordCount: 300, fileCount: 1,
                  modified: Date(), path: "/Users/dev/.claude/skills/\(n)/SKILL.md", source: .user)
        }
    }

    static func seededSettings() -> ClaudeSettings {
        // effortLevel = xhigh → above the High doctrine default → L-005 fires.
        ClaudeSettings(model: "opus[1m]", effort: .xhigh, effortRaw: "xhigh")
    }

    /// Mint the lessons, then wrap them with adjudication state — the first lesson
    /// shown APPLIED two days ago at a higher metric (now lower → "the edit is
    /// taking"), the rest pending — so both the fix flow and the closed loop read.
    static func seeded(now: Date) -> (pending: [AdjudicatedLesson], history: [AdjudicatedLesson], dream: DreamResult) {
        let report = AuditRender.seededReport()
        let lessons = LessonMiner.mint(report: report, catalog: seededCatalog(),
                                       settings: seededSettings(), now: now)
        let appliedAt = now.addingTimeInterval(-2 * 86400)
        var pending: [AdjudicatedLesson] = []
        for (i, l) in lessons.enumerated() {
            if i == 0 {
                let st = LessonState(status: .applied, updatedAt: appliedAt, appliedAt: appliedAt,
                                     appliedMetric: l.metricValue + 2)   // higher at apply → "taking"
                pending.append(AdjudicatedLesson(lesson: l, state: st))
            } else {
                pending.append(AdjudicatedLesson(lesson: l, state: nil))
            }
        }
        // Adjudicated ledger: the applied lesson + a dismissed example (shows the
        // append-only history / "audit the auditor").
        var history: [AdjudicatedLesson] = pending.filter { $0.status == .applied }
        if let ds = lessons.first(where: { $0.kind == .rightSizing }) {
            history.append(AdjudicatedLesson(lesson: ds,
                state: LessonState(status: .dismissed, updatedAt: now.addingTimeInterval(-3600))))
        }
        let dream = DreamResult(ranAt: now.addingTimeInterval(-41), trigger: .manual,
                                sessionsScanned: 5248, lessonsMinted: lessons.count, durationMs: 41)
        return (pending, history, dream)
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let (pending, history, dream) = seeded(now: now)
        let content = LedgerContent(
            dream: dream, pending: pending, history: history,
            showHistory: .constant(true),
            onCopy: { _ in }, onReveal: { _ in }, onInspect: { _ in },
            onKeep: { _ in }, onDismiss: { _ in })
        let framed = VStack(alignment: .leading, spacing: 16) {
            // The screen's ONE prominent verb rides the header (POLISH C9): the
            // real DreamNowButton, so the render can't mistake a caption for it.
            HStack(alignment: .center, spacing: 8) {
                RenderCaption("Dreaming Ledger · findings become fixes — the real LedgerContent over seeded lessons")
                Spacer()
                DreamNowButton()
            }
            content
        }
        writePNG(framed, to: path, dark: dark, width: 1080)
    }
}

// MARK: - Shared PNG writer

@MainActor
private func writePNG<V: View>(_ content: V, to path: String, dark: Bool, width: CGFloat) {
    let framed = content
        .padding(Theme.renderInset)
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.displayScale, 2)
        .environment(\.doorLightReduceMotionOverride, true)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    var rendered: NSImage?
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
    guard let img = rendered, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("render failed\n".utf8)); return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("RENDER: \(path)")
}

// MARK: - First-run onboarding headless render (`--render-onboarding`)

/// Both branded first-run beats over the real seeded Fleet Board. The board
/// remains legible behind each panel, proving that onboarding introduces trust
/// without replacing the product's first value with a setup screen.
@MainActor
enum OnboardingRender {
    static func run(to path: String, dark: Bool) {
        let now = SessionsRender.now
        let seeded = FleetRender.seeded(now: now)
        let content = VStack(alignment: .leading, spacing: Theme.blockGap) {
            RenderCaption("First launch · live Fleet Board remains visible")
            onboardingWindow(
                stage: .welcome(ProviderCorpusPresence(
                    providers: [.claude, .codex])),
                seeded: seeded)
            RenderCaption("First exact terminal jump · app primer before macOS")
            onboardingWindow(
                stage: .automation(terminalName: "Terminal"),
                seeded: seeded)
        }
        writePNG(content, to: path, dark: dark, width: 1_100)
    }

    private static func onboardingWindow(
        stage: OnboardingStage,
        seeded: (board: FleetBoard, attention: AttentionBoard,
                 signals: [String: AttentionSignals])
    ) -> some View {
        FleetFloor(
            board: seeded.board,
            attention: seeded.attention,
            signals: seeded.signals)
            .padding(Theme.cardPadding)
            .frame(width: 1_044, height: 640, alignment: .topLeading)
            .background(Theme.surfaceWindow)
            .overlay {
                switch stage {
                case .welcome:
                    OnboardingOverlay(stage: stage)
                case .automation:
                    OnboardingOverlay(stage: stage, deferAction: {})
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
    }
}

// MARK: - Provider-parity acceptance evidence (`--render-parity`)

/// Deterministic evidence for every provider-parity surface required by the
/// launch work order. Each still composes the exact production component; the
/// only render-only chrome is `RenderCaption`, per the shared evidence policy.
/// Fixtures never read live credentials, Keychain items, rollout files, or the
/// network. Both appearances are rendered from identical source values.
@MainActor
enum ParityRender {
    private static let now = Date(timeIntervalSince1970: 1_752_206_400)

    static func run(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data(
                "trifola: could not create parity render directory: \(error)\n".utf8))
            return
        }

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            renderModels(to: root.appendingPathComponent(
                "models-card-\(suffix).png").path, dark: dark)
            renderSpendTable(to: root.appendingPathComponent(
                "spend-table-\(suffix).png").path, dark: dark)
            renderProviderRows(to: root.appendingPathComponent(
                "provider-badges-filter-\(suffix).png").path, dark: dark)
            renderQuota(to: root.appendingPathComponent(
                "quota-section-\(suffix).png").path, dark: dark)
            renderTranscript(to: root.appendingPathComponent(
                "codex-transcript-\(suffix).png").path, dark: dark)
            renderOnboarding(to: root.appendingPathComponent(
                "onboarding-states-\(suffix).png").path, dark: dark)
        }
    }

    private static func renderModels(to path: String, dark: Bool) {
        let stats = [
            TierStat(tier: .codex, tokens: 82_480_000, cost: 195.42, sessions: 117),
            TierStat(tier: .opus, tokens: 21_310_000, cost: 86.71, sessions: 42),
            TierStat(tier: .sonnet, tokens: 34_780_000, cost: 48.19, sessions: 89),
            TierStat(tier: .haiku, tokens: 7_620_000, cost: 4.63, sessions: 28),
            TierStat(tier: .other, tokens: 940_000, cost: 1.14, sessions: 3),
        ]
        let total = stats.reduce(0) { $0 + $1.cost }
        let content = VStack(alignment: .leading, spacing: Theme.sectionGap) {
            RenderCaption("Overview models card — the production tier section names Codex separately from Other")
            Card(padding: Theme.cardPadding + Theme.micro) {
                TierSpendSection(stats: stats, total: total)
            }
        }
        writePNG(content, to: path, dark: dark, width: 940)
    }

    private static func renderSpendTable(to path: String, dark: Bool) {
        let rows = [
            ModelSpendStat(
                provider: .codex, model: "gpt-5.6-sol",
                usage: SessionUsage(inputTokens: 22_800_000,
                                    outputTokens: 3_420_000,
                                    cacheReadTokens: 56_260_000),
                cost: 195.42, sessions: 117),
            ModelSpendStat(
                provider: .claude, model: "claude-opus-4-8",
                usage: SessionUsage(inputTokens: 8_900_000,
                                    outputTokens: 1_280_000,
                                    cacheReadTokens: 11_130_000),
                cost: 86.71, sessions: 42),
            ModelSpendStat(
                provider: .codex, model: "gpt-5.4",
                usage: SessionUsage(inputTokens: 4_200_000,
                                    outputTokens: 630_000,
                                    cacheReadTokens: 9_480_000),
                cost: 31.58, sessions: 26),
            ModelSpendStat(
                provider: .claude, model: "claude-sonnet-5",
                usage: SessionUsage(inputTokens: 9_400_000,
                                    outputTokens: 1_040_000,
                                    cacheReadTokens: 24_340_000),
                cost: 27.96, sessions: 89),
        ]
        let content = VStack(alignment: .leading, spacing: Theme.sectionGap) {
            RenderCaption("Spend & Routing — the production exact-model table keeps provider provenance and the real model id")
            TopModelsByIDTable(rows: rows)
        }
        writePNG(content, to: path, dark: dark, width: 980)
    }

    private static func renderProviderRows(to path: String, dark: Bool) {
        let services = AppServices()
        services.now = now
        let navigation = AppNavigation()
        let snapshots = NavigationSnapshotStore()
        let items = providerSessions()
        let content = SessionsRenderContent(
            items: items,
            selectedID: "codex-parity-5601",
            transcriptEvents: codexTranscriptEvents())
            .frame(width: 1_180, height: 760, alignment: .topLeading)
            .environmentObject(services)
            .environmentObject(navigation)
            .environmentObject(snapshots)
        writePNG(content, to: path, dark: dark,
                 width: 1_180 + Theme.renderInset * 2)
    }

    private static func renderQuota(to path: String, dark: Bool) {
        let claude = QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 71,
                                  resetsAt: now.addingTimeInterval(74 * 60)),
            weekly: QuotaWindow(title: "Weekly (all models)", usedPercent: 54,
                                resetsAt: now.addingTimeInterval(3 * 86_400)),
            scoped: [QuotaWindow(title: "Opus only", usedPercent: 38,
                                 resetsAt: now.addingTimeInterval(3 * 86_400))],
            fetchedAt: now)
        let codex = QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 83,
                                  resetsAt: now.addingTimeInterval(42 * 60)),
            weekly: QuotaWindow(title: "Weekly", usedPercent: 46,
                                resetsAt: now.addingTimeInterval(4 * 86_400)),
            scoped: [],
            credits: QuotaCredits(hasCredits: true, unlimited: false,
                                  balance: "$42.75"),
            fetchedAt: now)
        let content = VStack(alignment: .leading, spacing: Theme.sectionGap) {
            RenderCaption("Plan quota — the production multi-provider section; Claude reads only after consent, Codex is local-only")
            Card {
                QuotaSection(
                    snapshots: [.claude: claude, .codex: codex],
                    statuses: [.claude: "ok", .codex: "local rollout"],
                    source: .keychain,
                    consent: QuotaConsent(claude: true, codex: true),
                    now: now)
            }
        }
        writePNG(content, to: path, dark: dark, width: 920)
    }

    private static func renderTranscript(to path: String, dark: Bool) {
        let content = VStack(alignment: .leading, spacing: Theme.sectionGap) {
            RenderCaption("Codex rollout — the production TranscriptView over events parsed by CodexRolloutTranscriptParser")
            TranscriptView(
                filePath: "/Users/dev/.codex/sessions/2026/07/11/rollout-parity.jsonl",
                provider: .codex,
                previewEvents: codexTranscriptEvents())
                .frame(height: 460)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        }
        writePNG(content, to: path, dark: dark, width: 920)
    }

    private static func renderOnboarding(to path: String, dark: Bool) {
        let content = VStack(alignment: .leading, spacing: Theme.sectionGap) {
            RenderCaption("Provider-aware onboarding — every corpus-presence state through the production callout")
            onboardingState("No corpus", providers: [])
            onboardingState("Claude only", providers: [.claude])
            onboardingState("Codex only", providers: [.codex])
            onboardingState("Both providers", providers: [.claude, .codex])
        }
        writePNG(content, to: path, dark: dark, width: 920)
    }

    private static func onboardingState(
        _ label: String, providers: Set<Provider>
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.micro) {
            RenderCaption(label)
            ProviderOnboardingCallout(
                presence: ProviderCorpusPresence(providers: providers))
        }
    }

    private static func providerSessions() -> [SessionsRenderItem] {
        [
            providerSession(
                id: "codex-parity-5601", provider: .codex,
                project: "trifola", title: "Finish provider parity",
                model: "gpt-5.6-sol", age: 46,
                usage: SessionUsage(inputTokens: 1_820_000,
                                    outputTokens: 164_000,
                                    cacheReadTokens: 5_420_000),
                context: 188_000, messages: 72, state: .running),
            providerSession(
                id: "claude-launch-42bc", provider: .claude,
                project: "checkout-web", title: "Verify launch migration",
                model: "claude-opus-4-8", age: 4 * 60,
                usage: SessionUsage(inputTokens: 940_000,
                                    outputTokens: 58_000,
                                    cacheReadTokens: 2_480_000),
                context: 212_000, messages: 48, state: .blocked),
            providerSession(
                id: "codex-docs-5a40", provider: .codex,
                project: "docs-site", title: "Regenerate release evidence",
                model: "gpt-5.4", age: 11 * 60,
                usage: SessionUsage(inputTokens: 480_000,
                                    outputTokens: 39_000,
                                    cacheReadTokens: 1_220_000),
                context: 96_000, messages: 31, state: .waiting),
            providerSession(
                id: "claude-api-180d", provider: .claude,
                project: "api-gateway", title: "Harden webhook retries",
                model: "claude-sonnet-5", age: 48 * 60,
                usage: SessionUsage(inputTokens: 320_000,
                                    outputTokens: 28_000,
                                    cacheReadTokens: 840_000),
                context: 68_000, messages: 24, state: .idle),
        ]
    }

    private static func providerSession(
        id: String, provider: Provider, project: String, title: String,
        model: String, age: TimeInterval, usage: SessionUsage,
        context: Int, messages: Int, state: AttentionState
    ) -> SessionsRenderItem {
        SessionsRenderItem(
            session: SessionSummary(
                id: id,
                provider: provider,
                project: project,
                cwd: "/Users/dev/Developer/\(project)",
                model: model,
                lastActivity: now.addingTimeInterval(-age),
                messageCount: messages,
                usage: usage,
                contextWeight: context,
                filePath: provider == .codex
                    ? "/Users/dev/.codex/sessions/2026/07/11/rollout-\(id).jsonl"
                    : "/Users/dev/.claude/projects/\(project)/\(id).jsonl",
                lastUserMessage: "Complete \(title.lowercased())",
                name: title,
                fileEdits: state == .running ? 9 : 2),
            state: state)
    }

    /// Parse fixture JSONL through the same production Codex adapter used by a
    /// live TranscriptStore. The still therefore proves session metadata,
    /// per-turn model context, user/agent narration, command/output summaries,
    /// and token-count projection without touching a user's rollout files.
    private static func codexTranscriptEvents() -> [TranscriptEvent] {
        let lines = [
            #"{"timestamp":"2026-07-11T09:10:00Z","type":"session_meta","payload":{"id":"meta-1","model_provider":"openai","cli_version":"0.104.0","history_mode":"full","cwd":"/Users/dev/Developer/trifola"}}"#,
            #"{"timestamp":"2026-07-11T09:10:01Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.6-sol","effort":"high"}}"#,
            #"{"timestamp":"2026-07-11T09:10:02Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"user-1","type":"user_message","message":"Finish provider parity and run the release gates."}}}"#,
            #"{"timestamp":"2026-07-11T09:10:05Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"agent-1","type":"agent_message","message":"I wired Codex into every production surface and am verifying the evidence."}}}"#,
            #"{"timestamp":"2026-07-11T09:10:07Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"call-1","type":"function_call","name":"exec_command","arguments":{"cmd":"swift test"}}}}"#,
            #"{"timestamp":"2026-07-11T09:10:18Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"result-1","type":"function_call_output","output":"All tests passed.","is_error":false}}}"#,
            #"{"timestamp":"2026-07-11T09:10:19Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"tokens-1","type":"token_count","info":{"last_token_usage":{"input_tokens":18200,"cached_input_tokens":9400,"output_tokens":1640,"reasoning_output_tokens":520}}}}}"#,
            #"{"timestamp":"2026-07-11T09:10:20Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"done-1","type":"task_complete","duration_ms":18000}}}"#,
        ]
        return lines.enumerated().flatMap { index, line in
            CodexRolloutTranscriptParser.events(
                fromLine: Data(line.utf8), fallbackID: "parity-\(index)")
        }
    }
}

// MARK: - Sessions browser headless render (`--render-sessions`)

/// The redesigned production browser over deterministic rows. State is seeded
/// explicitly so one still verifies the complete blocked / waiting / running /
/// idle grammar; the selected inspector uses the real TranscriptView hierarchy
/// over deterministic preview events instead of waiting on a file tail.
enum SessionsRender {
    static let now = Date(timeIntervalSince1970: 1_752_000_000)

    private static func item(id: String, project: String, name: String,
                             tier: ModelTier, state: AttentionState,
                             age: TimeInterval, usage: SessionUsage,
                             context: Int, messages: Int,
                             prompt: String, suppressed: Bool = false,
                             subagentOf: String? = nil) -> SessionsRenderItem {
        let session = SessionSummary(
            id: id,
            project: project,
            cwd: "/tmp/trifola-render/\(project)",
            model: tier.rawValue,
            lastActivity: now.addingTimeInterval(-age),
            messageCount: messages,
            usage: usage,
            contextWeight: context,
            filePath: subagentOf.map {
                "/tmp/trifola-render/\($0)/subagents/agent-\(id).jsonl"
            } ?? "/tmp/trifola-render/\(id).jsonl",
            lastUserMessage: prompt,
            name: name,
            fileEdits: state == .running ? 8 : 2)
        return SessionsRenderItem(session: session, state: state, suppressed: suppressed)
    }

    static func seededItems() -> [SessionsRenderItem] {
        [
            item(id: "sess-checkout-8f21", project: "checkout-web",
                 name: "Release checkout redesign", tier: .opus, state: .blocked,
                 age: 7 * 60, usage: SessionUsage(inputTokens: 1_820_000,
                                                  outputTokens: 96_000,
                                                  cacheReadTokens: 5_400_000),
                 context: 312_000, messages: 84,
                 prompt: "Run the production migration after approval"),
            item(id: "sess-ios-41bc", project: "mobile-app",
                 name: "Polish onboarding transitions", tier: .sonnet, state: .waiting,
                 age: 3 * 60, usage: SessionUsage(inputTokens: 740_000,
                                                  outputTokens: 44_000,
                                                  cacheReadTokens: 1_900_000),
                 context: 184_000, messages: 51,
                 prompt: "Which empty-state direction should we ship?"),
            item(id: "sess-api-c190", project: "api-gateway",
                 name: "Harden webhook retries", tier: .user, state: .running,
                 age: 18, usage: SessionUsage(inputTokens: 520_000,
                                              outputTokens: 31_000,
                                              cacheReadTokens: 1_260_000),
                 context: 126_000, messages: 37,
                 prompt: "Add retry jitter and run the integration suite"),
            item(id: "sess-docs-220d", project: "docs-site",
                 name: "Refresh launch guide", tier: .haiku, state: .idle,
                 age: 42 * 60, usage: SessionUsage(inputTokens: 210_000,
                                                  outputTokens: 18_000,
                                                  cacheReadTokens: 640_000),
                 context: 48_000, messages: 19,
                 prompt: "Update screenshots and cross-links"),
            item(id: "sess-billing-920a", project: "billing-worker",
                 name: "Trace invoice drift", tier: .opus, state: .running,
                 age: 46, usage: SessionUsage(inputTokens: 980_000,
                                              outputTokens: 72_000,
                                              cacheReadTokens: 2_800_000),
                 context: 238_000, messages: 63,
                 prompt: "Compare the ledger export against production events"),
            item(id: "sess-search-19dd", project: "search-service",
                 name: "Index relevance pass", tier: .sonnet, state: .idle,
                 age: 2 * 60 * 60, usage: SessionUsage(inputTokens: 410_000,
                                                       outputTokens: 29_000,
                                                       cacheReadTokens: 860_000),
                 context: 91_000, messages: 28,
                 prompt: "Measure the new ranking weights"),
            item(id: "sess-checkout-8f21/agent-review", project: "checkout-web",
                 name: "Review migration plan", tier: .sonnet, state: .idle,
                 age: 11 * 60, usage: SessionUsage(inputTokens: 180_000,
                                                   outputTokens: 11_000,
                                                   cacheReadTokens: 420_000),
                 context: 62_000, messages: 14,
                 prompt: "Review the migration diff", subagentOf: "sess-checkout-8f21"),
        ]
    }

    private static func seededLineageRows() -> [SessionLineageDisplayRow] {
        let parentKey = "claude:local:sess-checkout-8f21"
        let parentTitle = "Release checkout redesign"
        let counts = SessionLineageCounts(
            subagents: 1, remoteTasks: 1, codex: 1, imports: 1, heuristic: 1)
        func child(
            _ id: String, provider: Provider, title: String,
            edge: LineageEdgeKind, confidence: LineageConfidence = .deterministic,
            age: TimeInterval, duration: TimeInterval?, cost: Double,
            metadataOnly: Bool = false, detail: String? = nil
        ) -> SessionLineageDisplayRow {
            SessionLineageDisplayRow(
                id: "\(edge.label):\(id)", sessionID: id, provider: provider,
                project: "checkout-web", cwd: "/Users/dev/Developer/checkout-web",
                title: title, tier: provider == .codex ? .codex : .sonnet,
                model: provider == .codex ? "gpt-5.4" : "claude-sonnet-4-6",
                lastActivity: now.addingTimeInterval(-age), duration: duration,
                cost: cost, machineID: Machine.localID, isRemote: false,
                isActive: false, isContextHeavy: false,
                isMetadataOnly: metadataOnly,
                transcriptNote: metadataOnly
                    ? "Only spawn metadata is stored locally for this task." : nil,
                edgeKind: edge, confidence: confidence, edgeDetail: detail,
                spawnDepth: 1, displayDepth: 1,
                parentKey: parentKey, parentTitle: parentTitle,
                parentMissingNote: nil, hasChildren: false,
                descendantCounts: SessionLineageCounts(), totalDescendantCost: 0,
                isContextOnly: false)
        }
        return [
            SessionLineageDisplayRow(
                id: parentKey, sessionID: "sess-checkout-8f21", provider: .claude,
                project: "checkout-web", cwd: "/Users/dev/Developer/checkout-web",
                title: parentTitle, tier: .opus, model: "claude-opus-4-8",
                lastActivity: now.addingTimeInterval(-7 * 60), duration: nil,
                cost: 24.38, machineID: Machine.localID, isRemote: false,
                isActive: false, isContextHeavy: true, isMetadataOnly: false,
                transcriptNote: nil, edgeKind: nil, confidence: nil,
                edgeDetail: nil, spawnDepth: 0, displayDepth: 0,
                parentKey: nil, parentTitle: nil, parentMissingNote: nil,
                hasChildren: true, descendantCounts: counts,
                totalDescendantCost: 12.74, isContextOnly: false),
            child("sess-checkout-8f21/agent-review", provider: .claude,
                  title: "Review migration plan", edge: .subagent,
                  age: 11 * 60, duration: 4 * 60, cost: 2.18),
            child("session_remote_42", provider: .claude,
                  title: "Cloud compatibility sweep", edge: .remoteTask,
                  age: 9 * 60, duration: nil, cost: 0, metadataOnly: true,
                  detail: "Ultraplan remote task"),
            child("codex-spawn-92a1", provider: .codex,
                  title: "Validate rollback SQL", edge: .codexSpawn,
                  age: 8 * 60, duration: 6 * 60, cost: 6.42,
                  detail: "Verifier"),
            child("codex-import-77d0", provider: .codex,
                  title: "Imported plan context", edge: .importBridge,
                  age: 7 * 60, duration: nil, cost: 0, metadataOnly: true,
                  detail: "Imported from Claude session sess-che"),
            child("codex-exec-heuristic", provider: .codex,
                  title: "Migration smoke tests", edge: .orchestrated,
                  confidence: .heuristic, age: 6 * 60,
                  duration: 3 * 60, cost: 4.14,
                  detail: "linked by workspace + timing"),
        ]
    }

    fileprivate static func transcriptEvents() -> [TranscriptEvent] {
        let receipt = #"""
        {
          "migration": {
            "environment": "production",
            "command": "bun run db:migrate --production",
            "approval": "required",
            "checks": ["backup-ready", "plan-reviewed"]
          }
        }
        """#
        return [
            TranscriptEvent(id: "event-1", timestamp: now.addingTimeInterval(-92),
                            kind: .userPrompt("Run the production migration after approval")),
            TranscriptEvent(id: "event-2", timestamp: now.addingTimeInterval(-78),
                            kind: .assistantText("I verified the migration plan and isolated the write step.")),
            TranscriptEvent(id: "event-3", timestamp: now.addingTimeInterval(-61),
                            kind: .toolUse(name: "Bash", detail: "bun run db:migrate --production")),
            TranscriptEvent(id: "event-4", timestamp: now.addingTimeInterval(-58),
                            kind: .toolResult(preview: receipt,
                                              isError: false)),
            TranscriptEvent(id: "event-5", timestamp: now.addingTimeInterval(-47),
                            kind: .assistantText("The migration is ready. Approve the command when you want me to continue.")),
        ]
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let services = AppServices()
        services.now = now
        let content = SessionsRenderContent(
            items: seededItems(),
            selectedID: "sess-checkout-8f21",
            transcriptEvents: transcriptEvents(),
            lineageRows: seededLineageRows())
            .frame(width: 1180, height: 760, alignment: .topLeading)
            .environmentObject(services)
        writePNG(content, to: path, dark: dark,
                 width: 1180 + Theme.renderInset * 2)
    }
}

// MARK: - Populated conversation-search render (`--render-search`)

/// The production snippet-row component in an explicit populated search state.
/// All strings are synthetic; both providers and the exact scope disclosure are
/// visible without reading a real transcript corpus.
enum SearchRender {
    private static let now = SessionsRender.now

    private static func result(
        id: String, provider: Provider, project: String,
        age: TimeInterval, role: String, text: String,
        terms: [String], phrase: Bool
    ) -> SearchResult {
        var highlights: [SearchHighlight] = []
        for term in terms {
            if let range = text.range(of: term, options: .caseInsensitive) {
                highlights.append(SearchHighlight(
                    start: text.distance(from: text.startIndex, to: range.lowerBound),
                    length: text.distance(from: range.lowerBound, to: range.upperBound)))
            }
        }
        return SearchResult(
            candidate: SearchCandidate(
                id: id, provider: provider, project: project,
                cwd: "/fixture/\(project)",
                title: "Synthetic search fixture", filePath: "/fixture/\(id).jsonl",
                lastActivity: now.addingTimeInterval(-age),
                score: phrase ? 1_080 : 76, exactPhrase: phrase,
                matchedConversationText: true),
            snippet: SearchSnippet(
                text: text, highlights: highlights.sorted { $0.start < $1.start },
                role: role))
    }

    private static var results: [SearchResult] {
        [
            result(
                id: "search-claude-1", provider: .claude,
                project: "desktop-client", age: 8 * 60, role: "You",
                text: "Check the Keychain quota behavior before the release build.",
                terms: ["Keychain", "quota"], phrase: true),
            result(
                id: "search-codex-2", provider: .codex,
                project: "account-service", age: 27 * 60, role: "Assistant",
                text: "The quota guard now reports a bounded Keychain write failure.",
                terms: ["quota", "Keychain"], phrase: false),
            result(
                id: "search-claude-3", provider: .claude,
                project: "release-tools", age: 3 * 3_600, role: "Assistant",
                text: "I documented the Keychain storage quota and its retry path.",
                terms: ["Keychain", "quota"], phrase: false),
        ]
    }

    @MainActor
    private static func panel(pending: Bool) -> some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sessions")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.ink)
                    Text("Search titles, paths, and conversation text · user and assistant prose only")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(Theme.Typography.metadataMedium)
                        .foregroundStyle(Theme.muted)
                    Text(pending ? "keychain quota retry" : "keychain quota")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                }
                .padding(.horizontal, Theme.intraCell)
                .padding(.vertical, Theme.rhythm)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .fill(Theme.codeFill)
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
                }
                if pending {
                    HStack(spacing: Theme.rhythm) {
                        Image(systemName: "arrow.clockwise")
                            .font(Theme.Typography.metadataMedium)
                            .foregroundStyle(Theme.muted)
                        Text("Searching…")
                            .font(Theme.Typography.metadataMedium)
                            .foregroundStyle(Theme.ink)
                        Text("Showing previous results")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("0 title/path matches")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(Theme.gutter)

            Divider()

            VStack(alignment: .leading, spacing: Theme.micro) {
                Text("In conversation text")
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.ink)
                Text("User prompts and assistant prose · tool output excluded")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, Theme.rhythm)
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    SearchResultRow(
                        result: result, isSelected: index == 0,
                        now: now, onSelect: {})
                }
            }
            .padding(Theme.gutter)
            .opacity(pending ? 0.52 : 1)
        }
        .frame(width: 620, height: 560, alignment: .topLeading)
        .background(Theme.surfaceWindow)
        return content
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        writePNG(panel(pending: false), to: path, dark: dark,
                 width: 620 + Theme.renderInset * 2)
    }

    @MainActor
    static func runPending(to path: String, dark: Bool) {
        writePNG(panel(pending: true), to: path, dark: dark,
                 width: 620 + Theme.renderInset * 2)
    }
}

// MARK: - Menu-bar popover headless render (`--render-menubar`)

/// A deterministic MenuBarModel fed into the same MenuBarPanel used by the live
/// MenuBarExtra. The still covers blocked and waiting rows plus time/quota
/// signals while the fleet line records the concurrent running work.
enum MenuBarRender {
    private static func row(id: String, title: String, project: String,
                            age: TimeInterval, tier: ModelTier) -> MenuBarModel.AttentionRow {
        MenuBarModel.AttentionRow(
            id: id,
            title: title,
            project: project,
            cwd: "/tmp/trifola-render/\(project)",
            lastUserMessage: nil,
            age: age,
            tier: tier,
            classifierConfidence: .high,
            classifierReason: "deterministic visual fixture")
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let items = SessionsRender.seededItems()
        let sessionsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.session) })
        let model = MenuBarModel(
            glyph: .needsYou(blockedCount: 1),
            title: "1",
            fleetLine: "1 blocked · 1 waiting · 2 running · $84 today",
            blocked: [row(id: "sess-checkout-8f21", title: "Release checkout redesign",
                          project: "checkout-web", age: 7 * 60, tier: .opus)],
            waiting: [row(id: "sess-ios-41bc", title: "Polish onboarding transitions",
                          project: "mobile-app", age: 3 * 60, tier: .sonnet)],
            jeopardy: MenuBarModel.JeopardyLine(
                projectKey: "checkout-web", countdown: "18h", stateLabel: "At risk"),
            quotaLine: "Session (5h) 86% used · resets 42m")

        let services = AppServices()
        services.now = SessionsRender.now
        let content = MenuBarPanel(model: model, sessionsByID: sessionsByID)
            .environmentObject(services)
        writePNG(content, to: path, dark: dark,
                 width: Theme.Layout.menuWidth + Theme.renderInset * 2)
    }
}

// MARK: - Permanent full-window layout render (`--render-layout`)

/// The production rail + scaffold + Overview hero at the two launch widths the
/// design review judges. This is intentionally permanent: a temporary projection drifted
/// from the shipped rail and silently reintroduced both the gray slab and a greedy
/// KPI card.
enum LayoutRender {
    private static func live(_ id: String, _ project: String, _ title: String,
                             tier: ModelTier, now: Date) -> SessionSummary {
        SessionSummary(id: id, project: project, cwd: "/Users/dev/Developer/\(project)",
                       model: tier.rawValue, lastActivity: now.addingTimeInterval(-24),
                       messageCount: 18, usage: SessionUsage(inputTokens: 48_000),
                       contextWeight: 118_000, filePath: "/tmp/\(id).jsonl",
                       lastUserMessage: title)
    }

    fileprivate struct WindowSnapshot: View {
        let viewportWidth: CGFloat
        let now: Date

        private var burn: BurnGovernor {
            BurnGovernor(sessions: BurnRender.seededSessions(now: now), now: now)
        }
        private var liveSessions: [SessionSummary] {
            [live("layout-a", "my-app", "Build the Fleet Board", tier: .opus, now: now),
             live("layout-b", "mobile-app", "Fix the chat view layout", tier: .sonnet, now: now),
             live("layout-c", "api-gateway", "Run the gateway test suite", tier: .user, now: now)]
        }
        private var tierStats: [TierStat] {
            [TierStat(tier: .opus, tokens: 68_000_000, cost: 6214, sessions: 4120),
             TierStat(tier: .codex, tokens: 12_100_000, cost: 1792, sessions: 161),
             TierStat(tier: .sonnet, tokens: 29_100_000, cost: 394, sessions: 1068),
             TierStat(tier: .haiku, tokens: 8_800_000, cost: 142, sessions: 188)]
        }

        var body: some View {
            let contentWidth = viewportWidth - Theme.Layout.sidebarWidth - 1
            let sidebar = SidebarSnapshot(
                selected: .overview,
                worstState: .blocked,
                liveCount: 7,
                pendingLessonCount: 0,
                todayCost: burn.today.cost,
                monthProjection: burn.monthProjection,
                updatedText: "updated now",
                refreshText: nil,
                account: "local account",
                machine: "this Mac")

            HStack(spacing: 0) {
                SidebarRail(snapshot: sidebar)
                    .frame(width: Theme.Layout.sidebarWidth)
                    .background(Theme.surfaceSidebar)
                Divider()
                ScreenScaffold(
                    title: "Overview",
                    subtitle: "6,166 sessions across 42 projects · refreshed now · dollar values are API-rate estimates, not your bill",
                    scrolls: false,
                    trailing: {
                        QuietTapButton(action: {}) {
                            HStack(spacing: Theme.rhythm) {
                                RefreshActivityGlyph(working: false)
                                Text("Refresh")
                            }
                        }
                    }) {
                    VStack(alignment: .leading, spacing: Theme.blockGap) {
                        VStack(alignment: .leading, spacing: Theme.intraCell) {
                            Text("2 sessions need you · \(fmtUSD(burn.today.cost)) today at public API rates")
                                .font(.title3)
                                .foregroundStyle(Theme.ink)
                            HStack(spacing: Theme.intraCell) {
                                ArtifactPill(icon: "square.grid.3x3", name: "Fleet Board") {}
                                ArtifactPill(icon: "doc.text.magnifyingglass", name: "Audit evidence") {}
                            }
                        }
                        .frame(maxWidth: ScreenScaffoldMetrics.proseMaxWidth, alignment: .leading)
                        OverviewHeroComposition(snapshot: OverviewHeroSnapshot(
                            usageValue: "$8,542",
                            usageReading: "estimate from recorded usage — not your bill",
                            activeCount: 7,
                            activeReading: "sessions in the last 15m",
                            savingsValue: "$3,214",
                            savingsReading: "vs. uncached input at API rates",
                            governor: burn,
                            tierStats: tierStats,
                            tierTotal: 8_542,
                            topModelsByID: [
                                // Codex expands into its member models; a tier
                                // with one id stays single-line.
                                ModelSpendStat(
                                    provider: .codex, model: "gpt-5.6-sol",
                                    usage: SessionUsage(inputTokens: 9_200_000,
                                                        outputTokens: 610_000),
                                    cost: 1_490, sessions: 118),
                                ModelSpendStat(
                                    provider: .codex, model: "gpt-5.6-terra",
                                    usage: SessionUsage(inputTokens: 2_100_000,
                                                        outputTokens: 140_000),
                                    cost: 240, sessions: 31),
                                ModelSpendStat(
                                    provider: .codex, model: "gpt-5.6-luna",
                                    usage: SessionUsage(inputTokens: 800_000,
                                                        outputTokens: 40_000),
                                    cost: 62, sessions: 12),
                            ],
                            liveSessions: liveSessions))
                    }
                }
                .frame(width: contentWidth, height: 900, alignment: .top)
                .background(Theme.surfaceWindow)
            }
            .frame(width: viewportWidth, height: 900)
            .background(Theme.surfaceWindow)
        }
    }

    @MainActor
    static func run(base: String) {
        let now = Date()
        for width: CGFloat in [1440, 1680] {
            for dark in [true, false] {
                let mode = dark ? "dark" : "light"
                let path = "\(base)-\(Int(width))-\(mode).png"
                write(WindowSnapshot(viewportWidth: width, now: now),
                      to: path, dark: dark, width: width, height: 900)
            }
        }
    }

    @MainActor
    private static func write<V: View>(_ content: V, to path: String, dark: Bool,
                                       width: CGFloat, height: CGFloat) {
        let framed = content
            .frame(width: width, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.displayScale, 2)
            .environment(\.doorLightReduceMotionOverride, true)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let image = rendered, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("layout render failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("RENDER: \(path)")
    }
}

// MARK: - Fullscreen strengthening matrix (`--render-strengthen`)

/// Six real product surfaces at the three launch-review widths, in both
/// appearances. The matrix is a viewport test rather than a poster generator:
/// every image includes the production rail, production screen chrome, and a
/// deterministic synthetic fixture. At @2x backing scale the filenames retain
/// logical window widths, matching the existing layout render convention.
@MainActor
enum StrengthenRender {
    private static let now = Date(timeIntervalSince1970: 1_752_000_000)

    private struct MatrixWindow<Content: View>: View {
        let selected: AppSection
        let width: CGFloat
        @ViewBuilder let content: () -> Content

        private var sidebar: SidebarSnapshot {
            SidebarSnapshot(
                selected: selected,
                worstState: .blocked,
                liveCount: 7,
                pendingLessonCount: 4,
                todayCost: 659.43,
                monthProjection: 9_420,
                updatedText: "updated now",
                refreshText: nil,
                account: "local account",
                machine: "this Mac",
                animatesSelection: false)
        }

        var body: some View {
            HStack(spacing: 0) {
                SidebarRail(snapshot: sidebar)
                    .frame(width: Theme.Layout.sidebarWidth)
                    .background(Theme.surfaceSidebar)
                Divider()
                content()
                    .frame(width: width - Theme.Layout.sidebarWidth - 1,
                           height: CGFloat(StrengthenRenderMatrix.viewportHeight),
                           alignment: .top)
                    .background(Theme.surfaceWindow)
            }
            .frame(width: width,
                   height: CGFloat(StrengthenRenderMatrix.viewportHeight))
            .background(Theme.surfaceWindow)
        }
    }

    static func run(directory: String) {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data(
                "trifola: could not create strengthen render directory: \(error)\n".utf8))
            return
        }

        for entry in StrengthenRenderMatrix.entries(directory: directory) {
            render(entry)
        }
        renderSpotchecks(directory: directory)
    }

    private static func render(
        _ entry: StrengthenRenderEntry,
        selectedSessionID: String = "sess-checkout-8f21"
    ) {
        let width = CGFloat(entry.width)
        let dark = entry.theme == .dark
        let view: AnyView

        switch entry.surface {
        case .layout:
            view = AnyView(LayoutRender.WindowSnapshot(viewportWidth: width, now: now))

        case .sessions:
            let services = AppServices()
            services.now = SessionsRender.now
            let snapshots = NavigationSnapshotStore()
            let content = SessionsRenderContent(
                items: SessionsRender.seededItems(),
                selectedID: selectedSessionID,
                transcriptEvents: SessionsRender.transcriptEvents())
                .environmentObject(services)
                .environmentObject(services.navigation)
                .environmentObject(snapshots)
            view = AnyView(MatrixWindow(selected: .sessions, width: width) { content })

        case .fleet:
            let seeded = FleetRender.seeded(now: now)
            // ImageRenderer cannot realize an unbounded ScrollView. The matrix
            // is a fixed viewport, so compose the production floor eagerly and
            // let MatrixWindow clip at the requested 900pt height.
            let content = FleetFloor(board: seeded.board,
                                     attention: seeded.attention,
                                     signals: seeded.signals)
                .screenScaffoldFrame()
            view = AnyView(MatrixWindow(selected: .fleet, width: width) { content })

        case .audit:
            let content = ScreenScaffold(
                title: "Audit",
                subtitle: "Ranked cost causes from recorded usage · public API-rate estimates, never your bill",
                epithet: "evidence, not nags",
                scrolls: false) {
                    AuditContent(report: AuditRender.seededReport(),
                                 onInspect: { _ in }, onReveal: { _ in })
                }
            view = AnyView(MatrixWindow(selected: .audit, width: width) { content })

        case .ledger:
            let seeded = LedgerRender.seeded(now: now)
            let content = ScreenScaffold(
                title: "Dreaming Ledger",
                subtitle: "Deterministic proposals from audit evidence · copy only, never writes your configuration",
                epithet: "findings become fixes",
                scrolls: false,
                trailing: { DreamNowButton() }) {
                    LedgerContent(
                        dream: seeded.dream,
                        pending: seeded.pending,
                        history: seeded.history,
                        showHistory: .constant(true),
                        onCopy: { _ in }, onReveal: { _ in },
                        onInspect: { _ in }, onKeep: { _ in },
                        onDismiss: { _ in })
                }
            view = AnyView(MatrixWindow(selected: .ledger, width: width) { content })

        case .spend:
            let sessions = spendSessions()
            let corpus = CorpusProjection(sessions: sessions, now: now)
            let services = AppServices()
            services.now = now
            let snapshots = NavigationSnapshotStore(initialCorpus: corpus)
            let content = SpendScreen(scrolls: false)
                .environmentObject(services)
                .environmentObject(snapshots)
            view = AnyView(MatrixWindow(selected: .spend, width: width) { content })
        }

        writeViewport(view, to: entry.outputPath, dark: dark,
                      width: width,
                      height: CGFloat(StrengthenRenderMatrix.viewportHeight))
    }

    /// Supplemental acceptance evidence for the window-policy requirements that
    /// sit outside the hard 36-cell comparison matrix: minimum/default sizing,
    /// both compact Sessions panes, and a roughly 3360pt fullscreen canvas.
    private static func renderSpotchecks(directory: String) {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("spotchecks", isDirectory: true)
        try? FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)

        for theme in StrengthenRenderTheme.allCases {
            let suffix = theme.rawValue
            let entries: [(StrengthenRenderSurface, Int, String, String?)] = [
                (.sessions, 1_120, "sessions-min-list-1120-\(suffix).png", "missing-selection"),
                (.sessions, 1_120, "sessions-min-detail-1120-\(suffix).png", "sess-checkout-8f21"),
                (.layout, 1_440, "layout-default-1440-\(suffix).png", nil),
                (.layout, 3_360, "layout-fullscreen-3360-\(suffix).png", nil),
                (.sessions, 3_360, "sessions-fullscreen-3360-\(suffix).png", "sess-checkout-8f21"),
            ]
            for (surface, width, filename, selection) in entries {
                let entry = StrengthenRenderEntry(
                    surface: surface,
                    width: width,
                    theme: theme,
                    outputPath: root.appendingPathComponent(filename).path)
                render(entry, selectedSessionID: selection ?? "sess-checkout-8f21")
            }
        }
    }

    private static func spendSessions() -> [SessionSummary] {
        let projects = ["checkout-web", "mobile-app", "api-gateway", "billing-worker",
                        "docs-site", "search-service"]
        let tiers: [ModelTier] = [.opus, .sonnet, .user, .opus, .haiku, .sonnet]
        return (0..<24).map { index in
            let project = projects[index % projects.count]
            let tier = tiers[index % tiers.count]
            let inputTokens = 120_000 + index * 17_000
            let outputTokens = 18_000 + index * 1_900
            let cacheReadTokens = 280_000 + index * 31_000
            let cacheCreateTokens = 14_000 + index * 900
            let usage = SessionUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreateTokens: cacheCreateTokens,
                cacheReadTokens: cacheReadTokens)
            return SessionSummary(
                id: "spend-\(index)", project: project,
                cwd: "/tmp/trifola-render/\(project)", model: tier.rawValue,
                lastActivity: now.addingTimeInterval(-Double(index) * 3_600),
                messageCount: 18 + index, usage: usage,
                contextWeight: 72_000 + index * 5_000,
                filePath: "/tmp/trifola-render/spend-\(index).jsonl",
                lastUserMessage: "Synthetic render fixture for \(project)")
        }
    }

    private static func writeViewport<V: View>(
        _ content: V,
        to path: String,
        dark: Bool,
        width: CGFloat,
        height: CGFloat
    ) {
        let framed = content
            .frame(width: width, height: height)
            .clipped()
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.displayScale, 2)
            .environment(\.doorLightReduceMotionOverride, true)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        var rendered: NSImage?
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { rendered = renderer.nsImage }
        guard let image = rendered,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data(
                "strengthen render failed: \(path)\n".utf8))
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("RENDER: \(path)")
        } catch {
            FileHandle.standardError.write(Data(
                "strengthen render write failed: \(path): \(error)\n".utf8))
        }
    }
}

// MARK: - Credit-era burn governor headless render (`--render-burn`)
// Rasterizes the REAL burn tile + per-day sparkline (`BurnGovernorSection`) over a
// seeded ~30-day corpus of dated sessions, so the Jul-7 countdown's successor can
// be Read + judged without a window/Space: today's API-equiv burn, its Opus share,
// the recent-run-rate month projection, and the tier-colored per-day bars (the
// evidence grammar). Litmus: restrained, the "API-equiv, not your bill" label is
// unmissable, no red panic / no nag, tier hues match the spend-split bar.

enum BurnRender {

    private static func sess(_ n: Int, back: Int, tier: ModelTier, cost: Double,
                             cal: Calendar, today: Date) -> SessionSummary? {
        guard let d0 = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
        let at = cal.date(bySettingHour: 11, minute: 20, second: 0, of: d0) ?? d0
        let inp = Int(cost / max(tier.rates.inp, 0.001) * 1_000_000)
        let u = SessionUsage(inputTokens: inp)
        return SessionSummary(id: "burn-\(n)", project: "proj", cwd: "/tmp/proj",
                              model: tier.rawValue, lastActivity: at, messageCount: 8,
                              usage: u, contextWeight: 120_000, usageByTier: [tier: u])
    }

    /// A believable month: quiet + spotty early, ramping into a heavy recent week,
    /// Opus-dominant with a Custom/Sonnet/Haiku mix — and a lighter (partial) TODAY,
    /// honestly below the run-rate. Several empty days keep the quiet-day ticks.
    static func seededSessions(now: Date) -> [SessionSummary] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        // (daysBack, tier, API-equiv cost) — multiple entries per day = the day's mix.
        let plan: [(Int, ModelTier, Double)] = [
            (0, .opus, 34), (0, .sonnet, 5),                                  // today (partial)
            (1, .opus, 95), (1, .user, 22), (1, .sonnet, 9),
            (2, .opus, 70), (2, .sonnet, 10),
            (3, .opus, 120), (3, .user, 35), (3, .sonnet, 15), (3, .haiku, 4),
            (4, .opus, 30),                                                   // quiet-ish
            (5, .opus, 88), (5, .user, 20), (5, .sonnet, 12),
            (6, .opus, 40), (6, .haiku, 2),
            (7, .opus, 62), (7, .user, 14), (7, .sonnet, 8),
            (9, .opus, 44), (9, .user, 10),
            (10, .sonnet, 18),
            (12, .opus, 30), (12, .haiku, 3),
            (14, .opus, 55), (14, .user, 12),
            (16, .opus, 20),
            (18, .opus, 38), (18, .sonnet, 8),
            (20, .opus, 12),
            (23, .opus, 26), (23, .user, 6),
            (26, .opus, 15),
            (29, .opus, 22), (29, .sonnet, 5),
        ]
        return plan.enumerated().compactMap { i, p in
            sess(i, back: p.0, tier: p.1, cost: p.2, cal: cal, today: today)
        }
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let governor = BurnGovernor(sessions: seededSessions(now: now), now: now)
        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Credit-era burn governor (VISION 2.5) — the Jul-7 countdown's successor: today's API-rate estimate + Opus share + a recent-run-rate month projection, over a per-day tier-colored sparkline. The real BurnGovernorSection over a seeded ~30-day corpus.")
            BurnGovernorSection(governor: governor)
            Divider()
            // A tier legend so the sparkline hues read (same hues as spend-by-tier).
            HStack(spacing: 16) {
                ForEach([ModelTier.opus, .user, .sonnet, .haiku], id: \.self) { t in
                    HStack(spacing: 5) {
                        Circle().fill(t.color).frame(width: 6, height: 6)
                        Text(t.label).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
            }
        }
        writePNG(content, to: path, dark: dark, width: 860)
    }
}

// MARK: - Cost provenance headless render (`--render-provenance`)
// Rasterizes THE TRUST CAPSTONE (W3) — the Burn tile with its receipt EXPANDED:
// per-model legs (deduped token split incl. the 5m/1h cache-write split × the
// exact rate, with the Sonnet-5 effective-date rule visible), Σ = the tile's own
// number via the same code path, and the pricing/dedup/bucketing footers + the
// month-projection formula. Seeded with model-day slices so a date-dependent
// sonnet-5 leg ($2/$10 intro era) and an opus 1h cache-write leg both show.
// Litmus: mono receipt, arithmetic legible, calm (no color drama), no layout
// breakage in either theme.

enum ProvenanceRender {

    /// One session on one LOCAL day with real (model → usage) slices — the W3
    /// shape the receipt prices. Message counts + raw-vs-deduped counts ride
    /// along so the dedup footer reads honestly.
    private static func daySession(n: Int, back: Int, byModel: [String: (SessionUsage, Int)],
                                   cal: Calendar, now: Date) -> SessionSummary? {
        guard let d0 = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: now)) else { return nil }
        let at = back == 0 ? now : (cal.date(bySettingHour: 11, minute: 20, second: 0, of: d0) ?? d0)
        let day = CostProvenance.dayKey(for: at, calendar: cal)
        var usage = SessionUsage()
        var byTier: [ModelTier: SessionUsage] = [:]
        var modelUsage: [String: SessionUsage] = [:]
        var msgs: [String: Int] = [:]
        var deduped = 0
        for (model, (u, m)) in byModel {
            usage = usage + u
            byTier[ModelTier(raw: model)] = (byTier[ModelTier(raw: model)] ?? SessionUsage()) + u
            modelUsage[model] = u
            msgs[model] = m
            deduped += m
        }
        return SessionSummary(
            id: "prov-\(n)", project: "my-app", cwd: "/tmp/cmc",
            model: byModel.keys.sorted().first, lastActivity: at, messageCount: deduped,
            usage: usage, contextWeight: 120_000,
            usageByTier: byTier,
            usageByDay: [day: byTier],
            usageByModel: modelUsage,
            usageByModelDay: [day: modelUsage],
            messagesByModelDay: [day: msgs],
            rawUsageBlocks: Int(Double(deduped) * 2.6))   // the streaming-dedup ratio
    }

    /// A believable recent week — heavier days behind a moderate today, with an
    /// opus 1h cache-write slice and a date-dependent sonnet-5 leg on today.
    static func seededSessions(now: Date) -> [SessionSummary] {
        let cal = Calendar.current
        func opus(_ scale: Double) -> SessionUsage {
            SessionUsage(inputTokens: Int(300_000 * scale), outputTokens: Int(400_000 * scale),
                         cacheCreateTokens: Int(2_400_000 * scale), cacheReadTokens: Int(52_000_000 * scale),
                         cacheCreate1hTokens: Int(900_000 * scale))
        }
        let sonnet = SessionUsage(inputTokens: 308, outputTokens: 139_774,
                                  cacheCreateTokens: 668_618, cacheReadTokens: 18_971_200,
                                  cacheCreate1hTokens: 146_626)
        let haiku = SessionUsage(inputTokens: 48, outputTokens: 980,
                                 cacheCreateTokens: 181_321, cacheReadTokens: 120_106)
        let plan: [(Int, [String: (SessionUsage, Int)])] = [
            (0, ["claude-opus-4-8": (opus(1.0), 412), "claude-sonnet-5": (sonnet, 154),
                 "claude-haiku-4-5": (haiku, 6)]),
            (1, ["claude-opus-4-8": (opus(2.4), 980), "claude-haiku-4-5": (opus(0.3), 45)]),
            (2, ["claude-opus-4-8": (opus(1.6), 610)]),
            (3, ["claude-opus-4-8": (opus(0.7), 280), "claude-sonnet-5": (sonnet, 60)]),
            (4, ["claude-opus-4-8": (opus(1.1), 420)]),
            (5, ["claude-opus-4-8": (opus(0.5), 190)]),
            (6, ["claude-opus-4-8": (opus(0.9), 330)]),
            (7, ["claude-opus-4-8": (opus(1.3), 500)]),
        ]
        return plan.enumerated().compactMap { i, p in
            daySession(n: i, back: p.0, byModel: p.1, cal: cal, now: now)
        }
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let sessions = seededSessions(now: now)
        let governor = BurnGovernor(sessions: sessions, now: now)
        let today = CostProvenance.dayKey(for: now)
        let receipt = CostProvenance.dayReceipt(
            sessions: sessions, dayKey: today,
            footnotes: [CostProvenance.projectionFootnote(governor)])
        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Cost provenance (W3) — the Burn tile with its receipt expanded: per-model legs × exact dated rates → Σ = the tile's own number, same code path")
            BurnGovernorSection(governor: governor,
                                receipt: { receipt },
                                receiptInitiallyExpanded: true)
        }
        writePNG(content, to: path, dark: dark, width: 900)
    }
}

// MARK: - Cross-Machine Fleet headless render (`--render-crossmachine`)
// Rasterizes THE DIFFERENTIATOR — one pane over this Mac + workstation. Shows the
// fleet-wide totals + per-machine roll-up, the calm offline indicator, session rows
// carrying the machine chip (local + workstation), and the REAL Fleet Board Floor with
// machine-tagged bays (the same repo open on both machines reads as two distinct
// bays). snapshot.sh is Space-broken; this is the verification path — Read the PNGs
// and judge: the machine chip reads clearly, the offline indicator is calm.

enum CrossMachineRender {

    private static func sess(id: String, project: String, cwd: String, tier: ModelTier,
                             ageSecs: TimeInterval, cost: Double, machine: String,
                             edits: Int = 0, quote: String? = nil,
                             subagentOf: String? = nil, now: Date) -> SessionSummary {
        let inp = Int(cost / max(tier.rates.inp, 0.001) * 1_000_000)
        let path = subagentOf == nil
            ? "\(cwd)/\(id).jsonl"
            : "\(cwd)/\(subagentOf!)/subagents/agent-\(id.split(separator: "/").last ?? "x").jsonl"
        return SessionSummary(
            id: id, project: project, cwd: cwd, model: tier.rawValue,
            lastActivity: now.addingTimeInterval(-ageSecs), messageCount: 12,
            usage: SessionUsage(inputTokens: inp), contextWeight: 120_000,
            filePath: path, lastUserMessage: quote, fileEdits: edits,
            machineID: machine)
    }

    private static func sig(tool: String? = nil, detail: String = "",
                            kind: AttentionSignals.LastKind, stop: String? = nil,
                            dangling: Bool = false, hasPermissionGate: Bool = false,
                            ageSecs: TimeInterval, now: Date) -> AttentionSignals {
        let at = now.addingTimeInterval(-ageSecs)
        return AttentionSignals(
            lastEventAt: at, lastKind: kind, lastStopReason: stop,
            hasDanglingToolUse: dangling, danglingToolUseAt: dangling ? at : nil,
            lastToolActivityAt: (kind == .toolUse || kind == .toolResult) ? at : nil,
            lastToolName: tool, lastToolDetail: detail.isEmpty ? nil : detail,
            hasPermissionGate: hasPermissionGate)
    }

    static func seeded(now: Date) -> (sessions: [SessionSummary], board: FleetBoard,
                                      attention: AttentionBoard, rollups: [MachineRollup],
                                      statuses: [RemoteStatus],
                                      signals: [String: AttentionSignals]) {
        let cmc = "/Users/dev/Developer/my-app"
        let webapp = "/Users/dev/Developer/webapp"
        let pipelineDC = "/Users/dev/Developer/data-pipeline"
        let webappDC = "/Users/dev/Developer/webapp"
        let auditDC = "/Users/dev/Developer/security-audit"

        let localOpus = "77b3f2a1", localSub = "77b3f2a1/agent-a3c10a89"

        // This Mac.
        let local: [SessionSummary] = [
            sess(id: "0ed7bc81", project: "my-app", cwd: cmc, tier: .user,
                 ageSecs: 3, cost: 3.43, machine: "local", edits: 6,
                 quote: "build the cross-machine fleet", now: now),
            sess(id: localOpus, project: "my-app", cwd: cmc, tier: .opus,
                 ageSecs: 40, cost: 61, machine: "local", edits: 9,
                 quote: "wire the machine merge", now: now),
            sess(id: localSub, project: "my-app", cwd: cmc, tier: .opus,
                 ageSecs: 14, cost: 12, machine: "local", quote: "run the fleet tests",
                 subagentOf: localOpus, now: now),
            sess(id: "b5f4e5e5", project: "webapp", cwd: webapp, tier: .opus,
                 ageSecs: 240, cost: 3.67, machine: "local", edits: 1,
                 quote: "seed db + bun run dev", now: now),
        ]

        // workstation — mirrored READ-ONLY over Tailscale. Same webapp repo lives on both
        // machines → two distinct, machine-tagged bays.
        let remote: [SessionSummary] = [
            sess(id: "c91d22f0", project: "data-pipeline", cwd: pipelineDC, tier: .user,
                 ageSecs: 8, cost: 22, machine: "workstation", edits: 3,
                 quote: "/release-notes nightly", now: now),
            sess(id: "9942ce11", project: "webapp", cwd: webappDC, tier: .opus,
                 ageSecs: 25, cost: 14, machine: "workstation", edits: 2,
                 quote: "auth flow + payments e2e", now: now),
            sess(id: "e2290b7c", project: "security-audit", cwd: auditDC, tier: .sonnet,
                 ageSecs: 70, cost: 4.1, machine: "workstation", edits: 0,
                 quote: "flaky-test triage", now: now),
        ]

        let sessions = FleetMerge.merge(
            local: local,
            remotes: [(Machine(id: "workstation", name: "workstation", isLocal: false), remote)])

        let signals: [String: AttentionSignals] = [
            "0ed7bc81": sig(tool: "Write", detail: "Sources/TrifolaKit/Machine.swift", kind: .toolUse, ageSecs: 3, now: now),
            localOpus: sig(tool: "Edit", detail: "Sources/Trifola/AppServices.swift", kind: .toolResult, ageSecs: 40, now: now),
            localSub: sig(tool: "Bash", detail: "swift test", kind: .toolUse, ageSecs: 14, now: now),
            "b5f4e5e5": sig(tool: "Bash", detail: "approval · bun run dev", kind: .toolUse,
                              dangling: true, hasPermissionGate: true,
                              ageSecs: 240, now: now),
            "c91d22f0": sig(tool: "Bash", detail: "api-client fetch", kind: .toolResult, ageSecs: 8, now: now),
            "9942ce11": sig(tool: "WebFetch", detail: "docs.example.com/api", kind: .toolResult, ageSecs: 25, now: now),
            "e2290b7c": sig(kind: .assistantText, stop: "end_turn", ageSecs: 70, now: now),
        ]

        var ledger = ArrivalLedger()
        for s in sessions.sorted(by: { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }) {
            _ = ledger.claim(FleetBoard.bayKey(s)); _ = ledger.claim(s.id)
        }
        let board = FleetBoard.build(sessions: sessions, signals: signals, now: now, arrival: ledger).board
        let attention = AttentionBoard.build(sessions: sessions, signals: signals, now: now)

        let machines = [Machine.local, Machine(id: "workstation", name: "workstation", isLocal: false)]
        let rollups = FleetMerge.rollups(sessions, machines: machines)

        // workstation ONLINE (mirrored 3m ago); a second configured remote OFFLINE — so
        // both the online roll-up and the calm offline indicator read in one frame.
        let statuses: [RemoteStatus] = [
            RemoteStatus(machine: Machine(id: "workstation", name: "workstation", isLocal: false),
                         reachable: .reachable, hasMirror: true,
                         lastSynced: now.addingTimeInterval(-180), lastError: nil,
                         sessionCount: remote.count),
            RemoteStatus(machine: Machine(id: "mac-mini", name: "mac-mini", isLocal: false),
                         reachable: .unreachable, hasMirror: false,
                         lastSynced: nil, lastError: "unreachable", sessionCount: 0),
        ]
        return (sessions, board, attention, rollups, statuses, signals)
    }

    private struct FleetRow: View {
        let s: SessionSummary
        var body: some View {
            HStack(spacing: 8) {
                SeatMark(state: s.isActive ? .running : .idle, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(s.displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                        MachineChip(machineID: s.machineID)
                    }
                    Text("\(s.tier.label) · \(s.messageCount) msgs · \(fmtAgo(s.lastActivity))")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Text(fmtUSD(s.cost)).font(.subheadline).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, Theme.codePadding).padding(.vertical, Theme.toastVerticalInset)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let (sessions, board, attention, rollups, statuses, signals) = seeded(now: now)
        let totalSessions = rollups.reduce(0) { $0 + $1.sessionCount }
        let totalCost = rollups.reduce(0) { $0 + $1.cost }
        let online = statuses.filter { $0.isOnline }
        let offline = statuses.filter { !$0.isOnline }

        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Cross-Machine Fleet — one pane over this Mac + workstation, read-only over Tailscale (seeded)")

            // Fleet-wide totals + per-machine roll-up.
            HStack(spacing: 8) {
                SectionLabel("Fleet")
                Text("\(rollups.count) machines · \(totalSessions) sessions · \(fmtUSD(totalCost)) today")
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer()
            }
            VStack(spacing: 6) {
                ForEach(rollups) { r in
                    HStack(spacing: 8) {
                        MachineChip(machineID: r.machine.id)
                        Text(r.machine.name).font(.subheadline).foregroundStyle(Theme.ink)
                        if r.activeCount > 0 {
                            Text("\(r.activeCount) active").font(.caption).foregroundStyle(Theme.green)
                        }
                        Spacer()
                        Text("\(r.sessionCount) sessions · \(fmtTokens(r.tokens)) tokens").font(.caption).foregroundStyle(Theme.faint)
                        Text(fmtUSD(r.cost)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
            }
            // Calm indicators — workstation online, a second remote offline.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(online) { RemoteStatusLine(status: $0) }
                ForEach(offline) { RemoteStatusLine(status: $0) }
            }
            Divider()

            // Session rows carrying the machine chip (local + workstation).
            RenderCaption("Sessions — each row tagged by machine")
            VStack(spacing: 6) {
                ForEach(Array(sessions.filter { !$0.isSubagent }.prefix(7))) { FleetRow(s: $0) }
            }
            Divider()

            // The real Floor — machine-tagged bays (webapp shows on BOTH machines as
            // two distinct bays).
            FleetFloor(board: board, attention: attention, signals: signals)
        }
        writePNG(content, to: path, dark: dark, width: 1080)
    }
}

// MARK: - Session Builder headless render (`--render-launch`)
// Rasterizes the REAL builder components (CommandPreview + RecipeCardView) with a
// seeded recipe so the composed command — incl. the opus model pin — is visible +
// judgeable without a window/Space. No ScrollView (ImageRenderer can't size one).

enum LaunchRender {

    static func seededDraft() -> Recipe {
        Recipe(id: "seed-crypto",
               name: "release-notes run",
               cwd: "/Users/dev/Developer/data-pipeline",
               addDirs: ["/Users/dev/Developer/notes-app"],
               agents: [
                RecipeAgent(name: "researcher", description: "Deep opportunity researcher",
                            prompt: "You research live crypto earning opportunities.", model: .opus),
                RecipeAgent(name: "critic", description: "Adversarial reviewer",
                            prompt: "You stress-test the researcher's findings.", model: .opus),
                RecipeAgent(name: "vision", description: "Design/taste panel",
                            prompt: "You judge product taste.", model: .sonnet),
               ],
               effort: .high, permissionMode: .plan, background: false,
               skillRefs: ["release-notes", "api-client"], leadSkill: "release-notes")
    }

    static func savedRecipes() -> [Recipe] {
        [
            Recipe(id: "s0", name: "review + verify",
                   cwd: "/Users/dev/Developer/webapp",
                   agents: [
                    RecipeAgent(name: "reviewer", description: "Code reviewer", prompt: "Review the diff.", model: .opus),
                    RecipeAgent(name: "verifier", description: "Build + test", prompt: "Build and run the tests.", model: .sonnet),
                   ],
                   effort: .high, permissionMode: .plan, background: false,
                   prompt: "Review the open PR and verify the build.",
                   skillRefs: ["code-review"], leadSkill: "code-review"),
            Recipe(id: "s1", name: "iOS build loop",
                   cwd: "/Users/dev/Developer/mobile-app",
                   agents: [RecipeAgent(name: "builder", description: "SwiftUI builder", prompt: "Build + verify.", model: .opus)],
                   effort: .high, permissionMode: .acceptEdits,
                   skillRefs: ["mobile-app-ios", "ios-screenshot-loop"], leadSkill: "mobile-app-ios"),
            Recipe(id: "s2", name: "audit run",
                   cwd: "/Users/dev/Developer/security-audit",
                   agents: [RecipeAgent(name: "auditor", description: "Security auditor", prompt: "Audit contracts.", model: .opus)],
                   effort: .xhigh, permissionMode: .standard,
                   skillRefs: ["x-ray", "sql-tuner", "fizz"], leadSkill: "x-ray"),
        ]
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let draft = seededDraft()
        let promptPath = "~/Library/Application Support/Trifola/recipes/prompts/seed-crypto.txt"
        let cmd = RecipeComposer.compose(draft, promptFilePath: promptPath)

        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Launch · the Session Builder — the real form projection, command preview + recipe cards")
            HStack(alignment: .top, spacing: 24) {
                RecipeFormProjection(recipe: draft).frame(width: 470, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    CommandPreview(recipe: draft, command: cmd)
                    // The screen's one verb, in-frame, directly under the composed
                    // command (UI_GRIND LNC-1) — the real shared button.
                    LaunchVerb()
                    Divider()
                    Eyebrow("Saved recipes")
                    ForEach(savedRecipes()) { RecipeCardView(recipe: $0) }
                }
                .frame(width: 460, alignment: .leading)
            }
        }
        writePNG(content, to: path, dark: dark, width: 1040)
    }
}

// A read-only projection of the builder form (the live screen uses editable
// controls; this shows the same fields legibly for the headless render).
private struct RecipeFormProjection: View {
    let recipe: Recipe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("Name", recipe.name)
            field("Working dir (--add-dir for extras)", recipe.cwd)
            SectionLabel("Agents (--agents · model pins)")
            ForEach(recipe.agents) { a in
                HStack(spacing: 8) {
                    Text(a.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).frame(width: 90, alignment: .leading)
                    Text(a.model.rawValue).font(.caption.weight(.medium))
                        .foregroundStyle(a.model.tier.color)
                    Text(a.description).font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
                }
                .padding(Theme.intraCell)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
            }
            HStack(spacing: 16) {
                field("Effort", recipe.effort.label)
                field("Permission", recipe.permissionMode.label)
                // The app speaking → title case like its siblings (UI_GRIND LNC-4).
                field("Background", recipe.background ? "On" : "Off")
            }
            SectionLabel("Skills (runtime hint, not an install)")
            Text("★ = lead skill, named first in the prompt hint.")
                .font(.caption2).foregroundStyle(Theme.faint)
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(recipe.skillRefs, id: \.self) { r in
                    SkillRefChip(ref: r, isLead: recipe.resolvedLeadSkill == r)
                }
            }
        }
    }
    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.faint)
            Text(value).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
        }
    }
}

// MARK: - Skill hierarchy headless render (`--render-skills`)
// Rasterizes the REAL hierarchy components (lane stats · collisions · lane tree)
// with a seeded multi-lane skill set + ledger so the structure is visible without
// a window/Space. Bounded VStack (no ScrollView) per the ImageRenderer constraint.

enum SkillsRender {

    private static func sk(_ id: String, _ desc: String, triggers: [String] = [],
                           source: SkillSource = .user, name: String? = nil) -> Skill {
        Skill(id: id, name: name ?? id, description: desc, version: nil, triggers: triggers,
              allowedTools: [], hasManifest: true, wordCount: 400, fileCount: 1,
              modified: Date(), path: "/seed/\(source.pluginName ?? "user")/\(id)", source: source)
    }

    static func seededSkills() -> [Skill] {
        let plugin = { (m: String, p: String) in SkillSource.plugin(marketplace: m, plugin: p, version: "1.0.0") }
        return [
            // User — gstack family (collision on "take a screenshot"), a prefix
            // family (datakit-*), and standalones.
            sk("browse", "Fast headless browser for QA testing. (gstack)", triggers: ["take a screenshot", "browse this page"]),
            sk("qa", "Systematically QA test a web app. (gstack)", triggers: ["take a screenshot", "run qa"]),
            sk("codex", "OpenAI Codex CLI wrapper. (gstack)"),
            sk("datakit-export", "Animation knowledge for DataKit."),
            sk("datakit-core", "The DataKit composition contract."),
            sk("datakit-query", "Audio + media assets for DataKit."),
            sk("api-client", "MUST USE when researching anything on the internet.", triggers: ["deep dive", "research this topic"]),
            sk("release-notes", "Sweep every live crypto earning opportunity."),
            sk("graphify", "Any input to a knowledge graph."),
            // Plugin lane (was invisible to the flat scanner).
            sk("codex-cli-runtime", "Codex CLI runtime.", source: plugin("openai-codex", "codex"), name: "codex-cli-runtime"),
            sk("rescue", "Hand a stuck task to Codex.", source: plugin("openai-codex", "codex"), name: "rescue"),
            sk("access", "iMessage access.", source: plugin("claude-plugins-official", "imessage"), name: "access"),
            sk("configure", "iMessage configure.", source: plugin("claude-plugins-official", "imessage"), name: "configure"),
            // Project lane.
            sk("deploy", "Project deploy skill.", source: .project(dir: "/Users/dev/Developer/webapp/.claude/skills"), name: "deploy"),
        ]
    }

    static func seededLedger(_ skills: [Skill]) -> [String: SkillLedgerEntry] {
        let now = Date()
        func fired(_ key: String, _ n: Int, _ ago: TimeInterval, _ sess: Int) -> (String, SkillLedgerEntry) {
            (key, SkillLedgerEntry(name: key, invocations: n, sessionsTouched: sess,
                                   lastFired: now.addingTimeInterval(-ago), inCatalog: true, descriptionTokens: 0))
        }
        func dead(_ key: String) -> (String, SkillLedgerEntry) {
            (key, SkillLedgerEntry(name: key, invocations: 0, sessionsTouched: 0, lastFired: nil,
                                   inCatalog: true, descriptionTokens: 120))
        }
        var m: [String: SkillLedgerEntry] = [:]
        for (k, v) in [fired("api-client", 11, 7200, 6), fired("release-notes", 3, 90000, 2),
                       fired("browse", 4, 40000, 2), fired("codex:rescue", 2, 120000, 1)] { m[k] = v }
        for (k, v) in [dead("qa"), dead("codex"), dead("datakit-export"), dead("datakit-core"),
                       dead("datakit-query"), dead("graphify")] { m[k] = v }
        return m
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let skills = seededSkills()
        let hierarchy = SkillHierarchy.build(skills)
        let ledger = seededLedger(skills)
        func entry(_ s: Skill) -> SkillLedgerEntry? { ledger[s.qualifiedID] ?? ledger[s.id] ?? ledger[s.name] }

        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Stack · the skill hierarchy — real lane stats, collisions + lane tree over seeded skills")
            SkillLaneStats(hierarchy: hierarchy, deadCount: 6, catalog: 10)
            TriggerCollisionsPanel(collisions: hierarchy.collisions)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hierarchy.lanes) { lane in
                        SkillLaneView(lane: lane, selectedPath: "/seed/user/api-client",
                                      entryFor: { entry($0) })
                    }
                }
                .frame(width: 460, alignment: .leading)
                if let sel = skills.first(where: { $0.id == "api-client" }) {
                    // Non-scrolling projection of SkillDetail (ImageRenderer can't
                    // size the live ScrollView; the live screen uses the real one).
                    SkillDetailPreview(skill: sel, entry: entry(sel)).frame(width: 440)
                }
            }
            SkillUsageLegend()
        }
        writePNG(content, to: path, dark: dark, width: 1000)
    }
}

// Non-scrolling detail card for `--render-skills` (mirrors StackScreen.SkillDetail).
private struct SkillDetailPreview: View {
    let skill: Skill
    let entry: SkillLedgerEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(spacing: 8) {
                Text(skill.name).font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                // The real button (POLISH C9) — not a hand-rolled white-on-accent
                // capsule that only the harness ever drew.
                ProminentTapButton(size: .small, action: { }) { Label("Launch", systemImage: "paperplane.fill") }
            }
            HStack(spacing: 8) {
                SkillSourceBadge(source: skill.source)
                Text("/\(skill.qualifiedID)").font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            SkillLedgerBadge(entry: entry, source: skill.source)
            Text(skill.description).font(.subheadline).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !skill.triggers.isEmpty {
                Text("Triggers").font(.caption).foregroundStyle(Theme.muted)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(skill.triggers, id: \.self) { t in
                        Text(t).font(.caption).foregroundStyle(Theme.muted)
                            .padding(.horizontal, Theme.intraCell).padding(.vertical, Theme.rhythm / 2)
                            .background {
                                Capsule().fill(Theme.cardFill)
                                Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                            }
                    }
                }
            }
            Text(skill.path).font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }
}

// MARK: - Command palette headless render (`--render-palette`)
// Rasterizes the REAL palette panel (PalettePanel + PaletteRow) over a seeded
// multi-kind index, ranked by the REAL PaletteRanker with a seeded query ("cr")
// that hits a few sessions + a skill + a screen + a recipe — so the overlay can be
// Read + judged (door-light dots, mono ids, the selection accent, legibility)
// without a window/Space. snapshot.sh is Space-broken; this is the verification
// path. No ScrollView (`scrolls: false`) — ImageRenderer can't size one.

enum PaletteRender {

    private static func session(_ n: String, _ tier: ModelTier, _ state: AttentionState,
                                _ id: String, _ ageSecs: TimeInterval, _ machine: String,
                                now: Date) -> PaletteEntry {
        let hint = Text(String(id.prefix(8))).font(.system(.caption2, design: .monospaced))
            + Text(" · \(tier.label) · \(fmtAgeShort(ageSecs)) ago").font(.caption2)
        let eid = "session:\(id)"
        return PaletteEntry(
            id: eid, kind: .session, title: n, hint: hint, icon: PaletteKind.session.icon,
            tier: tier, state: state, machineID: machine,
            candidate: PaletteCandidate(id: eid, primary: n,
                                        secondary: [String(id.prefix(8)), tier.label],
                                        recency: now.addingTimeInterval(-ageSecs),
                                        group: PaletteKind.session.rawValue),
            altLabel: "Copy resume", run: {}, runAlt: {})
    }

    static func seededEntries(now: Date) -> [PaletteEntry] {
        var out: [PaletteEntry] = []

        // Sessions — the door light rides each row; a cross-machine pair shows chips.
        out.append(session("data-pipeline", .user, .running, "c91d22f0aa10", 130, "workstation", now: now))
        out.append(session("my-app", .opus, .running, "0ed7bc8135cc", 30, "local", now: now))
        out.append(session("webapp", .opus, .blocked, "b5f4e5e5c001", 240, "local", now: now))

        // A skill (user lane).
        let skID = "skill:0:release-notes"
        out.append(PaletteEntry(
            id: skID, kind: .skill, title: "release-notes",
            hint: Text("/release-notes").font(.system(.caption2, design: .monospaced))
                + Text(" · User").font(.caption2),
            icon: PaletteKind.skill.icon,
            candidate: PaletteCandidate(id: skID, primary: "release-notes",
                                        secondary: ["release-notes", "sweep every live crypto earning opportunity"],
                                        group: PaletteKind.skill.rawValue),
            altLabel: "Launch", run: {}, runAlt: {}))

        // A screen — matched via its keyword synonyms ("cost", "routing").
        let scID = "screen:spend"
        out.append(PaletteEntry(
            id: scID, kind: .screen, title: "Spend & Routing",
            hint: Text("⌘5").font(.system(.caption2, design: .monospaced))
                + Text(" · jump to section").font(.caption2),
            icon: "chart.pie",
            candidate: PaletteCandidate(id: scID, primary: "Spend & Routing",
                                        secondary: ["cost", "routing", "dollars", "tier", "money"],
                                        group: PaletteKind.screen.rawValue),
            run: {}))

        // A saved recipe.
        let rID = "recipe:seed-crypto"
        out.append(PaletteEntry(
            id: rID, kind: .recipe, title: "release-notes run",
            hint: Text("~/Developer/data-pipeline").font(.system(.caption2, design: .monospaced))
                + Text(" · High · 2 agents").font(.caption2),
            icon: PaletteKind.recipe.icon,
            candidate: PaletteCandidate(id: rID, primary: "release-notes run",
                                        secondary: ["data-pipeline", "release-notes", "api-client"],
                                        recency: now.addingTimeInterval(-86400),
                                        group: PaletteKind.recipe.rawValue),
            run: {}))

        // An action (won't match "cr" — shows the index is broad).
        let aID = "action:dream"
        out.append(PaletteEntry(
            id: aID, kind: .action, title: "Distill findings",
            hint: Text("mint lessons from the latest findings").font(.caption2),
            icon: "moon.stars",
            candidate: PaletteCandidate(id: aID, primary: "Distill findings",
                                        secondary: ["ledger", "lessons"],
                                        group: PaletteKind.action.rawValue),
            run: {}))
        return out
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let entries = seededEntries(now: now)
        let query = "cr"
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = PaletteRanker.rank(entries.map(\.candidate), query: query, now: now, limit: 60)
            .compactMap { byID[$0.id] }

        let panel = PalettePanel(query: query, results: ranked, selection: 0, scrolls: false) {
            Text(query).font(.title3).foregroundStyle(Theme.ink)
                + Text("  ⏐").font(.title3).foregroundStyle(Theme.faint)   // a faux caret
        }

        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Command palette (⌘K) — the real PalettePanel over a seeded index, ranked by the real PaletteRanker on query “cr”; door-light dots, mono ids, one accent on the selected row.")
            panel.frame(maxWidth: .infinity, alignment: .center)
        }
        writePNG(content, to: path, dark: dark, width: 720)
    }
}

// MARK: - Identity render (`--render-identity`)
// The signature made visible: the Trefoil Aperture leads the wordmark while its
// Door Light core carries the fleet's worst live state. Operational entity rows
// retain the original ring-and-core atom.

enum IdentityRender {

    private struct Lockup: View {
        let caption: String
        let state: DoorLightState
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                RenderCaption(caption)
                HStack(spacing: Theme.intraCell) {
                    BrandMark(state: state, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trifola")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("local · read-only")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, Theme.cardPadding).padding(.vertical, Theme.sectionGap)
                .frame(width: 220, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
            }
        }
    }

    private struct MenuMark: View {
        let img: NSImage
        let label: String
        var count: Int? = nil
        var body: some View {
            VStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(nsImage: img)
                        .renderingMode(.original)
                    if let count {
                        Text("\(count)").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    }
                }
                .padding(.horizontal, Theme.liveGaugeBottomInset).padding(.vertical, Theme.rowVerticalInset)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.cardFill)
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
                Text(label).font(.caption2).foregroundStyle(Theme.faint)
            }
        }
    }

    /// CG-backed canonical icon tile. Freezing it keeps ImageRenderer from
    /// applying appearance-dependent template treatment to the ivory mark.
    private struct AppIconSample: View {
        let image: CGImage

        var body: some View {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: 96, height: 96)
        }
    }

    /// Freeze AppBrand's deferred AppKit drawing handlers into CG-backed images.
    /// ImageRenderer otherwise reinterprets them under the light appearance and
    /// can drop the signature mark even when the source image is non-template.
    private static func frozenRaster(_ source: NSImage) -> NSImage {
        var rect = NSRect(origin: .zero, size: source.size)
        guard let cgImage = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            source.isTemplate = false
            return source
        }
        let image = NSImage(cgImage: cgImage, size: source.size)
        image.isTemplate = false
        return image
    }

    /// Draw the canonical icon directly into a concrete RGBA bitmap. A deferred
    /// NSImage handler still lost its white Door Light when ImageRenderer drew a
    /// light-mode frame; this path preserves AppBrand.drawAppIcon as the source
    /// while removing all later template/appearance interpretation.
    private static func frozenAppIcon() -> NSImage {
        let size = NSSize(width: AppBrand.Geometry.iconReferenceSize,
                          height: AppBrand.Geometry.iconReferenceSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return frozenRaster(AppBrand.dockIcon())
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        AppBrand.drawAppIcon(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        // PNG round-trip strips any AppKit representation/template metadata;
        // both ImageRenderer appearances must consume identical source pixels.
        if let data = bitmap.representation(using: .png, properties: [:]),
           let image = NSImage(data: data) {
            image.isTemplate = false
            return image
        }
        let fallback = NSImage(size: size)
        fallback.addRepresentation(bitmap)
        fallback.isTemplate = false
        return fallback
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        // The menu-bar glyph is a template at runtime (the system tints it); here we
        // draw it in the theme's label color so its geometry reads in the render.
        let markColor: NSColor = dark ? .white : .black
        let quiet = frozenRaster(AppBrand.markImage(size: 18, state: .quiet, color: markColor))
        let running = frozenRaster(AppBrand.markImage(size: 18, state: .running, color: markColor))
        let needs = frozenRaster(AppBrand.markImage(size: 18, state: .needsYou, color: markColor))
        let dockImage = frozenAppIcon()
        var dockRect = NSRect(origin: .zero, size: dockImage.size)
        guard let dock = dockImage.cgImage(forProposedRect: &dockRect, context: nil, hints: nil) else {
            FileHandle.standardError.write(Data("identity icon render failed\n".utf8))
            return
        }

        let content = VStack(alignment: .leading, spacing: 20) {
            RenderCaption("Trefoil Aperture identity shell + Door Light core: 24pt masthead, 18pt template glyph, packaged icon; operational rows keep the 8pt Door Light.")

            SectionLabel("Sidebar lockup — the mark's core takes the fleet's worst live state")
            HStack(alignment: .top, spacing: 16) {
                Lockup(caption: "quiet", state: .idle)
                Lockup(caption: "running", state: .running)
                Lockup(caption: "waiting on you", state: .waiting)
                Lockup(caption: "blocked", state: .blocked)
            }
            Divider()

            SectionLabel("Operational entity rows — unchanged 8pt Door Light semantics")
            HStack(spacing: 26) {
                ForEach([DoorLightState.idle, .running, .waiting, .blocked], id: \.self) { state in
                    HStack(spacing: 8) {
                        SeatMark(state: state, size: 8)
                        Text(String(describing: state)).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
            }
            Divider()

            SectionLabel("Menu-bar glyph — a template mark, three honest states")
            HStack(spacing: 26) {
                MenuMark(img: quiet, label: "quiet · open aperture")
                MenuMark(img: running, label: "running · small core")
                MenuMark(img: needs, label: "needs you · full core + count", count: 2)
                Spacer()
            }
            Divider()

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("App icon")
                    AppIconSample(image: dock)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Dock badge — blocked light + count")
                    ZStack(alignment: .bottomTrailing) {
                        AppIconSample(image: dock)
                        HStack(spacing: 4) {
                            SeatMark(state: .blocked, ring: Theme.red, size: 14)
                            Text("2").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.black.opacity(0.88), in: Capsule())
                    }
                }
            }
        }
        // 4 lockup cards ×220 + 3×16 gaps = 928 content + 56 padding — 900 clipped
        // the blocked card (the state that matters most) off the canvas (IDN-1).
        writePNG(content, to: path, dark: dark, width: 1010)
    }
}

// MARK: - Config-surface health headless render (`--render-config`)
// Rasterizes the REAL config-health ProbeCards (VISION 2.4) — MCP servers, hooks,
// plugins — over fixture config JSON run through the SAME pure parsers +
// probeResult mappings the live Stack grid uses (the card is the exact one the app
// draws). Two rows: a HEALTHY read (all present / fresh → up) and a CONFIG-ROT read
// (a missing MCP binary, a missing hook script, a stale plugin → degraded/amber) so
// the "make the rot visible" claim is the visual truth. HONEST LIMIT: presence
// only, never a live handshake — the card labels say so. snapshot.sh is Space-
// broken; this is the verification path (Read the PNGs, judge them).

enum ConfigRender {

    // Resolver used by BOTH rows: these three commands resolve; anything else
    // (ghost-mcp-bin, guard-hook.sh) is "missing" — the rot the second row shows.
    static func resolver(_ cmd: String) -> Bool {
        ["npx", "headroom", "precommit-check"].contains((cmd as NSString).lastPathComponent)
    }
    // Fixed clock so plugin staleness is reproducible across renders.
    static var now: Date { ISO8601DateFormatter().date(from: "2026-07-06T12:00:00Z") ?? Date() }

    // — Healthy fixtures —
    static let mcpHealthy = """
    {"mcpServers":{
      "cleanshot":{"type":"stdio","command":"npx","args":["-y","cleanshot-mcp"]},
      "headroom":{"type":"stdio","command":"headroom","args":["mcp","serve"]},
      "circle":{"type":"http","url":"https://api.circle.com/v1/codegen/mcp"}}}
    """
    static let hooksHealthy = """
    {"hooks":{
      "SessionStart":[
        {"matcher":"","hooks":[{"type":"command","command":"precommit-check","timeout":10}]},
        {"matcher":"","hooks":[{"type":"command","command":"echo 'MODEL SELF-CHECK…'"}]},
        {"matcher":"compact","hooks":[{"type":"command","command":"echo 'RESUMED…'"}]}],
      "PreCompact":[{"matcher":"","hooks":[{"type":"command","command":"echo 'PRE-COMPACT…'"}]}]}}
    """
    static let pluginsHealthy = """
    {"version":2,"plugins":{
      "code-review@claude-plugins-official":[{"scope":"user","version":"unknown","lastUpdated":"2026-07-06T08:38:35.768Z"}],
      "codex@openai-codex":[{"scope":"user","version":"1.0.4","lastUpdated":"2026-06-17T13:47:05.084Z"}],
      "imessage@claude-plugins-official":[{"scope":"user","version":"0.1.0","lastUpdated":"2026-07-02T13:35:09.765Z"}],
      "vercel@claude-plugins-official":[{"scope":"project","version":"0.44.0","lastUpdated":"2026-06-16T16:18:18.174Z"}]}}
    """

    // — Config-rot fixtures (a missing MCP binary, a missing hook script, a stale plugin) —
    static let mcpRot = """
    {"mcpServers":{
      "cleanshot":{"type":"stdio","command":"npx","args":["-y","cleanshot-mcp"]},
      "circle":{"type":"http","url":"https://api.circle.com/v1/codegen/mcp"},
      "ghost":{"type":"stdio","command":"ghost-mcp-bin"}}}
    """
    static let hooksRot = """
    {"hooks":{
      "SessionStart":[
        {"matcher":"","hooks":[{"type":"command","command":"precommit-check","timeout":10}]},
        {"matcher":"","hooks":[{"type":"command","command":"echo 'MODEL SELF-CHECK…'"}]}],
      "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard-hook.sh"}]}]}}
    """
    static let pluginsRot = """
    {"version":2,"plugins":{
      "code-simplifier@claude-plugins-official":[{"scope":"user","version":"1.0.0","lastUpdated":"2026-01-09T14:51:03.980Z"}],
      "rust-analyzer-lsp@claude-plugins-official":[{"scope":"user","version":"1.0.0","lastUpdated":"2026-06-13T12:16:59.401Z"}],
      "codex@openai-codex":[{"scope":"user","version":"1.0.4","lastUpdated":"2026-06-17T13:47:05.084Z"}]}}
    """

    private static func mcpResult(_ json: String, ms: Int) -> ProbeResult {
        withLatency(MCPConfig.probeResult(MCPConfig.classify(MCPConfig.parse(Data(json.utf8)), resolves: resolver)), ms)
    }
    private static func hooksResult(_ json: String, ms: Int) -> ProbeResult {
        withLatency(HooksConfig.probeResult(HooksConfig.classify(HooksConfig.parse(Data(json.utf8)), resolves: resolver)), ms)
    }
    private static func pluginsResult(_ json: String, ms: Int) -> ProbeResult {
        withLatency(PluginsConfig.probeResult(PluginsConfig.parse(Data(json.utf8), now: now)), ms)
    }
    /// Seeded believable latencies (varied, incl. one sub-ms) so the render shows
    /// the `<1 ms` format floor working — six identical "0 ms" read as "didn't
    /// actually probe" (UI_GRIND CFG-2).
    private static func withLatency(_ r: ProbeResult, _ ms: Int) -> ProbeResult {
        var out = r; out.latencyMs = ms; return out
    }

    // A row of the three real config ProbeCards, wired with the live probes' own
    // name/subtitle/symbol so the render can't drift from the app.
    @ViewBuilder
    private static func cardRow(_ mcp: ProbeResult, _ hooks: ProbeResult, _ plugins: ProbeResult) -> some View {
        let mcpP = MCPServersProbe(), hooksP = HooksProbe(), pluginsP = PluginsProbe()
        HStack(alignment: .top, spacing: Theme.sectionGap) {
            ProbeCard(name: mcpP.name, subtitle: mcpP.subtitle, symbol: mcpP.symbolName, result: mcp, probing: false)
            ProbeCard(name: hooksP.name, subtitle: hooksP.subtitle, symbol: hooksP.symbolName, result: hooks, probing: false)
            ProbeCard(name: pluginsP.name, subtitle: pluginsP.subtitle, symbol: pluginsP.symbolName, result: plugins, probing: false)
        }
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Config-surface health (VISION 2.4) — the real ProbeCards over fixture config JSON, through the same pure parsers the live Stack grid uses. Presence only, not a live handshake.")

            SectionLabel("Healthy read — every command present, every plugin fresh")
            cardRow(mcpResult(mcpHealthy, ms: 4), hooksResult(hooksHealthy, ms: 2), pluginsResult(pluginsHealthy, ms: 1))

            Divider()

            SectionLabel("Config rot made visible — a missing MCP binary, a missing hook script, a stale plugin")
            cardRow(mcpResult(mcpRot, ms: 3), hooksResult(hooksRot, ms: 0), pluginsResult(pluginsRot, ms: 1))
        }
        writePNG(content, to: path, dark: dark, width: 1140)
    }
}

// MARK: - Deadline Board headless render (`--render-deadlines`)
// Rasterizes the REAL DeadlineContent + the connect-Linear affordance so the board
// can be Read + judged without a window/Space (snapshot.sh is Space-broken). Seeds
// all five states — a STALLED alarm (red, still, pinned top), an OVERDUE fact, an
// AT-RISK card, an ON-TRACK live card, and a SHIPPED ember — plus the Linear panel in
// BOTH states (not-connected "Connect Linear" · connected "team X · Sync"). Litmus:
// the jeopardy sort reads worst-first, STALLED is the alarm, the door light + evidence
// grammar + mono/sans are consistent, and the connect state is calm, never a nag.

enum DeadlineRender {

    /// Fixed clock so the seeded states + countdowns are reproducible.
    static var now: Date { ISO8601DateFormatter().date(from: "2026-07-12T12:00:00Z")! }
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private static func at(_ y: Int, _ mo: Int, _ d: Int, _ hh: Int = 23, _ mm: Int = 59) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: hh, minute: mm, second: 0))!
    }

    private static func card(key: String, deadline: Date, kind: DeadlineKind, last: Date?,
                             cost: Double, sessions: Int, confirmed: Bool, shipped: Bool = false,
                             platform: String?, raw: String, file: String = "MEMORY.md", line: Int,
                             origin: DeadlineSource.Origin = .parsed) -> DeadlineCard {
        let rec = DeadlineRecord(projectKey: key, deadline: deadline, kind: kind,
                                 source: DeadlineSource(file: file, line: line, raw: raw, confirmed: confirmed, origin: origin),
                                 shipped: shipped, platform: platform)
        let live = last.map { now.timeIntervalSince($0) < 15 * 60 && now.timeIntervalSince($0) >= 0 } ?? false
        let act = ProjectActivity(project: key, lastActivity: last, cost: cost, sessionCount: sessions,
                                  machineID: Machine.localID, isLive: live, blocked: false)
        return DeadlineCard(record: rec, activity: act, now: now)
    }

    static func seeded() -> [DeadlineCard] {
        let cards = [
            // STALLED — near deadline, gone quiet: the alarm (red, still, pinned top).
            card(key: "alpha-hackathon", deadline: at(2026, 7, 13), kind: .hackathon,
                 last: at(2026, 7, 8), cost: 41, sessions: 12, confirmed: false,
                 platform: "Widgets · OSS Plugin Challenge",
                 raw: "deadline Jul 13 2026", line: 47),
            // OVERDUE — the date passed, not shipped: a fact, not a nag.
            card(key: "parser-lib", deadline: at(2026, 7, 10), kind: .bounty,
                 last: at(2026, 7, 6), cost: 8, sessions: 3, confirmed: true,
                 platform: "OSS Fund · 1k bug bounty", raw: "closes Jul 10 2026", line: 91),
            // AT-RISK — near, moderate jeopardy.
            card(key: "api-gateway", deadline: at(2026, 7, 17), kind: .hackathon,
                 last: at(2026, 7, 10), cost: 128, sessions: 31, confirmed: true,
                 platform: "DevPost Challenge · deploy step remains",
                 raw: "Submit before Jul 17", file: "hackathon/NOTES.md", line: 9),
            // ON-TRACK — near but freshly touched (a live pulse beside the frozen red card).
            card(key: "webapp", deadline: at(2026, 7, 19), kind: .hackathon,
                 last: at(2026, 7, 12, 11, 55), cost: 67, sessions: 44, confirmed: true,
                 platform: "OSS Sprint · core feature LIVE", raw: "submission Jul 19",
                 file: "webapp/NOTES.md", line: 3),
            // SHIPPED — user-confirmed; ember-faded, sunk below the fold.
            card(key: "security-audit", deadline: at(2026, 7, 1), kind: .audit,
                 last: at(2026, 7, 1), cost: 22, sessions: 7, confirmed: true, shipped: true,
                 platform: "audit done, coverage monitor armed", raw: "shipped Jul 1", line: 120),
        ]
        // Sort exactly as the board does.
        let recs = Dictionary(uniqueKeysWithValues: cards.map { c -> (String, DeadlineRecord) in
            (c.projectKey, DeadlineRecord(projectKey: c.projectKey, deadline: c.deadline, kind: c.kind,
                                          source: c.source, shipped: c.shipped, platform: c.platform))
        })
        let act = Dictionary(uniqueKeysWithValues: cards.map { c -> (String, ProjectActivity) in
            (c.projectKey, ProjectActivity(project: c.projectKey, lastActivity: c.lastActivity, cost: c.cost,
                                           sessionCount: c.sessionCount, machineID: c.machineID,
                                           isLive: c.isLive, blocked: false))
        })
        return DeadlineBoard.build(records: recs, activity: act, now: now)
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let cards = seeded()
        // The door light's tier ring: the tier of each project's session (seeded to
        // a believable mix so state-fill × tier-ring both read — UI_GRIND §2.1).
        let tiers: [String: ModelTier] = [
            "alpha-hackathon": .opus, "parser-lib": .sonnet, "api-gateway": .opus,
            "webapp": .sonnet, "security-audit": .haiku,
        ]
        let content = VStack(alignment: .leading, spacing: 18) {
            RenderCaption("Deadline Board — the evidence grammar pointed at the calendar. Jeopardy = idle ÷ runway; STALLED pinned top (still, red), SHIPPED sunk to embers. Every date carries its source line.")
            DeadlineContent(cards: cards, tiers: tiers)

            Divider()
            RenderCaption("Connect Linear — NOT connected: a calm one-way CTA (paste a personal key → Keychain), never a nag. The board is fully useful with Linear off.")
            DeadlineConnectPanel(connection: .notConnected)

            RenderCaption("Connect Linear — connected, team not yet picked: the team picker fetched over GraphQL.")
            DeadlineConnectPanel(connection: .connected(team: nil, lastSync: nil, backgroundSync: false),
                                 teams: [LinearTeam(id: "team_1", name: "Engineering"),
                                         LinearTeam(id: "team_2", name: "Hackathons")],
                                 selectedTeamID: nil,
                                 syncStatus: "Key saved to Keychain")

            RenderCaption("Connect Linear — connected · team Engineering, after a sync: the visible result list — every project's row says synced → (link), skipped (unconfirmed stays local), or canceled (stale mapping cleaned up). No silence.")
            DeadlineConnectPanel(connection: .connected(team: "Engineering",
                                                        lastSync: Date().addingTimeInterval(-600),
                                                        backgroundSync: true),
                                 selectedTeamID: "team_1",
                                 syncStatus: "Synced 3 projects to Linear (1 new) · 1 kept local (unconfirmed) · 1 canceled in Linear",
                                 report: [
                                     LinearSyncRow(projectKey: "webapp", name: "Webapp",
                                                   url: "https://linear.app/acme/project/webapp-9f2c1a", outcome: .created),
                                     LinearSyncRow(projectKey: "api-gateway", name: "Api-Gateway",
                                                   url: "https://linear.app/acme/project/api-gateway-11b7e0", outcome: .updated),
                                     LinearSyncRow(projectKey: "parser-lib", name: "Parser Lib",
                                                   url: "https://linear.app/acme/project/parser-lib-5d90c4", outcome: .updated),
                                     LinearSyncRow(projectKey: "alpha-hackathon", name: "Alpha Hackathon", outcome: .skipped),
                                     LinearSyncRow(projectKey: "forum-bot", name: "Forum Bot",
                                                   url: "https://linear.app/acme/project/forum-bot-77aa02", outcome: .canceled),
                                 ])
        }
        writePNG(content, to: path, dark: dark, width: 1180)
    }
}

// MARK: - Context-tax gauge headless render (`--render-contexttax`)
// Spree #1 — the "$20 hey" killer: the gauge + fresh-session advisor at both
// densities, over seeded gauges the real `ContextTax.gauge` builder computed
// from seeded sessions at the real bundled catalog rates. Composes ONLY the
// shared pure view + RenderCaption (POLISH C11 — no fabricated chrome).

enum ContextTaxRender {

    /// A seeded session gauged by the REAL builder — the render shows builder
    /// output, not hand-typed numbers.
    private static func gauge(_ id: String, _ project: String, model: String,
                              ctx: Int, hitRate: Double, live: Bool,
                              now: Date) -> ContextTaxGauge {
        // Reconstruct a usage whose cacheHitRate equals `hitRate` exactly:
        // totalInput 10M split between cache reads and fresh input.
        let total = 10_000_000
        let reads = Int(Double(total) * hitRate)
        let s = SessionSummary(
            id: id, project: project, cwd: "/tmp/\(project)", model: model,
            lastActivity: live ? now : now.addingTimeInterval(-3600),
            messageCount: 120,
            usage: SessionUsage(inputTokens: total - reads, cacheReadTokens: reads),
            contextWeight: ctx, filePath: "/tmp/\(project)/s.jsonl")
        return ContextTax.gauge(s, now: now, catalog: .bundled)
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        // The warm heavy session — advisor ON (live, over the visible 200k bar).
        let warmHeavy = gauge("s0", "mobile-app", model: "claude-opus-4-8",
                              ctx: 312_400, hitRate: 0.94, live: true, now: now)
        // The field case: 847k resent on one word, cache nearly cold — the
        // research corpus's "$20 hey" (docs/RESEARCH_postcutoff_pulse.md).
        let coldHey = gauge("s1", "beta-hackathon", model: "claude-opus-4-8",
                            ctx: 847_000, hitRate: 0.03, live: true, now: now)
        // A light session — gauge reads calm, no advisor.
        let light = gauge("s2", "webapp", model: "claude-sonnet-5",
                          ctx: 84_000, hitRate: 0.98, live: true, now: now)
        // Over-threshold but IDLE — the advisor honestly stays quiet (it only
        // speaks about live sessions; advising a dead one is a nag with no verb).
        let idleHeavy = gauge("s3", "ml-trainer", model: "claude-haiku-4-5",
                              ctx: 265_000, hitRate: 0.88, live: false, now: now)

        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Context tax — what the NEXT message re-sends, priced warm (cache-read rate) vs cold (fresh input) at each session's own model rates. Advisor fires only live + over the visible 200k threshold.")
            RenderCaption("Composition sub-line (plan 12) — attributes contextWeight to CLAUDE.md + connected-MCP idle-schema footprint off the REAL ~/.claude/CLAUDE.md + ~/.claude.json, remainder is history. Every number is a labeled ≈ estimate, never measured.")
            VStack(alignment: .leading, spacing: 14) {
                ContextTaxGaugeView(gauge: warmHeavy)
                Divider()
                ContextTaxGaugeView(gauge: coldHey)
                Divider()
                ContextTaxGaugeView(gauge: light)
                Divider()
                ContextTaxGaugeView(gauge: idleHeavy)
            }
            .padding(Theme.sectionGap)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
            RenderCaption("ml-trainer is over threshold but idle — the advisor stays quiet: it advises live sessions, it does not nag history.")
            Divider()
            RenderCaption("Live-tile density — the compact strip every tile on the live board wears.")
            VStack(alignment: .leading, spacing: 10) {
                ContextTaxGaugeView(gauge: warmHeavy, compact: true)
                ContextTaxGaugeView(gauge: coldHey, compact: true)
                ContextTaxGaugeView(gauge: light, compact: true)
            }
            .padding(Theme.sectionGap)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
        writePNG(content, to: path, dark: dark, width: 860)
    }
}

// MARK: - Reroute receipts headless render (`--render-reroutes`)
// Spree #2 — fallback/reroute forensics: the session receipt (silent flips +
// the excluded /model switch), the 14-day trend row, and the orchestrator-hog
// alert — all over REAL builder output (`Reroutes.receipt/build`,
// `OrchestratorHog.alert`) from seeded sessions, never hand-typed numbers.

enum RerouteRender {

    private static func dayKey(_ daysAgo: Int, now: Date) -> String {
        CostProvenance.dayKey(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    /// A seeded session whose flips/turn-census drive the REAL builders.
    private static func flippy(_ id: String, _ project: String, now: Date,
                               flips: [ModelFlip], turns: [String: Int]) -> SessionSummary {
        SessionSummary(
            id: id, project: project, cwd: "/tmp/\(project)", model: "claude-haiku-4-5",
            lastActivity: now, messageCount: turns.values.reduce(0, +) * 2,
            usage: SessionUsage(inputTokens: 400_000, cacheReadTokens: 9_000_000),
            contextWeight: 120_000, filePath: "/tmp/\(project)/s.jsonl",
            assistantTurnsByModel: turns, modelFlips: flips)
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let today = dayKey(0, now: now)

        // The messy session: a classifier upshift (custom→opus, the Jul 1
        // shape), a fallback downshift (opus→sonnet), and one deliberate
        // /model switch that the receipt lists but refuses to count.
        let messy = flippy(
            "r0", "mobile-app", now: now,
            flips: [
                ModelFlip(fromModel: "claude-haiku-4-5", toModel: "claude-opus-4-8",
                          timestamp: now.addingTimeInterval(-7_200), day: dayKey(0, now: now),
                          messageID: "msg_01Xq7fRw2Kd9", userInitiated: false),
                ModelFlip(fromModel: "claude-opus-4-8", toModel: "claude-sonnet-5",
                          timestamp: now.addingTimeInterval(-3_600), day: dayKey(0, now: now),
                          messageID: "msg_01B4tN8pLc2E", userInitiated: false),
                ModelFlip(fromModel: "claude-sonnet-5", toModel: "claude-haiku-4-5",
                          timestamp: now.addingTimeInterval(-1_800), day: dayKey(0, now: now),
                          messageID: "msg_01Zk3mV6yTa1", userInitiated: true),
            ],
            turns: ["claude-haiku-4-5": 24, "claude-opus-4-8": 9, "claude-sonnet-5": 8])
        // A second rerouted session two days back — gives the trend a spine.
        let older = flippy(
            "r1", "ml-trainer", now: now.addingTimeInterval(-2 * 86_400),
            flips: [
                ModelFlip(fromModel: "claude-haiku-4-5", toModel: "claude-opus-4-8",
                          timestamp: now.addingTimeInterval(-2 * 86_400), day: dayKey(2, now: now),
                          messageID: "msg_01Pq9sHh4Vf7", userInitiated: false),
            ],
            turns: ["claude-haiku-4-5": 40, "claude-opus-4-8": 2])
        // The clean session: a full census, zero flips — must render NOTHING.
        let clean = flippy("r2", "webapp", now: now, flips: [], turns: ["claude-haiku-4-5": 31])

        let report = Reroutes.build(sessions: [messy, older, clean])
        let receipt = Reroutes.receipt(for: messy)!

        // The hog day: one top-level session billing ~9/10 of a real-dollar
        // day (usage priced by the REAL catalog via usageByModelDay — the
        // same cost(onDay:) path every other surface prints).
        let hogUsage = SessionUsage(inputTokens: 2_000_000, outputTokens: 900_000)
        let sideUsage = SessionUsage(inputTokens: 300_000, outputTokens: 40_000)
        let hogMain = SessionSummary(
            id: "h0", project: "my-app", cwd: "/tmp/cmc",
            model: "claude-opus-4-8", lastActivity: now, messageCount: 400,
            usage: hogUsage, contextWeight: 0, filePath: "/tmp/cmc/h.jsonl",
            lastUserMessage: "Coordinate the launch review",
            usageByModelDay: [today: ["claude-opus-4-8": hogUsage]])
        let hogSub = SessionSummary(
            id: "h1", project: "cmc-subagent", cwd: "/tmp/cmc",
            model: "claude-sonnet-5", lastActivity: now, messageCount: 60,
            usage: sideUsage, contextWeight: 0, filePath: "/tmp/cmc/h1.jsonl",
            lastUserMessage: "Verify the launch checklist",
            usageByModelDay: [today: ["claude-sonnet-5": sideUsage]])
        let hogAlert = OrchestratorHog.alert(sessions: [hogMain, hogSub], day: today)

        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Reroute receipts — mid-session model flips with no /model command between turns. Deliberate switches are listed, never counted; clean sessions render nothing.")
            VStack(alignment: .leading, spacing: 14) {
                RerouteReceiptView(receipt: receipt)
                Divider()
                if let cleanReceipt = Reroutes.receipt(for: clean) {
                    RerouteReceiptView(receipt: cleanReceipt)
                } else {
                    RenderCaption("webapp — zero flips: no receipt block at all (evidence, not decoration).")
                }
            }
            .padding(Theme.sectionGap)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
            Divider()
            RenderCaption("The fleet trend row — reroutes/day over 14 days, dominant pair named, /model exclusions counted in the corner.")
            VStack(alignment: .leading, spacing: 10) {
                RerouteTrendRow(report: report, now: now)
            }
            .padding(Theme.sectionGap)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
            Divider()
            RenderCaption("The single-session concentration alert — fires only when one top-level session accounts for >\(fmtPct(OrchestratorHog.shareThreshold)) of a ≥\(fmtUSD(OrchestratorHog.minimumDayTotal)) API-rate day estimate; the threshold lives in the copy.")
            VStack(alignment: .leading, spacing: 10) {
                if let hogAlert {
                    OrchestratorHogRow(alert: hogAlert)
                } else {
                    RenderCaption("single-session alert did not fire on the seeded day — seeding bug, judge harshly.")
                }
            }
            .padding(Theme.sectionGap)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
        writePNG(content, to: path, dark: dark, width: 860)
    }
}

// MARK: - Plan quota headless render (`--render-quota`)
// Rasterizes PLAN QUOTA (W7, plan 04) — the REAL rate-limit windows from the
// OAuth usage endpoint — over a fixture snapshot that mirrors today's real
// anchor: at ~09:55 IST two headless sessions hit 'resets 10am', i.e. a 5h
// window in the red with a ~35-minute runway. Litmus: the near-limit row reads
// as evidence (red fill ≥90, mono %, reset runway) without nagging; the weekly
// + scoped rows stay calm accent; the degraded state below is ONE quiet line,
// not an alert. snapshot.sh is Space-broken; this is the verification path.

enum QuotaRender {

    /// The fixture: today's morning, reconstructed. 5h window at 91% with the
    /// reset ~35 minutes out (the 'resets 10am' moment, visible IN ADVANCE),
    /// weekly at 58% resetting in ~4d, and a scoped Custom weekly at 34%.
    static func seededSnapshot(now: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 91,
                                  resetsAt: now.addingTimeInterval(35 * 60)),
            weekly: QuotaWindow(title: "Weekly (all models)", usedPercent: 58,
                                resetsAt: now.addingTimeInterval(4 * 86_400 + 2 * 3_600)),
            scoped: [QuotaWindow(title: "Custom weekly", usedPercent: 34,
                                 resetsAt: now.addingTimeInterval(4 * 86_400 + 2 * 3_600))],
            fetchedAt: now)
    }

    @MainActor
    static func run(to path: String, dark: Bool) {
        let now = Date()
        let content = VStack(alignment: .leading, spacing: 16) {
            RenderCaption("Plan quota (W7, plan 04) — the REAL rate-limit windows next to the burn estimate: 5h session window at 91% with a ~35-min reset runway (today's 'resets 10am' moment, predictable in advance), weekly + Custom-scoped weekly calm. Fill is state, not decoration: red ≥90, amber ≥75, accent below.")
            VStack(alignment: .leading, spacing: 10) {
                QuotaSection(snapshot: seededSnapshot(now: now),
                             status: "ok", source: .keychain, now: now)
            }
            .padding(Theme.sectionGap)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
            Divider()
            RenderCaption("Graceful degradation — no credentials found. ONE calm line, no spinner, no alert; the app works fully without this surface.")
            VStack(alignment: .leading, spacing: 10) {
                QuotaSection(snapshot: nil, status: "unavailable (no credentials)",
                             source: nil, now: now)
            }
            .padding(Theme.sectionGap)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
        }
        writePNG(content, to: path, dark: dark, width: 860)
    }
}
