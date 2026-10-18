import SwiftUI
import Charts

private let overviewID = "__overview__"

struct DashboardView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar(selection: $store.selection)
                .scrollContentBackground(.hidden)
                .background(HUD.ink)
                .navigationSplitViewColumnWidth(min: 270, ideal: 300)
        } detail: {
            Group {
                if let s = store.session(store.selection) {
                    SessionDetail(session: s).id(s.id)
                } else {
                    OverviewView()
                }
            }
            .background(ScannerGround())
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Window ground: black ink with a faint scanner grid.
struct ScannerGround: View {
    var body: some View {
        ZStack {
            HUD.ink
            Canvas { ctx, size in
                stride(from: 0.0, through: max(size.width, size.height), by: 32).forEach { v in
                    ctx.fill(Path(CGRect(x: v, y: 0, width: 0.5, height: size.height)), with: .color(.white.opacity(0.025)))
                    ctx.fill(Path(CGRect(x: 0, y: v, width: size.width, height: 0.5)), with: .color(.white.opacity(0.025)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var selection: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            let now = ctx.date
            let startOfDay = Calendar.current.startOfDay(for: now)
            let weekStart = startOfDay.addingTimeInterval(-6 * 86400)
            let live = store.sessions.filter { $0.live(at: now).isVisible }
            let liveIDs = Set(live.map(\.id))
            let rest = store.sessions.filter { !liveIDs.contains($0.id) }

            List(selection: Binding(get: { selection ?? overviewID },
                                    set: { selection = $0 == overviewID ? nil : $0 })) {
                HStack(spacing: 10) {
                    LensMark(size: 18)
                    Text("Overview").font(.system(size: 13, weight: .medium))
                }
                .padding(.vertical, 3)
                .tag(overviewID)

                group("Live", live, now)
                group("Today", rest.filter { $0.end >= startOfDay }, now)
                group("Last 7 days", rest.filter { $0.end < startOfDay && $0.end >= weekStart }, now)
                group("Earlier", rest.filter { $0.end < weekStart }, now)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [SessionSummary], _ now: Date) -> some View {
        if !items.isEmpty {
            Section(title) {
                // Subagents nest under their session as disclosure rows.
                OutlineGroup(items, children: \.childrenOrNil) { s in
                    Group {
                        if s.isSubagent { SubagentRow(session: s, compact: true).padding(.vertical, 2) }
                        else { SessionRow(session: s, now: now) }
                    }
                    .tag(s.id)
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let now: Date

    var body: some View {
        let state = session.live(at: now)
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                LensMark(values: session.totals.byCategory, size: 22)
                if state.isVisible {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(HUD.ink, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(session.place).lineLimit(1)
                    Text("·")
                    Text(session.end, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(session.active.clock)
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Overview

enum TimeRange: String, CaseIterable, Identifiable {
    case hour = "1 hour", today = "Today", week = "7 days", month = "30 days", all = "All time"
    var id: String { rawValue }

    func since(_ now: Date) -> Date? {
        let sod = Calendar.current.startOfDay(for: now)
        switch self {
        case .hour: return now.addingTimeInterval(-3600)
        case .today: return sod
        case .week: return sod.addingTimeInterval(-6 * 86400)
        case .month: return sod.addingTimeInterval(-29 * 86400)
        case .all: return nil
        }
    }

    /// The previous window of equal length, to compare against.
    func previous(_ now: Date) -> (Date, Date)? {
        guard let s = since(now) else { return nil }
        if self == .today { return (s.addingTimeInterval(-86400), now.addingTimeInterval(-86400)) }
        let len = now.timeIntervalSince(s)
        return (s.addingTimeInterval(-len), s)
    }

    var periodName: String {
        switch self {
        case .hour: return "in the last hour"
        case .today: return "today"
        case .week: return "this week"
        case .month: return "this month"
        case .all: return "so far"
        }
    }

    var comparisonName: String {
        switch self {
        case .hour: return "the hour before"
        case .today: return "this time yesterday"
        case .week: return "the 7 days before"
        case .month: return "the 30 days before"
        case .all: return ""
        }
    }
}

struct OverviewView: View {
    @Environment(Store.self) private var store
    var scrolls = true
    // `State(...)` directly: the @State macro plugin isn't available without full Xcode.
    private let rangeState: State<TimeRange>
    private var range: TimeRange { rangeState.wrappedValue }

    init(scrolls: Bool = true, range: TimeRange = .today) {
        self.scrolls = scrolls
        self.rangeState = State(initialValue: range)
    }

    var body: some View {
        let now = Date()
        let prev = range.previous(now)
        let w = Insights.stats(store.sessions, from: range.since(now), to: now,
                               compareFrom: prev?.0, compareTo: prev?.1)
        let insights = Insights.list(w, periodName: range.periodName)

        Scrolling(enabled: scrolls) {
            VStack(alignment: .leading, spacing: 12) {
                header(w, now: now)

                if w.agg.active < 1 {
                    VStack(spacing: 10) {
                        LensMark(size: 44)
                        Text("No agent activity \(range.periodName)").font(.headline)
                        Text("Start a Claude Code or Cowork session and it appears here within seconds.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 60)
                    .surface()
                } else {
                    hero(w)
                    tiles(w)
                    activity(now)
                    if !AppUsage.shared.apps.isEmpty {
                        AppsCard(from: range.since(now), periodName: range.periodName)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        if !insights.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Eyebrow("Worth knowing")
                                ForEach(insights) { InsightRow(insight: $0) }
                            }
                            .surface()
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow("By activity")
                            CategoryLegend(values: w.agg.byCategory, showBlurb: true)
                        }
                        .surface()
                    }
                    HStack(alignment: .top, spacing: 14) {
                        RankCard(title: "Tools", rows: Aggregate.top(w.agg.byTool, 6))
                        RankCard(title: "Shell commands", rows: Aggregate.top(w.agg.byCommand, 6))
                        RankCard(title: "Projects", rows: Aggregate.top(w.agg.byProject, 6))
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
    }

    /// Status board: a system strip, a live headline, and a sentence on how the agents did in this range.
    private func header(_ w: WindowStats, now: Date) -> some View {
        let states = store.sessions.map { $0.live(at: now) }
        let working = states.filter(\.isWorking).count
        let waiting = states.filter { if case .waitingOnYou = $0 { return true }; return false }.count
        let seen = Set(store.sessions.filter { w.agg.sessionIDs.contains($0.id) }.map(\.source))
        let sources = [Source.claudeCode, .cowork, .codex, .chatgptChat, .grok, .muse, .grokBot].filter(seen.contains).map(\.rawValue).joined(separator: " / ")
        let host = Host.current().localizedName ?? "This Mac"

        let (headline, tint): (String, Color) = {
            if waiting > 0 { return ("\(waiting) agent\(waiting == 1 ? "" : "s") waiting on you", HUD.alarm) }
            if working > 0 { return ("\(working) agent\(working == 1 ? "" : "s") at work", HUD.phosphor) }
            if w.agg.active >= 1 { return ("All quiet · \(w.agg.active.clock) logged \(range.periodName)", HUD.paper) }
            return ("No signal \(range.periodName)", HUD.dim)
        }()

        return VStack(alignment: .leading, spacing: 10) {
            // System strip, after the scanner poster's top bar.
            HStack(spacing: 9) {
                Text("+")
                Text("AgentLens")
                Text("·").foregroundStyle(.tertiary)
                Text("System status")
                Text("·").foregroundStyle(.tertiary)
                Text("Scan: \(range.rawValue)").foregroundStyle(HUD.paper)
                if !sources.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(sources)
                }
                Spacer(minLength: 12)
                Text(host)
                Text("+")
            }
            .font(.hud(9.5, .semibold)).tracking(1.1).textCase(.uppercase)
            .foregroundStyle(HUD.dim).lineLimit(1)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        PulseDot(color: tint, animated: scrolls && (working > 0 || waiting > 0), size: 7)
                            .frame(width: 14, height: 14)
                        Text(headline.uppercased())
                            .font(.hud(19, .bold)).tracking(1.3)
                            .foregroundStyle(tint)
                            .shadow(color: tint.opacity(0.45), radius: 8)
                            .lineLimit(1)
                    }
                    Text(Insights.narrative(w, period: range.periodName, comparison: range.comparisonName,
                                            multiDay: range == .week || range == .month || range == .all))
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HooksPanel()
                Picker("", selection: rangeState.projectedValue) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 340)
            }
        }
        .padding(.bottom, 2)
    }

    private func hero(_ w: WindowStats) -> some View {
        HStack(alignment: .center, spacing: 22) {
            ThermalRule().frame(height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Agent time \(range.periodName)")
                Text(w.agg.active.clock).font(.hud(32, .semibold))
                    .shadow(color: Category.thinking.color.opacity(0.5), radius: 10)
                if let c = w.change {
                    HStack(spacing: 4) {
                        Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                        Text("\(Int(abs(c) * 100))% vs \(range.comparisonName)")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(c >= 0 ? Category.shell.color : .secondary)
                } else {
                    Text("Active work only. Idle time between turns isn't counted.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            ZStack {
                RingChart(values: w.agg.byCategory, lineWidth: 10, gapDegrees: 2.5)
                VStack(spacing: 0) {
                    let top = w.agg.byCategory.max { $0.value < $1.value }
                    Text(top.map { "\(Int(($0.value / w.agg.active * 100).rounded()))%" } ?? "")
                        .font(.hud(18, .semibold))
                    Text(top?.key.title.lowercased() ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 88, height: 88)
            CategoryLegend(values: w.agg.byCategory, limit: 5)
                .frame(width: 270)
        }
        .surface(padding: 14)
    }

    private func tiles(_ w: WindowStats) -> some View {
        HStack(spacing: 12) {
            StatTile(label: "Sessions", value: "\(w.agg.sessionIDs.count)", symbol: "square.stack")
            StatTile(label: "Prompts", value: "\(w.prompts)", symbol: "text.bubble")
            StatTile(label: "Work per prompt", value: w.perPrompt?.clock ?? "—", symbol: "arrow.triangle.branch")
            StatTile(label: "Waiting on you", value: (w.agg.byCategory[.waiting] ?? 0).clock, symbol: "hand.raised",
                     tint: (w.agg.byCategory[.waiting] ?? 0) >= 60 ? Category.waiting.color : nil)
            StatTile(label: "Files changed", value: "\(w.files.count)", symbol: "doc.on.doc")
        }
    }

    @ViewBuilder
    private func activity(_ now: Date) -> some View {
        if range == .today || range == .hour {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Eyebrow("Today, hour by hour")
                    Spacer()
                    Text("Each bar is 15 minutes").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                DayRibbon(sessions: store.sessions, day: now, now: now, barHeight: 38)
                    .padding(10)
                    .background(Color.black)
                    .crt()
                    .overlay(CornerBrackets(length: 8).stroke(HUD.bracket, lineWidth: 1))
                Hairline().padding(.vertical, 2)
                Eyebrow("Sessions")
                SessionLanes(sessions: store.sessions, day: now, now: now) { store.selection = $0 }
            }
            .surface(padding: 14)
        } else {
            let days = range == .week ? 7 : 30
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("When your agents work")
                    HourHeatmap(rows: Insights.hourGrid(store.sessions, days: days, now: now))
                }
                .surface(padding: 14)
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Per day")
                    DailyChart(byDay: Analyzer.aggregate(store.sessions, since: range.since(now)).byDay)
                }
                .surface(padding: 14)
                .frame(maxWidth: 420)
            }
        }
    }
}

private struct DailyChart: View {
    let byDay: [Date: [Category: TimeInterval]]

    var body: some View {
        let rows: [(Date, Category, Double)] = byDay.flatMap { day, cats in
            cats.map { (day, $0.key, $0.value / 60) }
        }
        Chart {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                BarMark(x: .value("Day", r.0, unit: .day), y: .value("Minutes", r.2), width: .ratio(0.62))
                    .foregroundStyle(by: .value("Activity", r.1.title))
                    .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale(domain: Category.allCases.map(\.title), range: Category.allCases.map(\.color))
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                AxisValueLabel { if let m = v.as(Double.self) { Text("\(Int(m))m") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
            }
        }
        .frame(height: 190)
    }
}

// MARK: - Session detail

struct SessionDetail: View {
    let session: SessionSummary
    var scrolls = true
    private let expandAllState = State(initialValue: false)
    private var expandAll: Bool { expandAllState.wrappedValue }

    init(session: SessionSummary, scrolls: Bool = true) {
        self.session = session
        self.scrolls = scrolls
    }

    var body: some View {
        Scrolling(enabled: scrolls) {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                HStack(spacing: 12) {
                    StatTile(label: "Active time", value: session.active.clock, symbol: "bolt")
                    StatTile(label: "Span", value: session.end.timeIntervalSince(session.start).clock, symbol: "calendar")
                    StatTile(label: "Prompts", value: "\(session.prompts)", symbol: "text.bubble")
                    StatTile(label: "Tool calls", value: "\(session.toolCalls)", symbol: "wrench.and.screwdriver",
                             note: session.errors > 0 ? "\(session.errors) failed" : nil)
                    StatTile(label: "Tokens out", value: session.outputTokens.compact, symbol: "text.cursor",
                             note: "\(session.inputTokens.compact) in")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Eyebrow("Session flow")
                        Spacer()
                        Text("Active time end to end · gaps mark each new prompt")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    SessionFlow(chunks: session.chunks)
                    CategoryKey(values: session.totals.byCategory)
                }
                .surface(padding: 14)

                if !session.children.isEmpty {
                    SubagentsCard(children: session.children) { AppController.shared.store.selection = $0 }
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("By activity")
                        CategoryLegend(values: session.totals.byCategory, showBlurb: true)
                    }
                    .surface()
                    RankCard(title: "Tools", rows: Aggregate.top(session.totals.byTool, 6))
                    if !session.totals.byCommand.isEmpty {
                        RankCard(title: "Shell commands", rows: Aggregate.top(session.totals.byCommand, 6))
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Workflow").font(.system(size: 18, weight: .semibold))
                    Text("\(session.chunks.count) step\(session.chunks.count == 1 ? "" : "s"), newest first")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show details", isOn: expandAllState.projectedValue).toggleStyle(.switch).controlSize(.small)
                }
                .padding(.top, 6)

                VStack(spacing: 0) {
                    let ordered = Array(session.chunks.enumerated()).reversed()
                    ForEach(Array(ordered), id: \.element.id) { i, c in
                        ChunkRow(index: i + 1, chunk: c, isLast: i == 0, expandAll: expandAll)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let state = session.live(at: ctx.date)
            HStack(alignment: .center, spacing: 16) {
                LensMark(values: session.totals.byCategory, size: 36)
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.title).font(.system(size: 18, weight: .semibold)).textSelection(.enabled).lineLimit(2)
                    HStack(spacing: 6) {
                        Chip(text: session.source.rawValue,
                             symbol: session.source.symbol)
                        if session.source != .cowork && !session.project.isEmpty {
                            Chip(text: session.project, symbol: "folder")
                        }
                        if let b = session.branch { Chip(text: b, symbol: "arrow.triangle.branch") }
                        if state.isVisible {
                            HStack(spacing: 5) {
                                PulseDot(color: state.color, animated: scrolls && state.isWorking, size: 6)
                                    .frame(width: 10, height: 10)
                                Text(state.headline)
                                if let s = state.since { Text(ctx.date.timeIntervalSince(s).clock).monospacedDigit().opacity(0.7) }
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(state.color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(state.color.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

/// One prompt in the workflow timeline: a node on the rail, and a card with what happened.
private struct ChunkRow: View {
    let index: Int
    let chunk: Chunk
    let isLast: Bool
    let expandAll: Bool
    private let expandedState = State(initialValue: false)
    private var expanded: Bool { expandedState.wrappedValue }

    var body: some View {
        let open = expanded || expandAll
        let dominant = chunk.byCategory.max { $0.value < $1.value }?.key ?? .thinking
        HStack(alignment: .top, spacing: 14) {
            // Rail
            VStack(spacing: 0) {
                Circle().fill(dominant.color).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(HUD.ink, lineWidth: 2))
                    .padding(.top, 13)
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(chunk.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 10) {
                        Label(chunk.active.clock, systemImage: "bolt.fill")
                        Label("\(chunk.toolCalls)", systemImage: "wrench.and.screwdriver")
                        if chunk.errors > 0 {
                            Label("\(chunk.errors)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Category.waiting.color)
                        }
                        if chunk.outputTokens > 0 { Label(chunk.outputTokens.compact, systemImage: "text.cursor") }
                    }
                    .labelStyle(TightLabel())
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }

                Text(chunk.prompt)
                    .font(.system(size: 12.5))
                    .lineLimit(open ? 14 : 1)
                    .textSelection(.enabled)

                if chunk.active >= 1 {
                    StepStrip(steps: chunk.steps, total: chunk.active)
                    StepSentence(steps: chunk.steps.coalesced())
                }

                if open { details }
            }
            .surface(radius: 9, padding: 10)
            .contentShape(Rectangle())
            .onTapGesture { expandedState.wrappedValue.toggle() }
            .padding(.bottom, 6)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hairline()
            ForEach(chunk.steps.filter { $0.duration >= 1 || !$0.labels.isEmpty }) { step in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(step.category.color)
                        .frame(width: 3).frame(minHeight: 16)
                    Text(step.category.title).font(.system(size: 11.5, weight: .medium)).frame(width: 118, alignment: .leading)
                    Text(step.duration.clock).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(step.labels.prefix(4).enumerated()), id: \.offset) { _, l in
                            Text(l).lineLimit(1).truncationMode(.middle)
                        }
                        if step.labels.count > 4 { Text("+\(step.labels.count - 4) more").foregroundStyle(.tertiary) }
                    }
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }
            if !chunk.files.isEmpty {
                Hairline()
                Eyebrow("Files changed")
                ForEach(chunk.files, id: \.self) { f in
                    Text(f).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
        }
    }
}

/// "Thinking 2m → Running commands 45s → Editing files 12s"
private struct StepSentence: View {
    let steps: [Step]
    var body: some View {
        let shown = Array(steps.prefix(7))
        HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.quaternary) }
                HStack(spacing: 4) {
                    Circle().fill(s.category.color).frame(width: 6, height: 6)
                    Text(s.category.title).foregroundStyle(.secondary)
                    Text(s.duration.clock).foregroundStyle(.tertiary).monospacedDigit()
                }
                .lineLimit(1).fixedSize()
            }
            if steps.count > shown.count { Text("+\(steps.count - shown.count)").foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11))
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

// MARK: - Shared pieces

/// ScrollView in the app; plain layout for offscreen snapshots (ImageRenderer can't draw scroll views).
private struct Scrolling<C: View>: View {
    let enabled: Bool
    @ViewBuilder let content: C

    var body: some View {
        if enabled { ScrollView { content } } else { content.frame(maxHeight: .infinity, alignment: .top) }
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var symbol: String? = nil
    var note: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(label)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.tileNumber).monospacedDigit().foregroundStyle(tint ?? .primary)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .surface(padding: 10)
    }
}

private struct RankCard: View {
    let title: String
    let rows: [(String, TimeInterval)]

    var body: some View {
        let rows = rows.filter { $0.1 >= 1 }
        let maxV = max(rows.first?.1 ?? 1, 1)
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(title)
            if rows.isEmpty {
                Text("Nothing yet").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(rows, id: \.0) { name, v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(v.clock).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.05))
                            Capsule().fill(HUD.heat(0.25 + 0.75 * v / maxV)).frame(width: max(3, g.size.width * v / maxV))
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .surface()
    }
}
