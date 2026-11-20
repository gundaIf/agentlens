import SwiftUI

// Shared "right now" pieces used by the dropdown and the notch pill.

extension SessionSummary {
    /// "agent-lens · main", or the agent's name when there's no project.
    var metaLine: String {
        var parts = [place]
        if let b = branch, source == .claudeCode || source == .codex || source == .grok { parts.append(b) }
        return parts.joined(separator: " · ")
    }
}

extension LiveState {
    var isWaiting: Bool { if case .waitingOnYou = self { return true }; return false }

    /// Order in lists: needs you, working, finished.
    var rank: Int {
        switch self {
        case .waitingOnYou: return 0
        case .running, .thinking: return 1
        case .finished: return 2
        case .idle: return 3
        }
    }

    /// One short phrase for tight spots.
    var phrase: String {
        switch self {
        case .running(let tool, _, _): return tool == "Bash" ? "Running a command" : "Using \(tool)"
        case .thinking: return "Thinking"
        case .waitingOnYou(let reason, _): return reason
        case .finished: return "Done · your turn"
        case .idle: return "Idle"
        }
    }
}

// MARK: - Buddy

/// A small face that reads the room: glances around while the agent works, perks up red when it
/// needs you, smiles when it's done, and dozes when idle.
struct Buddy: View {
    let state: LiveState
    var size: CGFloat = 18
    var animated = true

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in face(t: ctx.date.timeIntervalSinceReferenceDate) }
                .frame(width: size, height: size)
        } else {
            face(t: 0.6).frame(width: size, height: size)
        }
    }

    private func face(t: Double) -> some View {
        let color = state.color
        let hop: CGFloat = {
            guard animated, state.isWaiting else { return 0 }
            let p = t.truncatingRemainder(dividingBy: 1.4) / 1.4
            return p < 0.25 ? -sin(p / 0.25 * .pi) * size * 0.12 : 0
        }()
        return Canvas { ctx, s in
            let r = CGRect(origin: .zero, size: s).insetBy(dx: s.width * 0.04, dy: s.height * 0.04)
            let body = Path(roundedRect: r, cornerRadius: s.width * 0.34, style: .continuous)
            ctx.fill(body, with: .color(color.opacity(state.isVisible ? 0.95 : 0.35)))

            let eyeY = r.midY - s.height * 0.04
            let gap = s.width * 0.17
            let ink = GraphicsContext.Shading.color(HUD.ink)
            switch state {
            case .finished:
                // ^ ^
                for dx in [-gap, gap] {
                    var p = Path()
                    let c = CGPoint(x: r.midX + dx, y: eyeY + s.height * 0.03)
                    p.move(to: CGPoint(x: c.x - s.width * 0.08, y: c.y + s.height * 0.04))
                    p.addLine(to: CGPoint(x: c.x, y: c.y - s.height * 0.04))
                    p.addLine(to: CGPoint(x: c.x + s.width * 0.08, y: c.y + s.height * 0.04))
                    ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: max(1.2, s.width * 0.07), lineCap: .round, lineJoin: .round))
                }
            case .idle:
                for dx in [-gap, gap] {
                    var p = Path()
                    p.move(to: CGPoint(x: r.midX + dx - s.width * 0.07, y: eyeY + s.height * 0.04))
                    p.addLine(to: CGPoint(x: r.midX + dx + s.width * 0.07, y: eyeY + s.height * 0.04))
                    ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: max(1.2, s.width * 0.07), lineCap: .round))
                }
            default:
                // Eyes: glance side to side while working, wide while waiting, blink now and then.
                let blink = animated && t.truncatingRemainder(dividingBy: 4.2) < 0.12
                let look: CGFloat = {
                    guard animated, state.isWorking else { return 0 }
                    return CGFloat(sin(t * 1.3)) * s.width * 0.06
                }()
                let lift: CGFloat = { if case .thinking = state { return -s.height * 0.05 }; return 0 }()
                let w = s.width * (state.isWaiting ? 0.15 : 0.12)
                let h = blink ? s.height * 0.025 : s.height * (state.isWaiting ? 0.2 : 0.17)
                for dx in [-gap, gap] {
                    let e = CGRect(x: r.midX + dx - w / 2 + look, y: eyeY - h / 2 + lift, width: w, height: h)
                    ctx.fill(Path(roundedRect: e, cornerRadius: w / 2), with: ink)
                }
            }
        }
        .offset(y: hop)
    }
}

// MARK: - Session row

/// One live session: buddy, title, where, what it's doing and for how long, and a ⌘ number.
struct LiveSessionRow: View {
    let session: SessionSummary
    let now: Date
    var index: Int? = nil
    var animated = true
    var compact = false
    private let hover = State(initialValue: false)

    var body: some View {
        let state = session.live(at: now)
        Button { Jump.go(to: session) } label: {
            HStack(alignment: .center, spacing: 10) {
                Buddy(state: state, size: compact ? 16 : 20, animated: animated)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title).font(.system(size: compact ? 12 : 12.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let since = state.since {
                            Text(now.timeIntervalSince(since).clock)
                                .font(.hud(11, .medium)).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                    HStack(spacing: 5) {
                        Text(state.phrase).foregroundStyle(state.color).lineLimit(1).layoutPriority(1)
                        Text("·").foregroundStyle(.tertiary)
                        Text(state.detail ?? session.metaLine).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 11))
                }
                if let index, index <= 9, !compact {
                    Text("⌘\(index)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                        .opacity(hover.wrappedValue ? 1 : 0.55)
                        .frame(width: 22, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, compact ? 5 : 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(state.isWaiting ? HUD.alarm.opacity(0.10) : Color.white.opacity(hover.wrappedValue ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover.wrappedValue = h } }
        .help("Go to \(session.metaLine)")
        .contextMenu {
            Button("Go to session") { Jump.go(to: session) }
            Button("Open in dashboard") { AppController.shared.openDashboard(select: session.id) }
        }
    }
}

// MARK: - Limits

/// "5h · 62%" with a thin bar and the pace marker.
struct LimitRow: View {
    let gauge: LimitGauge
    let now: Date

    var body: some View {
        let tint = gauge.aheadOfPace ? HUD.amber : (gauge.used > 0.9 ? HUD.alarm : Color.primary.opacity(0.75))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(gauge.agent).font(.system(size: 11.5, weight: .medium))
                Text(gauge.window).font(.system(size: 11)).foregroundStyle(.secondary)
                if gauge.estimated {
                    Text("est.").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help("Claude Code doesn't save its limits locally. Estimated from your logs: tokens this 5-hour window against your busiest window in 30 days.")
                }
                Spacer()
                Text("\(Int((gauge.used * 100).rounded()))%").font(.hud(11.5, .semibold)).foregroundStyle(tint)
                if let r = gauge.resetsAt {
                    Text("resets in \(r.timeIntervalSince(now).countdown)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(tint).frame(width: max(3, g.size.width * gauge.used))
                    if let e = gauge.elapsed {
                        Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1.5, height: 8)
                            .offset(x: g.size.width * e - 0.75)
                            .help("Time passed in this window")
                    }
                }
            }
            .frame(height: 4)
        }
        .help(gauge.detail + (gauge.aheadOfPace ? " · using it faster than time is passing" : ""))
    }
}

/// Compact chip for the pill: "5h 62%".
struct LimitChip: View {
    let gauge: LimitGauge
    var body: some View {
        let tint = gauge.aheadOfPace ? HUD.amber : (gauge.used > 0.9 ? HUD.alarm : Color.secondary)
        HStack(spacing: 4) {
            Text(gauge.agent == "Codex" ? "Codex" : "Claude").foregroundStyle(.tertiary)
            Text(gauge.chip).foregroundStyle(tint)
        }
        .font(.hud(10, .medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}
