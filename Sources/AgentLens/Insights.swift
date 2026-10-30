import SwiftUI

struct Insight: Identifiable {
    let id = UUID()
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
}

/// Numbers for one time window, plus the previous window of the same length to compare against.
struct WindowStats {
    let from: Date?
    let to: Date
    let agg: Aggregate
    let previousActive: TimeInterval?
    let prompts: Int
    let files: Set<String>
    let errors: Int
    let longest: (chunk: Chunk, session: SessionSummary)?
    let byHour: [Int: TimeInterval]
    let errorSession: SessionSummary?
    /// Outcomes and friction across the sessions active in this window.
    var findings = Findings()

    var perPrompt: TimeInterval? { prompts > 0 ? agg.active / Double(prompts) : nil }

    /// "+23%" against the previous window, nil when there's nothing to compare.
    var change: Double? {
        guard let p = previousActive, p >= 60 else { return nil }
        return (agg.active - p) / p
    }
}

enum Insights {
    static func stats(_ sessions: [SessionSummary], from: Date?, to: Date = Date(), compareFrom: Date? = nil, compareTo: Date? = nil) -> WindowStats {
        let agg = Analyzer.aggregate(sessions, since: from)
        var prompts = 0, errors = 0
        var files = Set<String>()
        var longest: (Chunk, SessionSummary)?
        var errorCounts: [String: Int] = [:]
        for s in sessions where agg.sessionIDs.contains(s.id) {
            for c in s.chunks where from == nil || c.start >= from! {
                if c.prompt != "(session start)" { prompts += 1 }
                errors += c.errors
                errorCounts[s.id, default: 0] += c.errors
                files.formUnion(c.files)
                if c.active > (longest?.0.active ?? 0) { longest = (c, s) }
            }
        }
        var byHour: [Int: TimeInterval] = [:]
        for s in sessions {
            for seg in s.segments where from == nil || seg.start >= from! {
                byHour[Calendar.current.component(.hour, from: seg.start), default: 0] += seg.duration
            }
        }
        var previous: TimeInterval?
        if let cf = compareFrom, let ct = compareTo { previous = activeTime(sessions, from: cf, to: ct) }
        let errorID = errorCounts.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
        var w = WindowStats(from: from, to: to, agg: agg, previousActive: previous, prompts: prompts,
                            files: files, errors: errors, longest: longest.map { (chunk: $0.0, session: $0.1) },
                            byHour: byHour, errorSession: sessions.first { $0.id == errorID })
        w.findings = sessions.filter { agg.sessionIDs.contains($0.id) }.map(\.findings).combined
        return w
    }

    static func activeTime(_ sessions: [SessionSummary], from: Date, to: Date) -> TimeInterval {
        var total: TimeInterval = 0
        for s in sessions where s.end >= from && s.start <= to {
            for seg in s.segments where seg.start >= from && seg.start < to { total += seg.duration }
        }
        return total
    }

    /// Sentences worth reading, most useful first.
    static func list(_ w: WindowStats, periodName: String) -> [Insight] {
        var out: [Insight] = []
        let agg = w.agg
        guard agg.active >= 1 else { return [] }

        let top = agg.byCategory.filter { $0.value >= 1 }.sorted { $0.value > $1.value }
        if let first = top.first {
            let pct = { (v: TimeInterval) in "\(Int((v / agg.active * 100).rounded()))%" }
            var detail = "\(pct(first.value)) of agent time"
            if top.count > 1 { detail += ", then \(top[1].key.title.lowercased()) at \(pct(top[1].value))" }
            out.append(Insight(symbol: first.key.symbol, tint: first.key.color,
                               title: "Mostly \(first.key.title.lowercased())", detail: detail))
        }

        let waiting = agg.byCategory[.waiting] ?? 0
        if waiting >= 30 {
            var detail = "Agents sat paused on your answers"
            if agg.permissionWait >= 10 { detail += ", \(agg.permissionWait.clock) of it on permission prompts" }
            out.append(Insight(symbol: "hand.raised.fill", tint: Category.waiting.color,
                               title: "Kept waiting \(waiting.clock)", detail: detail))
        }

        if let l = w.longest, l.chunk.active >= 60 {
            out.append(Insight(symbol: "timer", tint: Color(hex: 0x4A9FF0),
                               title: "Longest unattended run: \(l.chunk.active.clock)",
                               detail: "“\(snippet(l.chunk.prompt))” in \(l.session.title)"))
        }

        if let per = w.perPrompt, w.prompts >= 2 {
            out.append(Insight(symbol: "arrow.triangle.branch", tint: Color(hex: 0x23B5A2),
                               title: "\(per.clock) of work per prompt",
                               detail: "Across \(w.prompts) prompts \(periodName)"))
        }

        if let (hour, v) = w.byHour.max(by: { $0.value < $1.value }), v >= 60 {
            out.append(Insight(symbol: "clock", tint: Color(hex: 0x8B7CF6),
                               title: "Busiest hour: \(hourRange(hour))",
                               detail: "\(v.clock) of agent work in that hour"))
        }

        if !w.files.isEmpty {
            let projects = Aggregate.top(agg.byProject, 1).first?.0
            out.append(Insight(symbol: "doc.on.doc", tint: Category.editing.color,
                               title: "\(w.files.count) file\(w.files.count == 1 ? "" : "s") changed",
                               detail: projects.map { "Most work in \($0)" } ?? ""))
        }

        let f = w.findings
        if f.hasOutcomes {
            out.insert(Insight(symbol: "shippingbox.fill", tint: HUD.phosphor,
                               title: "Shipped: \(f.outcomeSummary)",
                               detail: "What your agents produced \(periodName)"), at: min(1, out.count))
        }
        if let (cmd, n) = f.failingCommands.first {
            out.append(Insight(symbol: "arrow.triangle.2.circlepath", tint: Category.waiting.color,
                               title: "\(cmd) failed \(n)×",
                               detail: "The same command kept failing. Worth a closer look at the error."))
        }
        if let (file, n) = f.churnedFiles.first, n >= 8 {
            out.append(Insight(symbol: "pencil.and.scribble", tint: Category.editing.color,
                               title: "\(file) edited \(n)×",
                               detail: "Rewritten again and again. The agent may need a clearer brief."))
        }
        if w.errors > 0 {
            out.append(Insight(symbol: "exclamationmark.triangle", tint: Category.waiting.color,
                               title: "\(w.errors) failed tool call\(w.errors == 1 ? "" : "s")",
                               detail: w.errorSession.map { "Most in \($0.title)" } ?? ""))
        }
        return out
    }

    /// One or two plain sentences on how the agents did in this window, built from whatever stands out.
    static func narrative(_ w: WindowStats, period: String, comparison: String, multiDay: Bool) -> String {
        let agg = w.agg
        guard agg.active >= 1 else {
            return "No agent activity \(period). Start a Claude Code, Cowork or Grok session and it shows up here within seconds."
        }
        let n = agg.sessionIDs.count
        var first = "\(agg.active.clock) of agent work \(period) across \(n) session\(n == 1 ? "" : "s")"
        if agg.byProject.count == 1, let p = agg.byProject.keys.first, !p.isEmpty {
            first += " in " + (p.hasSuffix(".") ? String(p.dropLast()) : p)
        }
        if let c = w.change, !comparison.isEmpty, abs(c) >= 0.05 {
            first += ", \(c >= 0 ? "up" : "down") \(Int((abs(c) * 100).rounded()))% on \(comparison)"
        }

        // Sentence 2: what the work was, and when.
        var shape: [String] = []
        if let top = agg.byCategory.max(by: { $0.value < $1.value }) {
            shape.append("Mostly \(top.key.title.lowercased()) (\(Int((top.value / agg.active * 100).rounded()))%)")
        }
        if multiDay, agg.byDay.count > 1, let day = agg.byDay.max(by: { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) }) {
            shape.append("\(day.key.formatted(.dateTime.weekday(.wide))) was the busiest day")
        } else if w.byHour.count > 1, let (h, v) = w.byHour.max(by: { $0.value < $1.value }), v >= 60 {
            shape.append("busiest \(hourRange(h))")
        }

        // Sentence 3: friction. "but" when good news meets bad.
        let waiting = agg.byCategory[.waiting] ?? 0
        var friction = waiting >= 30 ? "They waited on you for \(waiting.clock)" : "They never had to wait on you"
        if w.errors >= 5 { friction += (waiting >= 30 ? " and " : ", but ") + "\(w.errors) tool calls failed" }

        return [first, shape.joined(separator: ", "), friction]
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(".") ? $0 : $0 + "." }
            .joined(separator: " ")
    }

    static func snippet(_ s: String, _ n: Int = 42) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    static func hourRange(_ h: Int) -> String {
        func f(_ h: Int) -> String {
            let h12 = h % 12 == 0 ? 12 : h % 12
            return "\(h12)\(h < 12 || h == 24 ? "am" : "pm")"
        }
        return "\(f(h))–\(f((h + 1) % 24))"
    }

    // MARK: Timelines

    /// Active time per category in `count` equal buckets across [from, to).
    static func buckets(_ sessions: [SessionSummary], from: Date, to: Date, count: Int) -> [[Category: TimeInterval]] {
        var out = Array(repeating: [Category: TimeInterval](), count: count)
        let width = to.timeIntervalSince(from) / Double(count)
        guard width > 0 else { return out }
        for s in sessions where s.end >= from && s.start <= to {
            for seg in s.segments {
                var a = max(seg.start, from)
                let b = min(seg.start.addingTimeInterval(seg.duration), to)
                while a < b {
                    let i = Int(a.timeIntervalSince(from) / width)
                    guard i >= 0 && i < count else { break }
                    let bucketEnd = from.addingTimeInterval(Double(i + 1) * width)
                    let piece = min(b, bucketEnd).timeIntervalSince(a)
                    out[i][seg.category, default: 0] += piece
                    a = a.addingTimeInterval(max(piece, 0.001))
                }
            }
        }
        return out
    }

    /// Active time for each hour of each of the last `days` days (oldest first).
    static func hourGrid(_ sessions: [SessionSummary], days: Int, now: Date) -> [(day: Date, hours: [TimeInterval])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var rows: [(Date, [TimeInterval])] = (0..<days).reversed().map {
            (cal.date(byAdding: .day, value: -$0, to: today)!, Array(repeating: 0, count: 24))
        }
        let first = rows.first?.0 ?? today
        for s in sessions where s.end >= first {
            for seg in s.segments where seg.start >= first {
                let d = cal.dateComponents([.day], from: first, to: cal.startOfDay(for: seg.start)).day ?? -1
                guard d >= 0 && d < rows.count else { continue }
                rows[d].1[cal.component(.hour, from: seg.start)] += seg.duration
            }
        }
        return rows.map { (day: $0.0, hours: $0.1) }
    }
}
