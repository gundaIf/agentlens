import AppKit
import Foundation

// `AgentLens --dump` prints what the app sees, for checking the numbers without the UI.
if CommandLine.arguments.contains("--dump") {
    let result = Worker().scanNow()
    let sessions = result?.sessions ?? []
    let now = Date()
    let all = Analyzer.aggregate(sessions, since: nil)
    print("Sessions: \(sessions.count)   active time: \(all.active.pretty)\n")
    print("By category:")
    for c in Category.allCases { if let v = all.byCategory[c] { print("  \(c.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(v.pretty)") } }
    print("    of which permission prompts: \(all.permissionWait.pretty)")
    print("\nHooks: \(HookInstaller.isInstalled() ? "installed" : "not installed")   events: \(result?.hookEvents ?? 0)" +
          (result?.lastHookEvent.map { ", last \(now.timeIntervalSince($0).pretty) ago" } ?? ""))
    print("\nTop tools:")
    for (k, v) in Aggregate.top(all.byTool, 8) { print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(v.pretty)") }
    print("\nTop shell commands:")
    for (k, v) in Aggregate.top(all.byCommand, 8) { print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(v.pretty)") }
    for s in sessions where s.source == .codex {
        print("\nChatGPT/Codex: \(s.title.prefix(50)) — \(s.active.pretty) active, \(s.prompts) prompts, \(s.toolCalls) tools, \(s.errors) failed, files \(Set(s.chunks.flatMap(\.files)).count), \(s.outputTokens) tokens out — \(s.live(at: now))")
        for c in s.chunks {
            print("    • \(c.prompt.prefix(44).replacingOccurrences(of: "\n", with: " ")) [\(c.active.pretty)] " + c.steps.coalesced().prefix(5).map { "\($0.category.rawValue) \($0.duration.pretty)" }.joined(separator: " → "))
        }
    }
    for s in sessions where s.source == .grok {
        let steps = s.chunks.map { c in c.steps.coalesced().prefix(4).map { "\($0.category.rawValue) \($0.duration.pretty)" }.joined(separator: " → ") }
        print("\nGrok: \(s.title.prefix(50)) — \(s.active.pretty) active, \(s.prompts) prompts, \(s.toolCalls) tools, waiting \((s.totals.byCategory[.waiting] ?? 0).pretty), files \(Set(s.chunks.flatMap(\.files)).count)")
        steps.forEach { print("    \($0)") }
    }
    print("\nSessions:")
    for s in sessions.prefix(12) {
        print("  [\(["Claude Code": "CC", "Cowork": "CW", "Grok": "GK", "ChatGPT": "GPT"][s.source.rawValue] ?? "AP")] \(s.active.pretty.padding(toLength: 8, withPad: " ", startingAt: 0)) \(s.title.prefix(44))  — \(s.live(at: now))")
        for c in s.children {
            let cats = c.totals.byCategory.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key.rawValue) \($0.value.pretty)" }.joined(separator: ", ")
            print("       ↳ \(c.active.pretty.padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.title.prefix(40))  [\(cats)]")
        }
    }
    print("\nFindings:")
    for s in sessions where s.findings.hasOutcomes || s.findings.hasFriction {
        let fail = s.findings.failingCommands.prefix(3).map { "\($0.0) ×\($0.1)" }.joined(separator: ", ")
        let churn = s.findings.churnedFiles.prefix(3).map { "\($0.0) ×\($0.1)" }.joined(separator: ", ")
        print("  \(s.title.prefix(40)): \(s.findings.outcomeSummary.isEmpty ? "—" : s.findings.outcomeSummary)"
              + (fail.isEmpty ? "" : " | failing: \(fail)") + (churn.isEmpty ? "" : " | churn: \(churn)"))
    }
    let withSubagents = sessions.filter { !$0.children.isEmpty }
    print("\nSubagents: \(withSubagents.map(\.children.count).reduce(0, +)) in \(withSubagents.count) sessions")
    for s in withSubagents.prefix(4) where !sessions.prefix(12).contains(where: { $0.id == s.id }) {
        print("  \(s.title.prefix(50)) — \(s.children.count) subagents")
        for c in s.children.prefix(5) {
            let cats = c.totals.byCategory.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key.rawValue) \($0.value.pretty)" }.joined(separator: ", ")
            print("     ↳ \(c.active.pretty.padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.agentType ?? "agent"): \(c.title.prefix(40))  [\(cats)]")
        }
    }
    if let s = sessions.max(by: { $0.active < $1.active }) {
        print("\nWorkflow of \"\(s.title)\":")
        for c in s.chunks.prefix(6) {
            let steps = c.steps.coalesced().prefix(6).map { "\($0.category.rawValue) \($0.duration.pretty)" }.joined(separator: " → ")
            print("  • \(c.prompt.prefix(50).replacingOccurrences(of: "\n", with: " ")) [\(c.active.pretty), \(c.toolCalls) tools]\n      \(steps)")
        }
    }
    exit(0)
}

// `AgentLens --export-csv <file>`: every session as CSV (same as Settings → Export sessions).
if let i = CommandLine.arguments.firstIndex(of: "--export-csv"), i + 1 < CommandLine.arguments.count {
    let sessions = Worker().scanNow()?.sessions ?? []
    try? Exporter.csv(sessions).write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
    print("Exported \(sessions.count) sessions to \(CommandLine.arguments[i + 1])")
    exit(0)
}

// `AgentLens --install-hooks` / `--uninstall-hooks` shows the settings.json diff and asks before writing.
if let flag = ["--install-hooks", "--uninstall-hooks"].first(where: CommandLine.arguments.contains) {
    let plan = HookInstaller.plan(install: flag == "--install-hooks")
    if let error = plan.error { print(error); exit(1) }
    guard plan.changes else { print("\(Paths.settings.path) already up to date."); exit(0) }
    print("Changes to \(Paths.settings.path):\n")
    for l in plan.diff where l.kind != .same { print((l.kind == .added ? "+ " : "- ") + l.text) }
    print("\nWrite these changes? [y/N] ", terminator: "")
    guard readLine()?.lowercased().hasPrefix("y") == true else { print("Nothing written."); exit(0) }
    do { try HookInstaller.apply(plan); print("Done. Restart running Claude Code sessions to pick up the hooks.") }
    catch { print("Failed: \(error.localizedDescription)"); exit(1) }
    exit(0)
}

// `AgentLens --ax-status`: whether macOS lets this build read other apps' windows. Run the copy inside
// AgentLens.app, since the permission belongs to the app bundle.
if CommandLine.arguments.contains("--ax-status") {
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted") for \(Bundle.main.bundleIdentifier ?? "(no bundle)")")
    exit(AXIsProcessTrusted() ? 0 : 1)
}

// `AgentLens --selftest-windows`: runs the window reader's logic on a made-up conversation.
if CommandLine.arguments.contains("--selftest-windows") {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    func snap(_ dt: Double, title: String, input: String?, buttons: [String] = [], labels: [String] = [], sig: Int) -> WindowSnapshot {
        WindowSnapshot(time: t0.addingTimeInterval(dt), title: title, buttons: buttons, statusLabels: labels,
                       input: input, textSignature: sig, progress: false)
    }
    let frames = [
        snap(0, title: "Trip plan", input: "", buttons: ["send"], sig: 10),
        snap(1, title: "Trip plan", input: "Plan a 3 day trip to Goa\nwith beaches", sig: 10),
        snap(1.5, title: "Trip plan", input: "Plan a 3 day trip to Goa\nwith beaches", sig: 10),
        snap(2, title: "Trip plan", input: "", buttons: ["stop generating"], sig: 11),
        snap(4, title: "Trip plan", input: "", buttons: ["stop generating"], labels: ["Searching the web…"], sig: 12),
        snap(9, title: "Trip plan", input: "", buttons: ["stop generating"], labels: ["Writing itinerary…"], sig: 20),
        snap(14, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(15, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(16, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(17, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(18, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(19, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(20, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(21, title: "Trip plan", input: "", buttons: ["send"], sig: 30),
        snap(60, title: "Budget", input: "How much would that cost", sig: 31),
        snap(60.5, title: "Budget", input: "How much would that cost", sig: 31),
        snap(61, title: "Budget", input: "", sig: 33),
        snap(62, title: "Budget", input: "", sig: 40),
        snap(63, title: "Budget", input: "", sig: 48),
        snap(64, title: "Budget", input: "", sig: 48),
        snap(65, title: "Budget", input: "", sig: 48),
        snap(66, title: "Budget", input: "", sig: 48),
        snap(67, title: "Budget", input: "", sig: 48),
        snap(68, title: "Budget", input: "", sig: 48),
        snap(69, title: "Budget", input: "", sig: 48),
        snap(70, title: "Budget", input: "", sig: 48),
        snap(71, title: "Budget", input: "", sig: 48),
    ]
    let tracker = WindowTracker()
    var events: [WindowEvent] = []
    for f in frames { events += tracker.ingest(f) }
    for e in events { print(String(format: "%5.1fs", e.time.timeIntervalSince(t0)), e.kind.rawValue, e.text) }
    let app = TrackedApp.catalog.first { $0.id == "com.meta.endo" }!
    for s in WindowSessions.build(events, app: app, now: t0.addingTimeInterval(80)) {
        print("\nSession \"\(s.title)\": \(s.active.pretty) answering, \(s.prompts) prompt(s), live: \(s.live(at: t0.addingTimeInterval(80)))")
        for c in s.chunks {
            print("  • \(c.prompt) [\(c.active.pretty)] " + c.steps.map { "\($0.category.title) \($0.duration.pretty)\($0.labels.isEmpty ? "" : " (\($0.labels.joined(separator: ", ")))")" }.joined(separator: " → "))
        }
    }

    // Flicker: a box that alternates between a placeholder-like value and empty every read, while
    // the page animates. The old reader logged a "prompt" every second here; this should log none.
    let flicker = WindowTracker()
    var fl: [WindowEvent] = []
    for i in 0..<120 {
        fl += flicker.ingest(snap(Double(200 + i), title: "Muse", input: i % 2 == 0 ? "Ask Muse anything" : "", sig: 900 + i))
    }
    print("\nFlicker test: \(fl.filter { $0.kind == .prompt }.count) prompts (want 0)")

    // App quits mid-answer: busy starts, then nothing more. After 90s it must stop showing as working.
    let quit = WindowTracker()
    var qe: [WindowEvent] = []
    qe += quit.ingest(snap(400, title: "Draft", input: "Write a haiku", sig: 1))
    qe += quit.ingest(snap(401, title: "Draft", input: "Write a haiku", sig: 1))
    qe += quit.ingest(snap(402, title: "Draft", input: "", buttons: ["stop"], sig: 2))
    qe += quit.ingest(snap(403, title: "Draft", input: "", buttons: ["stop"], sig: 3))
    let later = t0.addingTimeInterval(403 + 600)

    // Labelled transcript (Grok Bot style): window title is just the app name; messages carry authors.
    func chat(_ dt: Double, _ convo: String, _ n: Int, you: Bool, len: Int, text: String? = nil) -> WindowSnapshot {
        var s = snap(dt, title: "Grok Bot", input: "", sig: 1)
        s.chat = ChatLog(conversation: convo, count: n, lastFromUser: you, lastUserText: text, lastLength: len)
        return s
    }
    let ct = WindowTracker()
    var ce: [WindowEvent] = []
    let frames2: [WindowSnapshot] = [
        chat(500, "Sidekick", 7, you: false, len: 300),                        // opened: baseline, no prompt
        chat(501, "Sidekick", 7, you: false, len: 300),
        chat(502, "Sidekick", 8, you: true, len: 40, text: "Draft three posts for Helena"),
        chat(503, "Sidekick", 8, you: true, len: 40, text: "Draft three posts for Helena"),
        chat(510, "Sidekick", 9, you: false, len: 120),                        // reply starts streaming
        chat(511, "Sidekick", 9, you: false, len: 480),
        chat(512, "Sidekick", 9, you: false, len: 900),
    ] + (513...520).map { chat(Double($0), "Sidekick", 9, you: false, len: 900) }
      + [chat(530, "Helena PA", 4, you: false, len: 200), chat(531, "Helena PA", 4, you: false, len: 200)]
    for f in frames2 { ce += ct.ingest(f) }

    // ChatGPT read every few seconds: by the next read the reply is already below your message.
    let slow = WindowTracker()
    var se: [WindowEvent] = []
    for f in [chat(600, "Build Midjourney Style", 8, you: false, len: 500, text: "Make it moodier"),
              chat(604, "Build Midjourney Style", 10, you: false, len: 220, text: "Now try a wide shot"),
              chat(608, "Build Midjourney Style", 10, you: false, len: 640, text: "Now try a wide shot"),
              chat(612, "Build Midjourney Style", 10, you: false, len: 640, text: "Now try a wide shot"),
              chat(616, "Build Midjourney Style", 10, you: false, len: 640, text: "Now try a wide shot")] {
        se += slow.ingest(f)
    }
    print("\nSlow-read test: \(se.filter { $0.kind == .prompt }.map(\.text)) (want [\"Now try a wide shot\"])")
    print("\nChat transcript test:")
    for e in ce where e.kind != .beat { print(String(format: "  %5.0fs", e.time.timeIntervalSince(t0)), e.kind.rawValue, e.text) }
    for s in WindowSessions.build(ce, app: TrackedApp.catalog.first { $0.id == "com.anysphere.sand" }!, now: t0.addingTimeInterval(540)) {
        print("  Session \"\(s.title)\": \(s.active.pretty) answering, \(s.prompts) prompt(s)")
    }
    let q = WindowSessions.build(qe, app: app, now: later)
    print("Quit-mid-answer test: \(q.count) session, live = \(q.first.map { "\($0.live(at: later))" } ?? "none") (want not working)")
    exit(0)
}

// `AgentLens --snapshot <dir>` renders the main views to PNGs offscreen.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated { Snapshot.render(to: dir) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = AppController.shared
    app.run()
}
