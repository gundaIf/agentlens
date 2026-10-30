import Foundation

enum Source: String {
    case claudeCode = "Claude Code"
    case cowork = "Cowork"
    case grok = "Grok"
    case muse = "Muse"
    case grokBot = "Grok Bot"
    case codex = "ChatGPT"
    /// ChatGPT conversations followed by reading the app's window (chats that never touch ~/.codex).
    case chatgptChat = "ChatGPT chat"
}

/// What an agent's time was spent on. Every second of active time lands in exactly one of these.
enum Category: String, CaseIterable, Identifiable {
    case thinking = "Thinking"
    case shell = "Shell"
    case reading = "Reading"
    case editing = "Editing"
    case browser = "Browser"
    case web = "Web"
    case subagent = "Subagents"
    case waiting = "Waiting on you"
    case other = "Other tools"

    var id: String { rawValue }

    static func of(tool name: String) -> Category {
        // Claude Code uses PascalCase tool names, Cowork snake_case; compare without either.
        switch name.lowercased().replacingOccurrences(of: "_", with: "") {
        case "bash", "bashoutput", "killshell", "monitor", "runterminalcommand": return .shell
        case "read", "grep", "glob", "ls", "notebookread", "readfile", "listdir": return .reading
        case "edit", "write", "multiedit", "notebookedit", "searchreplace": return .editing
        case "webfetch", "websearch": return .web
        case "agent", "task", "sendmessage": return .subagent
        case "askuserquestion", "exitplanmode": return .waiting
        default:
            if name.contains("Claude_Browser") || name.contains("claude-in-chrome") || name.contains("playwright") {
                return .browser
            }
            return .other
        }
    }
}

enum EventKind {
    case prompt(String)
    case assistant(endTurn: Bool)
    case toolUse(id: String)
    case toolResult(id: String, isError: Bool)
    // From Claude Code hooks (events.jsonl), merged into the transcript's timeline.
    case hookToolStart(id: String)
    case hookToolEnd(id: String)
    case permissionPrompt(String)
    case hookStop
}

struct Event {
    let time: Date
    let kind: EventKind
    var outputTokens = 0
}

struct ToolCall {
    let id: String
    let name: String
    let detail: String
    var command: String? = nil
    let file: String?
    let start: Date
    var end: Date?
    var isError = false

    var category: Category { Category.of(tool: name) }

    /// Short human name: strips the mcp__server__ prefix.
    var shortName: String {
        name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
    }

    /// For shell calls, the command family ("git commit", "npm run", "python3"…).
    var commandKey: String? {
        guard category == .shell, let command, !command.isEmpty else { return nil }
        return ToolCall.commandFamily(command)
    }

    static func commandFamily(_ cmd: String) -> String {
        let parts = cmd.replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
            .split(separator: ";")
        for part in parts {
            var words = part.split(separator: " ").map(String.init)
            while let w = words.first, w.contains("=") && !w.hasPrefix("-") { words.removeFirst() } // FOO=bar cmd
            while let w = words.first, w.hasPrefix("-") || w == "[" || w == "time" || w == "sudo" { words.removeFirst() }
            guard let first = words.first else { continue }
            if first == "cd" || first == "export" || first == "set" || first == "setopt" { continue }
            let base = (first as NSString).lastPathComponent
            let twoWord: Set<String> = ["git", "npm", "pnpm", "yarn", "gh", "npx", "swift", "cargo", "go", "docker", "wrangler", "brew", "bun"]
            if twoWord.contains(base), words.count > 1, !words[1].hasPrefix("-") {
                return "\(base) \(words[1])"
            }
            return base
        }
        return "shell"
    }
}

/// A slice of active time with a single category.
struct Segment {
    let start: Date
    let duration: TimeInterval
    let category: Category
    let label: String
    var tool: String? = nil
    var command: String? = nil
    /// Waiting on a permission prompt (only known with hooks installed).
    var permission = false
}

/// Totals over any set of segments (one session, or everything in a date range).
struct Aggregate {
    var active: TimeInterval = 0
    var byCategory: [Category: TimeInterval] = [:]
    var byTool: [String: TimeInterval] = [:]
    var byCommand: [String: TimeInterval] = [:]
    var byProject: [String: TimeInterval] = [:]
    var byDay: [Date: [Category: TimeInterval]] = [:]
    var sessionIDs = Set<String>()
    /// The part of Waiting on you spent on permission prompts.
    var permissionWait: TimeInterval = 0

    mutating func add(_ seg: Segment, project: String, session: String) {
        active += seg.duration
        if seg.permission { permissionWait += seg.duration }
        byCategory[seg.category, default: 0] += seg.duration
        if let t = seg.tool { byTool[t, default: 0] += seg.duration }
        if let c = seg.command { byCommand[c, default: 0] += seg.duration }
        byProject[project, default: 0] += seg.duration
        byDay[Calendar.current.startOfDay(for: seg.start), default: [:]][seg.category, default: 0] += seg.duration
        sessionIDs.insert(session)
    }

    static func top(_ d: [String: TimeInterval], _ n: Int) -> [(String, TimeInterval)] {
        d.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }
}

/// A run of consecutive segments with the same category, e.g. "Reading 2m: App.swift, Model.swift".
struct Step: Identifiable {
    let id = UUID()
    let category: Category
    var duration: TimeInterval
    var labels: [String]
}

extension Array where Element == Step {
    /// For one-line summaries: folds steps shorter than `minimum` into the previous one,
    /// then merges neighbours of the same category. Totals are preserved.
    func coalesced(minimum: TimeInterval = 3) -> [Step] {
        var out: [Step] = []
        for s in self {
            if s.duration < minimum, !out.isEmpty { out[out.count - 1].duration += s.duration; continue }
            if let last = out.last, last.category == s.category {
                out[out.count - 1].duration += s.duration
                out[out.count - 1].labels += s.labels
            } else {
                out.append(s)
            }
        }
        return out
    }
}

/// One user prompt and everything the agent did in response.
struct Chunk: Identifiable {
    let id = UUID()
    let prompt: String
    let start: Date
    var end: Date
    var active: TimeInterval = 0
    var byCategory: [Category: TimeInterval] = [:]
    var steps: [Step] = []
    var toolCalls = 0
    var errors = 0
    var files: [String] = []
    var outputTokens = 0
}

enum LiveState {
    case running(tool: String, detail: String, since: Date)
    case thinking(since: Date)
    case waitingOnYou(reason: String, since: Date)
    case finished(at: Date)
    case idle

    var isWorking: Bool {
        switch self {
        case .running, .thinking: return true
        default: return false
        }
    }
    var isVisible: Bool {
        if case .idle = self { return false }
        return true
    }
}

struct SessionSummary: Identifiable {
    let id: String
    let source: Source
    let title: String
    let project: String
    let cwd: String
    let branch: String?
    let start: Date
    let end: Date
    let segments: [Segment]
    let totals: Aggregate
    let chunks: [Chunk]
    let toolCalls: Int
    let errors: Int
    let outputTokens: Int
    let inputTokens: Int
    let prompts: Int
    var active: TimeInterval { totals.active }

    // Inputs for live state, evaluated against the current clock.
    let lastEventTime: Date
    let lastEventEndedTurn: Bool
    let pendingTool: ToolCall?
    /// Set when a hook reported a permission prompt for the pending tool.
    let permissionSince: Date?

    // Subagents: a parent session lists its children; a child points back at its parent.
    var children: [SessionSummary] = []
    /// Outcomes (commits, PRs…) and friction (repeated failures, churned files).
    var findings = Findings()
    var parentID: String? = nil
    var agentType: String? = nil
    var childrenOrNil: [SessionSummary]? { children.isEmpty ? nil : children }
    var isSubagent: Bool { parentID != nil }

    func live(at now: Date) -> LiveState {
        let age = now.timeIntervalSince(lastEventTime)
        if let tool = pendingTool, now.timeIntervalSince(tool.start) < 30 * 60 {
            if let since = permissionSince { return .waitingOnYou(reason: "Needs permission: \(tool.shortName)", since: since) }
            if tool.category == .waiting { return .waitingOnYou(reason: "Asked you a question", since: tool.start) }
            return .running(tool: tool.shortName, detail: tool.detail, since: tool.start)
        }
        if lastEventEndedTurn {
            return age < 30 * 60 ? .finished(at: lastEventTime) : .idle
        }
        return age < 10 * 60 ? .thinking(since: lastEventTime) : .idle
    }
}

extension TimeInterval {
    var pretty: String {
        let s = Int(self.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" + (s % 60 >= 1 && s < 600 ? " \(s % 60)s" : "") }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

extension Int {
    var compact: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1_000) }
        return "\(self)"
    }
}
