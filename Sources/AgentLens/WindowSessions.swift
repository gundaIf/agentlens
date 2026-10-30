import AppKit
import ApplicationServices

// Following AI apps that keep their sessions online (Muse, Grok Bot, ChatGPT) by reading their window through
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
    /// Set when the window exposes a labelled transcript (messages tagged with author and time, as
    /// Grok Bot does). Far more reliable than watching the text box, so the tracker prefers it.
    var chat: ChatLog? = nil
}

struct ChatLog {
    let conversation: String?      // the main area's heading ("Sidekick")
    let count: Int                 // messages in the transcript
    let lastFromUser: Bool         // the newest message is yours ("You 9:21 AM")
    let lastUserText: String?      // first line of your newest message (all we keep)
    let lastLength: Int            // length of the newest message, to see a reply still growing
    /// False for a plain message list (Muse): we can't tell your messages from the app's.
    var authorsKnown = true
    /// First line of the newest message, used as the prompt when authors aren't known.
    var lastText: String? = nil
}

enum WindowEventKind: String { case title, prompt, busyStart, busyEnd, step, beat }

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
        // The app's main conversation window only. Dialogs and sheets ("Log in", "Save",
        // "Software Update") would otherwise turn into sessions of their own.
        func isStandard(_ w: AXUIElement) -> Bool {
            (AXInspect.string(w, kAXSubroleAttribute) ?? "AXStandardWindow") == "AXStandardWindow"
        }
        let windows = (AXInspect.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let window = [AXInspect.element(app, kAXMainWindowAttribute), AXInspect.element(app, kAXFocusedWindowAttribute)]
            .compactMap { $0 }.first(where: isStandard) ?? windows.first(where: isStandard)
        guard let window else { return nil }
        // Sign-in, settings and update windows are ordinary windows too, but never conversations.
        let windowName = (AXInspect.string(window, kAXTitleAttribute) ?? "").lowercased()
        let notChats = ["log in", "login", "sign in", "sign up", "settings", "preferences", "software update", "welcome", "about "]
        if notChats.contains(where: { windowName == $0 || windowName.hasPrefix($0) }) { return nil }

        var buttons: [String] = [], labels: [String] = []
        var progress = false
        var textCount = 0, textLength = 0
        var firstTextArea: String?
        var visited = 0
        var mainTitle: String?, heading: String?
        var messages: [(author: String, content: String?)] = []
        let stamped = try! NSRegularExpression(pattern: #"^(.+?)\s+\d{1,2}:\d{2}(:\d{2})?\s?([AaPp][Mm])?$"#)

        // Messages come in three styles:
        //   labelled articles "Sidekick 8:26 AM"   (Grok Bot)
        //   headings "You said:" / "ChatGPT said:"  (ChatGPT), text follows the heading
        //   a plain message list with no authors   (Muse's "Chat messages")
        var collectingSaid = false
        var plainLog: [String] = []
        let said = try! NSRegularExpression(pattern: #"^(.{1,40}?) said:$"#)
        let dateLabel = try! NSRegularExpression(pattern: #"^\d{1,2} \w{3,9}( \d{4})? at \d{1,2}[:.]\d{2}|^\d{1,2}[:.]\d{2}( ?[AaPp][Mm])?$|^(Today|Yesterday)( at .*)?$"#)

        func walk(_ e: AXUIElement, _ depth: Int, _ inLog: Bool) {
            guard depth < 60, visited < 8000 else { return }
            visited += 1
            let role = AXInspect.string(e, kAXRoleAttribute) ?? ""
            let sub = role == "AXGroup" ? AXInspect.string(e, kAXSubroleAttribute) : nil
            switch role {
            case "AXButton":
                let name = [AXInspect.string(e, kAXTitleAttribute), AXInspect.string(e, kAXDescriptionAttribute)]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                if !name.isEmpty { buttons.append(name) }
            case "AXProgressIndicator", "AXBusyIndicator":
                progress = true
            case "AXHeading":
                let t = AXInspect.string(e, kAXTitleAttribute) ?? AXInspect.string(e, kAXDescriptionAttribute) ?? ""
                if let m = said.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let a = Range(m.range(at: 1), in: t) {
                    messages.append((String(t[a]), ""))                 // "You said:": a message starts
                    collectingSaid = true
                } else if heading == nil {
                    heading = AXInspect.string(e, kAXDescriptionAttribute) ?? AXInspect.string(e, kAXTitleAttribute)
                }
            case "AXGroup":
                if sub == "AXLandmarkMain", mainTitle == nil { mainTitle = AXInspect.string(e, kAXTitleAttribute) }
                if sub == "AXDocumentArticle", let t = AXInspect.string(e, kAXTitleAttribute) {
                    let r = NSRange(t.startIndex..., in: t)
                    if let m = stamped.firstMatch(in: t, range: r), let a = Range(m.range(at: 1), in: t), t.count <= 80 {
                        messages.append((String(t[a]), nil))          // "Sidekick 8:26:24 AM": a message starts
                        collectingSaid = false
                    } else if !messages.isEmpty, messages[messages.count - 1].content == nil {
                        messages[messages.count - 1].content = t       // its body, one level down
                    }
                }
            case "AXStaticText":
                if let v = AXInspect.string(e, kAXValueAttribute) {
                    textCount += 1
                    textLength += v.count
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count <= 48, t.hasSuffix("…") || t.hasSuffix("...") { labels.append(t) }
                    // The heading's own text ("You said:") also shows up as a static text: it isn't the message.
                    let isSaidLabel = said.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
                    if isSaidLabel {
                        // skip
                    } else if collectingSaid, !messages.isEmpty, let c = messages[messages.count - 1].content, c.count < 4000 {
                        messages[messages.count - 1].content = c.isEmpty ? t : c + "\n" + t
                    } else if inLog, !t.isEmpty,
                              dateLabel.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil {
                        plainLog.append(t)
                    }
                }
            case "AXTextArea", "AXTextField":
                collectingSaid = false                                 // the composer ends the transcript
                if firstTextArea == nil, (AXInspect.attr(e, "AXEditable") as? Bool) ?? (role == "AXTextArea") {
                    let v = AXInspect.string(e, kAXValueAttribute)
                    // Some apps report their placeholder ("Ask anything…") as the value.
                    firstTextArea = (v != nil && v == AXInspect.string(e, kAXPlaceholderValueAttribute)) ? "" : v
                }
            default: break
            }
            if role == "AXTextArea" || role == "AXTextField" { return }
            let childInLog = inLog || sub == "AXApplicationLog"
            AXInspect.children(e).forEach { walk($0, depth + 1, childInLog) }
        }
        walk(window, 0, false)

        // Prefer the focused text box as the message box.
        var input = firstTextArea
        if let f = AXInspect.element(app, kAXFocusedUIElementAttribute),
           let r = AXInspect.string(f, kAXRoleAttribute), r == "AXTextArea" || r == "AXTextField" {
            input = AXInspect.string(f, kAXValueAttribute)
        }
        var chat: ChatLog?
        if messages.isEmpty, !plainLog.isEmpty {
            let last = plainLog[plainLog.count - 1]
            chat = ChatLog(conversation: nil, count: plainLog.count, lastFromUser: false, lastUserText: nil,
                           lastLength: last.count, authorsKnown: false,
                           lastText: String((last.components(separatedBy: .newlines).first ?? last).prefix(120)))
        } else if !messages.isEmpty {
            let you: Set<String> = ["you", "me", "user"]
            let last = messages[messages.count - 1]
            let lastMine = messages.last { you.contains($0.author.lowercased()) }
            // Trust the in-window heading only when the window title is just the app's name (Grok Bot, Muse).
            // ChatGPT titles its window after the conversation, which beats any heading.
            let windowTitle = AXInspect.string(window, kAXTitleAttribute) ?? ""
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
            let generic = windowTitle.isEmpty || windowTitle == appName
            let name = generic ? [mainTitle, heading].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } : nil
            chat = ChatLog(conversation: name, count: messages.count,
                           lastFromUser: you.contains(last.author.lowercased()),
                           lastUserText: lastMine?.content.map { String(($0.components(separatedBy: .newlines).first ?? $0).prefix(120)) },
                           lastLength: last.content?.count ?? 0)
        }
        return WindowSnapshot(time: now, title: AXInspect.string(window, kAXTitleAttribute) ?? "",
                              buttons: buttons, statusLabels: labels, input: input,
                              textSignature: textCount &* 1_000_003 &+ textLength, progress: progress, chat: chat)
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
    /// Text seen in the message box on two reads in a row (so flicker and other fields don't count).
    private var typed = ""
    private var typedCandidate = ""
    /// The box just emptied; it becomes a prompt only if the conversation changes soon after.
    private var pending: (text: String, time: Date)?
    private var lastEmitted: (text: String, time: Date)?
    private var lastBeat = Date.distantPast
    private var lastChatCount: Int?
    /// False until the first snapshot has been taken in (the baseline).
    private var seenBefore = false
    private var lastFromUser = false
    private var lastUserText: String?
    private var newestText: (text: String, time: Date)?

    private func emitPrompt(_ text: String?, at t: Date, into out: inout [WindowEvent]) {
        let text = text.flatMap { $0.isEmpty ? nil : $0 } ?? "(message)"
        let repeatSend = lastEmitted.map { $0.text == text && t.timeIntervalSince($0.time) < 120 } ?? false
        if !repeatSend {
            out.append(WindowEvent(time: t, kind: .prompt, text: text))
            lastEmitted = (text, t)
        }
        lastPrompt = t
    }


    func ingest(_ s: WindowSnapshot) -> [WindowEvent] {
        var out: [WindowEvent] = []
        // A labelled transcript names the conversation; the window title may just be the app's name.
        let title = (s.chat?.conversation).flatMap { $0.isEmpty ? nil : $0 } ?? s.title.trimmingCharacters(in: .whitespaces)
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
            lastChatCount = nil
            lastFromUser = false
            lastUserText = nil
            newestText = nil
            lastTitle = title
            out.append(WindowEvent(time: s.time, kind: .title, text: title))
        }

        // With a transcript, "the conversation changed" means a message was added or is still growing.
        let signature = s.chat.map { $0.count &* 1_000_003 &+ $0.lastLength } ?? s.textSignature
        if let sig = lastSignature, sig != signature { lastSignatureChange = s.time }
        lastSignature = signature

        if let c = s.chat {
            if c.authorsKnown {
                // A prompt is a change in your newest message, whether or not a reply has already appeared
                // below it (slow-to-read apps like ChatGPT are only read every few seconds). Scrolling up to
                // older messages doesn't change your newest one. Also: your message becoming the newest again
                // with the same text (sending "yes" twice). Not the count: Grok Bot keeps only the latest few.
                // Baseline first, so opening a chat doesn't replay it.
                let newText = c.lastUserText != nil && lastUserText != nil && c.lastUserText != lastUserText
                let flipped = c.lastFromUser && !lastFromUser
                if lastChatCount != nil, newText || flipped {
                    emitPrompt(c.lastUserText, at: s.time, into: &out)
                }
                lastFromUser = c.lastFromUser
                lastUserText = c.lastUserText
            } else if let n = lastChatCount, c.count > n || (c.lastText != nil && c.lastText != newestText?.text) {
                // No authors (Muse): remember the newest message; it becomes the prompt if answering starts soon.
                newestText = (c.lastText ?? "", s.time)
            }
            lastChatCount = c.count
        }

        // Prompt: text sat in the box, the box emptied, and the conversation then changed
        // (your message appeared) within 6 seconds. Anything else is flicker, not a send.
        let input = (s.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.input != nil, s.chat == nil {
            if input.count >= 2 {
                if input == typedCandidate { typed = input } else { typedCandidate = input }
            } else if input.isEmpty {
                if typed.count >= 2 { pending = (typed, s.time) }
                typed = ""; typedCandidate = ""
            }
        }
        if let p = pending {
            if lastSignatureChange >= p.time {
                let first = String((p.text.components(separatedBy: .newlines).first ?? p.text).prefix(120))
                let repeatSend = lastEmitted.map { $0.text == first && p.time.timeIntervalSince($0.time) < 120 } ?? false
                if !repeatSend {
                    out.append(WindowEvent(time: p.time, kind: .prompt, text: first))
                    lastEmitted = (first, p.time)
                    lastPrompt = p.time
                }
                pending = nil
            } else if s.time.timeIntervalSince(p.time) > 6 {
                pending = nil
            }
        }
        lastInput = input

        // A command, not a title: the word starts or ends the name ("Stop generating", Muse's "…message Stop").
        // Links like "…Anthony Christopher…" or "…animaciones en stop motion" once kept ChatGPT "answering".
        let stopShowing = s.buttons.contains { b in
            b.range(of: #"^(stop|cancel|interrupt)\b|\b(stop|cancel|interrupt)$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let streaming = s.time.timeIntervalSince(lastSignatureChange) < 2.5 && s.time.timeIntervalSince(lastPrompt) < 15 * 60
        // Your message is the newest and no reply has started: the agent is working on it.
        // Capped at 3 minutes on its own: a message that only gets a reaction (❤️) never gets a reply.
        let awaiting = s.chat?.lastFromUser == true && s.time.timeIntervalSince(lastPrompt) < 3 * 60
        let nowBusy = stopShowing || s.progress || streaming || awaiting

        if nowBusy {
            quietSince = nil
            if !busy {
                // Authors unknown: the message that appeared just before answering began is your prompt.
                // Not on the first look at a window: an answer already under way isn't a new exchange.
                if s.chat?.authorsKnown == false, seenBefore, s.time.timeIntervalSince(lastPrompt) > 20 {
                    let recent = newestText.flatMap { s.time.timeIntervalSince($0.time) < 20 ? $0.text : nil }
                    emitPrompt(recent, at: s.time, into: &out)
                }
                busy = true
                lastStep = ""
                out.append(WindowEvent(time: s.time, kind: .busyStart))
            }
            if let label = s.statusLabels.last, label != lastStep {
                lastStep = label
                out.append(WindowEvent(time: s.time, kind: .step, text: label))
            }
            // Heartbeat, so a turn whose end we never saw (app quit, window closed) can be closed later.
            if s.time.timeIntervalSince(lastBeat) >= 30 {
                lastBeat = s.time
                out.append(WindowEvent(time: s.time, kind: .beat))
            }
        } else if busy {
            // Require a moment of calm so a pause mid-reply doesn't end the turn.
            if quietSince == nil { quietSince = s.time }
            if s.time.timeIntervalSince(quietSince!) >= 3 {
                busy = false
                out.append(WindowEvent(time: quietSince!, kind: .busyEnd))
            }
        }
        seenBefore = true
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
    /// Per app, when it's next due. Slow-to-read windows (ChatGPT: ~0.5s) are read less often, so
    /// watching never weighs on the app being watched. Only touched on `queue`.
    private var nextRead: [String: Date] = [:]

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { WindowWatcher.shared.tick() }
        }
    }

    private func tick() {
        guard AXInspect.trusted, !busy else { return }
        let targets = AppUsage.shared.apps.filter { $0.readsWindow && $0.isTracked }.compactMap { app -> (TrackedApp, pid_t)? in
            NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first.map { (app, $0.processIdentifier) }
        }
        guard !targets.isEmpty else { return }
        busy = true
        let trackers = targets.map { t in self.trackers[t.0.id] ?? { let n = WindowTracker(); self.trackers[t.0.id] = n; return n }() }
        queue.async {
            for (i, (app, pid)) in targets.enumerated() {
                if let due = self.nextRead[app.id], Date() < due { continue }
                let began = Date()
                let snapshot = WindowReader.snapshot(pid: pid)
                // Pace: a read costing ~1/4 of the interval at most, between 1 and 4 seconds.
                let cost = Date().timeIntervalSince(began)
                self.nextRead[app.id] = began.addingTimeInterval(min(4, max(1, cost * 4)) - 0.05)
                guard let snap = snapshot else { continue }
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

    static func read(_ url: URL) -> [WindowEvent] { dedupe(readRaw(url)) }

    static func readRaw(_ url: URL) -> [WindowEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String],
                  let t = o["t"].flatMap(iso.date), let k = o["k"].flatMap(WindowEventKind.init) else { return nil }
            return WindowEvent(time: t, kind: k, text: o["x"] ?? "")
        }
    }

    /// Older builds logged the same "prompt" every second when a window's text box flickered.
    /// Keep one of any identical prompt repeated within two minutes.
    static func dedupe(_ events: [WindowEvent]) -> [WindowEvent] {
        var out: [WindowEvent] = []
        var lastPrompt: [String: Date] = [:]
        for e in events {
            if e.kind == .prompt {
                if let t = lastPrompt[e.text], e.time.timeIntervalSince(t) < 120 { lastPrompt[e.text] = e.time; continue }
                lastPrompt[e.text] = e.time
            }
            out.append(e)
        }
        return out
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
        guard let source = app.source else { return [] }
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

            var previous: Date?
            for e in g.events {
                defer { if e.kind != .title { previous = e.time } }
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
                case .title:
                    // A title is the first thing a (re)started watcher writes. An answer still open from a
                    // previous run never got its end; close it where that run last heard of it.
                    if busySince != nil, let p = previous { close(at: p); busySince = nil; step = nil }
                case .beat: break
                }
            }
            // Busy with no word from the watcher for 90s (it beats every 30s): the turn ended unseen,
            // e.g. the app quit or the window closed. Close it where we last heard of it.
            var stillBusy = busySince != nil
            if stillBusy, now.timeIntervalSince(last.time) > 90 {
                close(at: last.time); busySince = nil; step = nil; stillBusy = false
            }
            if stillBusy { close(at: max(last.time, now)) }
            // A window that never got a prompt and barely did anything isn't a session.
            let realPrompts = chunks.filter { $0.prompt != "(conversation in progress)" }.count
            // Under 5s of answering is leftover flicker from older builds, not a real exchange.
            let answering = segments.map(\.duration).reduce(0, +)
            if (realPrompts == 0 && answering < 10) || answering < 5 { return nil }

            var totals = Aggregate()
            for s in segments { totals.add(s, project: app.name, session: id) }
            let lastKind = evs.last(where: { $0.kind != .beat })?.kind ?? .busyEnd
            return SessionSummary(
                id: id, source: source, title: g.title, project: app.name, cwd: "", branch: nil,
                start: first.time, end: stillBusy ? max(last.time, now) : last.time,
                segments: segments, totals: totals, chunks: chunks,
                toolCalls: 0, errors: 0, outputTokens: 0, inputTokens: 0,
                prompts: chunks.filter { $0.prompt != "(conversation in progress)" }.count,
                lastEventTime: stillBusy ? now : last.time,
                lastEventEndedTurn: !stillBusy && (lastKind != .prompt || now.timeIntervalSince(last.time) > 90),
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
