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
        case .thinking: return Color(hex: 0xF27AB8)
        case .shell: return Color(hex: 0xF5A15B)
        case .reading: return Color(hex: 0xA594F9)
        case .editing: return Color(hex: 0xF2CC60)
        case .browser: return Color(hex: 0x6EA8F7)
        case .web: return Color(hex: 0x5FCFE0)
        case .subagent: return Color(hex: 0xA8D672)
        case .waiting: return Color(hex: 0xF2706B)
        case .other: return Color(hex: 0x8E8E96)
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
    /// Time left until a reset: "45m", "2h 10m", "10d 5h".
    var countdown: String {
        let s = Int(max(self, 0))
        if s >= 2 * 86400 { return "\(s / 86400)d \((s % 86400) / 3600)h" }
        return clock
    }

    /// "2h 14m", "14m", "45s": no seconds once past ten minutes.
    var clock: String {
        let s = Int(self.rounded())
        if s < 60 { return "\(s)s" }
        if s < 600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

// MARK: - Tokens

/// Calm, neutral surfaces with colour reserved for state and categories.
/// (Names kept from the earlier HUD look so every view picks up the new tokens.)
enum HUD {
    static let ink = Color(hex: 0x111114)          // window ground
    static let panel = Color(hex: 0x18181C)        // cards
    static let raised = Color(hex: 0x202026)       // rows, tiles, hover
    static let line = Color.white.opacity(0.07)    // hairlines
    static let bracket = Color.clear               // corner brackets retired
    static let dim = Color.white.opacity(0.48)
    static let paper = Color(hex: 0xF2F2F4)        // primary button fill
    static let paperInk = Color(hex: 0x111114)
    static let phosphor = Color(hex: 0x5BD68A)     // live / OK
    static let alarm = Color(hex: 0xF2706B)        // needs you
    static let amber = Color(hex: 0xF2B544)        // warnings, pace

    /// Kept for charts that want a ramp (heatmap): cool → warm, softened.
    static let thermal: [Color] = [
        Color(hex: 0x3A3F6B), Color(hex: 0x6B5FB8), Color(hex: 0xB86FC4),
        Color(hex: 0xE58A9A), Color(hex: 0xF2A86B), Color(hex: 0xF2CC60),
    ]

    /// A colour on the ramp, 0 (cold) … 1 (hot).
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
    /// Readouts and labels. Was monospaced everywhere; now the system face with tabular digits,
    /// so numbers line up without the instrument-panel look.
    static func hud(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    static let heroNumber = Font.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit()
    static let tileNumber = Font.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()
    static let eyebrow = Font.system(size: 11.5, weight: .semibold)
    /// Big numbers: rounded, tabular.
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// Section label, in sentence case.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.eyebrow).foregroundStyle(.secondary)
    }
}

// MARK: - Surfaces

/// L-shaped corner marks. No longer drawn by default; kept for the app icon.
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

/// A card: soft fill, one hairline, generous radius.
struct Surface: ViewModifier {
    var radius: CGFloat = 12
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HUD.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(HUD.line, lineWidth: 1))
    }
}

extension View {
    /// Old call sites pass radius 3 (the HUD look); anything under 8 becomes the standard card radius.
    func surface(radius: CGFloat = 12, padding: CGFloat = 14) -> some View {
        modifier(Surface(radius: radius < 8 ? 12 : radius, padding: max(padding, 12)))
    }

    /// The CRT treatment is retired; a soft rounded clip remains.
    func crt() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Divider.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(HUD.line).frame(height: 1)
    }
}

/// Small tag. `paper` draws a filled light tag.
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = HUD.dim
    var paper = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(paper ? HUD.paperInk : tint)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(paper ? HUD.paper : tint.opacity(0.13), in: Capsule())
    }
}

/// A title with a status dot.
struct NameTag: View {
    let text: String
    var dot: Color? = nil
    var body: some View {
        HStack(spacing: 7) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
        }
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

/// A status dot that breathes while an agent is working.
struct PulseDot: View {
    let color: Color
    var animated = true
    var size: CGFloat = 8

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
                dot.background(
                    Circle().fill(color.opacity(0.28 * (1 - phase)))
                        .frame(width: size * (1 + 1.2 * phase), height: size * (1 + 1.2 * phase))
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

/// A segmented control drawn in SwiftUI (renders in snapshots, matches the cards).
struct Segmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = o } } label: {
                    Text(label(o))
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background {
                            if on { Capsule().fill(Color.white.opacity(0.12)).matchedGeometryEffect(id: "seg", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.05), in: Capsule())
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

/// Faint scanlines, used only by the app icon artwork.
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
