import SwiftUI
import TrifolaKit

// MARK: - ProviderMark
// Single source of truth for provider identity glyphs. Path-based shapes so the
// marks stay resolution-independent and monochrome-tintable; the shape is the
// differentiator, never brand-color alone. Used by session rows, filter chips,
// inspector, fleet tokens, and the Live board.

/// Recognizable provider mark: Claude's Anthropic starburst asterisk, OpenAI's
/// hexagonal blossom knot, and xAI's official Grok mark. Always carries an
/// accessibility label; under Increase Contrast fills at full-opacity monochrome ink.
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = Theme.iconGutter
    /// Optional tint override. Nil → muted graphite, or full ink under Increase Contrast.
    var tint: Color? = nil

    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    private var fill: Color {
        if accessibilityContrast == .increased { return Theme.ink }
        return tint ?? Theme.muted
    }

    var body: some View {
        Group {
            switch provider.markKind {
            case .claudeStarburst:
                ClaudeStarburstShape()
                    .fill(fill, style: FillStyle(eoFill: false, antialiased: true))
            case .openAIBlossom:
                OpenAIBlossomShape()
                    .fill(fill, style: FillStyle(eoFill: true, antialiased: true))
            case .grokMark:
                GrokMarkShape()
                    .fill(fill, style: FillStyle(eoFill: true, antialiased: true))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.markAccessibilityLabel)
        .help(provider.markAccessibilityLabel)
    }
}

// MARK: - Shapes (faithful path geometry, unit-square viewBox 0…24)

/// Anthropic Claude starburst asterisk — the official published Claude mark
/// path data, verbatim (viewBox 24×24). Regenerate from the source SVG only;
/// never round or redraw coordinates.
struct ClaudeStarburstShape: Shape {
    private static let viewBoxPath = SVGPathGeometry.path(d)

    func path(in rect: CGRect) -> Path {
        SVGPathGeometry.fit(Self.viewBoxPath, viewBox: 24, in: rect)
    }

    private static let d =
        "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-."
            + "0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.704"
            + "2.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.09"
            + "72 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.83"
            + "56l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078."
            + "6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.833"
            + "6.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2"
            + ".4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6."
            + "287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1."
            + "5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2"
            + "368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793."
            + "4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l."
            + "2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.431"
            + "1h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 "
            + "1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.839"
            + "6-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.436"
            + "4.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.224"
            + "7.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.910"
            + "7-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3"
            + "314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-"
            + "1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.60"
            + "71.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.139"
            + "7.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.32"
            + "18-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-."
            + "1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.716"
            + "4-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868"
            + "-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7"
            + "467.2307-.2429 1.9064-1.3114Z"
}

/// OpenAI hexagonal blossom knot — the official published OpenAI monogram
/// path data, verbatim (viewBox 24×24); even-odd fill keeps the inner facets
/// open at 12–24pt. Regenerate from the source SVG only; never round or
/// redraw coordinates.
struct OpenAIBlossomShape: Shape {
    private static let viewBoxPath = SVGPathGeometry.path(d)

    func path(in rect: CGRect) -> Path {
        SVGPathGeometry.fit(Self.viewBoxPath, viewBox: 24, in: rect)
    }

    private static let d =
        "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0"
            + " 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 "
            + "0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511"
            + " 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.259"
            + "9 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-"
            + "2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4"
            + "755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0"
            + " .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4."
            + "504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-"
            + ".5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.842"
            + "8-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4."
            + "4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1"
            + ".9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685"
            + "a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7"
            + ".872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .0"
            + "71 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79"
            + " 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.77"
            + "59 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l"
            + "4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02"
            + "-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3"
            + "757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0"
            + "976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067"
            + "-1.4997Z"
}

/// xAI Grok mark — the official published Grok logo path data (viewBox 24×24),
/// even-odd filled to match its `fill-rule="evenodd"`. Coordinates are verbatim;
/// only the two packed arc-flag pairs (`00…` → `0 0 …`) are whitespace-expanded
/// for the parser, which SVG treats as identical. Regenerate from the official
/// SVG only; never round or redraw coordinates.
struct GrokMarkShape: Shape {
    private static let viewBoxPath = SVGPathGeometry.path(d)

    func path(in rect: CGRect) -> Path {
        SVGPathGeometry.fit(Self.viewBoxPath, viewBox: 24, in: rect)
    }

    private static let d =
        "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.54"
            + "2 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 "
            + "1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5."
            + "539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.0"
            + "82.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.72"
            + "3c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.1"
            + "66-1.425l2.705-1.25a7.808 7.808 0 0 0 -1.829 -1A8.975 8.975 0 "
            + "0 0 5.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487"
            + "-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6."
            + "815"
}

// MARK: - Minimal SVG path → SwiftUI Path
// Supports the command set used by the three brand marks (M/m L/l H/h V/v C/c
// S/s Q/q A/a Z/z). Numbers may be comma- or space-separated; consecutive
// commands of the same kind may omit the letter (SVG rules).

enum SVGPathGeometry {
    /// Scales a viewBox-space path (parsed once, cached per shape) into `rect`.
    static func fit(_ path: Path, viewBox: CGFloat, in rect: CGRect) -> Path {
        guard viewBox > 0 else { return Path() }
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / viewBox, y: rect.height / viewBox)
        return path.applying(transform)
    }

    /// Arguments consumed per repetition of each supported command.
    private static let arity: [Character: Int] = [
        "M": 2, "m": 2, "L": 2, "l": 2, "H": 1, "h": 1, "V": 1, "v": 1,
        "C": 6, "c": 6, "S": 4, "s": 4, "Q": 4, "q": 4, "A": 7, "a": 7,
        "Z": 0, "z": 0,
    ]

    static func path(_ d: String) -> Path {
        let raw = parse(d)
        var path = Path()

        var cx: CGFloat = 0, cy: CGFloat = 0
        var startX: CGFloat = 0, startY: CGFloat = 0
        var lastCX: CGFloat = 0, lastCY: CGFloat = 0
        var lastWasCubic = false

        for cmd in raw {
            guard let argCount = arity[cmd.op] else {
                assertionFailure("SVGPathGeometry: unsupported path command '\(cmd.op)'")
                continue
            }
            assert(argCount == 0
                    ? cmd.args.isEmpty
                    : !cmd.args.isEmpty && cmd.args.count.isMultiple(of: argCount),
                   "SVGPathGeometry: malformed argument count \(cmd.args.count) for '\(cmd.op)'")
            switch cmd.op {
            case "M":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx = cmd.args[i]; cy = cmd.args[i + 1]
                    if i == 0 {
                        path.move(to: CGPoint(x: cx, y: cy))
                        startX = cx; startY = cy
                    } else {
                        path.addLine(to: CGPoint(x: cx, y: cy))
                    }
                    i += 2
                    lastWasCubic = false
                }
            case "m":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx += cmd.args[i]; cy += cmd.args[i + 1]
                    if i == 0 {
                        path.move(to: CGPoint(x: cx, y: cy))
                        startX = cx; startY = cy
                    } else {
                        path.addLine(to: CGPoint(x: cx, y: cy))
                    }
                    i += 2
                    lastWasCubic = false
                }
            case "L":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx = cmd.args[i]; cy = cmd.args[i + 1]
                    path.addLine(to: CGPoint(x: cx, y: cy))
                    i += 2
                    lastWasCubic = false
                }
            case "l":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx += cmd.args[i]; cy += cmd.args[i + 1]
                    path.addLine(to: CGPoint(x: cx, y: cy))
                    i += 2
                    lastWasCubic = false
                }
            case "H":
                for x in cmd.args {
                    cx = x
                    path.addLine(to: CGPoint(x: cx, y: cy))
                    lastWasCubic = false
                }
            case "h":
                for dx in cmd.args {
                    cx += dx
                    path.addLine(to: CGPoint(x: cx, y: cy))
                    lastWasCubic = false
                }
            case "V":
                for y in cmd.args {
                    cy = y
                    path.addLine(to: CGPoint(x: cx, y: cy))
                    lastWasCubic = false
                }
            case "v":
                for dy in cmd.args {
                    cy += dy
                    path.addLine(to: CGPoint(x: cx, y: cy))
                    lastWasCubic = false
                }
            case "C":
                var i = 0
                while i + 5 < cmd.args.count {
                    let x1 = cmd.args[i], y1 = cmd.args[i + 1]
                    let x2 = cmd.args[i + 2], y2 = cmd.args[i + 3]
                    let x = cmd.args[i + 4], y = cmd.args[i + 5]
                    path.addCurve(to: CGPoint(x: x, y: y),
                                  control1: CGPoint(x: x1, y: y1),
                                  control2: CGPoint(x: x2, y: y2))
                    lastCX = x2; lastCY = y2
                    cx = x; cy = y
                    lastWasCubic = true
                    i += 6
                }
            case "c":
                var i = 0
                while i + 5 < cmd.args.count {
                    let x1 = cx + cmd.args[i], y1 = cy + cmd.args[i + 1]
                    let x2 = cx + cmd.args[i + 2], y2 = cy + cmd.args[i + 3]
                    let x = cx + cmd.args[i + 4], y = cy + cmd.args[i + 5]
                    path.addCurve(to: CGPoint(x: x, y: y),
                                  control1: CGPoint(x: x1, y: y1),
                                  control2: CGPoint(x: x2, y: y2))
                    lastCX = x2; lastCY = y2
                    cx = x; cy = y
                    lastWasCubic = true
                    i += 6
                }
            case "S":
                var i = 0
                while i + 3 < cmd.args.count {
                    let x1 = lastWasCubic ? 2 * cx - lastCX : cx
                    let y1 = lastWasCubic ? 2 * cy - lastCY : cy
                    let x2 = cmd.args[i], y2 = cmd.args[i + 1]
                    let x = cmd.args[i + 2], y = cmd.args[i + 3]
                    path.addCurve(to: CGPoint(x: x, y: y),
                                  control1: CGPoint(x: x1, y: y1),
                                  control2: CGPoint(x: x2, y: y2))
                    lastCX = x2; lastCY = y2
                    cx = x; cy = y
                    lastWasCubic = true
                    i += 4
                }
            case "s":
                var i = 0
                while i + 3 < cmd.args.count {
                    let x1 = lastWasCubic ? 2 * cx - lastCX : cx
                    let y1 = lastWasCubic ? 2 * cy - lastCY : cy
                    let x2 = cx + cmd.args[i], y2 = cy + cmd.args[i + 1]
                    let x = cx + cmd.args[i + 2], y = cy + cmd.args[i + 3]
                    path.addCurve(to: CGPoint(x: x, y: y),
                                  control1: CGPoint(x: x1, y: y1),
                                  control2: CGPoint(x: x2, y: y2))
                    lastCX = x2; lastCY = y2
                    cx = x; cy = y
                    lastWasCubic = true
                    i += 4
                }
            case "Q":
                var i = 0
                while i + 3 < cmd.args.count {
                    let x1 = cmd.args[i], y1 = cmd.args[i + 1]
                    let x = cmd.args[i + 2], y = cmd.args[i + 3]
                    path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
                    cx = x; cy = y
                    lastWasCubic = false
                    i += 4
                }
            case "q":
                var i = 0
                while i + 3 < cmd.args.count {
                    let x1 = cx + cmd.args[i], y1 = cy + cmd.args[i + 1]
                    let x = cx + cmd.args[i + 2], y = cy + cmd.args[i + 3]
                    path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x1, y: y1))
                    cx = x; cy = y
                    lastWasCubic = false
                    i += 4
                }
            case "A", "a":
                let rel = cmd.op == "a"
                var i = 0
                while i + 6 < cmd.args.count {
                    let rx = abs(cmd.args[i])
                    let ry = abs(cmd.args[i + 1])
                    let xAxisRotation = cmd.args[i + 2]
                    let largeArc = cmd.args[i + 3] != 0
                    let sweep = cmd.args[i + 4] != 0
                    let x = rel ? cx + cmd.args[i + 5] : cmd.args[i + 5]
                    let y = rel ? cy + cmd.args[i + 6] : cmd.args[i + 6]
                    addArc(to: &path,
                           from: CGPoint(x: cx, y: cy),
                           to: CGPoint(x: x, y: y),
                           rx: rx, ry: ry,
                           xAxisRotation: xAxisRotation,
                           largeArc: largeArc, sweep: sweep)
                    cx = x; cy = y
                    lastWasCubic = false
                    i += 7
                }
            case "Z", "z":
                path.closeSubpath()
                cx = startX; cy = startY
                lastWasCubic = false
            default:
                break
            }
        }
        return path
    }

    // MARK: Arc → cubic approximation (SVG elliptical arc)

    private static func addArc(
        to path: inout Path,
        from: CGPoint, to: CGPoint,
        rx: CGFloat, ry: CGFloat,
        xAxisRotation: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        if rx == 0 || ry == 0 {
            path.addLine(to: to)
            return
        }
        let phi = xAxisRotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (from.x - to.x) / 2
        let dy = (from.y - to.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        var rxv = rx, ryv = ry
        let lambda = (x1p * x1p) / (rxv * rxv) + (y1p * y1p) / (ryv * ryv)
        if lambda > 1 {
            let s = sqrt(lambda)
            rxv *= s; ryv *= s
        }

        let rx2 = rxv * rxv, ry2 = ryv * ryv
        let x1p2 = x1p * x1p, y1p2 = y1p * y1p
        var sq = max(0, (rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
                     / (rx2 * y1p2 + ry2 * x1p2))
        sq = sqrt(sq)
        if largeArc == sweep { sq = -sq }
        let cxp = sq * (rxv * y1p) / ryv
        let cyp = sq * -(ryv * x1p) / rxv

        let cxv = cosPhi * cxp - sinPhi * cyp + (from.x + to.x) / 2
        let cyv = sinPhi * cxp + cosPhi * cyp + (from.y + to.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat,
                   _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let n = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard n > 0 else { return 0 }
            var a = acos(max(-1, min(1, (ux * vx + uy * vy) / n)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rxv, (y1p - cyp) / ryv)
        var dTheta = angle((x1p - cxp) / rxv, (y1p - cyp) / ryv,
                           (-x1p - cxp) / rxv, (-y1p - cyp) / ryv)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        // Segment into cubics (≤90° each).
        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segments)
        let t = 4 / 3 * tan(delta / 4)
        var a0 = theta1
        for _ in 0..<segments {
            let a1 = a0 + delta
            let cos0 = cos(a0), sin0 = sin(a0)
            let cos1 = cos(a1), sin1 = sin(a1)
            let p0 = CGPoint(x: cxv + rxv * cos0 * cosPhi - ryv * sin0 * sinPhi,
                             y: cyv + rxv * cos0 * sinPhi + ryv * sin0 * cosPhi)
            let p1 = CGPoint(x: cxv + rxv * cos1 * cosPhi - ryv * sin1 * sinPhi,
                             y: cyv + rxv * cos1 * sinPhi + ryv * sin1 * cosPhi)
            let c1 = CGPoint(
                x: p0.x - t * (rxv * sin0 * cosPhi + ryv * cos0 * sinPhi),
                y: p0.y - t * (rxv * sin0 * sinPhi - ryv * cos0 * cosPhi))
            let c2 = CGPoint(
                x: p1.x + t * (rxv * sin1 * cosPhi + ryv * cos1 * sinPhi),
                y: p1.y + t * (rxv * sin1 * sinPhi - ryv * cos1 * cosPhi))
            // First control is relative to current point which equals p0 after move/line.
            path.addCurve(to: p1, control1: c1, control2: c2)
            a0 = a1
        }
    }

    // MARK: Lexer

    private struct Command {
        var op: Character
        var args: [CGFloat]
    }

    private static func parse(_ d: String) -> [Command] {
        let cleaned = d.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        var commands: [Command] = []
        var i = cleaned.startIndex
        func skipSeparators() {
            while i < cleaned.endIndex {
                let c = cleaned[i]
                if c == " " || c == "," || c == "\n" || c == "\t" {
                    i = cleaned.index(after: i)
                } else {
                    break
                }
            }
        }
        func readNumber() -> CGFloat? {
            skipSeparators()
            guard i < cleaned.endIndex else { return nil }
            let start = i
            if cleaned[i] == "+" || cleaned[i] == "-" {
                i = cleaned.index(after: i)
            }
            var sawDigit = false
            while i < cleaned.endIndex, cleaned[i].isNumber {
                sawDigit = true
                i = cleaned.index(after: i)
            }
            if i < cleaned.endIndex, cleaned[i] == "." {
                i = cleaned.index(after: i)
                while i < cleaned.endIndex, cleaned[i].isNumber {
                    sawDigit = true
                    i = cleaned.index(after: i)
                }
            }
            if i < cleaned.endIndex, cleaned[i] == "e" || cleaned[i] == "E" {
                i = cleaned.index(after: i)
                if i < cleaned.endIndex, cleaned[i] == "+" || cleaned[i] == "-" {
                    i = cleaned.index(after: i)
                }
                while i < cleaned.endIndex, cleaned[i].isNumber {
                    i = cleaned.index(after: i)
                }
            }
            guard sawDigit else {
                i = start
                return nil
            }
            return CGFloat(Double(cleaned[start..<i]) ?? 0)
        }

        skipSeparators()
        while i < cleaned.endIndex {
            let c = cleaned[i]
            if c.isLetter {
                let op = c
                i = cleaned.index(after: i)
                var args: [CGFloat] = []
                while let n = readNumber() { args.append(n) }
                commands.append(Command(op: op, args: args))
            } else {
                // Orphan number — append to previous command (implicit repeat).
                if var last = commands.last, let n = readNumber() {
                    last.args.append(n)
                    while let more = readNumber() { last.args.append(more) }
                    commands[commands.count - 1] = last
                } else {
                    i = cleaned.index(after: i)
                }
            }
            skipSeparators()
        }
        return commands
    }
}
