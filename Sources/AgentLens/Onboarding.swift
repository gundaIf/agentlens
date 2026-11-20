import SwiftUI
import AppKit

/// First-run welcome: what AgentLens does, what it reads (and doesn't), and the optional extras.
/// Three short steps; nothing is changed until you switch it on here.
@MainActor
enum Onboarding {
    private static var window: NSWindow?

    static func showIfNeeded() {
        if !Preferences.shared.onboarded { show() }
    }

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(HUD.ink)
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: OnboardingView { finish() }.environment(AppController.shared.store))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func finish() {
        Preferences.shared.onboarded = true
        window?.close()
    }
}

struct OnboardingView: View {
    @Environment(Store.self) private var store
    var startStep = 0
    let done: () -> Void
    private let stepState: State<Int>
    private var step: Int { stepState.wrappedValue }

    init(startStep: Int = 0, done: @escaping () -> Void) {
        self.startStep = startStep
        self.done = done
        self.stepState = State(initialValue: startStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome.transition(.push(from: .trailing))
                case 1: agents.transition(.push(from: .trailing))
                default: extras.transition(.push(from: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36).padding(.top, 40)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i == step ? Color.white : Color.white.opacity(0.2))
                            .frame(width: i == step ? 16 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Back") { go(step - 1) }.buttonStyle(QuietButton())
                }
                Button(step == 2 ? "Done" : "Continue") { step == 2 ? done() : go(step + 1) }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 36).padding(.vertical, 22)
        }
        .frame(width: 560, height: 560)
        .background(HUD.ink)
        .environment(\.colorScheme, .dark)
    }

    private func go(_ s: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) { stepState.wrappedValue = s }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            LensMark(size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text("See what your agents are doing.").font(.system(size: 24, weight: .semibold))
                Text("AgentLens sits in your menu bar and watches Claude Code, Cowork, Codex and Grok. It shows which one needs you, and where the time went.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                privacyRow("Your code or messages leave this Mac", "Never")
                privacyRow("Account", "None")
                privacyRow("Telemetry or analytics", "None")
                privacyRow("Goes online for", "Update check only")
                privacyRow("Changes to agent settings", "Shown first, backed up", last: true)
            }
            .background(HUD.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HUD.line))
        }
    }

    private func privacyRow(_ k: String, _ v: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(k).font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Text(v).font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            if !last { Hairline().padding(.leading, 14) }
        }
    }

    private var agents: some View {
        let prefs = Preferences.shared
        let counts = Dictionary(grouping: store.allSessions, by: \.source).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Agents on this Mac").font(.system(size: 22, weight: .semibold))
                Text("Read from each agent's own local logs. Switch off any you don't want counted.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            SettingsGroup {
                ForEach(Array(AgentGroup.all.enumerated()), id: \.element.id) { i, g in
                    let n = g.sources.reduce(0) { $0 + (counts[$1] ?? 0) }
                    SettingsRow(symbol: g.symbol, image: g.icon, tint: g.tint, title: g.name,
                                subtitle: n > 0 ? "\(n) session\(n == 1 ? "" : "s") found" : g.detail,
                                divider: i < AgentGroup.all.count - 1) {
                        HUDSwitch(isOn: prefs.isOn(g)) { prefs.set(g, on: $0) }
                    }
                }
            }
        }
    }

    private var extras: some View {
        let prefs = Preferences.shared
        let notifier = Notifier.shared
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("A few optional extras").font(.system(size: 22, weight: .semibold))
                Text("All off-switchable later in Settings.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            SettingsGroup {
                SettingsRow(symbol: "capsule.fill", tint: Color(hex: 0x3A3A44), title: "Live pill",
                            subtitle: Pill.shared.hasNotch ? "Grows out of the notch while agents run; hover to see them"
                                                           : "A small floating pill while agents run; hover to see them") {
                    HUDSwitch(isOn: prefs.pill) { prefs.pill = $0 }
                }
                SettingsRow(symbol: "bell.badge.fill", tint: HUD.alarm, title: "Notifications",
                            subtitle: "When an agent finishes or has waited on you for a while") {
                    HUDSwitch(isOn: notifier.enabled) { notifier.enabled = $0 }
                }
                SettingsRow(symbol: "power", tint: Color(hex: 0x8E8E93), title: "Open at login") {
                    HUDSwitch(isOn: prefs.launchAtLogin) { prefs.setLaunchAtLogin($0) }
                }
                SettingsRow(symbol: "hand.raised.fill", tint: Color(hex: 0x30B0C7), title: "Follow chat apps",
                            subtitle: "Muse, Grok Bot and ChatGPT chats, read through their windows. Needs Accessibility.") {
                    if AXAccess.shared.trusted {
                        Text("On").font(.system(size: 11, weight: .medium)).foregroundStyle(HUD.phosphor)
                    } else {
                        RowButton(title: "Connect", tint: HUD.phosphor) { AXAccess.shared.connect() }
                    }
                }
                SettingsRow(symbol: "link", tint: Color(hex: 0xF5A15B), title: "Claude Code hooks",
                            subtitle: store.hooksInstalled ? "Installed" : "Exact permission waits. Shows the settings.json change before writing.",
                            divider: false) {
                    if store.hooksInstalled {
                        Text("On").font(.system(size: 11, weight: .medium)).foregroundStyle(HUD.phosphor)
                    } else {
                        RowButton(title: "Review…") { AppController.shared.openDashboard(select: nil) }
                    }
                }
            }
            Text("Tip: ⌘1–⌘9 in the menu jump to that agent's terminal or app. ⌃⌥↩ jumps to the one that needs you, from anywhere.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { prefs.refreshLogin() }
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HUD.paperInk)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(HUD.paper.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
    }
}
