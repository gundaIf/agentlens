import AppKit
import Observation

/// AI apps that keep their conversations online (Muse, Grok Bot…). Nothing on disk says what the
/// AI did, so AgentLens measures the one thing it can see: when the app is in front and you're
/// at the keyboard. Intervals are appended to app-usage.jsonl, so history survives restarts.
struct TrackedApp: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String
    /// Set when AgentLens follows this app's sessions by reading its window (needs Accessibility
    /// permission); the sessions it reads are labelled with this source.
    var source: Source? = nil
    var readsWindow: Bool { source != nil }

    static let catalog: [TrackedApp] = [
        // Claude Code and Cowork write full logs on this Mac, so Claude needs no window reading.
        TrackedApp(id: "com.anthropic.claudefordesktop", name: "Claude"),
        TrackedApp(id: "com.meta.endo", name: "Muse", source: .muse),
        TrackedApp(id: "com.anysphere.sand", name: "Grok Bot", source: .grokBot),
        // The current ChatGPT app ships with Codex inside and identifies as com.openai.codex.
        // Codex work comes from ~/.codex; plain chats only show in the window.
        TrackedApp(id: "com.openai.codex", name: "ChatGPT", source: .chatgptChat),
        TrackedApp(id: "com.openai.chat", name: "ChatGPT", source: .chatgptChat),
        TrackedApp(id: "ai.perplexity.mac", name: "Perplexity"),
    ]

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    var icon: NSImage? { url.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    /// The icon as a plain sRGB bitmap. Drawing the NSImage directly switched SwiftUI's offscreen
    /// renderer into another colour space and washed out every colour around it.
    var iconBitmap: CGImage? {
        guard let icon else { return nil }
        let px = 64
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

struct UsageInterval {
    let app: String
    let start: Date
    let end: Date
}

@MainActor
@Observable
final class AppUsage {
    static let shared = AppUsage()

    /// Apps from the catalog that are installed on this Mac.
    let apps = TrackedApp.catalog.filter { $0.url != nil }
    private(set) var intervals: [UsageInterval] = []
    private(set) var current: (app: String, start: Date)?
    private(set) var running = Set<String>()

    /// Stop counting after this long without keyboard or mouse input.
    private let idleLimit: TimeInterval = 5 * 60
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    private var file: URL { Paths.support.appendingPathComponent("app-usage.jsonl") }

    func start() {
        guard !started else { return }
        started = true
        load()
        refreshRunning()
        frontmostChanged(NSWorkspace.shared.frontmostApplication)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { AppUsage.shared.frontmostChanged(app) }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppUsage.shared.refreshRunning() }
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppUsage.shared.close(at: Date()) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppUsage.shared.frontmostChanged(NSWorkspace.shared.frontmostApplication) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { AppUsage.shared.tick() }
        }
        tick()
    }

    /// Loads history without starting observers, for --snapshot and --dump.
    func loadOnly() {
        load()
        refreshRunning()
    }

    // MARK: Queries

    func time(_ app: String, from: Date?, to: Date = Date()) -> TimeInterval {
        var total: TimeInterval = 0
        var all = intervals.filter { $0.app == app }
        if let c = current, c.app == app { all.append(UsageInterval(app: app, start: c.start, end: to)) }
        for i in all {
            let a = max(i.start, from ?? .distantPast), b = min(i.end, to)
            if b > a { total += b.timeIntervalSince(a) }
        }
        return total
    }

    func isFront(_ app: String) -> Bool { current?.app == app }
    func isRunning(_ app: String) -> Bool { running.contains(app) }

    // MARK: Tracking

    private func frontmostChanged(_ app: NSRunningApplication?) {
        let now = Date()
        let id = app?.bundleIdentifier
        if current?.app == id { return }
        close(at: now)
        if let id, apps.contains(where: { $0.id == id }), idleSeconds() < idleLimit {
            current = (id, now)
        }
    }

    private func tick() {
        let idle = idleSeconds()
        if idle >= idleLimit {
            // Count up to the last input, not the moment we noticed.
            close(at: Date().addingTimeInterval(-idle))
        } else if current == nil {
            frontmostChanged(NSWorkspace.shared.frontmostApplication)
        }
    }

    func close(at end: Date) {
        guard let c = current else { return }
        current = nil
        let stop = max(end, c.start)
        guard stop.timeIntervalSince(c.start) >= 2 else { return }
        let interval = UsageInterval(app: c.app, start: c.start, end: stop)
        intervals.append(interval)
        append(interval)
    }

    private func refreshRunning() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        running = Set(apps.map(\.id).filter { ids.contains($0) })
    }

    private func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Storage

    private static let iso = ISO8601DateFormatter()

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        intervals = data.split(separator: 0x0A).compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: String],
                  let app = o["app"], let s = o["start"].flatMap(AppUsage.iso.date), let e = o["end"].flatMap(AppUsage.iso.date)
            else { return nil }
            return UsageInterval(app: app, start: s, end: e)
        }
    }

    private func append(_ i: UsageInterval) {
        let obj = ["app": i.app, "start": AppUsage.iso.string(from: i.start), "end": AppUsage.iso.string(from: i.end)]
        guard var line = try? JSONSerialization.data(withJSONObject: obj) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }
}
