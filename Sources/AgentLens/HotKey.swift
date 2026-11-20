import AppKit
import Carbon.HIToolbox

/// ⌃⌥↩ from anywhere: go to the agent that needs you (or the most recent working one).
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@MainActor
enum HotKey {
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.fire() } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x414C4E53), id: 1) // 'ALNS'
        RegisterEventHotKey(UInt32(kVK_Return), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    private static func fire() {
        let now = Date()
        let list = AppController.shared.store.sessions.filter { $0.live(at: now).isVisible }
            .sorted { ($0.live(at: now).rank, $1.end) < ($1.live(at: now).rank, $0.end) }
        if let s = list.first { Jump.go(to: s) } else { AppController.shared.openDashboard(select: nil) }
    }
}
