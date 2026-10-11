import Foundation

/// Turns a transcript's raw events into a partition of active time.
///
/// Between two consecutive events, the gap is attributed to whatever the agent was doing:
/// a pending tool call → that tool's category; otherwise, mid-turn → Thinking;
/// after end_turn → idle (not counted). Long gaps are capped so sessions left open for
/// days don't count as days of work.
///
/// With hooks installed, their events are merged in: exact tool start/end times, and
/// permission prompts, whose wait is credited to Waiting on you instead of the tool.
enum Analyzer {
    static let maxThinkingGap: TimeInterval = 10 * 60
    static let maxToolGap: TimeInterval = 30 * 60

    /// A session, with its subagents (inline sidechains, or files in `subagents/`) as children.
    static func summarize(_ t: Transcript, hooks: HookLog? = nil, subagentFiles: [Transcript] = []) -> SessionSummary? {
        let project = t.source == .cowork ? "Cowork" : ((t.cwd ?? "") as NSString).lastPathComponent
        let session = t.sessionID
        guard var s = summarize(log: t.main, id: t.id, source: t.source, title: t.displayTitle, project: project,
                                cwd: t.cwd, branch: t.branch,
                                hooks: hooks?.events(session: session, subagent: t.subagent?.agentID) ?? []) else { return nil }
        s.agentType = t.subagent?.agentType
        s.parentID = t.subagent?.parentPath

        var children: [SessionSummary] = []
        for agent in t.sidechainOrder {
            guard let log = t.sidechains[agent],
                  var c = summarize(log: log, id: t.id + "#" + agent, source: t.source,
                                    title: String((log.firstPrompt ?? "Subagent").prefix(60)), project: project,
                                    cwd: t.cwd, branch: t.branch,
                                    hooks: hooks?.events(session: session, subagent: agent) ?? []) else { continue }
            c.parentID = t.id
            children.append(c)
        }
        for f in subagentFiles {
            if let c = summarize(f, hooks: hooks) { children.append(c) }
        }
        s.children = children.sorted { $0.start < $1.start }
        return s
    }

    static func summarize(log: Log, id: String, source: Source, title: String, project: String,
                          cwd: String?, branch: String?, hooks: [Event]) -> SessionSummary? {
        // Hook events slot in after transcript events with the same timestamp.
        let events = hooks.isEmpty ? log.events
            : (log.events.enumerated().map { ($0.element, 0, $0.offset) } + hooks.enumerated().map { ($0.element, 1, $0.offset) })
                .sorted { ($0.0.time, $0.1, $0.2) < ($1.0.time, $1.1, $1.2) }.map(\.0)
        guard let first = log.events.first, let last = events.last else { return nil }
        let tools = log.tools

        var segments: [Segment] = []
        var chunks: [Chunk] = []
        var pending: [String] = []
        var permission: [String: Date] = [:]    // pending tool id → when its permission prompt appeared
        var turnEnded = true
        var toolCalls = 0, errors = 0, prompts = 0

        func currentChunkIndex(_ time: Date) -> Int {
            if chunks.isEmpty { chunks.append(Chunk(prompt: "(session start)", start: time, end: time)) }
            return chunks.count - 1
        }

        for (i, e) in events.enumerated() {
            // 1. Apply the event.
            switch e.kind {
            case .prompt(let text):
                prompts += 1
                pending.removeAll(); permission.removeAll()
                turnEnded = false
                chunks.append(Chunk(prompt: text, start: e.time, end: e.time))
            case .assistant(let endTurn):
                if endTurn { turnEnded = true; pending.removeAll(); permission.removeAll() } else { turnEnded = false }
            case .toolUse(let id):
                pending.append(id)
                turnEnded = false
                toolCalls += 1
                let ci = currentChunkIndex(e.time)
                chunks[ci].toolCalls += 1
                if let call = tools[id], call.category == .editing, let f = call.file, !chunks[ci].files.contains(f) {
                    chunks[ci].files.append(f)
                }
            case .toolResult(let id, let isError):
                pending.removeAll { $0 == id }
                permission[id] = nil
                if isError { errors += 1; chunks[currentChunkIndex(e.time)].errors += 1 }
            case .hookToolStart(let id):
                // Normally the transcript's tool_use came first; if not, start the call here.
                if tools[id] != nil, !pending.contains(id), !(tools[id]?.end.map { $0 <= e.time } ?? false) {
                    pending.append(id); turnEnded = false
                }
            case .hookToolEnd(let id):
                pending.removeAll { $0 == id }
                permission[id] = nil
            case .permissionPrompt:
                if let id = pending.last { permission[id] = e.time }
            case .hookStop:
                turnEnded = true; pending.removeAll(); permission.removeAll()
            }
            let ci = currentChunkIndex(e.time)
            chunks[ci].outputTokens += e.outputTokens
            chunks[ci].end = e.time

            // 2. Attribute the gap until the next event.
            guard i + 1 < events.count else { break }
            let gap = events[i + 1].time.timeIntervalSince(e.time)
            guard gap > 0 else { continue }
            var seg: Segment?
            if let id = pending.last, let call = tools[id] {
                let label = call.detail.isEmpty ? call.shortName : call.detail
                if permission[id] != nil {
                    seg = Segment(start: e.time, duration: min(gap, maxToolGap), category: .waiting,
                                  label: "Permission: \(call.shortName) · \(label)", tool: "Permission prompt", permission: true)
                } else {
                    seg = Segment(start: e.time, duration: min(gap, maxToolGap), category: call.category,
                                  label: label, tool: call.shortName, command: call.commandKey)
                }
            } else if !turnEnded, gap <= maxThinkingGap {
                seg = Segment(start: e.time, duration: gap, category: .thinking, label: "")
            }
            guard let s = seg else { continue }
            segments.append(s)
            chunks[ci].active += s.duration
            chunks[ci].byCategory[s.category, default: 0] += s.duration
            if var step = chunks[ci].steps.last, step.category == s.category {
                step.duration += s.duration
                if !s.label.isEmpty, !step.labels.contains(s.label) { step.labels.append(s.label) }
                chunks[ci].steps[chunks[ci].steps.count - 1] = step
            } else {
                chunks[ci].steps.append(Step(category: s.category, duration: s.duration,
                                             labels: s.label.isEmpty ? [] : [s.label]))
            }
        }

        var totals = Aggregate()
        for s in segments { totals.add(s, project: project, session: id) }

        let lastEndedTurn: Bool = {
            if case .assistant(let end) = last.kind { return end }
            if case .hookStop = last.kind { return true }
            return false
        }()

        return SessionSummary(
            id: id, source: source, title: title, project: project,
            cwd: cwd ?? "", branch: branch,
            start: first.time, end: last.time,
            segments: segments, totals: totals, chunks: chunks,
            toolCalls: toolCalls, errors: errors,
            outputTokens: log.outputTokens, inputTokens: log.inputTokens, prompts: prompts,
            lastEventTime: last.time, lastEventEndedTurn: lastEndedTurn,
            pendingTool: pending.last.flatMap { tools[$0] },
            permissionSince: pending.last.flatMap { permission[$0] }
        )
    }

    /// Totals across sessions, limited to segments that started on/after `since`.
    static func aggregate(_ sessions: [SessionSummary], since: Date?) -> Aggregate {
        var agg = Aggregate()
        for s in sessions where since == nil || s.end >= since! {
            for seg in s.segments where since == nil || seg.start >= since! {
                agg.add(seg, project: s.project, session: s.id)
            }
        }
        return agg
    }
}
