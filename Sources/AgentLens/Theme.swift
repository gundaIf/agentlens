import SwiftUI
import AppKit

// MARK: - Palette

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Category {
    /// Thermal-camera hues: hot activities (thinking, commands, editing) glow magenta → orange → yellow,
    /// reading and browsing sit in the cool violet → blue end, waiting is alarm red.
    var color: Color {
        switch self {
        case .thinking: return Color(hex: 0xFF3FA4)
        case .shell: return Color(hex: 0xFF8A1F)
        case .reading: return Color(hex: 0x8E6BFF)
        case .editing: return Color(hex: 0xFFE14A)
        case .browser: return Color(hex: 0x3D7BFF)
        case .web: return Color(hex: 0x22D3EE)
        case .subagent: return Color(hex: 0xB6F23C)
        case .waiting: return Color(hex: 0xFF3B30)
        case .other: return Color(hex: 0x8C8A99)
        }
    }

    /// Name shown in the UI.
    var title: String {
        switch self {
        case .thinking: return "Thinking"
        case .shell: return "Running commands"
        case .reading: return "Reading code"
        case .editing: return "Editing files"
        case .browser: return "Browsing"
        case .web: return "Web research"
        case .subagent: return "Helper agents"
        case .waiting: return "Waiting on you"
        case .other: return "Other tools"
        }
    }

    /// For tight spots like the colour key under the day ribbon.
    var shortTitle: String {
        switch self {
        case .thinking: return "Thinking"
        case .shell: return "Commands"
        case .reading: return "Reading"
        case .editing: return "Editing"
        case .browser: return "Browsing"
        case .web: return "Web"
        case .subagent: return "Helpers"
        case .waiting: return "Waiting"
        case .other: return "Other"
        }
    }

    var blurb: String {
        switch self {
        case .thinking: return "Reasoning, and writing code or replies"
        case .shell: return "Builds, tests, git, installs"
        case .reading: return "Opening and searching files"
        case .editing: return "Writing and changing files"
        case .browser: return "Driving a browser"
        case .web: return "Fetching pages, searching"
        case .subagent: return "Work handed to sub-agents"
        case .waiting: return "Paused on your answer or approval"
        case .other: return "Connectors and other tools"
        }
    }

    var symbol: String {
        switch self {
        case .thinking: return "sparkles"
        case .shell: return "terminal"
        case .reading: return "doc.text.magnifyingglass"
        case .editing: return "pencil.line"
        case .browser: return "safari"
        case .web: return "globe"
        case .subagent: return "person.2"
        case .waiting: return "hand.raised"
        case .other: return "puzzlepiece.extension"
        }
    }
}

extension LiveState {
    var color: Color {
        switch self {
        case .running: return HUD.phosphor
        case .thinking: return Category.thinking.color
        case .waitingOnYou: return HUD.alarm
        case .finished: return HUD.paper
        case .idle: return HUD.dim
        }
    }

    var headline: String {
        switch self {
        case .running(let tool, _, _): return tool == "Bash" ? "Running a command" : "Using \(tool)"
        case .thinking: return "Thinking"
        case .waitingOnYou(let reason, _): return reason
        case .finished: return "Finished · your turn"
        case .idle: return "Idle"
        }
    }

    var detail: String? {
        if case .running(_, let d, _) = self, !d.isEmpty { return d }
        return nil
    }

    var since: Date? {
        switch self {
        case .running(_, _, let s), .thinking(let s), .waitingOnYou(_, let s): return s
        case .finished(let at): return at
        case .idle: return nil
        }
    }

    /// Kept for callers outside the redesigned views.
    func text(now: Date) -> String {
        let d = detail.map { " · \($0)" } ?? ""
        let t = since.map { " — \(now.timeIntervalSince($0).pretty)" } ?? ""
        return headline + d + t
    }
}

extension TimeInterval {
    /// "2h 14m", "14m", "45s": no seconds once past ten minutes.
    var clock: String {
        let s = Int(self.rounded())
        if s < 60 { return "\(s)s" }
        if s < 600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

// MARK: - HUD tokens

/// The instrument look: black ground, thermal accents, phosphor green for "live", cream paper for labels.
enum HUD {
    static let ink = Color(hex: 0x09080D)          // window ground
    static let panel = Color(hex: 0x111018)        // framed panels
    static let raised = Color(hex: 0x1A1824)       // rows, tiles
    static let line = Color.white.opacity(0.11)    // frames
    static let bracket = Color.white.opacity(0.55) // corner brackets
    static let dim = Color.white.opacity(0.42)
    static let paper = Color(hex: 0xEDE6CF)        // name tags (Pioneers' cream)
    static let paperInk = Color(hex: 0x15131C)
    static let phosphor = Color(hex: 0x39FF6A)     // live / OK
    static let alarm = Color(hex: 0xFF3B30)

    /// Cold → hot, as on a thermal camera's scale.
    static let thermal: [Color] = [
        Color(hex: 0x2B1BFF), Color(hex: 0x8E2BFF), Color(hex: 0xFF2E9A),
        Color(hex: 0xFF5A2E), Color(hex: 0xFFA21F), Color(hex: 0xFFF04A),
    ]

    /// A colour on the thermal scale, 0 (cold) … 1 (hot).
    static func heat(_ t: Double) -> Color {
        let t = min(max(t, 0), 1) * Double(thermal.count - 1)
        let i = min(Int(t), thermal.count - 2)
        return blend(thermal[i], thermal[i + 1], t - Double(i))
    }

    private static func blend(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let x = NSColor(a).usingColorSpace(.sRGB)!, y = NSColor(b).usingColorSpace(.sRGB)!
        return Color(.sRGB, red: x.redComponent + (y.redComponent - x.redComponent) * f,
                     green: x.greenComponent + (y.greenComponent - x.greenComponent) * f,
                     blue: x.blueComponent + (y.blueComponent - x.blueComponent) * f)
    }
}

extension Font {
    /// Readouts and labels: monospaced, like an instrument display.
    static func hud(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static let heroNumber = Font.system(size: 34, weight: .semibold, design: .monospaced)
    static let tileNumber = Font.system(size: 18, weight: .semibold, design: .monospaced)
    static let eyebrow = Font.system(size: 10, weight: .semibold, design: .monospaced)
}

/// Section label: "▸ NOW", in monospaced caps.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 5) {
            Text("▸").foregroundStyle(HUD.phosphor.opacity(0.85))
            Text(text.uppercased()).foregroundStyle(HUD.dim)
        }
        .font(.eyebrow)
        .tracking(1.2)
    }
}

// MARK: - Surfaces

/// L-shaped marks at each corner, as on a scanner's bounding box.
struct CornerBrackets: Shape {
    var length: CGFloat = 7
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 3, r.height / 3)
        for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                               (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            p.move(to: CGPoint(x: x + dx * l, y: y))
            p.addLine(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y + dy * l))
        }
        return p
    }
}

/// Faint CRT scanlines.
struct Scanlines: View {
    var spacing: CGFloat = 3
    var opacity: Double = 0.16
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(opacity)))
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// A framed instrument panel: dark fill, hairline frame, bright corner brackets.
struct Surface: ViewModifier {
    var radius: CGFloat = 3
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HUD.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(HUD.line, lineWidth: 1))
            .overlay(CornerBrackets().stroke(HUD.bracket, lineWidth: 1.2).padding(-0.5))
    }
}

extension View {
    func surface(radius: CGFloat = 3, padding: CGFloat = 12) -> some View {
        modifier(Surface(radius: radius, padding: padding))
    }

    /// CRT treatment for hero visuals: scanlines and a soft vignette.
    func crt() -> some View {
        overlay(Scanlines())
            .overlay(RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 40, endRadius: 400)
                .allowsHitTesting(false))
    }
}

/// Dotted divider, like the scanner's connector lines.
struct Hairline: View {
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: g.size.width, y: 0)) }
                .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }
        .frame(height: 1)
    }
}

/// Small tag. `paper` draws the cream name-tag style from the references.
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = HUD.dim
    var paper = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text.uppercased()).lineLimit(1)
        }
        .font(.hud(9.5, .semibold))
        .tracking(0.6)
        .foregroundStyle(paper ? HUD.paperInk : tint)
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(paper ? HUD.paper : tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(paper ? .clear : tint.opacity(0.45), lineWidth: 0.8))
    }
}

/// Cream name tag with a status dot, as on the thermal scan's labels.
struct NameTag: View {
    let text: String
    var dot: Color? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.hud(11, .semibold)).foregroundStyle(HUD.paperInk).lineLimit(1)
            Spacer(minLength: 4)
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(HUD.paper.opacity(0.94), in: Rectangle())
    }
}

/// Crosshair reticle.
struct Reticle: View {
    var size: CGFloat = 14
    var color: Color = .white
    var body: some View {
        Canvas { ctx, s in
            let c = CGPoint(x: s.width / 2, y: s.height / 2), r = s.width * 0.28
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), lineWidth: 1.2)
            var p = Path()
            p.move(to: CGPoint(x: c.x, y: 0)); p.addLine(to: CGPoint(x: c.x, y: s.height))
            p.move(to: CGPoint(x: 0, y: c.y)); p.addLine(to: CGPoint(x: s.width, y: c.y))
            ctx.stroke(p, with: .color(color), lineWidth: 1.2)
        }
        .frame(width: size, height: size)
    }
}

/// The thermal scale with tick marks, used as an edge rule on hero panels.
struct ThermalRule: View {
    var vertical = true
    var body: some View {
        Canvas { ctx, size in
            let len = vertical ? size.height : size.width
            let barRect = vertical ? CGRect(x: 0, y: 0, width: 5, height: size.height) : CGRect(x: 0, y: size.height - 5, width: size.width, height: 5)
            ctx.fill(Path(barRect), with: .linearGradient(Gradient(colors: vertical ? HUD.thermal.reversed() : HUD.thermal),
                                                         startPoint: .zero, endPoint: vertical ? CGPoint(x: 0, y: len) : CGPoint(x: len, y: 0)))
            var i = 0
            var t: CGFloat = 0
            while t <= len {
                let major = i % 5 == 0
                let w: CGFloat = major ? 6 : 3
                let r = vertical ? CGRect(x: 7, y: t, width: w, height: 0.8) : CGRect(x: t, y: size.height - 7 - w, width: 0.8, height: w)
                ctx.fill(Path(r), with: .color(.white.opacity(major ? 0.5 : 0.25)))
                t += 4; i += 1
            }
        }
        .frame(width: vertical ? 14 : nil, height: vertical ? nil : 14)
    }
}

/// A status dot that breathes while an agent is working.
struct PulseDot: View {
    let color: Color
    var animated = true
    var size: CGFloat = 8

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6
                dot.background(
                    Circle().fill(color.opacity(0.35 * (1 - phase)))
                        .frame(width: size * (1 + 1.4 * phase), height: size * (1 + 1.4 * phase))
                )
            }
        } else {
            dot
        }
    }

    private var dot: some View {
        Circle().fill(color).frame(width: size, height: size)
            .frame(width: size * 2.4, height: size * 2.4)
    }
}

// MARK: - Category displays

/// Horizontal bar split by category, largest first.
struct CategoryBar: View {
    let values: [Category: TimeInterval]
    var height: CGFloat = 8

    var body: some View {
        let parts = values.filter { $0.value >= 1 }.sorted { $0.value > $1.value }
        let total = max(parts.map(\.value).reduce(0, +), 1)
        GeometryReader { geo in
            let gaps = CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(parts, id: \.key) { c, v in
                    Capsule().fill(c.color)
                        .frame(width: max(height, (geo.size.width - gaps) * v / total))
                        .help("\(c.title): \(v.clock)")
                }
            }
        }
        .frame(height: height)
    }
}

struct CategoryLegend: View {
    let values: [Category: TimeInterval]
    var limit = 9
    var showBlurb = false

    var body: some View {
        let total = max(values.values.reduce(0, +), 1)
        let rows = values.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.prefix(limit)
        VStack(alignment: .leading, spacing: showBlurb ? 10 : 7) {
            ForEach(Array(rows), id: \.key) { c, v in
                HStack(alignment: showBlurb ? .top : .center, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(c.color)
                        .frame(width: 10, height: 10)
                        .padding(.top, showBlurb ? 3 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.system(size: 12.5, weight: .medium))
                        if showBlurb { Text(c.blurb).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    Text(v.clock).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    Text(percent(v / total))
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    private func percent(_ f: Double) -> String {
        f < 0.01 ? "<1%" : "\(Int((f * 100).rounded()))%"
    }
}
