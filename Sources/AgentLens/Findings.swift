import Foundation

/// What a session produced, and where it went round in circles. Read from the commands and edits
/// the agent made, so it works for any source that records tool calls (Claude Code, Cowork, Codex).
struct Findings {
    // Outcomes
    var commits = 0
    var pushes = 0
    var pullRequests = 0
    var releases = 0
    // Friction
    /// Command families that failed 3+ times, most first: ("swift build", 4).
    var failingCommands: [(String, Int)] = []
    /// Files edited 5+ times, most first: ("App.swift", 7).
    var churnedFiles: [(String, Int)] = []

    var hasOutcomes: Bool { commits + pushes + pullRequests + releases > 0 }
    var hasFriction: Bool { !failingCommands.isEmpty || !churnedFiles.isEmpty }

    /// "3 commits · 1 PR · 1 release"
    var outcomeSummary: String {
        var parts: [String] = []
        func add(_ n: Int, _ one: String, _ many: String) { if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") } }
        add(commits, "commit", "commits")
        add(pullRequests, "PR", "PRs")
        add(releases, "release", "releases")
        if commits == 0 { add(pushes, "push", "pushes") }
        return parts.joined(separator: " · ")
    }

    static func from(_ calls: [ToolCall]) -> Findings {
        var f = Findings()
        var failures: [String: Int] = [:]
        var edits: [String: Int] = [:]
        for c in calls {
            if let cmd = c.command, c.category == .shell {
                if !c.isError {
                    if matches(cmd, #"\bgit\b[^;&|]*\bcommit\b"#) { f.commits += 1 }
                    if matches(cmd, #"\bgit\b[^;&|]*\bpush\b"#) { f.pushes += 1 }
                    if matches(cmd, #"\bgh\s+pr\s+create\b"#) { f.pullRequests += 1 }
                    if matches(cmd, #"\bgh\s+release\s+create\b"#) { f.releases += 1 }
                } else {
                    failures[ToolCall.commandFamily(cmd), default: 0] += 1
                }
            }
            if c.category == .editing, let file = c.file {
                edits[file, default: 0] += 1
            }
        }
        f.failingCommands = failures.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        f.churnedFiles = edits.filter { $0.value >= 5 }.sorted { $0.value > $1.value }
            .map { (($0.key as NSString).lastPathComponent, $0.value) }
        return f
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}

extension Array where Element == Findings {
    /// Totals across sessions (friction lists are merged by name).
    var combined: Findings {
        var f = Findings()
        var fails: [String: Int] = [:], churn: [String: Int] = [:]
        for x in self {
            f.commits += x.commits; f.pushes += x.pushes
            f.pullRequests += x.pullRequests; f.releases += x.releases
            x.failingCommands.forEach { fails[$0.0, default: 0] += $0.1 }
            x.churnedFiles.forEach { churn[$0.0, default: 0] += $0.1 }
        }
        f.failingCommands = fails.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        f.churnedFiles = churn.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        return f
    }
}
