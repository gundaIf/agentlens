import Foundation
import Observation

/// One usage window: how much is used, when it resets, and how far through the window we are.
struct LimitGauge: Identifiable {
    let id: String
    let agent: String          // "Claude Code", "Codex"
    let window: String         // "5h", "Week", "30 days"
    /// 0…1 of the limit (Codex, exact) or of your own busiest window (Claude, estimated).
    let used: Double
    /// 0…1 of the window's time that has passed; the pace marker.
    let elapsed: Double?
    let resetsAt: Date?
    /// True when `used` is an estimate from local logs rather than the agent's own number.
    let estimated: Bool
    let detail: String

    /// Using it up faster than time passes.
    var aheadOfPace: Bool {
        guard let elapsed else { return false }
        return used > 0.5 && used > elapsed + 0.1
    }

    var chip: String { "\(window) · \(Int((used * 100).rounded()))%" }
}

/// Usage limits, read from local files only.
///
/// - Codex writes its real rate-limit state into every rollout (`rate_limits` on `token_count` events):
///   percent used, window length and reset time. Those are shown as they are.
/// - Claude Code keeps no limit numbers on disk, so its 5-hour window is estimated the way Anthropic
///   counts it: a window opens at the hour of your first message and lasts five hours. Usage is shown
///   against your own busiest window in the last 30 days, and labelled as an estimate.
@MainActor
@Observable
final class Limits {
    static let shared = Limits()
    private(set) var gauges: [LimitGauge] = []
    @ObservationIgnored private var lastRefresh = Date.distantPast

    func refreshIfNeeded(_ sessions: [SessionSummary], now: Date = Date()) {
        guard now.timeIntervalSince(lastRefresh) > 20 else { return }
        lastRefresh = now
        var g: [LimitGauge] = []
        if let c = Self.claudeWindow(sessions, now: now) { g.append(c) }
        g += Self.codex(now: now)
        gauges = g
    }

    // MARK: Claude Code (estimated)

    static func claudeWindow(_ sessions: [SessionSummary], now: Date) -> LimitGauge? {
        let claude = sessions.filter { $0.source == .claudeCode || $0.source == .cowork }
        let since = now.addingTimeInterval(-30 * 86400)
        // (time, output tokens) for every prompt in the last 30 days.
        let points = claude.flatMap { s in s.chunks.filter { $0.start >= since }.map { ($0.start, $0.outputTokens) } }
            .sorted { $0.0 < $1.0 }
        guard !points.isEmpty else { return nil }

        let window: TimeInterval = 5 * 3600
        var blocks: [(start: Date, tokens: Int, last: Date)] = []
        for (t, tokens) in points {
            if let b = blocks.last, t < b.start.addingTimeInterval(window) {
                blocks[blocks.count - 1].tokens += tokens
                blocks[blocks.count - 1].last = t
            } else {
                let hour = Calendar.current.dateInterval(of: .hour, for: t)?.start ?? t
                blocks.append((hour, tokens, t))
            }
        }
        guard let current = blocks.last, now < current.start.addingTimeInterval(window) else { return nil }
        let peak = max(blocks.map(\.tokens).max() ?? 1, 1)
        let resets = current.start.addingTimeInterval(window)
        let used = Double(current.tokens) / Double(peak)
        return LimitGauge(id: "claude-5h", agent: "Claude Code", window: "5h",
                          used: min(used, 1), elapsed: now.timeIntervalSince(current.start) / window,
                          resetsAt: resets, estimated: true,
                          detail: "\(current.tokens.compact) tokens out · \(Int((used * 100).rounded()))% of your busiest window")
    }

    // MARK: Codex (exact)

    static func codex(now: Date) -> [LimitGauge] {
        guard let file = newestRollout(), let line = lastLine(containing: "\"rate_limits\"", in: file),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = findRateLimits(obj) else { return [] }
        var out: [LimitGauge] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.doubleValue
            var resets: Date? = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if resets == nil, let secs = (w["resets_in_seconds"] as? NSNumber)?.doubleValue {
                resets = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)?
                    .addingTimeInterval(secs)
            }
            // A window that has already reset since the file was written is back at zero.
            let stale = resets.map { $0 < now } ?? false
            var elapsed: Double? = nil
            if let minutes, let resets, minutes > 0 {
                elapsed = min(max(1 - resets.timeIntervalSince(now) / (minutes * 60), 0), 1)
            }
            out.append(LimitGauge(id: "codex-\(key)", agent: "Codex", window: windowName(minutes),
                                  used: stale ? 0 : min(pct / 100, 1), elapsed: elapsed,
                                  resetsAt: stale ? nil : resets, estimated: false,
                                  detail: stale ? "Reset since last use" : "\(Int(pct.rounded()))% of your plan's limit"))
        }
        return out
    }

    private static func windowName(_ minutes: Double?) -> String {
        guard let m = minutes else { return "Limit" }
        switch m {
        case ..<(6 * 60): return "\(Int((m / 60).rounded()))h"
        case ..<(8 * 1440): return "Week"
        default: return "\(Int((m / 1440).rounded())) days"
        }
    }

    private static func findRateLimits(_ any: Any) -> [String: Any]? {
        if let d = any as? [String: Any] {
            if let rl = d["rate_limits"] as? [String: Any] { return rl }
            for v in d.values { if let r = findRateLimits(v) { return r } }
        }
        return nil
    }

    /// Newest `rollout-*.jsonl` under ~/.codex/sessions (checks the last few day folders only).
    private static func newestRollout() -> URL? {
        let fm = FileManager.default
        let root = Paths.home.appendingPathComponent(".codex/sessions")
        func sortedDirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var days: [URL] = []
        outer: for y in sortedDirs(root) {
            for m in sortedDirs(y) {
                for d in sortedDirs(m) { days.append(d); if days.count >= 5 { break outer } }
            }
        }
        var best: (URL, Date)?
        for d in days {
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.lastPathComponent.hasPrefix("rollout-") && f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || m > best!.1 { best = (f, m) }
            }
        }
        return best?.0
    }

    /// The last line in the file's final 512 KB that contains `needle`.
    private static func lastLine(containing needle: String, in url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 512_000 ? size - 512_000 : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last { $0.contains(needle) }.map(String.init)
    }
}
