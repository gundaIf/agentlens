import Foundation

/// Where AgentLens reads and writes. `AGENTLENS_HOME` overrides the home folder, for testing.
enum Paths {
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["AGENTLENS_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var support: URL { home.appendingPathComponent("Library/Application Support/AgentLens") }
    static var events: URL { support.appendingPathComponent("events.jsonl") }
    static var hookScript: URL { support.appendingPathComponent("hook.pl") }
    static var settings: URL { home.appendingPathComponent(".claude/settings.json") }
}

/// One line of events.jsonl, written by hook.pl.
struct HookRecord {
    let time: Date
    let event: String
    let session: String
    var toolUseID: String?
    var toolName: String?
    var notificationType: String?
    var message: String?
    var agentID: String?

    var isPermissionPrompt: Bool {
        guard event == "Notification" else { return false }
        if let t = notificationType { return t == "permission_prompt" }
        // Older Claude Code versions send only the message text.
        return (message ?? "").localizedCaseInsensitiveContains("permission")
    }
}

/// Tails events.jsonl and indexes records by Claude Code session id.
final class HookLog {
    private(set) var bySession: [String: [HookRecord]] = [:]
    private(set) var count = 0
    private(set) var lastEvent: Date?
    private var offset: UInt64 = 0
    private var partial = Data()

    /// Reads newly appended lines; returns the session ids that got new records.
    func poll() -> Set<String> {
        let url = Paths.events
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return [] }
        var changed = Set<String>()
        if size < offset {       // truncated: start over
            changed = Set(bySession.keys)
            bySession = [:]; count = 0; offset = 0; partial = Data()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return changed }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return changed }
        offset += UInt64(data.count)

        var buffer = partial
        buffer.append(data)
        var lineStart = buffer.startIndex
        while let nl = buffer[lineStart...].firstIndex(of: 0x0A) {
            if let r = HookLog.parse(buffer[lineStart..<nl]) {
                bySession[r.session, default: []].append(r)
                count += 1
                lastEvent = r.time
                changed.insert(r.session)
            }
            lineStart = buffer.index(after: nl)
        }
        partial = Data(buffer[lineStart...])
        return changed
    }

    static func parse(_ line: Data) -> HookRecord? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let t = (o["t"] as? NSNumber)?.doubleValue,
              let event = o["event"] as? String,
              let session = o["session"] as? String else { return nil }
        return HookRecord(time: Date(timeIntervalSince1970: t), event: event, session: session,
                          toolUseID: o["tool_use_id"] as? String, toolName: o["tool_name"] as? String,
                          notificationType: o["notification_type"] as? String,
                          message: o["message"] as? String, agentID: o["agent_id"] as? String)
    }

    /// Hook records for a session, as timeline events for the Analyzer.
    /// `subagent` limits them to what applies to one subagent: its own tool calls and its stop.
    func events(session: String, subagent: String? = nil) -> [Event] {
        (bySession[session] ?? []).compactMap { r in
            switch r.event {
            case "PreToolUse": return r.toolUseID.map { Event(time: r.time, kind: .hookToolStart(id: $0)) }
            case "PostToolUse", "PostToolUseFailure": return r.toolUseID.map { Event(time: r.time, kind: .hookToolEnd(id: $0)) }
            case "Notification" where subagent == nil && r.isPermissionPrompt:
                return Event(time: r.time, kind: .permissionPrompt(r.message ?? "Needs permission"))
            case "Stop" where subagent == nil: return Event(time: r.time, kind: .hookStop)
            case "SubagentStop" where subagent != nil && r.agentID == subagent: return Event(time: r.time, kind: .hookStop)
            default: return nil
            }
        }
    }
}

/// Adds or removes the AgentLens hooks in ~/.claude/settings.json. Never writes without `apply`.
enum HookInstaller {
    static let events = ["PreToolUse", "PostToolUse", "Notification", "Stop", "SubagentStop"]
    static let marker = "AgentLens/hook.pl"

    /// Appends a compact record of each hook call to events.jsonl. Perl and JSON::PP ship with macOS.
    /// Prints nothing and always exits 0, so it can never block or alter a tool call.
    static let script = #"""
    #!/usr/bin/perl
    # AgentLens hook: appends one small JSON line per Claude Code hook call to events.jsonl.
    use strict; use warnings; use JSON::PP; use Time::HiRes qw(time);
    eval {
        local $/; my $in = <STDIN>;
        my $d = decode_json($in);
        my %e = (t => 0 + sprintf("%.3f", time), event => $d->{hook_event_name}, session => $d->{session_id});
        for my $k (qw(tool_name tool_use_id notification_type message agent_id agent_type)) {
            $e{$k} = $d->{$k} if defined $d->{$k} && !ref $d->{$k};
        }
        $e{message} = substr($e{message}, 0, 200) if defined $e{message};
        my $dir = ($ENV{AGENTLENS_HOME} || $ENV{HOME}) . "/Library/Application Support/AgentLens";
        open(my $f, '>>', "$dir/events.jsonl") or die;
        print $f JSON::PP->new->canonical->encode(\%e), "\n";
        close $f;
    };
    exit 0;
    """#

    static var command: String {
        let path = Paths.hookScript.path.replacingOccurrences(of: "'", with: "'\\''")
        return "/usr/bin/perl '\(path)'"
    }

    struct Plan {
        let install: Bool
        let before: String
        let after: String
        let diff: [DiffLine]
        let error: String?
        var changes: Bool { error == nil && before != after }
    }

    struct DiffLine: Identifiable {
        enum Kind { case same, added, removed }
        let id: Int
        let kind: Kind
        let text: String
    }

    static func isInstalled() -> Bool {
        guard let text = try? String(contentsOf: Paths.settings, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Computes the new settings.json text without writing anything.
    static func plan(install: Bool) -> Plan {
        let url = Paths.settings
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var root: [String: Any] = [:]
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Any] else {
                return Plan(install: install, before: before, after: before, diff: [],
                            error: "\(url.path) isn't valid JSON, so AgentLens won't touch it.")
            }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for name in events {
            // Drop any earlier AgentLens entries, keep everyone else's.
            var groups = (hooks[name] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var g = group
                let kept = (g["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String ?? "").contains(marker)) }
                if kept.isEmpty, g["hooks"] != nil { return nil }
                g["hooks"] = kept
                return g
            }
            if install {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
                if name == "PreToolUse" || name == "PostToolUse" { group["matcher"] = "*" }
                groups.append(group)
            }
            if groups.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        let data = (try? JSONSerialization.data(withJSONObject: root,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let after = (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        return Plan(install: install, before: before, after: after, diff: diff(before, after), error: nil)
    }

    /// Writes the plan: the hook script (on install), a backup of settings.json, then settings.json.
    static func apply(_ plan: Plan) throws {
        let fm = FileManager.default
        if plan.install {
            try fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try script.write(to: Paths.hookScript, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hookScript.path)
            if !fm.fileExists(atPath: Paths.events.path) { fm.createFile(atPath: Paths.events.path, contents: nil) }
        }
        try fm.createDirectory(at: Paths.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: Paths.settings.path) {
            let backup = Paths.settings.appendingPathExtension("agentlens-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: Paths.settings, to: backup)
        }
        try plan.after.write(to: Paths.settings, atomically: true, encoding: .utf8)
    }

    /// Line diff (LCS) of two texts, every line marked same / added / removed.
    static func diff(_ a: String, _ b: String) -> [DiffLine] {
        let x = a.isEmpty ? [] : a.components(separatedBy: "\n")
        let y = b.isEmpty ? [] : b.components(separatedBy: "\n")
        let n = x.count, m = y.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        func add(_ k: DiffLine.Kind, _ t: String) { out.append(DiffLine(id: out.count, kind: k, text: t)) }
        while i < n || j < m {
            if i < n, j < m, x[i] == y[j] { add(.same, x[i]); i += 1; j += 1 }
            else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { add(.added, y[j]); j += 1 }
            else { add(.removed, x[i]); i += 1 }
        }
        return out
    }
}
