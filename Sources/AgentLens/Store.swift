import Foundation
import Observation

/// Finds transcripts for Claude Code, Cowork and Grok, tails them, and publishes summaries.
/// All file work happens on a background queue; the UI only sees finished summaries.
@MainActor
@Observable
final class Store {
    /// Everything found, whatever the user tracks.
    private(set) var allSessions: [SessionSummary] = []
    /// When new agent activity was last read (for the health line in Settings).
    private(set) var lastChange: Date?
    /// What the UI shows: agents the user turned off in Settings are left out.
    var sessions: [SessionSummary] { allSessions.filter { Preferences.shared.isTracked($0.source) } }
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
        allSessions = r.sessions
        lastChange = Date()
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
    private let codex = CodexSessions()
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
        if codex.poll() { changed = true }
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
        // A Codex task inside ChatGPT also shows in its window; keep the exact ~/.codex version only.
        let codexSessions = codex.summaries
        let windowSessions = windows.summaries.filter { w in
            w.source != .chatgptChat || !codexSessions.contains { c in
                c.start <= w.end.addingTimeInterval(60) && c.end >= w.start.addingTimeInterval(-60)
            }
        }
        return ScanResult(sessions: (Array(summaries.values) + grok.summaries + windowSessions + codexSessions).sorted { $0.end > $1.end },
                          hookEvents: hooks.count, lastHookEvent: hooks.lastEvent)
    }

    // Claude Code deletes session logs after 30 days (its cleanupPeriodDays), which used to erase
    // them from AgentLens's history too. So AgentLens keeps a hard link to each log in its own
    // archive: while the original exists it's the same file (no extra space, appends included);
    // once Claude Code deletes it, the link survives and the session stays in AgentLens.
    private var claudeRoot: URL { Paths.home.appendingPathComponent(".claude/projects") }
    private var coworkRoot: URL { Paths.home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions") }
    private var archiveRoot: URL { Paths.support.appendingPathComponent("archive") }
    private var lastArchive = Date.distantPast
    private var keepHistory: Bool { UserDefaults.standard.object(forKey: "keepHistory") as? Bool ?? true }

    private func discover() {
        discoverClaude(in: claudeRoot)
        discoverCowork(in: coworkRoot)
        guard keepHistory else { return }
        if Date().timeIntervalSince(lastArchive) > 300 {
            archiveAll()
            lastArchive = Date()
        }
        // Archived sessions whose original is gone.
        discoverClaude(in: archiveRoot.appendingPathComponent("claude"), original: claudeRoot)
        discoverCowork(in: archiveRoot.appendingPathComponent("cowork"), original: coworkRoot)
    }

    /// The same file under `original`, when `url` lives under `root` (an archive).
    private func counterpart(_ url: URL, root: URL, original: URL) -> URL {
        URL(fileURLWithPath: original.path + url.path.dropFirst(root.path.count))
    }

    /// From an archive, take only files whose original no longer exists.
    private func wanted(_ f: URL, root: URL, original: URL?) -> Bool {
        guard let original else { return true }
        let o = counterpart(f, root: root, original: original)
        return transcripts[o.path] == nil && !FileManager.default.fileExists(atPath: o.path)
    }

    // Claude Code (CLI, IDE, desktop Code tab): <root>/<project>/<session>.jsonl
    private func discoverClaude(in root: URL, original: URL? = nil) {
        for dir in children(root) {
            for f in children(dir) where f.pathExtension == "jsonl" && wanted(f, root: root, original: original) {
                add(f, source: .claudeCode, title: nil)
                addSubagents(of: f, source: .claudeCode)
            }
        }
    }

    // Cowork: <root>/<org>/<user>/local_<id>/.claude/projects/<p>/<s>.jsonl,
    // with the session title in the sibling local_<id>.json.
    private func discoverCowork(in root: URL, original: URL? = nil) {
        for org in children(root) {
            for user in children(org) {
                for sess in children(user) where sess.lastPathComponent.hasPrefix("local_") && sess.hasDirectoryPath {
                    let title = coworkTitle(user.appendingPathComponent(sess.lastPathComponent + ".json"))
                    for p in children(sess.appendingPathComponent(".claude/projects")) {
                        for f in children(p) where f.pathExtension == "jsonl" && wanted(f, root: root, original: original) {
                            add(f, source: .cowork, title: title)
                            addSubagents(of: f, source: .cowork)
                        }
                    }
                }
            }
        }
    }

    /// Hard-links every Claude Code and Cowork log (plus subagent files and Cowork titles) into the archive.
    private func archiveAll() {
        let claudeArchive = archiveRoot.appendingPathComponent("claude")
        for dir in children(claudeRoot) {
            for f in children(dir) where f.pathExtension == "jsonl" {
                link(f, root: claudeRoot, into: claudeArchive)
                for s in children(f.deletingPathExtension().appendingPathComponent("subagents")) {
                    link(s, root: claudeRoot, into: claudeArchive)
                }
            }
        }
        let coworkArchive = archiveRoot.appendingPathComponent("cowork")
        for org in children(coworkRoot) {
            for user in children(org) {
                for sess in children(user) where sess.lastPathComponent.hasPrefix("local_") && sess.hasDirectoryPath {
                    let meta = user.appendingPathComponent(sess.lastPathComponent + ".json")
                    if FileManager.default.fileExists(atPath: meta.path) { link(meta, root: coworkRoot, into: coworkArchive) }
                    for p in children(sess.appendingPathComponent(".claude/projects")) {
                        for f in children(p) where f.pathExtension == "jsonl" {
                            link(f, root: coworkRoot, into: coworkArchive)
                            for s in children(f.deletingPathExtension().appendingPathComponent("subagents")) {
                                link(s, root: coworkRoot, into: coworkArchive)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Keeps `<archive>/<same relative path>` hard-linked to `file`. Re-links if the original was
    /// replaced by a new file (different inode).
    private func link(_ file: URL, root: URL, into archive: URL) {
        let fm = FileManager.default
        let dest = counterpart(file, root: root, original: archive)
        let inode = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? Int }
        guard let src = inode(file) else { return }
        if let d = inode(dest) {
            if d == src { return }
            try? fm.removeItem(at: dest)   // our own stale link; the original was rewritten
        }
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.linkItem(at: file, to: dest)
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
