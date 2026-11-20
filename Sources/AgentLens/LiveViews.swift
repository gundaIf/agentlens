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
        case .running(let tool, _, _):
            if tool == "Bash" { return "Running a command" }
            // Window-followed chats report their step ("Answering", "Searching…") rather than a tool.
            if tool == "Answering" || tool.hasSuffix("…") { return tool }
            return "Using \(tool)"
        case .thinking: return "Thinking"
        case .waitingOnYou(let reason, _): return reason
        case .finished: return "Done · your turn"
        case .idle: return "Idle"
        }
    }
}

// MARK: - Die

/// A tiny die that shows the agent's state: it keeps tumbling and hopping while the agent works
/// (faster when running a tool, lazier when thinking), rattles red when it needs you, lands on six
/// when it's done, and sits still on one when idle.
struct Die: View {
    let state: LiveState
    var size: CGFloat = 18
    var animated = true
    /// For snapshots: draw the pose at this moment instead of animating.
    var at: Double? = nil

    var body: some View {
        if let at {
            die(t: at).frame(width: size, height: size)
        } else if animated {
            TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in die(t: ctx.date.timeIntervalSinceReferenceDate) }
                .frame(width: size, height: size)
        } else {
            die(t: 0.3).frame(width: size, height: size)
        }
    }

    private struct Pose { var face: Int; var angle: Double; var dx: CGFloat; var dy: CGFloat; var squash: CGFloat }

    private func pose(t: Double) -> Pose {
        switch state {
        case .running, .thinking:
            // One roll per period: tumble a quarter turn while hopping, then rest a beat.
            let period = { if case .thinking = state { return 1.35 }; return 0.85 }()
            let n = Int(floor(t / period))
            let p = (t - Double(n) * period) / period
            let rollLen = 0.5
            let dir: Double = n % 2 == 0 ? 1 : -1
            func faceFor(_ k: Int) -> Int { ((k % 6 + 6) % 6 * 5 + 2) % 6 + 1 }
            if p < rollLen {
                let q = p / rollLen
                let e = q < 0.5 ? 2 * q * q : 1 - pow(-2 * q + 2, 2) / 2     // ease in-out
                let hop = sin(.pi * q)
                return Pose(face: q < 0.5 ? faceFor(n - 1) : faceFor(n), angle: dir * 90 * e,
                            dx: CGFloat(dir * sin(.pi * q)) * size * 0.1, dy: -CGFloat(hop) * size * 0.22, squash: 1)
            }
            // Landing: a small squash right after touchdown.
            let land = (p - rollLen) / (1 - rollLen)
            let squash = land < 0.25 ? 1 - CGFloat(sin(.pi * land / 0.25)) * 0.12 : 1
            return Pose(face: faceFor(n), angle: 0, dx: 0, dy: 0, squash: squash)
        case .waitingOnYou:
            // Rattle in place, a burst every second or so.
            let p = t.truncatingRemainder(dividingBy: 1.1)
            let shake = p < 0.4 ? sin(p * 70) * (1 - p / 0.4) : 0
            return Pose(face: 3, angle: shake * 14, dx: CGFloat(shake) * size * 0.06, dy: 0, squash: 1)
        case .finished:
            return Pose(face: 6, angle: 0, dx: 0, dy: 0, squash: 1)
        case .idle:
            return Pose(face: 1, angle: 0, dx: 0, dy: 0, squash: 1)
        }
    }

    private func die(t: Double) -> some View {
        let pz = animated || at != nil ? pose(t: t) : pose(t: state.isWorking ? 0.84 : t)
        let color = state.isVisible ? state.color : Color.white.opacity(0.35)
        return Canvas { ctx, s in
            let r = CGRect(origin: .zero, size: s).insetBy(dx: s.width * 0.14, dy: s.height * 0.14)
            ctx.fill(Path(roundedRect: r, cornerRadius: r.width * 0.26, style: .continuous), with: .color(color))
            // A soft top highlight so it reads as a little cube.
            ctx.fill(Path(roundedRect: CGRect(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.06,
                                              width: r.width * 0.76, height: r.height * 0.16), cornerRadius: r.height * 0.08),
                     with: .color(.white.opacity(0.22)))
            let pip = max(1.1, r.width * 0.1)
            let g: [CGFloat] = [0.25, 0.5, 0.75]
            let spots: [(Int, Int)] = {
                switch pz.face {
                case 1: return [(1, 1)]
                case 2: return [(0, 0), (2, 2)]
                case 3: return [(0, 0), (1, 1), (2, 2)]
                case 4: return [(0, 0), (2, 0), (0, 2), (2, 2)]
                case 5: return [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)]
                default: return [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)]
                }
            }()
            for (x, y) in spots {
                let c = CGPoint(x: r.minX + r.width * g[x], y: r.minY + r.height * g[y])
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - pip, y: c.y - pip, width: pip * 2, height: pip * 2)),
                         with: .color(HUD.ink.opacity(0.9)))
            }
        }
        .scaleEffect(x: 2 - pz.squash, y: pz.squash, anchor: .bottom)
        .rotationEffect(.degrees(pz.angle))
        .offset(x: pz.dx, y: pz.dy)
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
                Die(state: state, size: compact ? 16 : 20, animated: animated)
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
