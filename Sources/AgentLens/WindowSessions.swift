import AppKit
import ApplicationServices

// Following AI apps that keep their sessions online (Muse, Grok Bot) by reading their window through
// the Accessibility API. Nothing here is app-specific: it relies on signals every chat-style app shows.
//
//   conversation  = the window title
//   prompt sent   = the message box had text, then emptied (we keep only its first line)
//   working       = a Stop/Cancel button or a progress indicator is showing, or the reply text is still
//                   changing shortly after a prompt
//   step labels   = short status texts ending in "…" ("Searching…", "Making…")
//
// The watcher writes events to ~/Library/Application Support/AgentLens/windows/<bundle>.jsonl;
// WindowSessions turns those into SessionSummary values like any other source.

/// What the reader sees in one look at an app's front window.
struct WindowSnapshot {
    let time: Date
    let title: String
    let buttons: [String]          // lowercased titles/descriptions
    let statusLabels: [String]     // short texts ending in "…"
    let input: String?             // the message box's current text
    let textSignature: Int         // changes when the conversation text changes (content isn't kept)
    let progress: Bool             // a progress or busy indicator is showing
}

enum WindowEventKind: String { case title, prompt, busyStart, busyEnd, step }

struct WindowEvent {
    let time: Date
    let kind: WindowEventKind
    var text: String = ""
}

// MARK: - Reading the window

enum WindowReader {
    private static var enabled = Set<pid_t>()

    static func snapshot(pid: pid_t, now: Date = Date()) -> WindowSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        if !enabled.contains(pid) {
            // Electron/Chromium apps build their tree only when asked; harmless for native apps.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabled.insert(pid)
        }
        let window = AXInspect.element(app, kAXFocusedWindowAttribute)
            ?? AXInspect.element(app, kAXMainWindowAttribute)
            ?? (AXInspect.attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        guard let window else { return nil }

        var buttons: [String] = [], labels: [String] = []
        var progress = false
        var textCount = 0, textLength = 0
        var firstTextArea: String?
        var visited = 0

        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 45, visited < 4000 else { return }
            visited += 1
            let role = AXInspect.string(e, kAXRoleAttribute) ?? ""
            switch role {
            case "AXButton":
                let name = [AXInspect.string(e, kAXTitleAttribute), AXInspect.string(e, kAXDescriptionAttribute)]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                if !name.isEmpty { buttons.append(name) }
            case "AXProgressIndicator", "AXBusyIndicator":
                progress = true
            case "AXStaticText":
                if let v = AXInspect.string(e, kAXValueAttribute) {
                    textCount += 1
                    textLength += v.count
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count <= 48, t.hasSuffix("…") || t.hasSuffix("...") { labels.append(t) }
                }
            case "AXTextArea", "AXTextField":
                if firstTextArea == nil, (AXInspect.attr(e, "AXEditable") as? Bool) ?? (role == "AXTextArea") {
                    firstTextArea = AXInspect.string(e, kAXValueAttribute)
                }
            default: break
            }
            if role == "AXTextArea" || role == "AXTextField" { return }
            AXInspect.children(e).forEach { walk($0, depth + 1) }
        }
        walk(window, 0)

        // Prefer the focused text box as the message box.
        var input = firstTextArea
        if let f = AXInspect.element(app, kAXFocusedUIElementAttribute),
           let r = AXInspect.string(f, kAXRoleAttribute), r == "AXTextArea" || r == "AXTextField" {
            input = AXInspect.string(f, kAXValueAttribute)
        }
        return WindowSnapshot(time: now, title: AXInspect.string(window, kAXTitleAttribute) ?? "",
                              buttons: buttons, statusLabels: labels, input: input,
                              textSignature: textCount &* 1_000_003 &+ textLength, progress: progress)
    }
}

// MARK: - Turning snapshots into events

/// Per-app state machine. Pure logic (no AX), so it can be tested with made-up snapshots.
final class WindowTracker {
    private var lastTitle = ""
    private var lastInput = ""
    private var lastSignature: Int?
    private var lastSignatureChange = Date.distantPast
    private var lastPrompt = Date.distantPast
    private var busy = false
    private var quietSince: Date?
    private var lastStep = ""

    private static let stopWords = ["stop", "cancel", "interrupt"]

    func ingest(_ s: WindowSnapshot) -> [WindowEvent] {
        var out: [WindowEvent] = []
        let title = s.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != lastTitle {
            // Another conversation: close the old one's turn, and don't mistake the new page of text
            // for a reply streaming in.
            if busy {
                busy = false
                out.append(WindowEvent(time: s.time, kind: .busyEnd))
            }
            quietSince = nil
            lastSignature = nil
            lastSignatureChange = .distantPast
            lastPrompt = .distantPast
            lastTitle = title
            out.append(WindowEvent(time: s.time, kind: .title, text: title))
        }

        if let sig = lastSignature, sig != s.textSignature { lastSignatureChange = s.time }
        lastSignature = s.textSignature

        // Prompt: the box had text and is now empty.
        let input = (s.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty, lastInput.count >= 2 {
            let first = lastInput.components(separatedBy: .newlines).first ?? lastInput
            out.append(WindowEvent(time: s.time, kind: .prompt, text: String(first.prefix(120))))
            lastPrompt = s.time
        }
        if s.input != nil { lastInput = input }

        let stopShowing = s.buttons.contains { b in WindowTracker.stopWords.contains { b.contains($0) } }
        let streaming = s.time.timeIntervalSince(lastSignatureChange) < 2.5 && s.time.timeIntervalSince(lastPrompt) < 15 * 60
        let nowBusy = stopShowing || s.progress || streaming

        if nowBusy {
            quietSince = nil
            if !busy {
                busy = true
                lastStep = ""
                out.append(WindowEvent(time: s.time, kind: .busyStart))
            }
            if let label = s.statusLabels.last, label != lastStep {
                lastStep = label
                out.append(WindowEvent(time: s.time, kind: .step, text: label))
            }
        } else if busy {
            // Require a moment of calm so a pause mid-reply doesn't end the turn.
            if quietSince == nil { quietSince = s.time }
            if s.time.timeIntervalSince(quietSince!) >= 3 {
                busy = false
                out.append(WindowEvent(time: quietSince!, kind: .busyEnd))
            }
        }
        return out
    }
}

// MARK: - Watching (main app only)

@MainActor
final class WindowWatcher {
    static let shared = WindowWatcher()
    private var trackers: [String: WindowTracker] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "agentlens.windows", qos: .utility)
    private var busy = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { WindowWatcher.shared.tick() }
        }
    }

    private func tick() {
        guard AXInspect.trusted, !busy else { return }
        let targets = AppUsage.shared.apps.filter(\.readsWindow).compactMap { app -> (TrackedApp, pid_t)? in
            NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first.map { (app, $0.processIdentifier) }
        }
        guard !targets.isEmpty else { return }
        busy = true
        let trackers = targets.map { t in self.trackers[t.0.id] ?? { let n = WindowTracker(); self.trackers[t.0.id] = n; return n }() }
        queue.async {
            for (i, (app, pid)) in targets.enumerated() {
                guard let snap = WindowReader.snapshot(pid: pid) else { continue }
                let events = trackers[i].ingest(snap)
                if !events.isEmpty { WindowLog.append(events, app: app.id) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { WindowWatcher.shared.busy = false } }
        }
    }
}

enum WindowLog {
    static var dir: URL { Paths.support.appendingPathComponent("windows") }
    static func file(_ bundle: String) -> URL { dir.appendingPathComponent("\(bundle).jsonl") }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func append(_ events: [WindowEvent], app: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = Data()
        for e in events {
            var o = ["t": iso.string(from: e.time), "k": e.kind.rawValue]
            if !e.text.isEmpty { o["x"] = e.text }
            if let line = try? JSONSerialization.data(withJSONObject: o) { data.append(line); data.append(0x0A) }
        }
        let url = file(app)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static func read(_ url: URL) -> [WindowEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String],
                  let t = o["t"].flatMap(iso.date), let k = o["k"].flatMap(WindowEventKind.init) else { return nil }
            return WindowEvent(time: t, kind: k, text: o["x"] ?? "")
        }
    }
}

// MARK: - Sessions from the event log (runs on the store's worker)

final class WindowSessions {
    private var stamps: [String: String] = [:]
    private var cache: [String: [SessionSummary]] = [:]

    var summaries: [SessionSummary] { cache.values.flatMap { $0 } }

    func poll() -> Bool {
        var changed = false
        for app in TrackedApp.catalog where app.readsWindow {
            let url = WindowLog.file(app.id)
            let a = try? FileManager.default.attributesOfItem(atPath: url.path)
            let stamp = "\((a?[.size] as? NSNumber)?.int64Value ?? -1):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if stamps[app.id] == stamp { continue }
            stamps[app.id] = stamp
            cache[app.id] = WindowSessions.build(WindowLog.read(url), app: app)
            changed = true
        }
        return changed
    }

    /// Splits an app's events into sessions (new conversation title, or 30 min of silence) and builds
    /// one chunk per prompt, with the answering time as segments labelled by the step texts.
    static func build(_ events: [WindowEvent], app: TrackedApp, now: Date = Date()) -> [SessionSummary] {
        let source: Source = app.id == "com.meta.endo" ? .muse : .grokBot
        var groups: [(title: String, events: [WindowEvent])] = []
        var title = app.name
        for e in events {
            if e.kind == .title { title = e.text }
            let gap = groups.last?.events.last.map { e.time.timeIntervalSince($0.time) } ?? .infinity
            // A different conversation title starts a new session (once the current one has content).
            let titleChanged = e.kind == .title && (groups.last.map { $0.title != e.text && !$0.events.isEmpty } ?? false)
            if groups.isEmpty || gap > 30 * 60 || titleChanged {
                groups.append((title, []))
            }
            if e.kind == .title { groups[groups.count - 1].title = e.text }
            groups[groups.count - 1].events.append(e)
        }

        return groups.compactMap { g -> SessionSummary? in
            let evs = g.events.filter { $0.kind != .title }
            guard evs.contains(where: { $0.kind != .busyEnd }), let first = evs.first, let last = evs.last else { return nil }
            let id = "window:\(app.id):\(Int(first.time.timeIntervalSince1970))"
            var chunks: [Chunk] = []
            var segments: [Segment] = []
            var busySince: Date?
            var step: (label: String, since: Date)?

            func close(at t: Date) {
                guard let since = step?.since ?? busySince, t > since else { return }
                let label = step?.label ?? ""
                let seg = Segment(start: since, duration: min(t.timeIntervalSince(since), Analyzer.maxToolGap),
                                  category: category(for: label), label: label, tool: label.isEmpty ? nil : label)
                segments.append(seg)
                if chunks.isEmpty { chunks.append(Chunk(prompt: "(conversation in progress)", start: since, end: since)) }
                var c = chunks[chunks.count - 1]
                c.active += seg.duration
                c.byCategory[seg.category, default: 0] += seg.duration
                if var s = c.steps.last, s.category == seg.category {
                    s.duration += seg.duration
                    if !label.isEmpty, !s.labels.contains(label) { s.labels.append(label) }
                    c.steps[c.steps.count - 1] = s
                } else {
                    c.steps.append(Step(category: seg.category, duration: seg.duration, labels: label.isEmpty ? [] : [label]))
                }
                c.end = t
                chunks[chunks.count - 1] = c
            }

            for e in evs {
                switch e.kind {
                case .prompt:
                    if busySince != nil { close(at: e.time); step = nil; busySince = e.time }
                    chunks.append(Chunk(prompt: e.text, start: e.time, end: e.time))
                case .busyStart:
                    busySince = e.time; step = nil
                case .step:
                    if busySince != nil { close(at: e.time) }
                    step = (e.text, e.time)
                case .busyEnd:
                    close(at: e.time); busySince = nil; step = nil
                case .title: break
                }
            }
            let stillBusy = busySince != nil
            if stillBusy { close(at: max(last.time, now)) }

            var totals = Aggregate()
            for s in segments { totals.add(s, project: app.name, session: id) }
            let lastKind = evs.last!.kind
            return SessionSummary(
                id: id, source: source, title: g.title, project: app.name, cwd: "", branch: nil,
                start: first.time, end: stillBusy ? max(last.time, now) : last.time,
                segments: segments, totals: totals, chunks: chunks,
                toolCalls: 0, errors: 0, outputTokens: 0, inputTokens: 0,
                prompts: chunks.filter { $0.prompt != "(conversation in progress)" }.count,
                lastEventTime: stillBusy ? now : last.time,
                lastEventEndedTurn: !stillBusy && lastKind != .prompt,
                pendingTool: stillBusy ? ToolCall(id: "", name: step?.label ?? "Answering", detail: "", file: nil, start: step?.since ?? busySince!) : nil,
                permissionSince: nil
            )
        }
    }

    /// Step labels to activity categories, by the verbs apps use.
    static func category(for label: String) -> Category {
        let l = label.lowercased()
        if l.isEmpty || l.contains("think") || l.contains("reason") { return .thinking }
        if l.contains("search") || l.contains("brows") || l.contains("web") || l.contains("fetch") { return .web }
        if l.contains("read") || l.contains("look") || l.contains("analy") { return .reading }
        if l.contains("writ") || l.contains("edit") || l.contains("mak") || l.contains("creat") || l.contains("generat") || l.contains("draw") { return .editing }
        if l.contains("run") || l.contains("command") || l.contains("execut") || l.contains("install") { return .shell }
        return .other
    }
}
