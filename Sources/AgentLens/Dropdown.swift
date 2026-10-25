import SwiftUI
import AppKit
import Observation

/// The menu bar dropdown: a borderless panel that hangs from the status item and unrolls downward,
/// with its sections cascading in. Replaces NSPopover, whose arrow and fixed animation fought the design
/// (and once opened clipped under the menu bar).
///
/// Motion: open = the panel is revealed top-down by a growing mask on a spring while sections fade and
/// drop 4pt into place, 35ms apart. Close = a 140ms fold back up. The mask clips rather than scales,
/// so text never stretches mid-animation.
@MainActor
@Observable
final class DropdownState {
    var presented = false
}

private struct DropdownPresentedKey: EnvironmentKey {
    static let defaultValue = true   // fully shown outside the dropdown (snapshots, previews)
}

extension EnvironmentValues {
    var dropdownPresented: Bool {
        get { self[DropdownPresentedKey.self] }
        set { self[DropdownPresentedKey.self] = newValue }
    }
}

extension View {
    /// Section `index` of the dropdown fades and drops into place after the ones above it.
    func cascade(_ index: Int) -> some View { modifier(Cascade(index: index)) }
}

private struct Cascade: ViewModifier {
    let index: Int
    @Environment(\.dropdownPresented) private var presented

    func body(content: Content) -> some View {
        content
            .opacity(presented ? 1 : 0)
            .offset(y: presented ? 0 : -4)
            .animation(presented ? .easeOut(duration: 0.26).delay(0.05 + Double(index) * 0.035) : .easeIn(duration: 0.1),
                       value: presented)
    }
}

/// Frame, thermal top edge, shadow and the unrolling mask around the dropdown's content.
struct DropdownChrome<Content: View>: View {
    let state: DropdownState
    let onSize: (CGSize) -> Void
    @ViewBuilder let content: Content

    static var shadowMargin: CGFloat { 22 }
    static var bottomMargin: CGFloat { 30 }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 14,
                                           bottomTrailingRadius: 14, topTrailingRadius: 5, style: .continuous)
        content
            .environment(\.dropdownPresented, state.presented)
            .background(HUD.ink)
            .overlay(alignment: .top) {
                LinearGradient(colors: HUD.thermal, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1.5)
                    .opacity(0.9)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // Unroll: reveal from the top edge down.
            .mask(alignment: .top) {
                GeometryReader { g in
                    Rectangle().frame(height: state.presented ? g.size.height + 40 : 0)
                }
                .padding(.bottom, -40)
            }
            .shadow(color: .black.opacity(state.presented ? 0.55 : 0), radius: 18, y: 12)
            .shadow(color: Category.thinking.color.opacity(state.presented ? 0.10 : 0), radius: 30, y: 6)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { onSize(g.size) }
                    .onChange(of: g.size) { _, s in onSize(s) }
            })
            .padding(.horizontal, Self.shadowMargin)
            .padding(.bottom, Self.bottomMargin)
            .environment(\.colorScheme, .dark)
    }
}

final class DropdownPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // drawn in SwiftUI so it animates with the content
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .none
    }

    // Key without activating the app, so Esc and ⌘D work while you stay in your current app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DropdownController {
    let state = DropdownState()
    private let panel = DropdownPanel()
    private weak var button: NSStatusBarButton?
    private var contentSize = CGSize(width: 340, height: 400)
    private var shrinkWork: DispatchWorkItem?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var generation = 0

    var isShown: Bool { panel.isVisible && state.presented }

    init<V: View>(button: NSStatusBarButton, content: V) {
        self.button = button
        let host = NSHostingView(rootView: DropdownChrome(state: state, onSize: { [weak self] size in
            MainActor.assumeIsolated { self?.resize(to: size) }
        }) { content })
        host.sizingOptions = []
        panel.contentView = host
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        generation += 1
        place()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        button?.highlight(true)
        installMonitors()
        // Start on the click itself: the panel is already laid out folded (presented == false while hidden).
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { state.presented = true }
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let g = generation
        removeMonitors()
        button?.highlight(false)
        withAnimation(.easeIn(duration: 0.14)) { state.presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, self.generation == g else { return }   // reopened meanwhile
            self.panel.orderOut(nil)
        }
    }

    /// Grow at once; shrink only after the content's own animation has played out, so sections
    /// folding away (Less, leaving Settings) aren't cut off by the window mid-motion.
    private func resize(to size: CGSize) {
        shrinkWork?.cancel()
        if size.height >= contentSize.height || !panel.isVisible {
            contentSize = size
            place()
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.contentSize = size; self?.place() }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
        }
    }

    /// Hangs the panel under the status item, top-anchored so content changes grow it downward.
    private func place() {
        guard let button, let bw = button.window else { return }
        let icon = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (bw.screen ?? NSScreen.main)!.frame
        let m = DropdownChrome<EmptyView>.shadowMargin
        let width = contentSize.width + 2 * m
        let height = contentSize.height + DropdownChrome<EmptyView>.bottomMargin
        var x = icon.midX - width / 2
        x = min(max(x, screen.minX + 6 - m), screen.maxX - width - 6 + m)
        let top = icon.minY - 5
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    /// Draws the panel as it is right now into a PNG (for `--film`; no screen recording needed).
    func capture(to url: URL) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    var panelFrame: NSRect { panel.frame }

    private func installMonitors() {
        removeMonitors()
        // Clicks anywhere outside AgentLens close it (clicks on the icon go through toggle()).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { AppController.shared.hideDropdown() }
        }) { eventMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            if e.keyCode == 53 {  // Esc
                MainActor.assumeIsolated { AppController.shared.hideDropdown() }
                return nil
            }
            return e
        }) { eventMonitors.append(m) }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppController.shared.hideDropdown() }
        })
    }

    private func removeMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}
