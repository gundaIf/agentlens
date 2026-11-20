import SwiftUI

/// `--snapshot <dir>`: renders the main views to PNGs offscreen (screen capture isn't available here),
/// plus the 1024px app icon artwork that build.sh packs into AppIcon.icns.
@MainActor
enum Snapshot {
    static func render(to dir: URL) {
        let store = Store()
        store.loadNow()
        Limits.shared.refreshIfNeeded(store.sessions)
        AppUsage.shared.loadOnly()
        let bg = ScannerGround()
        for scheme in [ColorScheme.dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            // The dropdown's states. `expanded` is a saved preference, so put it back afterwards.
            let wasExpanded = Preferences.shared.expanded
            Preferences.shared.expanded = false
            save(MenuView(animated: false).environment(store).background(bg), "menu\(suffix)", dir, scheme)
            Preferences.shared.expanded = true
            save(MenuView(animated: false).environment(store).background(bg), "menu-expanded", dir, scheme)
            Preferences.shared.expanded = wasExpanded
            save(MenuView(animated: false, page: .settings).environment(store).background(bg), "settings", dir, scheme)
            save(MenuView(animated: false, page: .settings, settingsAdvanced: true).environment(store).background(bg), "settings-advanced", dir, scheme)
            save(OverviewView(scrolls: false, range: .today).environment(store).frame(width: 1000, height: 1400).background(bg),
                 "overview-today\(suffix)", dir, scheme)
        }
        save(OverviewView(scrolls: false, range: .week).environment(store).frame(width: 1000, height: 1400).background(bg),
             "overview-week", dir, .dark)
        if let s = store.sessions.max(by: { $0.active < $1.active }) {
            save(SessionDetail(session: s, scrolls: false).environment(store).frame(width: 1000, height: 1500, alignment: .top).background(bg),
                 "session", dir, .dark)
        }
        if let s = store.sessions.filter({ !$0.children.isEmpty }).max(by: { $0.children.count < $1.children.count }) {
            save(SessionDetail(session: s, scrolls: false).environment(store).frame(width: 1000, height: 1900).background(bg),
                 "session-subagents", dir, .dark)
        }
        save(HookDiffSheet(plan: HookInstaller.plan(install: true), scrolls: false) {}.environment(store).background(bg), "hooks-sheet", dir, .dark)
        // The live pill: notch and floating, folded and open.
        for (name, notch, open) in [("pill-notch", true, false), ("pill-notch-open", true, true),
                                    ("pill-floating", false, false), ("pill-floating-open", false, true)] {
            let st = PillState()
            st.expanded = open
            if notch { st.notchWidth = 185; st.notchHeight = 32 }
            save(PillContent(state: st, animated: false, fixedNow: Date()).environment(store).padding(20).background(Color(white: 0.85)),
                 name, dir, .dark)
        }
        for i in 0..<3 {
            save(OnboardingView(startStep: i) {}.environment(store), "welcome-\(i + 1)", dir, .dark)
        }
        save(AppIconArt(), "AppIcon", dir, .dark, scale: 1)
    }

    private static func save<V: View>(_ view: V, _ name: String, _ dir: URL, _ scheme: ColorScheme, scale: CGFloat = 1.5) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        r.scale = scale
        r.isOpaque = false
        guard let cg = r.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
