import Foundation

/// The events of one agent: the main conversation, or one subagent.
final class Log {
    var events: [Event] = []
    var tools: [String: ToolCall] = [:]
    var inputTokens = 0
    var outputTokens = 0
    var seenMessageIDs = Set<String>()

    var firstPrompt: String? {
        for e in events { if case .prompt(let p) = e.kind { return p } }
        return nil
    }
}

/// Facts about a subagent transcript, from `subagents/agent-<id>.meta.json`.
struct SubagentInfo {
    let parentPath: String      // the parent session's .jsonl
    let agentID: String
    var description: String?
    var agentType: String?
}

/// One transcript file, read incrementally: each poll only parses bytes appended since the last one.
final class Transcript {
    let url: URL
    let source: Source
    var title: String?
    var customTitle: String?
    var cwd: String?
    var branch: String?
    /// Set for `<session>/subagents/agent-<id>.jsonl` files, whose lines are all sidechain lines.
    var subagent: SubagentInfo?
    let main = Log()
    /// Older transcripts keep subagent lines inline (`isSidechain: true`), keyed by agentId.
    private(set) var sidechains: [String: Log] = [:]
    private(set) var sidechainOrder: [String] = []
    private(set) var changed = true

    private var offset: UInt64 = 0
    private var partial = Data()

    var events: [Event] { main.events }
    var tools: [String: ToolCall] { main.tools }
    var inputTokens: Int { main.inputTokens }
    var outputTokens: Int { main.outputTokens }

    /// Claude Code session id: the file name, or the parent's for a subagent file.
    var sessionID: String {
        let path = subagent?.parentPath ?? url.path
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(url: URL, source: Source, title: String? = nil) {
        self.url = url
        self.source = source
        self.title = title
    }

    var id: String { url.path }
    var displayTitle: String {
        if let t = customTitle ?? title ?? subagent?.description, !t.isEmpty { return t }
        if let p = main.firstPrompt { return String(p.prefix(60)) }
        return url.deletingPathExtension().lastPathComponent
    }

    func markRead() { changed = false }
    /// Forces a re-summary, e.g. when new hook events arrive for this session.
    func invalidate() { changed = true }

    /// Reads any newly appended lines. Returns true if anything new was parsed.
    @discardableResult
    func poll() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return false }
        if size < offset { reset() }            // file was rewritten
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }
        offset += UInt64(data.count)

        var buffer = partial
        buffer.append(data)
        var lineStart = buffer.startIndex
        while let nl = buffer[lineStart...].firstIndex(of: 0x0A) {
            parse(line: buffer[lineStart..<nl])
            lineStart = buffer.index(after: nl)
        }
        partial = Data(buffer[lineStart...])
        changed = true
        return true
    }

    private func reset() {
        offset = 0; partial = Data()
        main.events = []; main.tools = [:]; main.seenMessageIDs = []; main.inputTokens = 0; main.outputTokens = 0
        sidechains = [:]; sidechainOrder = []
    }

    private func sidechain(_ id: String) -> Log {
        if let l = sidechains[id] { return l }
        let l = Log()
        sidechains[id] = l
        sidechainOrder.append(id)
        return l
    }

    private func parse(line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if type == "custom-title", let t = obj["customTitle"] as? String { customTitle = t; return }
        guard type == "user" || type == "assistant",
              let ts = obj["timestamp"] as? String,
              let time = Transcript.iso.date(from: ts),
              let message = obj["message"] as? [String: Any] else { return }
        let log: Log
        if obj["isSidechain"] as? Bool == true, subagent == nil {
            log = sidechain(obj["agentId"] as? String ?? "sidechain")
        } else {
            log = main
        }
        if let c = obj["cwd"] as? String { cwd = c }
        if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }

        if type == "user" {
            if obj["isMeta"] as? Bool == true { return }
            if let text = message["content"] as? String {
                addPrompt(text, at: time, to: log)
            } else if let blocks = message["content"] as? [[String: Any]] {
                var text = ""
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_result":
                        let id = b["tool_use_id"] as? String ?? ""
                        let err = b["is_error"] as? Bool ?? false
                        if var call = log.tools[id] { call.end = time; call.isError = err; log.tools[id] = call }
                        log.events.append(Event(time: time, kind: .toolResult(id: id, isError: err)))
                    case "text":
                        text += (b["text"] as? String ?? "")
                    default: break
                    }
                }
                if !text.isEmpty { addPrompt(text, at: time, to: log) }
            }
            return
        }

        // assistant
        var out = 0
        if let id = message["id"] as? String, !log.seenMessageIDs.contains(id), let usage = message["usage"] as? [String: Any] {
            log.seenMessageIDs.insert(id)
            out = usage["output_tokens"] as? Int ?? 0
            log.outputTokens += out
            log.inputTokens += (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        }
        let endTurn = (message["stop_reason"] as? String).map { $0 == "end_turn" || $0 == "stop_sequence" } ?? false
        var sawTool = false
        for b in (message["content"] as? [[String: Any]]) ?? [] where b["type"] as? String == "tool_use" {
            let id = b["id"] as? String ?? UUID().uuidString
            let name = b["name"] as? String ?? "tool"
            let input = b["input"] as? [String: Any] ?? [:]
            let (detail, file) = Transcript.describe(name: name, input: input)
            let command = (input["command"] as? String)?.components(separatedBy: "\n").first
            log.tools[id] = ToolCall(id: id, name: name, detail: detail, command: command, file: file, start: time)
            log.events.append(Event(time: time, kind: .toolUse(id: id), outputTokens: sawTool ? 0 : out))
            sawTool = true
        }
        if !sawTool { log.events.append(Event(time: time, kind: .assistant(endTurn: endTurn), outputTokens: out)) }
    }

    private func addPrompt(_ raw: String, at time: Date, to log: Log) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash commands arrive wrapped in tags; keep the command, drop local echo noise.
        if text.hasPrefix("<local-command") || text.hasPrefix("<system-reminder>") { return }
        if text.hasPrefix("[Request interrupted") {
            log.events.append(Event(time: time, kind: .assistant(endTurn: true)))
            return
        }
        if let r = text.range(of: "<command-name>"), let e = text.range(of: "</command-name>") {
            let cmd = String(text[r.upperBound..<e.lowerBound])
            var args = ""
            if let a = text.range(of: "<command-args>"), let ae = text.range(of: "</command-args>") {
                args = String(text[a.upperBound..<ae.lowerBound])
            }
            text = (cmd + " " + args).trimmingCharacters(in: .whitespaces)
        }
        // Unwrap pasted blocks and other markup so prompts read as plain text.
        text = text.replacingOccurrences(of: "<pasted_content[^>]*>", with: "[pasted] ", options: .regularExpression)
            .replacingOccurrences(of: "</?[a-z_-]+( [^>]*)?>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        log.events.append(Event(time: time, kind: .prompt(text)))
    }

    static func describe(name: String, input: [String: Any]) -> (String, String?) {
        func s(_ k: String) -> String? { input[k] as? String }
        func short(_ path: String) -> String {
            let comps = (path as NSString).pathComponents.filter { $0 != "/" }
            return comps.suffix(2).joined(separator: "/")
        }
        switch name {
        case "Bash", "bash":
            // Prefer the agent's own one-line description of the command.
            if let d = s("description"), !d.isEmpty { return (d, nil) }
            let cmd = (s("command") ?? "").components(separatedBy: "\n").first ?? ""
            return (String(cmd.prefix(160)), nil)
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "read", "edit", "write":
            let p = s("file_path") ?? s("notebook_path") ?? s("path") ?? ""
            return (short(p), p.isEmpty ? nil : p)
        case "Grep", "Glob": return (s("pattern") ?? "", nil)
        case "WebFetch": return (s("url") ?? "", nil)
        case "WebSearch": return (s("query") ?? "", nil)
        case "Agent", "Task": return (s("description") ?? "", nil)
        case "AskUserQuestion":
            let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
            return (q ?? "", nil)
        default:
            if let url = s("url") { return (url, nil) }
            if let a = s("action") { return (a, nil) }
            if let actions = input["actions"] as? [[String: Any]] {
                let names = actions.compactMap { a -> String? in
                    let inner = a["input"] as? [String: Any]
                    return (inner?["action"] as? String) ?? (a["name"] as? String)
                }
                return (names.prefix(4).joined(separator: " → "), nil)
            }
            return (s("description") ?? s("query") ?? s("title") ?? "", nil)
        }
    }
}
