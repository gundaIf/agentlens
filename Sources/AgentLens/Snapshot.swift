import SwiftUI

/// `--snapshot <dir>`: renders the main views to PNGs offscreen (screen capture isn't available here),
/// plus the 1024px app icon artwork that build.sh packs into AppIcon.icns.
@MainActor
enum Snapshot {
    static func render(to dir: URL) {
        let store = Store()
        store.loadNow()
        AppUsage.shared.loadOnly()
        let bg = ScannerGround()
        for scheme in [ColorScheme.dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            save(MenuView(animated: false).environment(store).background(bg), "menu\(suffix)", dir, scheme)
            save(OverviewView(scrolls: false, range: .today).environment(store).frame(width: 1000, height: 1400).background(bg),
                 "overview-today\(suffix)", dir, scheme)
        }
        save(OverviewView(scrolls: false, range: .week).environment(store).frame(width: 1000, height: 1400).background(bg),
             "overview-week", dir, .dark)
        if let s = store.sessions.max(by: { $0.active < $1.active }) {
            save(SessionDetail(session: s, scrolls: false).environment(store).frame(width: 1000, height: 1500).background(bg),
                 "session", dir, .dark)
        }
        if let s = store.sessions.filter({ !$0.children.isEmpty }).max(by: { $0.children.count < $1.children.count }) {
            save(SessionDetail(session: s, scrolls: false).environment(store).frame(width: 1000, height: 1900).background(bg),
                 "session-subagents", dir, .dark)
        }
        save(HookDiffSheet(plan: HookInstaller.plan(install: true), scrolls: false) {}.environment(store).background(bg), "hooks-sheet", dir, .dark)
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
