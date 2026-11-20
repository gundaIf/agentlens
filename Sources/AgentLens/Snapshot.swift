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
            // Exactly the window's margin, over a wallpaper-like ground, so a clipped shadow would show.
            save(PillContent(state: st, animated: false, fixedNow: Date()).environment(store)
                    .padding(.horizontal, PillChrome.shadowPad).padding(.bottom, PillChrome.shadowPad)
                    .background(LinearGradient(colors: [Color(hex: 0x9DB4C8), Color(hex: 0xD8C9B4)], startPoint: .topLeading, endPoint: .bottomTrailing)),
                 name, dir, .dark)
        }
        for i in 0..<3 {
            save(OnboardingView(startStep: i) {}.environment(store), "welcome-\(i + 1)", dir, .dark)
        }
        // The die: one roll as a filmstrip, then each state.
        let now = Date()
        save(HStack(spacing: 6) {
            ForEach(0..<12, id: \.self) { i in
                Die(state: .running(tool: "Bash", detail: "", since: now), size: 40, at: Double(i) * 0.85 / 12 + 0.85 * 3)
            }
        }.padding(14).background(Color.black), "die-roll", dir, .dark, scale: 2)
        save(HStack(spacing: 14) {
            Die(state: .running(tool: "Bash", detail: "", since: now), size: 40, at: 0.85 * 3 + 0.6)
            Die(state: .thinking(since: now), size: 40, at: 2)
            Die(state: .waitingOnYou(reason: "", since: now), size: 40, at: 0.05)
            Die(state: .finished(at: now), size: 40, at: 0)
            Die(state: .idle, size: 40, at: 0)
        }.padding(14).background(Color.black), "die-states", dir, .dark, scale: 2)
        // The menu bar die: idle, waiting, then one roll, on dark and light menu bars.
        var frames: [(MenuGlyph.State, Double)] = [(.idle, 0), (.waiting, 0.05)]
        for i in 0..<8 { frames.append((.working, 0.85 * 3 + Double(i) * 0.85 / 8)) }
        let images: [NSImage] = frames.map { MenuGlyph.image($0.0, t: $0.1) }
        save(VStack(spacing: 0) {
            GlyphStrip(images: images, fg: .white, bg: Color(hex: 0x2A2A30))
            GlyphStrip(images: images, fg: .black, bg: Color(hex: 0xE8E6E1))
        }, "menu-glyph", dir, .dark, scale: 4)
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

private struct GlyphStrip: View {
    let images: [NSImage]
    let fg: Color
    let bg: Color
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<images.count, id: \.self) { i in
                Image(nsImage: images[i]).renderingMode(.template).foregroundStyle(fg)
            }
        }
        .padding(.horizontal, 12).frame(height: 24).background(bg)
    }
}
