import Foundation

/// Grok's coding agent (the `grok` CLI): one folder per session under ~/.grok/sessions/<cwd>/<id>/.
///
/// Unlike Claude Code, Grok writes an explicit timing log, events.jsonl: turn_started / turn_ended,
/// phase_changed (waiting_for_model, streaming_reasoning, streaming_text, tool_execution,
/// permission_prompt), tool_started / tool_completed and permission_requested / resolved.
/// So time attribution reads phases directly instead of inferring them from gaps.
/// Prompts come from chat_history.jsonl (user messages, in turn order), files from hunk_records.jsonl,
/// and the title from summary.json. Sessions are small, so a changed session is simply re-read.
final class GrokSessions {
    private var cache: [String: (stamp: String, summary: SessionSummary?)] = [:]

    var summaries: [SessionSummary] { cache.values.compactMap(\.summary) }

    /// Re-reads sessions whose files changed. Returns true if anything did.
    func poll() -> Bool {
        let root = Paths.home.appendingPathComponent(".grok/sessions")
        var changed = false
        var seen = Set<String>()
        for cwdDir in children(root) {
            for dir in children(cwdDir) where FileManager.default.fileExists(atPath: dir.appendingPathComponent("events.jsonl").path) {
                seen.insert(dir.path)
                let stamp = ["events.jsonl", "chat_history.jsonl", "summary.json", "hunk_records.jsonl"]
                    .map { stampOf(dir.appendingPathComponent($0)) }.joined(separator: "|")
                if cache[dir.path]?.stamp == stamp { continue }
                cache[dir.path] = (stamp, GrokSessions.summarize(dir))
                changed = true
            }
        }
        for key in cache.keys where !seen.contains(key) { cache[key] = nil; changed = true }
        return changed
    }

    private func stampOf(_ url: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "-" }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mod = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(mod)"
    }

    private func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: Parsing

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ s: String?) -> Date? {
        guard var s else { return nil }
        // summary.json uses microseconds ("…45.908865Z"); ISO8601DateFormatter wants at most milliseconds.
        if let dot = s.firstIndex(of: "."), let z = s.firstIndex(of: "Z"), s.distance(from: dot, to: z) > 4 {
            s = String(s[..<s.index(dot, offsetBy: 4)]) + "Z"
        }
        return iso.date(from: s)
    }

    private static func lines(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    static func summarize(_ dir: URL) -> SessionSummary? {
        let events = lines(dir.appendingPathComponent("events.jsonl"))
        guard !events.isEmpty else { return nil }

        let summary = (try? Data(contentsOf: dir.appendingPathComponent("summary.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let cwd = (summary["info"] as? [String: Any])?["cwd"] as? String ?? ""
        let project = (cwd as NSString).lastPathComponent

        // User prompts in order; turn N answers prompt N.
        let prompts: [String] = lines(dir.appendingPathComponent("chat_history.jsonl")).compactMap { m in
            guard m["type"] as? String == "user" else { return nil }
            if let s = m["content"] as? String { return s }
            let blocks = m["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        let title = [summary["generated_title"], summary["session_summary"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty }
            ?? prompts.first.map { String($0.prefix(60)) } ?? "Grok session"

        var segments: [Segment] = []
        var chunks: [Chunk] = []
        var phase = "idle"
        var inTurn = false
        var tool: (name: String, start: Date)?
        var permissionSince: Date?
        var toolCalls = 0, errors = 0
        var prev: Date?
        var first: Date?, last: Date?

        for e in events {
            guard let t = date(e["ts"] as? String), let type = e["type"] as? String else { continue }
            first = first ?? t
            last = t

            // 1. Credit the time since the previous event to the phase we were in.
            if let p = prev, inTurn, !chunks.isEmpty {
                let gap = t.timeIntervalSince(p)
                var seg: Segment?
                switch phase {
                case "tool_execution":
                    let name = tool?.name ?? "tool"
                    seg = Segment(start: p, duration: min(gap, Analyzer.maxToolGap), category: Category.of(tool: name),
                                  label: name, tool: name)
                case "permission_prompt":
                    var s = Segment(start: p, duration: min(gap, Analyzer.maxToolGap), category: .waiting,
                                    label: "Permission: \(tool?.name ?? "tool")", tool: tool?.name)
                    s.permission = true
                    seg = s
                default:
                    if gap <= Analyzer.maxThinkingGap { seg = Segment(start: p, duration: gap, category: .thinking, label: "") }
                }
                if let s = seg, s.duration > 0 {
                    segments.append(s)
                    add(s, to: &chunks[chunks.count - 1])
                }
            }
            prev = t

            // 2. Apply the event.
            switch type {
            case "turn_started":
                inTurn = true
                phase = "waiting_for_model"
                let n = chunks.count
                chunks.append(Chunk(prompt: n < prompts.count ? prompts[n] : "Turn \(n + 1)", start: t, end: t))
            case "phase_changed":
                phase = e["phase"] as? String ?? phase
                if phase == "permission_prompt" { permissionSince = permissionSince ?? t } else { permissionSince = nil }
            case "tool_started":
                tool = (e["tool_name"] as? String ?? "tool", t)
                toolCalls += 1
                if !chunks.isEmpty { chunks[chunks.count - 1].toolCalls += 1 }
            case "tool_completed":
                if let o = e["outcome"] as? String, o != "success" {
                    errors += 1
                    if !chunks.isEmpty { chunks[chunks.count - 1].errors += 1 }
                }
            case "permission_requested":
                permissionSince = permissionSince ?? t
            case "permission_resolved":
                permissionSince = nil
            case "turn_ended":
                inTurn = false
                phase = "idle"
                permissionSince = nil
            default: break
            }
            if !chunks.isEmpty { chunks[chunks.count - 1].end = t }
        }
        guard let start = first, let end = last else { return nil }

        // Files the agent edited, attached to the prompt that caused them.
        for h in lines(dir.appendingPathComponent("hunk_records.jsonl")) {
            guard let path = h["filePath"] as? String, let i = h["promptIndex"] as? Int else { continue }
            let idx = min(max(i, 0), chunks.count - 1)
            if idx >= 0, !chunks[idx].files.contains(path) { chunks[idx].files.append(path) }
        }

        var totals = Aggregate()
        let id = "grok:" + dir.lastPathComponent
        for s in segments { totals.add(s, project: project, session: id) }

        let pending: ToolCall? = (inTurn && (phase == "tool_execution" || phase == "permission_prompt"))
            ? tool.map { ToolCall(id: "", name: $0.name, detail: "", file: nil, start: $0.start) } : nil

        return SessionSummary(
            id: id, source: .grok, title: title, project: project,
            cwd: cwd, branch: nil,
            start: start, end: end,
            segments: segments, totals: totals, chunks: chunks,
            toolCalls: toolCalls, errors: errors,
            outputTokens: 0, inputTokens: 0, prompts: chunks.count,
            lastEventTime: end, lastEventEndedTurn: !inTurn,
            pendingTool: pending,
            permissionSince: inTurn ? permissionSince : nil
        )
    }

    private static func add(_ s: Segment, to chunk: inout Chunk) {
        chunk.active += s.duration
        chunk.byCategory[s.category, default: 0] += s.duration
        if var step = chunk.steps.last, step.category == s.category {
            step.duration += s.duration
            if !s.label.isEmpty, !step.labels.contains(s.label) { step.labels.append(s.label) }
            chunk.steps[chunk.steps.count - 1] = step
        } else {
            chunk.steps.append(Step(category: s.category, duration: s.duration, labels: s.label.isEmpty ? [] : [s.label]))
        }
    }
}
