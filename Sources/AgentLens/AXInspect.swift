import AppKit
import ApplicationServices
import Observation

/// Reading other apps' windows through the macOS Accessibility API. Used for apps like Muse that keep
/// their sessions online: their window is the only place AgentLens can see what's happening.
/// Needs the user to turn on AgentLens in System Settings → Privacy & Security → Accessibility.
/// Whether AgentLens may read other apps' windows, kept current so the UI reacts the moment the user
/// switches it on in System Settings (no restart needed).
@MainActor
@Observable
final class AXAccess {
    static let shared = AXAccess()
    private(set) var trusted = AXIsProcessTrusted()
    /// When the user last clicked Connect; used to explain a grant that didn't take.
    private(set) var requestedAt: Date?
    @ObservationIgnored private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = AXIsProcessTrusted()
                if t != AXAccess.shared.trusted { AXAccess.shared.trusted = t }
            }
        }
    }

    /// Shows the system prompt and opens Privacy & Security → Accessibility.
    func connect() {
        requestedAt = Date()
        AXInspect.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The user clicked Connect a while ago and access still isn't on: usually a stale entry from an
    /// earlier build that looks switched on but doesn't match this one.
    func looksStuck(now: Date) -> Bool {
        guard !trusted, let r = requestedAt else { return false }
        return now.timeIntervalSince(r) > 20
    }
}

enum AXInspect {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility settings.
    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Electron and Chromium apps (Grok Bot) only build their accessibility tree once a reader asks for it.
    static func enableTree(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Structure of an app's windows for building a reader: roles, identifiers, button names and short
    /// labels. Longer text (which could be conversation content) is reported only as its length.
    static func structure(bundle: String, maxDepth: Int = 30) -> String {
        guard trusted else { return "not trusted for Accessibility\n" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            return "\(bundle) is not running\n"
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        enableTree(root)
        var out = ""
        var count = 0

        func label(_ s: String?, keepUpTo: Int) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let flat = s.replacingOccurrences(of: "\n", with: " ")
            return flat.count <= keepUpTo ? "\"\(flat)\"" : "<text len=\(flat.count)>"
        }

        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, count < 4000 else { return }
            count += 1
            let role = string(e, kAXRoleAttribute) ?? "?"
            var parts = [role]
            if let sub = string(e, kAXSubroleAttribute) { parts.append("sub=\(sub)") }
            if let id = string(e, kAXIdentifierAttribute), !id.isEmpty { parts.append("id=\(id)") }
            // Buttons, tabs and window titles are UI chrome: keep them. Body text: length only.
            let chrome = ["AXButton", "AXWindow", "AXTab", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXLink"].contains(role)
            if let t = label(string(e, kAXTitleAttribute), keepUpTo: chrome ? 80 : 24) { parts.append("title=\(t)") }
            if let d = label(string(e, kAXDescriptionAttribute), keepUpTo: chrome ? 80 : 24) { parts.append("desc=\(d)") }
            if let h = label(string(e, kAXHelpAttribute), keepUpTo: 40) { parts.append("help=\(h)") }
            if let v = attr(e, kAXValueAttribute) {
                if let s = v as? String { parts.append("value=\(label(s, keepUpTo: 24) ?? "\"\"")") }
                else if let n = v as? NSNumber { parts.append("value=\(n)") }
            }
            if let enabled = attr(e, kAXEnabledAttribute) as? Bool, !enabled { parts.append("disabled") }
            let kids = children(e)
            if !kids.isEmpty { parts.append("[\(kids.count)]") }
            out += String(repeating: "  ", count: depth) + parts.joined(separator: " ") + "\n"
            kids.forEach { walk($0, depth + 1) }
        }

        for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
        return out.isEmpty ? "no windows\n" : out
    }
}
