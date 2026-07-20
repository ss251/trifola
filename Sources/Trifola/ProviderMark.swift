import SwiftUI
import TrifolaKit

// MARK: - ProviderMark
// Single source of truth for provider identity glyphs. Path-based shapes so the
// marks stay resolution-independent and monochrome-tintable; the shape is the
// differentiator, never brand-color alone. Used by session rows, filter chips,
// inspector, fleet tokens, and the Live board.

/// Recognizable provider mark: Claude's Anthropic starburst asterisk, OpenAI's
/// hexagonal blossom knot. Always carries an accessibility label; under
/// Increase Contrast fills at full-opacity monochrome ink.
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
            switch provider {
            case .claude:
                ClaudeStarburstShape()
                    .fill(fill, style: FillStyle(eoFill: false, antialiased: true))
            case .codex:
                OpenAIBlossomShape()
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

/// Anthropic Claude starburst asterisk — center-radiating spoke form used as
/// the Claude mark. Path derived from the public Claude symbol (viewBox 24×24).
struct ClaudeStarburstShape: Shape {
    func path(in rect: CGRect) -> Path {
        SVGPathGeometry.path(Self.d, viewBox: 24, in: rect)
    }

    private static let d =
        "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073"
        + "-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06"
        + " 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098"
        + "-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462"
        + "-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833"
        + ".365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644"
        + "-1.032-.17-.619a2.97 2.97 0 0 1 -.104 -.729L6.283.134 6.696 0l.996.134"
        + ".42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158"
        + "V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28"
        + ".48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242"
        + ".985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34"
        + " 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02"
        + " 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486"
        + "-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02"
        + ".225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312"
        + "-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455"
        + "-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345"
        + " 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167"
        + "-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747"
        + ".322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018"
        + "-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401"
        + "-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56"
        + "l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"
}

/// OpenAI hexagonal blossom knot — six interlocking arcs. Path derived from
/// the classic public OpenAI monogram (viewBox 24×24); even-odd fill keeps the
/// inner facets open at 12–24pt.
struct OpenAIBlossomShape: Shape {
    func path(in rect: CGRect) -> Path {
        SVGPathGeometry.path(Self.d, viewBox: 24, in: rect)
    }

    private static let d =
        "M22.282 9.821a6 6 0 0 0-.516-4.91a6.05 6.05 0 0 0-6.51-2.9A6.065 6.065"
        + " 0 0 0 4.981 4.18a6 6 0 0 0-3.998 2.9a6.05 6.05 0 0 0 .743 7.097a5.98"
        + " 5.98 0 0 0 .51 4.911a6.05 6.05 0 0 0 6.515 2.9A6 6 0 0 0 13.26 24"
        + "a6.06 6.06 0 0 0 5.772-4.206a6 6 0 0 0 3.997-2.9a6.06 6.06 0 0 0"
        + "-.747-7.073M13.26 22.43a4.48 4.48 0 0 1-2.876-1.04l.141-.081l4.779"
        + "-2.758a.8.8 0 0 0 .392-.681v-6.737l2.02 1.168a.07.07 0 0 1 .038.052"
        + "v5.583a4.504 4.504 0 0 1-4.494 4.494M3.6 18.304a4.47 4.47 0 0 1"
        + "-.535-3.014l.142.085l4.783 2.759a.77.77 0 0 0 .78 0l5.843-3.369v2.332"
        + "a.08.08 0 0 1-.033.062L9.74 19.95a4.5 4.5 0 0 1-6.14-1.646M2.34 7.896"
        + "a4.5 4.5 0 0 1 2.366-1.973V11.6a.77.77 0 0 0 .388.677l5.815 3.354"
        + "l-2.02 1.168a.08.08 0 0 1-.071 0l-4.83-2.786A4.504 4.504 0 0 1 2.34"
        + " 7.872zm16.597 3.855l-5.833-3.387L15.119 7.2a.08.08 0 0 1 .071 0l4.83"
        + " 2.791a4.494 4.494 0 0 1-.676 8.105v-5.678a.79.79 0 0 0-.407-.667"
        + "m2.01-3.023l-.141-.085l-4.774-2.782a.78.78 0 0 0-.785 0L9.409 9.23"
        + "V6.897a.07.07 0 0 1 .028-.061l4.83-2.787a4.5 4.5 0 0 1 6.68 4.66zm"
        + "-12.64 4.135l-2.02-1.164a.08.08 0 0 1-.038-.057V6.075a4.5 4.5 0 0 1"
        + " 7.375-3.453l-.142.08L8.704 5.46a.8.8 0 0 0-.393.681zm1.097-2.365"
        + "l2.602-1.5l2.607 1.5v2.999l-2.597 1.5l-2.607-1.5Z"
}

// MARK: - Minimal SVG path → SwiftUI Path
// Supports the command set used by the two brand marks (M/m L/l H/h V/v C/c
// S/s Q/q A/a Z/z). Numbers may be comma- or space-separated; consecutive
// commands of the same kind may omit the letter (SVG rules).

enum SVGPathGeometry {
    static func path(_ d: String, viewBox: CGFloat, in rect: CGRect) -> Path {
        let raw = parse(d)
        var path = Path()
        guard viewBox > 0 else { return path }
        let sx = rect.width / viewBox
        let sy = rect.height / viewBox
        let ox = rect.minX
        let oy = rect.minY
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * sx, y: oy + y * sy)
        }

        var cx: CGFloat = 0, cy: CGFloat = 0
        var startX: CGFloat = 0, startY: CGFloat = 0
        var lastCX: CGFloat = 0, lastCY: CGFloat = 0
        var lastWasCubic = false

        for cmd in raw {
            switch cmd.op {
            case "M":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx = cmd.args[i]; cy = cmd.args[i + 1]
                    if i == 0 {
                        path.move(to: pt(cx, cy))
                        startX = cx; startY = cy
                    } else {
                        path.addLine(to: pt(cx, cy))
                    }
                    i += 2
                    lastWasCubic = false
                }
            case "m":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx += cmd.args[i]; cy += cmd.args[i + 1]
                    if i == 0 {
                        path.move(to: pt(cx, cy))
                        startX = cx; startY = cy
                    } else {
                        path.addLine(to: pt(cx, cy))
                    }
                    i += 2
                    lastWasCubic = false
                }
            case "L":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx = cmd.args[i]; cy = cmd.args[i + 1]
                    path.addLine(to: pt(cx, cy))
                    i += 2
                    lastWasCubic = false
                }
            case "l":
                var i = 0
                while i + 1 < cmd.args.count {
                    cx += cmd.args[i]; cy += cmd.args[i + 1]
                    path.addLine(to: pt(cx, cy))
                    i += 2
                    lastWasCubic = false
                }
            case "H":
                for x in cmd.args {
                    cx = x
                    path.addLine(to: pt(cx, cy))
                    lastWasCubic = false
                }
            case "h":
                for dx in cmd.args {
                    cx += dx
                    path.addLine(to: pt(cx, cy))
                    lastWasCubic = false
                }
            case "V":
                for y in cmd.args {
                    cy = y
                    path.addLine(to: pt(cx, cy))
                    lastWasCubic = false
                }
            case "v":
                for dy in cmd.args {
                    cy += dy
                    path.addLine(to: pt(cx, cy))
                    lastWasCubic = false
                }
            case "C":
                var i = 0
                while i + 5 < cmd.args.count {
                    let x1 = cmd.args[i], y1 = cmd.args[i + 1]
                    let x2 = cmd.args[i + 2], y2 = cmd.args[i + 3]
                    let x = cmd.args[i + 4], y = cmd.args[i + 5]
                    path.addCurve(to: pt(x, y),
                                  control1: pt(x1, y1),
                                  control2: pt(x2, y2))
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
                    path.addCurve(to: pt(x, y),
                                  control1: pt(x1, y1),
                                  control2: pt(x2, y2))
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
                    path.addCurve(to: pt(x, y),
                                  control1: pt(x1, y1),
                                  control2: pt(x2, y2))
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
                    path.addCurve(to: pt(x, y),
                                  control1: pt(x1, y1),
                                  control2: pt(x2, y2))
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
                    path.addQuadCurve(to: pt(x, y), control: pt(x1, y1))
                    cx = x; cy = y
                    lastWasCubic = false
                    i += 4
                }
            case "q":
                var i = 0
                while i + 3 < cmd.args.count {
                    let x1 = cx + cmd.args[i], y1 = cy + cmd.args[i + 1]
                    let x = cx + cmd.args[i + 2], y = cy + cmd.args[i + 3]
                    path.addQuadCurve(to: pt(x, y), control: pt(x1, y1))
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
                           largeArc: largeArc, sweep: sweep,
                           map: pt)
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
        largeArc: Bool, sweep: Bool,
        map: (CGFloat, CGFloat) -> CGPoint
    ) {
        if rx == 0 || ry == 0 {
            path.addLine(to: map(to.x, to.y))
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
            path.addCurve(to: map(p1.x, p1.y),
                          control1: map(c1.x, c1.y),
                          control2: map(c2.x, c2.y))
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
