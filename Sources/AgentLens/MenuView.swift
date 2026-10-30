import SwiftUI

enum MenuPage { case home, settings }

/// The dropdown under the menu bar icon. Minimal by default (today's time and who's working);
/// "More" opens the ribbon, AI apps and insights; the gear swaps in Settings.
struct MenuView: View {
    @Environment(Store.self) private var store
    @Environment(\.dropdownPresented) private var presented
    var animated = true
    private let pageState: State<MenuPage>
    private var page: MenuPage { pageState.wrappedValue }
    private let settingsAdvanced: Bool

    init(animated: Bool = true, page: MenuPage = .home, settingsAdvanced: Bool = false) {
        self.animated = animated
        self.pageState = State(initialValue: page)
        self.settingsAdvanced = settingsAdvanced
    }

    var body: some View {
        ZStack(alignment: .top) {
            if page == .home {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in home(now: ctx.date) }
                    .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                SettingsView(advanced: settingsAdvanced) { go(.home) }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            }
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .background(HUD.ink)
        .environment(\.colorScheme, .dark)
        // Reopening the dropdown always starts on the main page.
        .onChange(of: presented) { _, shown in if !shown { pageState.wrappedValue = .home } }
    }

    private func go(_ p: MenuPage) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) { pageState.wrappedValue = p }
    }

    @ViewBuilder
    private func home(now: Date) -> some View {
        let prefs = Preferences.shared
        let expanded = prefs.expanded
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let yesterday = today.addingTimeInterval(-86400)
        let stats = Insights.stats(store.sessions, from: today, to: now,
                                   compareFrom: yesterday, compareTo: now.addingTimeInterval(-86400))
        let live = store.sessions.filter { $0.live(at: now).isVisible }
            .sorted { rank($0.live(at: now)) < rank($1.live(at: now)) }
        let insights = Insights.list(stats, periodName: "today")
        let apps = AppUsage.shared.apps.filter(\.isTracked)

        VStack(alignment: .leading, spacing: 0) {
            // Header: mark, name, recording light, settings.
            HStack(spacing: 7) {
                LensMark(size: 15)
                Text("AGENTLENS").font(.hud(11, .bold)).tracking(1.6)
                Spacer()
                if live.contains(where: { $0.live(at: now).isWorking }) {
                    HStack(spacing: 4) {
                        PulseDot(color: HUD.alarm, animated: animated, size: 5).frame(width: 8, height: 8)
                        Text("REC").font(.hud(9.5, .bold)).foregroundStyle(HUD.alarm)
                    }
                }
                if UpdateChecker.shared.updateAvailable {
                    Button { NSWorkspace.shared.open(UpdateChecker.shared.latestURL ?? UpdateChecker.releasesURL) } label: {
                        Chip(text: "Update", symbol: "arrow.down.circle", tint: HUD.phosphor)
                    }
                    .buttonStyle(.plain)
                    .help("AgentLens \(UpdateChecker.shared.latest ?? "") is available")
                }
                IconButton(symbol: "gearshape", help: "Settings") { go(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 8)
            .cascade(0)

            // Today, in one line.
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(stats.agg.active.clock)
                                .font(.hud(24, .semibold))
                                .shadow(color: Category.thinking.color.opacity(0.45), radius: 6)
                            Text("TODAY").font(.hud(9.5, .semibold)).tracking(0.8).foregroundStyle(HUD.dim)
                        }
                        Text(subline(stats)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if stats.agg.active >= 1 {
                        RingChart(values: stats.agg.byCategory, lineWidth: 4.5, gapDegrees: 4)
                            .frame(width: 30, height: 30)
                    }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 9) {
                        DayRibbon(sessions: store.sessions, day: now, now: now, barHeight: 20)
                            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                            .background(Color.black)
                            .crt()
                            .overlay(CornerBrackets(length: 5).stroke(HUD.bracket, lineWidth: 1))
                        if stats.agg.active >= 1 { CategoryKey(values: stats.agg.byCategory) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 11)
            .cascade(1)

            Hairline()

            // Now
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Eyebrow("Now")
                    Spacer()
                    let working = live.filter { $0.live(at: now).isWorking }.count
                    if working > 0 { Chip(text: "\(working) working", tint: HUD.phosphor) }
                }
                if !store.loaded {
                    Text("Reading transcripts…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if live.isEmpty {
                    Text("All quiet. No agents active in the last 30 minutes.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    let limit = expanded ? 4 : 3
                    VStack(spacing: 0) {
                        ForEach(live.prefix(limit)) { s in
                            LiveRow(session: s, now: now, animated: animated) {
                                AppController.shared.openDashboard(select: s.id)
                            }
                        }
                    }
                    .padding(.horizontal, -6)
                    if live.count > limit {
                        Text("+\(live.count - limit) more in the dashboard").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .cascade(2)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if !apps.isEmpty {
                        Hairline()
                        AppsSection(now: now)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    if !insights.isEmpty {
                        Hairline()
                        VStack(alignment: .leading, spacing: 7) {
                            Eyebrow("Worth knowing")
                            ForEach(insights.prefix(2)) { InsightRow(insight: $0, compact: true) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .cascade(3)
            }

            Hairline()

            // Footer: dashboard, and the More / Less control.
            HStack(spacing: 10) {
                Button { AppController.shared.openDashboard(select: nil) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "viewfinder")
                        Text("DASHBOARD").tracking(0.8)
                    }
                    .font(.hud(10.5, .semibold))
                    .foregroundStyle(HUD.paperInk)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(HUD.paper, in: RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("d")
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { prefs.expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Less" : "More").font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundStyle(HUD.dim)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Show less" : "Show the day ribbon, AI apps and insights")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .cascade(4)
        }
    }

        private func subline(_ s: WindowStats) -> String {
        guard s.agg.active >= 1 else { return "Nothing yet. Start an agent and it shows up here." }
        var parts = ["\(s.agg.sessionIDs.count) session\(s.agg.sessionIDs.count == 1 ? "" : "s")"]
        if let c = s.change {
            parts.append("\(c >= 0 ? "↑" : "↓") \(Int(abs(c) * 100))% vs this time yesterday")
        } else {
            let projects = s.agg.byProject.count
            parts.append("\(projects) project\(projects == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private func rank(_ s: LiveState) -> Int {
        switch s {
        case .waitingOnYou: return 0
        case .running, .thinking: return 1
        case .finished: return 2
        case .idle: return 3
        }
    }
}

/// Compact colour key for the day ribbon: top three activities (four overflow the popover).
struct CategoryKey: View {
    let values: [Category: TimeInterval]
    var body: some View {
        let top = values.filter { $0.value >= 1 }.sorted { $0.value > $1.value }.prefix(3)
        HStack(spacing: 12) {
            ForEach(Array(top), id: \.key) { c, v in
                HStack(spacing: 5) {
                    Circle().fill(c.color).frame(width: 6, height: 6)
                    Text(c.shortTitle).foregroundStyle(.secondary)
                    Text(v.clock).foregroundStyle(.tertiary).monospacedDigit()
                }
                .lineLimit(1).fixedSize()
            }
        }
        .font(.system(size: 10.5))
    }
}

struct LiveRow: View {
    let session: SessionSummary
    let now: Date
    var animated = true
    let action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        let state = session.live(at: now)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    NameTag(text: session.title, dot: state.color)
                    if let since = state.since {
                        Text("▲ \(now.timeIntervalSince(since).clock)")
                            .font(.hud(10.5, .semibold)).foregroundStyle(state.color)
                            .fixedSize()
                    }
                }
                // What it's doing, then the command's description (or where it runs).
                HStack(spacing: 4) {
                    Text(state.headline.uppercased()).font(.hud(9.5, .semibold)).tracking(0.5)
                        .foregroundStyle(state.color).layoutPriority(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(state.detail ?? session.place)
                        .font(.system(size: 11)).foregroundStyle(.secondary).truncationMode(.tail)
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(Color.white.opacity(hover.wrappedValue ? 0.06 : 0), in: Rectangle())
            .contentShape(Rectangle())
            .help(session.place)
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }
}

struct InsightRow: View {
    let insight: Insight
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 10) {
            Image(systemName: insight.symbol)
                .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                .foregroundStyle(insight.tint)
                .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                .background(insight.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(insight.title).font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                if !insight.detail.isEmpty {
                    Text(insight.detail).font(.system(size: compact ? 10.5 : 11.5)).foregroundStyle(.secondary)
                        .lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A quiet icon-only button that brightens on hover.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover.wrappedValue ? Color.white : HUD.dim)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(hover.wrappedValue ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover.wrappedValue = h } }
        .help(help)
    }
}
