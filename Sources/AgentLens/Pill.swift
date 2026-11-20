import SwiftUI
import AppKit
import Observation

enum PillShape: String, CaseIterable, Hashable {
    case auto, notch, floating
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .notch: return "Notch"
        case .floating: return "Floating"
        }
    }
}

@MainActor
@Observable
final class PillState {
    var expanded = false
    /// Notch geometry for the layout (0 when floating).
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
    var floating: Bool { notchWidth == 0 }
}

/// The live pill: a black shape that grows out of the notch (or floats as a small capsule on Macs
/// without one) while agents run. Hover or click to open the session list; it drops open on its own
/// when an agent starts waiting on you, then tucks away. It never takes focus, hides in full-screen
/// apps, and disappears when nothing is running.
@MainActor
final class Pill {
    static let shared = Pill()
    let state = PillState()

    private var panel: PillPanel?
    private var contentSize = CGSize(width: 200, height: 32)
    private var knownWaiting = Set<String>()
    private var collapseWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var hovering = false
    private var autoOpened = false
    private var screenObserver: NSObjectProtocol?

    /// A display with a camera housing in the menu bar.
    var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }
    var hasNotch: Bool { notchScreen != nil }

    private var useNotch: Bool {
        switch Preferences.shared.pillShape {
        case .auto, .notch: return hasNotch
        case .floating: return false
        }
    }

    // MARK: Visibility

    /// Sessions the pill cares about: working, waiting, or finished in the last two minutes.
    func sessions(now: Date) -> [SessionSummary] {
        AppController.shared.store.sessions.filter {
            let st = $0.live(at: now)
            if st.isWorking || st.isWaiting { return true }
            if case .finished(let at) = st { return now.timeIntervalSince(at) < 120 }
            return false
        }
        .sorted { ($0.live(at: now).rank, $1.end) < ($1.live(at: now).rank, $0.end) }
    }

    /// Called every couple of seconds from the app's timer.
    func update() {
        let now = Date()
        let list = sessions(now: now)
        let shouldShow = Preferences.shared.pill && !list.isEmpty
        if !shouldShow {
            panel?.orderOut(nil)
            state.expanded = false
            knownWaiting.removeAll()
            return
        }
        if panel == nil { makePanel() }
        if panel?.isVisible == false {
            relayout()
            panel?.orderFrontRegardless()
        }
        // Drop open on its own when something new starts waiting on you.
        let waiting = Set(list.filter { $0.live(at: now).isWaiting }.map(\.id))
        if Preferences.shared.pillAutoOpen, !waiting.subtracting(knownWaiting).isEmpty {
            expand(auto: true)
        }
        knownWaiting = waiting
    }

    func expand(auto: Bool = false) {
        collapseWork?.cancel()
        shrinkWork?.cancel()
        autoOpened = auto
        if !state.expanded {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { state.expanded = true }
        }
        if auto { scheduleCollapse(after: 6) }
    }

    func collapse() {
        collapseWork?.cancel()
        guard state.expanded else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { state.expanded = false }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.collapse()
            }
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func hover(_ inside: Bool) {
        hovering = inside
        hoverWork?.cancel()
        if inside {
            collapseWork?.cancel()
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.expand() } }
            hoverWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
        } else {
            scheduleCollapse(after: autoOpened ? 1.2 : 0.35)
        }
    }

    // MARK: Window

    private func makePanel() {
        let p = PillPanel()
        let host = PillHostingView(rootView: PillChrome(state: state) { [weak self] size in
            MainActor.assumeIsolated { self?.resize(to: size) }
        })
        host.sizingOptions = []
        p.contentView = host
        p.onMoved = { [weak self] in self?.saveFloatingOrigin() }
        panel = p
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    /// Re-reads the notch and the shape preference.
    func relayout() {
        if useNotch, let s = notchScreen {
            let left = s.auxiliaryTopLeftArea?.width ?? 0
            let right = s.auxiliaryTopRightArea?.width ?? 0
            state.notchWidth = max(s.frame.width - left - right, 160)
            state.notchHeight = s.safeAreaInsets.top
        } else {
            state.notchWidth = 0
            state.notchHeight = 0
        }
        panel?.isMovableByWindowBackground = state.floating
        place()
    }

    private func resize(to size: CGSize) {
        shrinkWork?.cancel()
        if size.width >= contentSize.width && size.height >= contentSize.height {
            contentSize = size
            place()
        } else {
            // Let the fold animation finish before the window shrinks around it.
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.contentSize = size; self?.place() }
            }
            shrinkWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
    }

    private var placing = false

    private func place() {
        guard let panel else { return }
        placing = true
        defer { placing = false }
        let pad = PillChrome.shadowPad
        let w = contentSize.width + pad * 2, h = contentSize.height + pad
        if !state.floating, let s = notchScreen {
            let x = s.frame.midX - w / 2
            panel.setFrame(NSRect(x: x, y: s.frame.maxY - h, width: w, height: h), display: true)
        } else {
            let s = NSScreen.main ?? NSScreen.screens[0]
            let d = UserDefaults.standard
            let cx = (d.object(forKey: "pillCenterX") as? Double).map { CGFloat($0) } ?? s.frame.midX
            let top = (d.object(forKey: "pillTop") as? Double).map { CGFloat($0) } ?? (s.visibleFrame.maxY - 8)
            var x = cx - w / 2
            x = min(max(x, s.frame.minX), s.frame.maxX - w)
            panel.setFrame(NSRect(x: x, y: top - h, width: w, height: h), display: true)
        }
    }

    private func saveFloatingOrigin() {
        guard state.floating, !placing, let f = panel?.frame else { return }
        let d = UserDefaults.standard
        d.set(Double(f.midX), forKey: "pillCenterX")
        d.set(Double(f.maxY), forKey: "pillTop")
    }
}

final class PillPanel: NSPanel {
    var onMoved: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // No .fullScreenAuxiliary: stays out of full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .none
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMoved?() }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Allow sitting over the menu bar, next to the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Tracks the pointer even though the panel never becomes active.
final class PillHostingView<V: View>: NSHostingView<V> {
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        MainActor.assumeIsolated { Pill.shared.hover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { Pill.shared.hover(false) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

struct PillChrome: View {
    let state: PillState
    let onSize: (CGSize) -> Void
    static let shadowPad: CGFloat = 18

    var body: some View {
        PillContent(state: state)
            .environment(AppController.shared.store)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { onSize(g.size) }
                    .onChange(of: g.size) { _, s in onSize(s) }
            })
            .padding(.horizontal, Self.shadowPad)
            .padding(.bottom, Self.shadowPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }
}

struct PillContent: View {
    @Environment(Store.self) private var store
    let state: PillState
    var animated = true
    /// For snapshots: render as if these were the sessions and this the time.
    var fixedNow: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let now = fixedNow ?? ctx.date
            let list = fixedNow == nil ? Pill.shared.sessions(now: now)
                : store.sessions.filter { $0.live(at: now).isVisible }.sorted { $0.live(at: now).rank < $1.live(at: now).rank }
            content(list: list, now: now)
        }
    }

    @ViewBuilder
    private func content(list: [SessionSummary], now: Date) -> some View {
        let expanded = state.expanded
        let notch = !state.floating
        let width: CGFloat = expanded ? 380 : (notch ? state.notchWidth + 2 * 74 : 0)
        let shape = notch
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: expanded ? 22 : 12,
                                              bottomTrailingRadius: expanded ? 22 : 12, topTrailingRadius: 0, style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: expanded ? 18 : 17, style: .continuous))

        VStack(spacing: 0) {
            collapsedBar(list: list, now: now, notch: notch)
                .frame(height: notch ? state.notchHeight : 34)
            if expanded {
                expandedBody(list: list, now: now)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: width > 0 ? width : nil)
        .fixedSize(horizontal: width == 0, vertical: true)
        .background(Color.black, in: shape)
        .overlay(shape.stroke(Color.white.opacity(notch ? 0 : 0.10), lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(expanded || !notch ? 0.45 : 0), radius: 14, y: 8)
        .contentShape(shape)
        .onTapGesture { expanded ? Pill.shared.collapse() : Pill.shared.expand() }
    }

    /// The always-visible strip: buddy on the left, a count or timer on the right, the notch between.
    private func collapsedBar(list: [SessionSummary], now: Date, notch: Bool) -> some View {
        let top = list.first
        let st = top?.live(at: now) ?? .idle
        let waiting = list.filter { $0.live(at: now).isWaiting }
        let working = list.filter { $0.live(at: now).isWorking }.count
        return HStack(spacing: 8) {
            Die(state: st, size: notch ? min(16, state.notchHeight - 10) : 18, animated: animated)
            if notch {
                Spacer(minLength: state.notchWidth)
            } else {
                Text(waiting.isEmpty ? (working > 0 ? "\(working) working" : "Done") : "Needs you")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(waiting.isEmpty ? Color.white : HUD.alarm)
            }
            Group {
                if let w = waiting.first, let since = w.live(at: now).since {
                    Text(now.timeIntervalSince(since).clock).foregroundStyle(HUD.alarm)
                } else if working > 0 {
                    HStack(spacing: 4) {
                        PulseDot(color: HUD.phosphor, animated: animated, size: 5).frame(width: 8, height: 8)
                        if notch { Text("\(working)") }
                    }
                    .foregroundStyle(.white)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(HUD.phosphor)
                }
            }
            .font(.hud(12, .semibold))
        }
        .padding(.horizontal, notch ? 18 : 12)
    }

    private func expandedBody(list: [SessionSummary], now: Date) -> some View {
        let gauges = Limits.shared.gauges
        return VStack(alignment: .leading, spacing: 4) {
            if list.isEmpty {
                Text("Nothing running").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
            }
            ForEach(list.prefix(6)) { s in
                LiveSessionRow(session: s, now: now, animated: animated)
            }
            HStack(spacing: 6) {
                ForEach(gauges.prefix(2)) { LimitChip(gauge: $0) }
                Spacer()
                Button { AppController.shared.openDashboard(select: nil) } label: {
                    Text("Dashboard").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.top, 4)
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 12)
    }
}
