import SwiftUI
import AppKit
import Observation
import ServiceManagement

// MARK: - Preferences

/// User choices, kept in UserDefaults. Everything here takes effect immediately.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    /// The dropdown shows the ribbon, AI apps and insights, not just today and who's working.
    var expanded: Bool { didSet { d.set(expanded, forKey: "menuExpanded") } }
    /// The number of working agents next to the menu bar icon.
    var showCount: Bool { didSet { d.set(showCount, forKey: "showCount"); AppController.shared.updateIcon() } }
    /// Agent groups the user turned off (by `AgentGroup.id`).
    private(set) var hidden: Set<String> { didSet { d.set(Array(hidden), forKey: "hiddenAgents") } }
    /// Keep sessions after Claude Code deletes its logs (30 days by default). Read by the store's worker.
    var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }
    private(set) var launchAtLogin = false
    private(set) var loginNeedsApproval = false

    private init() {
        expanded = d.object(forKey: "menuExpanded") as? Bool ?? false
        showCount = d.object(forKey: "showCount") as? Bool ?? true
        hidden = Set(d.stringArray(forKey: "hiddenAgents") ?? [])
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
        refreshLogin()
    }

    func isTracked(_ s: Source) -> Bool {
        guard let g = AgentGroup.all.first(where: { $0.sources.contains(s) }) else { return true }
        return !hidden.contains(g.id)
    }

    func isOn(_ g: AgentGroup) -> Bool { !hidden.contains(g.id) }

    func set(_ g: AgentGroup, on: Bool) {
        if on { hidden.remove(g.id) } else { hidden.insert(g.id) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AgentLens: launch at login: \(error.localizedDescription)")
        }
        refreshLogin()
    }

    func refreshLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }
}

/// How agents appear in Settings → Track. One switch can cover several sources.
struct AgentGroup: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let tint: Color
    let sources: Set<Source>
    var bundle: String? = nil

    static let all: [AgentGroup] = [
        AgentGroup(id: "claude", name: "Claude Code & Cowork", detail: "Full sessions from local logs",
                   symbol: "chevron.left.forwardslash.chevron.right", tint: Color(hex: 0xFF8A1F),
                   sources: [.claudeCode, .cowork], bundle: "com.anthropic.claudefordesktop"),
        AgentGroup(id: "chatgpt", name: "ChatGPT", detail: "Codex sessions and chats",
                   symbol: "sparkle", tint: Color(hex: 0x22D3EE), sources: [.codex, .chatgptChat], bundle: "com.openai.codex"),
        AgentGroup(id: "grok", name: "Grok", detail: "The grok coding agent",
                   symbol: "bolt.horizontal.circle", tint: Color(hex: 0x8E6BFF), sources: [.grok]),
        AgentGroup(id: "muse", name: "Muse", detail: "Followed through its window",
                   symbol: "macwindow", tint: Color(hex: 0x3D7BFF), sources: [.muse], bundle: "com.meta.endo"),
        AgentGroup(id: "grokbot", name: "Grok Bot", detail: "Followed through its window",
                   symbol: "macwindow", tint: Color(hex: 0xB6F23C), sources: [.grokBot], bundle: "com.anysphere.sand"),
    ]

    /// The app's own icon when it's installed.
    var icon: CGImage? {
        guard let bundle else { return nil }
        return TrackedApp(id: bundle, name: name).iconBitmap
    }
}

extension TrackedApp {
    /// Every source whose sessions belong to this app's row.
    var allSources: Set<Source> {
        var s = Set(source.map { [$0] } ?? [])
        if id == "com.openai.codex" || id == "com.openai.chat" { s.insert(.codex) }
        if id == "com.anthropic.claudefordesktop" { s.formUnion([.claudeCode, .cowork]) }
        return s
    }

    @MainActor var isTracked: Bool {
        let s = allSources
        return s.isEmpty || s.contains { Preferences.shared.isTracked($0) }
    }
}

// MARK: - Controls

/// A switch in the instrument style: phosphor track when on, drawn in SwiftUI so it renders anywhere.
struct HUDSwitch: View {
    let isOn: Bool
    let action: (Bool) -> Void

    var body: some View {
        Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) { action(!isOn) } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? HUD.phosphor.opacity(0.9) : Color.white.opacity(0.14))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.10), lineWidth: 0.5))
                    .shadow(color: isOn ? HUD.phosphor.opacity(0.45) : .clear, radius: 5)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A grouped list in the System Settings manner: one rounded panel, rows split by inset hairlines.
struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased()).font(.hud(9.5, .semibold)).tracking(1.1).foregroundStyle(HUD.dim)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(HUD.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var symbol: String? = nil
    var image: CGImage? = nil
    var tint: Color = HUD.dim
    let title: String
    var subtitle: String? = nil
    var divider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 2).resizable()
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if divider {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 42)
            }
        }
    }
}

/// Small text button used at the end of rows ("Connect", "Show").
struct RowButton: View {
    let title: String
    var tint: Color = HUD.paper
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings page

/// Settings, shown inside the dropdown in place of the main page.
struct SettingsView: View {
    @Environment(Store.self) private var store
    let back: () -> Void
    private let advancedState: State<Bool>
    private var advanced: Bool { advancedState.wrappedValue }

    init(advanced: Bool = false, back: @escaping () -> Void) {
        self.back = back
        self.advancedState = State(initialValue: advanced)
    }

    var body: some View {
        let prefs = Preferences.shared
        let notifier = Notifier.shared
        VStack(alignment: .leading, spacing: 14) {
            // Title bar
            HStack(spacing: 6) {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back").font(.system(size: 12))
                    }
                    .foregroundStyle(HUD.dim)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                Spacer()
                Text("SETTINGS").font(.hud(11, .bold)).tracking(1.6)
                Spacer()
                // Balances the Back button so the title stays centred.
                Color.clear.frame(width: 44, height: 1)
            }

            SettingsGroup {
                SettingsRow(symbol: "bell.badge.fill", tint: Color(hex: 0xFF3B30), title: "Notifications",
                            subtitle: notifier.enabled && !notifier.allowed
                                ? "Turned off for AgentLens in System Settings"
                                : "When an agent finishes or needs you") {
                    HUDSwitch(isOn: notifier.enabled) { notifier.enabled = $0 }
                }
                SettingsRow(symbol: "power", tint: Color(hex: 0x8E8E93), title: "Open at login",
                            subtitle: prefs.loginNeedsApproval ? "Approve in System Settings → General → Login Items" : nil) {
                    HUDSwitch(isOn: prefs.launchAtLogin) { prefs.setLaunchAtLogin($0) }
                }
                SettingsRow(symbol: "number", tint: Color(hex: 0x3D7BFF), title: "Count in menu bar",
                            subtitle: "How many agents are working", divider: false) {
                    HUDSwitch(isOn: prefs.showCount) { prefs.showCount = $0 }
                }
            }

            SettingsGroup("Track") {
                ForEach(Array(AgentGroup.all.enumerated()), id: \.element.id) { i, g in
                    SettingsRow(symbol: g.symbol, image: g.icon, tint: g.tint, title: g.name, subtitle: g.detail,
                                divider: i < AgentGroup.all.count - 1) {
                        HUDSwitch(isOn: prefs.isOn(g)) { prefs.set(g, on: $0) }
                    }
                }
            }

            // Advanced: collapsed until asked for.
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { advancedState.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text("ADVANCED").font(.hud(9.5, .semibold)).tracking(1.1)
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(advanced ? 90 : 0))
                        Spacer()
                    }
                    .foregroundStyle(HUD.dim)
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if advanced {
                    SettingsGroup {
                        SettingsRow(symbol: "hand.raised.fill", tint: Color(hex: 0x30B0C7), title: "Accessibility",
                                    subtitle: AXAccess.shared.trusted ? "Following Muse, Grok Bot and ChatGPT chats"
                                                                      : "Needed to follow apps that keep chats online") {
                            if AXAccess.shared.trusted {
                                Text("On").font(.system(size: 11, weight: .medium)).foregroundStyle(HUD.phosphor)
                            } else {
                                RowButton(title: "Connect", tint: HUD.phosphor) { AXAccess.shared.connect() }
                            }
                        }
                        SettingsRow(symbol: "link", tint: Color(hex: 0xFF8A1F), title: "Claude Code hooks",
                                    subtitle: store.hooksInstalled ? "Installed · exact tool and permission times"
                                                                   : "Optional · separates permission waits") {
                            RowButton(title: "Manage") { AppController.shared.openDashboard(select: nil) }
                        }
                        SettingsRow(symbol: "clock.arrow.circlepath", tint: Color(hex: 0x8E6BFF), title: "Keep history",
                                    subtitle: "Keep sessions after Claude Code deletes its logs (30 days). Stays on this Mac.") {
                            HUDSwitch(isOn: prefs.keepHistory) { prefs.keepHistory = $0 }
                        }
                        SettingsRow(symbol: "folder.fill", tint: Color(hex: 0x3D7BFF), title: "Data folder",
                                    subtitle: "Usage, hook and window logs. Nothing leaves this Mac.") {
                            RowButton(title: "Show") {
                                try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([Paths.support])
                            }
                        }
                        SettingsRow(symbol: "scope", tint: Color(hex: 0x2A2735), title: "AgentLens \(AppInfo.version)",
                                    subtitle: "github.com/gundaIf/agentlens", divider: false) {
                            RowButton(title: "Releases") {
                                NSWorkspace.shared.open(URL(string: "https://github.com/gundaIf/agentlens/releases")!)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            HStack {
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Text("Quit AgentLens").font(.system(size: 12, weight: .medium)).foregroundStyle(HUD.alarm.opacity(0.9))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        .onAppear { prefs.refreshLogin() }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
