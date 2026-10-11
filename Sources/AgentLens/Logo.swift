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

    /// Monochrome template image so macOS tints it for light/dark menu bars.
    static func image(_ state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let c = NSPoint(x: rect.midX, y: rect.midY)

            // Corner brackets: the scanner's bounding box.
            let b = NSBezierPath()
            let inset: CGFloat = 1.5, l: CGFloat = 4
            let r = rect.insetBy(dx: inset, dy: inset)
            for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                                   (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                b.move(to: NSPoint(x: x + dx * l, y: y))
                b.line(to: NSPoint(x: x, y: y))
                b.line(to: NSPoint(x: x, y: y + dy * l))
            }
            b.lineWidth = 1.5
            b.stroke()

            switch state {
            case .idle:
                // Small reticle.
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
                ring.lineWidth = 1.4
                ring.stroke()
            case .working:
                // Locked on: filled target with crosshair ticks.
                NSBezierPath(ovalIn: NSRect(x: c.x - 3.4, y: c.y - 3.4, width: 6.8, height: 6.8)).fill()
                let t = NSBezierPath()
                for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
                    t.move(to: NSPoint(x: c.x + dx * 4.6, y: c.y + dy * 4.6))
                    t.line(to: NSPoint(x: c.x + dx * 6.4, y: c.y + dy * 6.4))
                }
                t.lineWidth = 1.4
                t.stroke()
            case .waiting:
                NSBezierPath(roundedRect: NSRect(x: c.x - 0.9, y: c.y - 0.4, width: 1.8, height: 4.6), xRadius: 0.9, yRadius: 0.9).fill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 1, y: c.y - 3.4, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AgentLens"
        return image
    }
}
