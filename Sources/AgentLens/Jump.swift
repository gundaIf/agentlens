import AppKit
import Darwin

/// "Go to" for a session: brings forward the app the agent runs in (terminal, editor, Claude, ChatGPT…).
///
/// For agents that run as a process (Claude Code, Codex, Grok) it finds the agent process working in the
/// session's folder and walks up its parents to the first regular app, so a session started in Ghostty
/// opens Ghostty, one in Cursor opens Cursor, and one in Claude's Code tab opens Claude.
/// For agents followed through a window it opens that app.
@MainActor
enum Jump {
    static func go(to s: SessionSummary) {
        if let app = app(for: s) {
            app.activate()
        } else {
            AppController.shared.openDashboard(select: s.id)
            return
        }
        AppController.shared.hideDropdown()
        Pill.shared.collapse()
    }

    /// The running app hosting the session, if one can be found.
    static func app(for s: SessionSummary) -> NSRunningApplication? {
        let processNames: [String]
        switch s.source {
        case .claudeCode: processNames = ["claude", "node"]
        case .codex: processNames = ["codex"]
        case .grok: processNames = ["grok", "node", "bun"]
        default: processNames = []
        }
        if !processNames.isEmpty, !s.cwd.isEmpty,
           let app = hostApp(processNames: processNames, cwd: s.cwd) {
            return app
        }
        let bundles: [String]
        switch s.source {
        case .claudeCode, .cowork, .claudeChat: bundles = ["com.anthropic.claudefordesktop"]
        case .codex, .chatgptChat: bundles = ["com.openai.codex", "com.openai.chat"]
        case .muse: bundles = ["com.meta.endo"]
        case .grokBot: bundles = ["com.anysphere.sand"]
        case .grok: bundles = []
        }
        // Claude Code from a terminal with no live process left: nothing sensible to bring forward.
        if s.source == .claudeCode { return nil }
        for b in bundles {
            if let a = NSRunningApplication.runningApplications(withBundleIdentifier: b).first { return a }
        }
        return nil
    }

    // MARK: - Processes

    /// The agent process for this folder: an exact working-directory match, else the process started in
    /// the closest parent folder (agents `cd` into subfolders, but the process keeps its launch folder).
    private static func hostApp(processNames: [String], cwd: String) -> NSRunningApplication? {
        let target = (cwd as NSString).standardizingPath
        var best: (pid: pid_t, depth: Int)?
        for pid in allPIDs() where isAgent(pid, names: processNames) {
            guard let raw = workingDirectory(of: pid) else { continue }
            let dir = (raw as NSString).standardizingPath
            guard dir != "/", dir == target || target.hasPrefix(dir + "/") else { continue }
            let depth = dir.split(separator: "/").count
            if best == nil || depth > best!.depth { best = (pid, depth) }
        }
        return best.flatMap { regularAncestor(of: $0.pid) }
    }

    private static func isAgent(_ pid: pid_t, names: [String]) -> Bool {
        if names.contains(name(of: pid)) { return true }
        // Claude Code ships as a versioned binary (…/claude-code/2.1.x/<hash>), Codex as …/codex.
        let p = path(of: pid)
        return names.contains { p.contains("/\($0)-code/") || p.hasSuffix("/\($0)") }
    }

    private static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    private static func regularAncestor(of pid: pid_t) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let parent = parentPID(of: p), parent > 1, parent != p else { return nil }
            p = parent
        }
        return nil
    }

    private static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(got, 0)))).filter { $0 > 0 }
    }

    private static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
