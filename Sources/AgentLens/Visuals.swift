import SwiftUI

private func hourLabel(_ h: Int) -> String {
    switch h % 24 {
    case 0: return "12a"
    case 12: return "12p"
    case let x where x < 12: return "\(x)a"
    case let x: return "\(x - 12)p"
    }
}

/// The day at a glance: one stacked bar per 15 minutes, coloured by what agents were doing.
struct DayRibbon: View {
    let sessions: [SessionSummary]
    let day: Date
    var now = Date()
    var barHeight: CGFloat = 34
    var showLabels = true

    var body: some View {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        let count = 96
        let buckets = Insights.buckets(sessions, from: start, to: end, count: count)
        let width = 86400.0 / Double(count)
        let nowIndex = now >= start && now < end ? Int(now.timeIntervalSince(start) / width) : nil

        VStack(spacing: 5) {
            Canvas { ctx, size in
                let slot = size.width / CGFloat(count)
                let barW = max(1, slot - 1)
                // Faint hour guides.
                for h in stride(from: 0, through: 24, by: 6) {
                    let x = CGFloat(h) * 4 * slot
                    ctx.fill(Path(CGRect(x: min(x, size.width - 0.5), y: 0, width: 0.5, height: size.height)),
                             with: .color(.primary.opacity(0.08)))
                }
                for (i, b) in buckets.enumerated() {
                    let x = CGFloat(i) * slot
                    let total = b.values.reduce(0, +)
                    if total < 1 {
                        let future = nowIndex.map { i > $0 } ?? false
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - 2, width: barW, height: 2), cornerRadius: 1),
                                 with: .color(.primary.opacity(future ? 0.04 : 0.10)))
                        continue
                    }
                    let fill = min(1, total / width)
                    let h = max(4, size.height * CGFloat(0.25 + 0.75 * fill))
                    var y = size.height
                    for c in Category.allCases {
                        guard let v = b[c], v > 0 else { continue }
                        let ph = h * CGFloat(v / total)
                        y -= ph
                        ctx.fill(Path(CGRect(x: x, y: y, width: barW, height: ph)), with: .color(c.color))
                    }
                }
                if let n = nowIndex {
                    let x = (CGFloat(n) + 0.5) * slot
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.55)))
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: -2.5, width: 5, height: 5)), with: .color(.primary.opacity(0.7)))
                }
            }
            .frame(height: barHeight)

            if showLabels {
                HStack {
                    ForEach([0, 6, 12, 18, 24], id: \.self) { h in
                        Text(hourLabel(h)).frame(maxWidth: .infinity, alignment: h == 0 ? .leading : (h == 24 ? .trailing : .center))
                    }
                }
                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

/// Today as swimlanes: one row per session, segments at their real clock times.
struct SessionLanes: View {
    let sessions: [SessionSummary]
    let day: Date
    var now = Date()
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let dayEnd = start.addingTimeInterval(86400)
        let rows = sessions
            .map { s in (s, s.segments.filter { $0.start >= start && $0.start < dayEnd }) }
            .filter { !$0.1.isEmpty }
            .sorted { ($0.1.first?.start ?? start) < ($1.1.first?.start ?? start) }
        let firstSeg = rows.compactMap { $0.1.first?.start }.min() ?? start
        let lastSeg = rows.compactMap { $0.1.last.map { $0.start.addingTimeInterval($0.duration) } }.max() ?? now
        let fromHour = max(0, cal.component(.hour, from: firstSeg) - 1)
        let toHour = min(24, cal.component(.hour, from: max(lastSeg, min(now, dayEnd))) + 1)
        let from = start.addingTimeInterval(Double(fromHour) * 3600)
        let to = start.addingTimeInterval(Double(max(toHour, fromHour + 2)) * 3600)
        let span = to.timeIntervalSince(from)
        let hours = Array(stride(from: fromHour, through: max(toHour, fromHour + 2), by: max(1, (toHour - fromHour) / 8)))

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 190, height: 1)
                GeometryReader { g in
                    ForEach(hours, id: \.self) { h in
                        Text(hourLabel(h))
                            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary)
                            .position(x: g.size.width * CGFloat(Double(h - fromHour) * 3600 / span), y: 6)
                    }
                }
                .frame(height: 14)
            }
            .padding(.bottom, 6)

            ForEach(rows, id: \.0.id) { s, segs in
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        LensMark(values: s.totals.byCategory, size: 14)
                        Text(s.title).font(.system(size: 12)).lineLimit(1)
                    }
                    .frame(width: 190, alignment: .leading)

                    Canvas { ctx, size in
                        for h in hours {
                            let x = size.width * CGFloat(Double(h - fromHour) * 3600 / span)
                            ctx.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.primary.opacity(0.06)))
                        }
                        ctx.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1), cornerRadius: 0.5),
                                 with: .color(.primary.opacity(0.06)))
                        for seg in segs {
                            let x = size.width * CGFloat(seg.start.timeIntervalSince(from) / span)
                            let w = max(1.5, size.width * CGFloat(seg.duration / span))
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: 3, width: w, height: size.height - 6), cornerRadius: 2),
                                     with: .color(seg.category.color))
                        }
                        if now > from && now < to {
                            let x = size.width * CGFloat(now.timeIntervalSince(from) / span)
                            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.4)))
                        }
                    }
                    .frame(height: 20)

                    Text(segs.map(\.duration).reduce(0, +).clock)
                        .font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(s.id) }
            }
        }
    }
}

/// When agents work: hour-of-day columns, one row per day, darker = more agent time.
struct HourHeatmap: View {
    let rows: [(day: Date, hours: [TimeInterval])]

    var body: some View {
        let peak = max(rows.flatMap(\.hours).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Color.clear.frame(width: 44, height: 1)
                ForEach(0..<24, id: \.self) { h in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 12)
                        .overlay(alignment: .leading) {
                            if h % 6 == 0 {
                                Text(hourLabel(h)).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                        }
                }
            }
            ForEach(rows, id: \.day) { row in
                HStack(spacing: 3) {
                    Text(row.day, format: .dateTime.weekday(.abbreviated).day())
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let v = row.hours[h]
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(v < 1 ? Color.white.opacity(0.04) : HUD.heat(0.08 + 0.92 * sqrt(v / peak)))
                            .frame(maxWidth: .infinity)
                            .frame(height: rows.count > 14 ? 9 : 16)
                            .help(v < 1 ? "" : "\(hourLabel(h)): \(v.clock)")
                    }
                }
            }
        }
    }
}

/// A session's active time laid end to end, with a small break between prompts.
struct SessionFlow: View {
    let chunks: [Chunk]

    var body: some View {
        let total = max(chunks.map(\.active).reduce(0, +), 1)
        Canvas { ctx, size in
            let gaps = CGFloat(max(chunks.count - 1, 0)) * 3
            let usable = max(size.width - gaps, 1)
            var x: CGFloat = 0
            for (ci, chunk) in chunks.enumerated() {
                for step in chunk.steps {
                    let w = usable * CGFloat(step.duration / total)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(step.category.color))
                    x += w
                }
                if ci < chunks.count - 1 { x += 3 }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The steps of one chunk laid end to end, widths proportional to active time.
struct StepStrip: View {
    let steps: [Step]
    let total: TimeInterval

    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            let gaps = CGFloat(max(steps.count - 1, 0))
            let usable = max(size.width - gaps, 1)
            for s in steps {
                let w = max(1, usable * CGFloat(s.duration / max(total, 1)))
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)), with: .color(s.category.color))
                x += w + 1
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}
