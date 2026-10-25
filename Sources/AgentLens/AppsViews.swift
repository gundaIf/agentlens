import SwiftUI

extension Source {
    var symbol: String {
        switch self {
        case .claudeCode: return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "person.crop.circle"
        case .grok: return "bolt.horizontal.circle"
        case .muse, .grokBot, .chatgptChat: return "macwindow"
        case .codex: return "sparkle"
        }
    }
}

extension SessionSummary {
    /// Where the session ran, for meta lines: the project for Claude Code, otherwise the agent's name.
    var place: String {
        switch source {
        case .claudeCode: return project
        case .cowork: return "Cowork"
        case .grok: return project.isEmpty ? "Grok" : "Grok · \(project)"
        case .muse, .grokBot: return source.rawValue
        case .chatgptChat: return "ChatGPT"
        case .codex: return project.isEmpty || project == "ChatGPT project" ? "ChatGPT" : "ChatGPT · \(project)"
        }
    }
}

/// One AI app: icon, whether it's in use right now, and time in use since `from`.
struct AppUsageRow: View {
    @Environment(Store.self) private var store
    let app: TrackedApp
    let now: Date
    let from: Date?
    var maxTime: TimeInterval = 0
    var compact = true

    var body: some View {
        let usage = AppUsage.shared
        let time = usage.time(app.id, from: from, to: now)
        let front = usage.isFront(app.id)
        let open = usage.isRunning(app.id)
        HStack(spacing: compact ? 8 : 10) {
            if let icon = app.iconBitmap {
                Image(decorative: icon, scale: 2).resizable().frame(width: compact ? 18 : 24, height: compact ? 18 : 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                HStack(spacing: 4) {
                    // When we follow the window, say what the agent is doing; otherwise whether it's open.
                    if let s = liveSession, case let state = s.live(at: now), state.isVisible {
                        Text((app.readsWindow && s.source != .codex ? windowHeadline(state) : state.headline.uppercased())).font(.hud(9.5, .semibold)).foregroundStyle(state.color)
                        Text("·").foregroundStyle(.tertiary)
                        Text(s.title).foregroundStyle(.secondary).truncationMode(.tail)
                    } else {
                        Text(front ? "In use now" : (open ? "Open" : "Not running"))
                            .foregroundStyle(front ? Category.shell.color : Color.secondary)
                    }
                }
                .font(.system(size: 11)).lineLimit(1)
                if !compact && maxTime > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.05))
                            Capsule().fill(HUD.heat(0.25 + 0.75 * time / maxTime)).frame(width: max(3, g.size.width * time / maxTime))
                        }
                    }
                    .frame(height: 3).padding(.top, 3)
                }
            }
            Spacer(minLength: 6)
            if app.readsWindow {
                if AXAccess.shared.trusted {
                    Chip(text: "Following", symbol: "dot.radiowaves.left.and.right", tint: HUD.phosphor)
                        .help("AgentLens reads \(app.name)'s window to follow its sessions: titles, prompts' first lines, answering time and step labels.")
                } else {
                    Button { AXAccess.shared.connect() } label: { Chip(text: "Connect", symbol: "link", tint: HUD.phosphor) }
                        .buttonStyle(.plain)
                        .help("Follow \(app.name)'s sessions by letting AgentLens read its window. Opens Privacy & Security → Accessibility.")
                }
            }
            Text(time >= 1 ? time.clock : "—")
                .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(time >= 1 ? Color.primary : Color.secondary)
        }
    }
}

extension AppUsageRow {
    private var sources: Set<Source> { app.allSources }

    /// The most recent session for this app: read from its window, or (ChatGPT) from Codex's own logs.
    var liveSession: SessionSummary? {
        store.sessions.filter { sources.contains($0.source) }.max { $0.end < $1.end }
    }

    func windowHeadline(_ s: LiveState) -> String {
        switch s {
        case .running(let step, _, _): return step == "Answering" ? "ANSWERING" : "ANSWERING · \(step.uppercased())"
        case .thinking: return "ANSWERING"
        case .finished: return "DONE · YOUR TURN"
        case .waitingOnYou: return "WAITING ON YOU"
        case .idle: return ""
        }
    }
}

/// Shown when Connect was clicked but access still isn't on (usually a stale entry from an older build).
struct ConnectHint: View {
    let now: Date
    var body: some View {
        if AXAccess.shared.looksStuck(now: now) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Still not connected. If AgentLens is already switched on in Accessibility, it's an entry from an older version: select it, click −, then click Connect again.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { AXAccess.shared.connect() } label: { Chip(text: "Open Accessibility settings", symbol: "gearshape", tint: HUD.paper) }
                    .buttonStyle(.plain)
            }
            .padding(8)
            .background(HUD.alarm.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(HUD.alarm.opacity(0.35), lineWidth: 0.8))
        }
    }
}

/// Popover section: the AI apps installed on this Mac, today.
struct AppsSection: View {
    let now: Date

    var body: some View {
        let usage = AppUsage.shared
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow("AI apps")
                Spacer()
                Text("time in use today").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            ForEach(usage.apps.filter(\.isTracked)) { app in
                AppUsageRow(app: app, now: now, from: Calendar.current.startOfDay(for: now))
            }
            ConnectHint(now: now)
        }
    }
}

/// Dashboard card: time in each AI app over the selected range.
struct AppsCard: View {
    let from: Date?
    let periodName: String

    var body: some View {
        let usage = AppUsage.shared
        let now = Date()
        let times = usage.apps.map { usage.time($0.id, from: from, to: now) }
        let since = usage.intervals.map(\.start).min()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("AI apps · time in use")
                Spacer()
                Text(times.reduce(0, +).clock + " \(periodName)")
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(usage.apps.filter(\.isTracked)) { app in
                AppUsageRow(app: app, now: now, from: from, maxTime: max(times.max() ?? 0, 1), compact: false)
            }
            Text("These apps keep their chats online, so AgentLens counts the time each one was in front while you were at the keyboard. It can't see what the AI did."
                 + (since.map { " Tracking since \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute()))." } ?? " Tracking starts now."))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .surface(padding: 14)
    }
}
