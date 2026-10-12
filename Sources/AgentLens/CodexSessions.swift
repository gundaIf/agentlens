import Foundation

/// OpenAI Codex, the agent inside the ChatGPT desktop app (and the `codex` CLI).
/// Sessions are ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, titled in ~/.codex/session_index.jsonl.
///
/// Codex logs each step as an `item_completed` event with exact start and end times (ms), typed:
/// UserMessage (the prompt), Reasoning, AgentMessage (writing the reply), CommandExecution, FileChange
/// and Extension (web search, plugins). Turns are bracketed by task_started / task_complete.
/// So time comes straight from the steps; gaps inside a turn are the model working (Thinking).
final class CodexSessions {
    private var cache: [String: (stamp: String, summary: SessionSummary?)] = [:]
    private var titles: [String: String] = [:]
    private var indexStamp = ""

    var summaries: [SessionSummary] { cache.values.compactMap(\.summary) }

    private var root: URL { Paths.home.appendingPathComponent(".codex") }

    func poll() -> Bool {
        var changed = false
        let index = root.appendingPathComponent("session_index.jsonl")
        let istamp = stamp(index)
        if istamp != indexStamp {
            indexStamp = istamp
            titles = [:]
            for o in CodexSessions.lines(index) {
                if let id = o["id"] as? String, let name = o["thread_name"] as? String, !name.isEmpty { titles[id] = name }
            }
            cache = cache.mapValues { (stamp: "", summary: $0.summary) }   // re-title everything
        }
        var seen = Set<String>()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
            seen.insert(url.path)
            let s = stamp(url)
            if cache[url.path]?.stamp == s { continue }
            cache[url.path] = (s, CodexSessions.summarize(url, titles: titles))
            changed = true
        }
        for key in cache.keys where !seen.contains(key) { cache[key] = nil; changed = true }
        return changed
    }

    private func stamp(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "-" }
        return "\((a[.size] as? NSNumber)?.int64Value ?? 0):\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    // MARK: Parsing

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func lines(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    private static func ms(_ v: Any?) -> Date? {
        guard let n = (v as? NSNumber)?.doubleValue, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    private static func text(_ content: Any?) -> String {
        ((content as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// One step with its real start/end.
    private struct Item {
        let start: Date, end: Date
        let category: Category
        let label: String
        let tool: String?
        var command: String? = nil
        var files: [String] = []
        var failed = false
    }

    private struct Turn {
        var start: Date
        var end: Date?
        var prompt: String?
        var steps: [Item] = []
        var outputTokens = 0
    }

    static func summarize(_ url: URL, titles: [String: String]) -> SessionSummary? {
        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var originator = ""
        var turns: [Turn] = []
        var inputTokens = 0, outputTokens = 0
        var first: Date?, last: Date?

        for o in lines(url) {
            let ts = (o["timestamp"] as? String).flatMap(iso.date)
            if let ts { first = first ?? ts; last = ts }
            let type = o["type"] as? String
            let p = o["payload"] as? [String: Any] ?? [:]

            switch type {
            case "session_meta":
                sessionID = p["id"] as? String ?? sessionID
                cwd = p["cwd"] as? String ?? cwd
                originator = p["originator"] as? String ?? originator
            case "token_usage_record":
                let u = p["usage"] as? [String: Any] ?? [:]
                let out = (u["output_tokens"] as? Int ?? 0)
                outputTokens += out
                inputTokens += (u["input_tokens"] as? Int ?? 0)
                if !turns.isEmpty { turns[turns.count - 1].outputTokens += out }
            case "event_msg":
                switch p["type"] as? String {
                case "task_started":
                    turns.append(Turn(start: ms(p["started_at"]) ?? ts ?? Date()))
                case "task_complete":
                    if !turns.isEmpty { turns[turns.count - 1].end = ms(p["completed_at"]) ?? ts }
                case "item_completed":
                    guard let item = p["item"] as? [String: Any], let kind = item["type"] as? String else { break }
                    let s = ms(p["started_at_ms"]) ?? ts ?? Date()
                    let e = ms(p["completed_at_ms"]) ?? s
                    if turns.isEmpty { turns.append(Turn(start: s)) }
                    var step: Item?
                    switch kind {
                    case "UserMessage":
                        if turns[turns.count - 1].prompt == nil {
                            turns[turns.count - 1].prompt = text(item["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    case "Reasoning":
                        step = Item(start: s, end: e, category: .thinking, label: "", tool: nil)
                    case "AgentMessage":
                        step = Item(start: s, end: e, category: .thinking, label: "", tool: nil)
                    case "CommandExecution":
                        let cmd = ((item["command"] as? [String]) ?? []).joined(separator: " ")
                        let shown = cmd.replacingOccurrences(of: "^(/bin/)?(ba|z)?sh -l?c ", with: "", options: .regularExpression)
                        var st = Item(start: s, end: e, category: .shell, label: String(shown.prefix(140)), tool: "exec")
                        st.command = shown
                        st.failed = (item["status"] as? String) == "failed" || ((item["exit_code"] as? Int).map { $0 != 0 } ?? false)
                        step = st
                    case "FileChange":
                        let paths = ((item["changes"] as? [String: Any]) ?? [:]).keys.sorted()
                        var st = Item(start: s, end: e, category: .editing,
                                      label: paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), tool: "apply_patch")
                        st.files = paths
                        st.failed = (item["status"] as? String) == "failed"
                        step = st
                    case "Extension":
                        let k = item["kind"] as? String ?? "extension"
                        let cat: Category = (k.contains("web") || k.contains("search")) ? .web : (k.contains("brows") ? .browser : .other)
                        step = Item(start: s, end: e, category: cat, label: (item["query"] as? String) ?? k, tool: k)
                    default:
                        break
                    }
                    if let step { turns[turns.count - 1].steps.append(step) }
                default: break
                }
            default: break
            }
        }
        guard let start = first, let end = last, !turns.isEmpty else { return nil }

        let id = "codex:" + sessionID
        // ChatGPT Projects run in ~/.codex/.chatgpt-projects/g-p-<id>; the folder name means nothing to people.
        let project = cwd.contains("/.chatgpt-projects/") ? "ChatGPT project" : (cwd as NSString).lastPathComponent
        var segments: [Segment] = []
        var chunks: [Chunk] = []
        var toolCalls = 0, errors = 0

        for t in turns {
            var chunk = Chunk(prompt: t.prompt.flatMap { $0.isEmpty ? nil : $0 } ?? "(turn)", start: t.start, end: t.end ?? end)
            chunk.outputTokens = t.outputTokens
            var cursor = t.start
            func add(_ seg: Segment) {
                guard seg.duration > 0 else { return }
                segments.append(seg)
                chunk.active += seg.duration
                chunk.byCategory[seg.category, default: 0] += seg.duration
                if var s = chunk.steps.last, s.category == seg.category {
                    s.duration += seg.duration
                    if !seg.label.isEmpty, !s.labels.contains(seg.label) { s.labels.append(seg.label) }
                    chunk.steps[chunk.steps.count - 1] = s
                } else {
                    chunk.steps.append(Step(category: seg.category, duration: seg.duration,
                                                      labels: seg.label.isEmpty ? [] : [seg.label]))
                }
            }
            for st in t.steps.sorted(by: { $0.start < $1.start }) {
                // Gap before this step: the model working between steps.
                let gap = st.start.timeIntervalSince(cursor)
                if gap > 0, gap <= Analyzer.maxThinkingGap {
                    add(Segment(start: cursor, duration: gap, category: .thinking, label: ""))
                }
                let from = max(st.start, cursor)
                add(Segment(start: from, duration: min(st.end.timeIntervalSince(from), Analyzer.maxToolGap),
                            category: st.category, label: st.label, tool: st.tool,
                            command: st.command.map(ToolCall.commandFamily)))
                cursor = max(cursor, st.end)
                if st.tool != nil { toolCalls += 1; chunk.toolCalls += 1 }
                if st.failed { errors += 1; chunk.errors += 1 }
                for f in st.files where !chunk.files.contains(f) { chunk.files.append(f) }
            }
            if let e = t.end, e > cursor, e.timeIntervalSince(cursor) <= Analyzer.maxThinkingGap {
                add(Segment(start: cursor, duration: e.timeIntervalSince(cursor), category: .thinking, label: ""))
            }
            chunks.append(chunk)
        }

        var totals = Aggregate()
        for s in segments { totals.add(s, project: project, session: id) }
        let open = turns.last?.end == nil
        let title = titles[sessionID] ?? chunks.first.map { String($0.prompt.prefix(60)) } ?? "Codex session"

        return SessionSummary(
            id: id, source: .codex, title: title, project: project,
            cwd: cwd, branch: nil,
            start: start, end: end,
            segments: segments, totals: totals, chunks: chunks,
            toolCalls: toolCalls, errors: errors,
            outputTokens: outputTokens, inputTokens: inputTokens, prompts: chunks.filter { $0.prompt != "(turn)" }.count,
            lastEventTime: end, lastEventEndedTurn: !open,
            pendingTool: nil, permissionSince: nil
        )
    }
}
