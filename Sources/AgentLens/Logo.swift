import SwiftUI
import AppKit

/// The AgentLens mark: a lens whose ring is drawn in activity colours, so the logo
/// doubles as a tiny chart. Pass `values` to draw a real split; omit for the brand ring.
struct LensMark: View {
    var values: [Category: TimeInterval]? = nil
    var size: CGFloat = 22
    var dark = true

    var body: some View {
        let line = max(2, size * 0.15)
        ZStack {
            if let values, values.values.contains(where: { $0 >= 1 }) {
                RingChart(values: values, lineWidth: line, gapDegrees: size > 40 ? 2.5 : 0)
            } else {
                Circle()
                    .stroke(AngularGradient(colors: LensMark.brandStops, center: .center),
                            style: StrokeStyle(lineWidth: line))
            }
            // Reticle in place of a pupil.
            if size >= 14 {
                Reticle(size: size * 0.42, color: .white.opacity(0.9))
            } else {
                Circle().fill(Color.white).frame(width: size * 0.22, height: size * 0.22)
            }
        }
        .padding(line / 2)
        .frame(width: size, height: size)
    }

    /// The thermal scale wrapped into a ring.
    static let brandStops: [Color] = HUD.thermal + HUD.thermal.reversed().dropFirst()
}

/// Donut of category shares, clockwise from 12 o'clock, largest first.
struct RingChart: View {
    let values: [Category: TimeInterval]
    var lineWidth: CGFloat = 10
    var gapDegrees: Double = 2

    var body: some View {
        let parts = values.filter { $0.value >= 1 }.sorted { $0.value > $1.value }
        let total = max(parts.map(\.value).reduce(0, +), 1)
        let gap = parts.count > 1 ? gapDegrees / 360 : 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: lineWidth)
            ForEach(Array(parts.enumerated()), id: \.element.key) { i, part in
                let start = parts.prefix(i).map(\.value).reduce(0, +) / total
                let end = start + part.value / total
                Circle()
                    .trim(from: start + gap / 2, to: max(start + gap / 2, end - gap / 2))
                    .stroke(part.key.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

// MARK: - App icon

/// 1024×1024 app icon artwork, rendered to PNG by `--snapshot` and packed into AppIcon.icns by build.sh.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824pt body on a 1024 canvas.
            ZStack {
                Color(hex: 0x07060B)
                // Faint scanner grid.
                Canvas { ctx, size in
                    stride(from: 0.0, through: size.width, by: 41.2).forEach { x in
                        ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.04)))
                        ctx.fill(Path(CGRect(x: 0, y: x, width: size.width, height: 1)), with: .color(.white.opacity(0.04)))
                    }
                }
                // Heat bloom.
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0xFF2E9A, opacity: 0.55), Color(hex: 0x8E2BFF, opacity: 0.25), .clear],
                                         center: .center, startRadius: 20, endRadius: 360))
                    .frame(width: 720, height: 720)
                Scanlines(spacing: 6, opacity: 0.22)
            }
            .frame(width: 824, height: 824)
            .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 3))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 14)

            // Bounding-box brackets.
            CornerBrackets(length: 70)
                .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 10, lineCap: .square))
                .frame(width: 600, height: 600)

            // Tick scale around the ring.
            ForEach(0..<60) { i in
                Rectangle()
                    .fill(Color.white.opacity(i % 5 == 0 ? 0.55 : 0.2))
                    .frame(width: i % 5 == 0 ? 5 : 3, height: i % 5 == 0 ? 24 : 13)
                    .offset(y: -262)
                    .rotationEffect(.degrees(Double(i) * 6))
            }

            Circle()
                .stroke(AngularGradient(colors: LensMark.brandStops, center: .center), style: StrokeStyle(lineWidth: 58))
                .frame(width: 400, height: 400)
                .shadow(color: Color(hex: 0xFF2E9A, opacity: 0.6), radius: 24)

            // Crosshair.
            Reticle(size: 150, color: .white)
                .scaleEffect(1)
                .shadow(color: .white.opacity(0.6), radius: 6)

            // Readout tag, as on the scanner labels.
            HStack(spacing: 10) {
                Text("LENS").font(.system(size: 38, weight: .bold, design: .monospaced)).foregroundStyle(HUD.paperInk)
                Circle().fill(HUD.phosphor).frame(width: 22, height: 22)
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
            .background(HUD.paper)
            .offset(x: 140, y: -300)
        }
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - Menu bar glyph

enum MenuGlyph {
    enum State { case idle, working, waiting }

    /// A tiny die, as a monochrome template image so macOS tints it for light/dark menu bars.
    /// Idle: an outlined die showing one. Working: a solid die that tumbles and hops (pass the time `t`).
    /// Waiting: a solid die that rattles in place.
    static func image(_ state: State, t: Double = 0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            var face = 1, angle = 0.0, dx: CGFloat = 0, dy: CGFloat = 0, squash: CGFloat = 1
            switch state {
            case .idle: break
            case .working:
                let period = 0.85, n = Int(floor(t / period))
                let p = (t - Double(n) * period) / period
                let dir: Double = n % 2 == 0 ? 1 : -1
                func faceFor(_ k: Int) -> Int { ((k % 6 + 6) % 6 * 5 + 2) % 6 + 1 }
                if p < 0.5 {
                    let q = p / 0.5
                    let e = q < 0.5 ? 2 * q * q : 1 - pow(-2 * q + 2, 2) / 2
                    face = q < 0.5 ? faceFor(n - 1) : faceFor(n)
                    angle = -dir * 90 * e
                    dx = CGFloat(dir * sin(.pi * q)) * 1.2
                    dy = CGFloat(sin(.pi * q)) * 1.2
                } else {
                    face = faceFor(n)
                    let land = (p - 0.5) / 0.5
                    if land < 0.25 { squash = 1 - CGFloat(sin(.pi * land / 0.25)) * 0.12 }
                }
            case .waiting:
                face = 3
                let p = t.truncatingRemainder(dividingBy: 1.1)
                let shake = p < 0.4 ? sin(p * 70) * (1 - p / 0.4) : 0
                angle = shake * 14
                dx = CGFloat(shake) * 0.8
            }

            let side: CGFloat = 11
            let base = NSPoint(x: rect.midX + dx, y: rect.midY - side / 2 + dy)   // bottom-centre of the die
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.translateBy(x: base.x, y: base.y + side / 2)
            ctx.rotate(by: CGFloat(angle * .pi / 180))
            ctx.translateBy(x: 0, y: -side / 2)
            ctx.scaleBy(x: 2 - squash, y: squash)
            let body = NSRect(x: -side / 2, y: 0, width: side, height: side)
            let shape = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)

            let pip: CGFloat = 1.25
            let g: [CGFloat] = [0.25, 0.5, 0.75]
            let spots: [(Int, Int)] = {
                switch face {
                case 1: return [(1, 1)]
                case 2: return [(0, 0), (2, 2)]
                case 3: return [(0, 0), (1, 1), (2, 2)]
                case 4: return [(0, 0), (2, 0), (0, 2), (2, 2)]
                case 5: return [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)]
                default: return [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)]
                }
            }()
            let pips = NSBezierPath()
            for (x, y) in spots {
                let c = NSPoint(x: body.minX + side * g[x], y: body.minY + side * g[y])
                let r = face == 1 ? pip * 1.3 : pip
                pips.appendOval(in: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }

            NSColor.black.set()
            if state == .idle {
                shape.lineWidth = 1.4
                let inner = NSBezierPath(roundedRect: body.insetBy(dx: 0.7, dy: 0.7), xRadius: 2.4, yRadius: 2.4)
                inner.lineWidth = 1.4
                inner.stroke()
                pips.fill()
            } else {
                // Solid die with the pips punched out.
                shape.fill()
                ctx.setBlendMode(.clear)
                pips.fill()
            }
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AgentLens"
        return image
    }
}
