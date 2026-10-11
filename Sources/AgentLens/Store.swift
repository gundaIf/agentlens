import Foundation
import Observation

/// Finds transcripts for Claude Code, Cowork and Grok, tails them, and publishes summaries.
/// All file work happens on a background queue; the UI only sees finished summaries.
@MainActor
@Observable
final class Store {
    private(set) var sessions: [SessionSummary] = []
    private(set) var loaded = false
    private(set) var now = Date()
    var selection: String?
    /// Hook events seen in events.jsonl, and whether our hooks are in ~/.claude/settings.json.
    private(set) var hookEvents = 0
    private(set) var lastHookEvent: Date?
    private(set) var hooksInstalled = HookInstaller.isInstalled()

    @ObservationIgnored private let worker = Worker()
    @ObservationIgnored private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.refresh()
            }
        }
    }

    func refresh() {
        worker.scan { [weak self] result in
            Task { @MainActor in
                guard let self, let result else { return }
                self.apply(result)
            }
        }
    }

    /// Synchronous load, for --snapshot.
    func loadNow() {
        if let r = worker.scanNowSync() { apply(r) }
        loaded = true
    }

    private func apply(_ r: ScanResult) {
        sessions = r.sessions
        hookEvents = r.hookEvents
        lastHookEvent = r.lastHookEvent
        loaded = true
    }

    func refreshHookStatus() { hooksInstalled = HookInstaller.isInstalled() }

    /// A session or a subagent, by id.
    func session(_ id: String?) -> SessionSummary? {
        guard let id else { return nil }
        for s in sessions {
            if s.id == id { return s }
            if let c = s.children.first(where: { $0.id == id }) { return c }
        }
        return nil
    }
}

struct ScanResult {
    let sessions: [SessionSummary]
    let hookEvents: Int
    let lastHookEvent: Date?
}

final class Worker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "agentlens.worker", qos: .utility)
    private var transcripts: [String: Transcript] = [:]
    /// Subagent transcripts (`<session>/subagents/agent-*.jsonl`), keyed by the parent's path.
    private var subagents: [String: [String: Transcript]] = [:]
    private let hooks = HookLog()
    private let grok = GrokSessions()
    private let windows = WindowSessions()
    private var summaries: [String: SessionSummary] = [:]
    private var busy = false
    private var lastDiscovery = Date.distantPast

    /// Calls back with the full list when something changed, or nil if nothing did.
    func scan(_ done: @escaping @Sendable (ScanResult?) -> Void) {
        queue.async { [self] in
            guard !busy else { return }
            busy = true
            defer { busy = false }
            done(scanNow())
        }
    }

    func scanNowSync() -> ScanResult? { queue.sync { scanNow() } }

    func scanNow() -> ScanResult? {
        if Date().timeIntervalSince(lastDiscovery) > 10 {
            discover()
            lastDiscovery = Date()
        }
        let hookSessions = hooks.poll()
        var changed = !hookSessions.isEmpty
        if grok.poll() { changed = true }
        if windows.poll() { changed = true }
        for t in transcripts.values {
            let subs = (subagents[t.id] ?? [:]).values.sorted { $0.id < $1.id }
            t.poll()
            subs.forEach { $0.poll() }
            guard t.changed || subs.contains(where: \.changed) || hookSessions.contains(t.sessionID) else { continue }
            summaries[t.id] = Analyzer.summarize(t, hooks: hooks, subagentFiles: subs)
            t.markRead()
            subs.forEach { $0.markRead() }
            changed = true
        }
        guard changed else { return nil }
        return ScanResult(sessions: (Array(summaries.values) + grok.summaries + windows.summaries).sorted { $0.end > $1.end },
                          hookEvents: hooks.count, lastHookEvent: hooks.lastEvent)
    }

    private func discover() {
        let home = Paths.home

        // Claude Code (CLI, IDE, desktop Code tab): ~/.claude/projects/<project>/<session>.jsonl
        let projects = home.appendingPathComponent(".claude/projects")
        for dir in children(projects) {
            for f in children(dir) where f.pathExtension == "jsonl" {
                add(f, source: .claudeCode, title: nil)
                addSubagents(of: f, source: .claudeCode)
            }
        }

        // Cowork: .../local-agent-mode-sessions/<org>/<user>/local_<id>/.claude/projects/<p>/<s>.jsonl
        // with the session title in the sibling local_<id>.json.
        let cowork = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        for org in children(cowork) {
            for user in children(org) {
                for sess in children(user) where sess.lastPathComponent.hasPrefix("local_") && sess.hasDirectoryPath {
                    let title = coworkTitle(user.appendingPathComponent(sess.lastPathComponent + ".json"))
                    for p in children(sess.appendingPathComponent(".claude/projects")) {
                        for f in children(p) where f.pathExtension == "jsonl" {
                            add(f, source: .cowork, title: title)
                            addSubagents(of: f, source: .cowork)
                        }
                    }
                }
            }
        }
    }

    private func add(_ url: URL, source: Source, title: String?) {
        if let existing = transcripts[url.path] {
            if let title, existing.title != title { existing.title = title }
            return
        }
        transcripts[url.path] = Transcript(url: url, source: source, title: title)
    }

    /// `<session>.jsonl` may have a sibling `<session>/subagents/` with one file per subagent,
    /// plus `agent-<id>.meta.json` holding its description and type.
    private func addSubagents(of session: URL, source: Source) {
        let dir = session.deletingPathExtension().appendingPathComponent("subagents")
        for f in children(dir) where f.pathExtension == "jsonl" {
            if subagents[session.path]?[f.path] != nil { continue }
            let name = f.deletingPathExtension().lastPathComponent
            var info = SubagentInfo(parentPath: session.path,
                                    agentID: name.hasPrefix("agent-") ? String(name.dropFirst(6)) : name)
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name + ".meta.json")),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                info.description = meta["description"] as? String
                info.agentType = meta["agentType"] as? String
            }
            let t = Transcript(url: f, source: source)
            t.subagent = info
            subagents[session.path, default: [:]][f.path] = t
        }
    }

    private func coworkTitle(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["title"] as? String
    }

    private func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    }
}
