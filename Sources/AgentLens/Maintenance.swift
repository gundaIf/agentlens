import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - Update check

/// Asks GitHub for the latest AgentLens release, at launch and once a day. The request carries
/// nothing about you or your agents; it can be turned off in Settings → Advanced.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let releasesURL = URL(string: "https://github.com/gundaIf/agentlens/releases")!

    private(set) var latest: String?
    private(set) var latestURL: URL?
    private(set) var lastChecked: Date?
    private(set) var failed = false

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "checkUpdates"); if enabled { check() } }
    }
    @ObservationIgnored private var timer: Timer?

    private init() {
        enabled = UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true
    }

    var updateAvailable: Bool {
        guard enabled, let latest else { return false }
        return UpdateChecker.isNewer(latest, than: AppInfo.version)
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.check() }
        }
    }

    func check() {
        guard enabled else { return }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/gundaIf/agentlens/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, error in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (obj?["tag_name"] as? String).map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            let url = (obj?["html_url"] as? String).flatMap(URL.init(string:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let u = UpdateChecker.shared
                    u.lastChecked = Date()
                    u.failed = error != nil || tag == nil
                    if let tag { u.latest = tag; u.latestURL = url }
                }
            }
        }.resume()
    }

    /// "0.4.10" is newer than "0.4.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

// MARK: - Export

enum Exporter {
    static func csv(_ sessions: [SessionSummary]) -> String {
        let iso = ISO8601DateFormatter()
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["agent,title,project,start,end,active_minutes,prompts,tool_calls,failed_calls,output_tokens,commits,pull_requests,releases,files_changed"]
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            let files = Set(s.chunks.flatMap(\.files)).count
            rows.append([
                q(s.source.rawValue), q(s.title), q(s.project), iso.string(from: s.start), iso.string(from: s.end),
                String(format: "%.1f", s.active / 60), "\(s.prompts)", "\(s.toolCalls)", "\(s.errors)",
                "\(s.outputTokens)", "\(s.findings.commits)", "\(s.findings.pullRequests)", "\(s.findings.releases)", "\(files)",
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Asks where to save, then writes every tracked session as CSV.
    @MainActor
    static func exportCSV(_ sessions: [SessionSummary]) {
        AppController.shared.hideDropdown()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "AgentLens sessions \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.title = "Export sessions"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv(sessions).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
