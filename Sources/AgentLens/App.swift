import SwiftUI
import AppKit

/// Owns the menu bar item, its dropdown and the dashboard window.
/// Plain AppKit here: SwiftUI's MenuBarExtra never created its status item in this build setup.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    let store = Store()
    private var statusItem: NSStatusItem!
    private var dropdown: DropdownController!
    private var dashboard: NSWindow?
    private var iconTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `open -n AgentLens.app --args --ax-structure <bundle id> <file>`: write that app's window structure and quit.
        // Launched through `open` so macOS attributes the Accessibility check to AgentLens, not the shell.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--ax-structure"), i + 2 < args.count {
            try? AXInspect.structure(bundle: args[i + 1]).write(toFile: args[i + 2], atomically: true, encoding: .utf8)
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        store.start()
        AppUsage.shared.start()
        AXAccess.shared.start()
        WindowWatcher.shared.start()
        Notifier.shared.setUp()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleDropdown)
        statusItem.button?.imagePosition = .imageLeading
        dropdown = DropdownController(button: statusItem.button!, content: MenuView().environment(store))

        updateIcon()
        if let i = CommandLine.arguments.firstIndex(of: "--film"), i + 1 < CommandLine.arguments.count {
            film(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppController.shared.updateIcon() }
        }
    }

    /// Eye icon, plus a count when agents are working right now.
    func updateIcon() {
        let now = Date()
        let working = store.sessions.filter { $0.live(at: now).isWorking }.count
        let waiting = store.sessions.contains { if case .waitingOnYou = $0.live(at: now) { return true }; return false }
        Notifier.shared.check(store.sessions, now: now)
        guard let button = statusItem.button else { return }
        button.image = MenuGlyph.image(waiting ? .waiting : (working > 0 ? .working : .idle))
        button.attributedTitle = working > 0
            ? NSAttributedString(string: "\(working)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .baselineOffset: 0.5,
              ])
            : NSAttributedString(string: "")
        button.imageHugsTitle = true
        button.toolTip = waiting ? "An agent is waiting on you"
            : working > 0 ? "\(working) agent\(working == 1 ? "" : "s") working" : "AgentLens"
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppUsage.shared.close(at: Date())
    }

    @objc private func toggleDropdown() { dropdown.toggle() }

    /// `--film <dir>`: opens and closes the dropdown once, saving frames along the way, then quits.
    private func film(to dir: URL) {
        let opens: [Double] = [0, 0.05, 0.1, 0.16, 0.24, 0.34, 0.5, 0.9]
        let closes: [Double] = [0.04, 0.08, 0.12]
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
            let start = DispatchTime.now()
            dropdown.show()
            for t in opens {
                DispatchQueue.main.asyncAfter(deadline: start + t) { [self] in
                    dropdown.capture(to: dir.appendingPathComponent(String(format: "open-%03d.png", Int(t * 1000))))
                    if t == opens.last { print("panel frame:", dropdown.panelFrame, "icon:", statusItem.button!.window!.frame) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: start + 1.2) { [self] in
                let s2 = DispatchTime.now()
                dropdown.hide()
                for t in closes {
                    DispatchQueue.main.asyncAfter(deadline: s2 + t) { [self] in
                        dropdown.capture(to: dir.appendingPathComponent(String(format: "close-%03d.png", Int(t * 1000))))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: s2 + 0.5) { exit(0) }
            }
        }
    }

    func hideDropdown() { dropdown.hide() }

    func openDashboard(select id: String?) {
        if let id { store.selection = id }
        dropdown.hide()
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "AgentLens"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0.035, green: 0.031, blue: 0.051, alpha: 1)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: DashboardView().environment(store).frame(minWidth: 900, minHeight: 560))
            window.setContentSize(NSSize(width: 1120, height: 720))
            window.center()
            window.setFrameAutosaveName("AgentLensDashboard")
            dashboard = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }
}
