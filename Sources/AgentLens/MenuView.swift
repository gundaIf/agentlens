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
            .sorted { ($0.live(at: now).rank, $1.end) < ($1.live(at: now).rank, $0.end) }
        let working = live.filter { $0.live(at: now).isWorking }.count
        let waiting = live.filter { $0.live(at: now).isWaiting }.count
        let insights = Insights.list(stats, periodName: "today")
        let apps = AppUsage.shared.apps.filter(\.isTracked)
        let gauges = Limits.shared.gauges
        let shown = Array(live.prefix(expanded ? 9 : 6))

        VStack(alignment: .leading, spacing: 0) {
            // Header: mark, name, one-line status, settings.
            HStack(spacing: 8) {
                LensMark(size: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AgentLens").font(.system(size: 13, weight: .semibold))
                    Text(status(working: working, waiting: waiting))
                        .font(.system(size: 11)).foregroundStyle(waiting > 0 ? HUD.alarm : Color.secondary)
                        .contentTransition(.opacity)
                }
                Spacer()
                if UpdateChecker.shared.updateAvailable {
                    Button { NSWorkspace.shared.open(UpdateChecker.shared.latestURL ?? UpdateChecker.releasesURL) } label: {
                        Chip(text: "Update", symbol: "arrow.down.circle", tint: HUD.phosphor)
                    }
                    .buttonStyle(.plain)
                    .help("AgentLens \(UpdateChecker.shared.latest ?? "") is available")
                }
                IconButton(symbol: "gearshape", help: "Settings (⌘,)") { go(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            .cascade(0)

            // Sessions, newest need-you first.
            VStack(alignment: .leading, spacing: 2) {
                if !store.loaded {
                    Text("Reading transcripts…").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 10)
                } else if live.isEmpty {
                    HStack(spacing: 12) {
                        Die(state: .idle, size: 26, animated: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All quiet").font(.system(size: 12.5, weight: .semibold))
                            Text("Agents show up here the moment they start.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 10)
                } else {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                        LiveSessionRow(session: s, now: now, index: i + 1, animated: animated)
                    }
                    if live.count > shown.count {
                        Button { AppController.shared.openDashboard(select: nil) } label: {
                            Text("+\(live.count - shown.count) more in the dashboard")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 8)
            .background(shortcuts(shown))
            .cascade(1)

            Hairline()

            // Today, and limits.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(stats.agg.active.clock).font(.number(20))
                            Text("today").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Text(subline(stats)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if stats.agg.active >= 1 {
                        RingChart(values: stats.agg.byCategory, lineWidth: 4, gapDegrees: 4)
                            .frame(width: 26, height: 26)
                    }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 9) {
                        DayRibbon(sessions: store.sessions, day: now, now: now, barHeight: 20)
                            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                            .background(Color.white.opacity(0.03))
                            .crt()
                        if stats.agg.active >= 1 { CategoryKey(values: stats.agg.byCategory) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !gauges.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(gauges.prefix(3)) { LimitRow(gauge: $0, now: now) }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
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
                    HStack(spacing: 6) {
                        Text("Open dashboard").font(.system(size: 12, weight: .medium))
                        Text("⌘D").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
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
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Show less" : "Show the day ribbon, AI apps and insights")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .cascade(4)
        }
    }

    /// ⌘1–⌘9 go to that session, ⌘↩ to the first one (the one that needs you, if any).
    private func shortcuts(_ sessions: [SessionSummary]) -> some View {
        ZStack {
            ForEach(Array(sessions.prefix(9).enumerated()), id: \.element.id) { i, s in
                Button("") { Jump.go(to: s) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            if let first = sessions.first {
                Button("") { Jump.go(to: first) }.keyboardShortcut(.return, modifiers: .command)
            }
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func status(working: Int, waiting: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? "All quiet" : parts.joined(separator: " · ")
    }

    private func subline(_ s: WindowStats) -> String {
        guard s.agg.active >= 1 else { return "Nothing yet today" }
        var parts = ["\(s.agg.sessionIDs.count) session\(s.agg.sessionIDs.count == 1 ? "" : "s")"]
        if let c = s.change {
            parts.append("\(c >= 0 ? "↑" : "↓") \(Int(abs(c) * 100))% vs yesterday")
        } else {
            let projects = s.agg.byProject.count
            parts.append("\(projects) project\(projects == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
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
                    Text(state.phrase).font(.system(size: 11, weight: .medium))
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
