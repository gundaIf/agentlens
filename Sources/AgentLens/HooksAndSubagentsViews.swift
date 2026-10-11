import SwiftUI

// MARK: - Hooks

/// Status of the optional Claude Code hooks, with a button that previews the settings.json diff
/// and only writes it after the user confirms.
struct HooksPanel: View {
    @Environment(Store.self) private var store
    // `State(...)` directly: the @State macro plugin isn't available without full Xcode.
    private let planState = State<HookInstaller.Plan?>(initialValue: nil)
    private let showingState = State(initialValue: false)

    var body: some View {
        let installed = store.hooksInstalled
        // Compact: sits in the Overview header next to the range picker. Details live in the tooltip and sheet.
        Button {
            planState.wrappedValue = HookInstaller.plan(install: !installed)
            showingState.wrappedValue = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: installed ? "bolt.fill" : "bolt.slash")
                Text(installed ? "Exact timing on" : "Install hooks…")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(installed ? Color.green : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background((installed ? Color.green : Color.primary).opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
        .help((installed ? "Claude Code hooks installed. Click to remove. " : "") + subtitle(installed))
        .sheet(isPresented: showingState.projectedValue) {
            if let plan = planState.wrappedValue {
                HookDiffSheet(plan: plan) { showingState.wrappedValue = false }
                    .environment(store)
            }
        }
    }

    private func subtitle(_ installed: Bool) -> String {
        if installed {
            if let last = store.lastHookEvent {
                return "\(store.hookEvents) events, last \(Date().timeIntervalSince(last).clock) ago. Permission prompts count as Waiting on you."
            }
            return "No events yet. Restart running Claude Code sessions to pick up the hooks."
        }
        return "Install hooks to separate permission prompts from running tools and get exact tool times."
    }
}

/// Shows exactly what will change in ~/.claude/settings.json and asks before writing.
struct HookDiffSheet: View {
    @Environment(Store.self) private var store
    let plan: HookInstaller.Plan
    var scrolls = true      // false for offscreen snapshots, which can't draw scroll views
    let dismiss: () -> Void
    private let errorState = State<String?>(initialValue: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.install ? "Install AgentLens hooks" : "Remove AgentLens hooks").font(.title3.bold())
            Text(plan.install
                 ? "AgentLens adds a hook to PreToolUse, PostToolUse, Notification, Stop and SubagentStop. Each call appends one small line (event, session, tool name and id, time) to ~/Library/Application Support/AgentLens/events.jsonl. The hook prints nothing and always exits 0, so it can't block or change a tool call. Your other settings and hooks are kept. A backup is saved as settings.json.agentlens-backup."
                 : "Removes only the AgentLens entries. Your other settings and hooks are kept. A backup is saved as settings.json.agentlens-backup.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let error = plan.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if !plan.changes {
                Text("settings.json already matches. Nothing to write.").foregroundStyle(.secondary)
            } else {
                Text(Paths.settings.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                let lines = VStack(alignment: .leading, spacing: 0) {
                        ForEach(plan.diff) { line in
                            Text(prefix(line.kind) + line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.kind == .same ? Color.secondary : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .background(background(line.kind))
                        }
                    }
                    .textSelection(.enabled)
                Group {
                    if scrolls { ScrollView { lines }.frame(minHeight: 240, maxHeight: 380) } else { lines }
                }
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
            if let e = errorState.wrappedValue { Text(e).foregroundStyle(.red).font(.callout) }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(plan.install ? "Write to settings.json" : "Remove from settings.json") {
                    do {
                        try HookInstaller.apply(plan)
                        store.refreshHookStatus()
                        dismiss()
                    } catch {
                        errorState.wrappedValue = "Couldn't write: \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!plan.changes)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func prefix(_ k: HookInstaller.DiffLine.Kind) -> String {
        switch k { case .same: return "  "; case .added: return "+ "; case .removed: return "- " }
    }

    private func background(_ k: HookInstaller.DiffLine.Kind) -> Color {
        switch k { case .same: return .clear; case .added: return .green.opacity(0.15); case .removed: return .red.opacity(0.15) }
    }
}

// MARK: - Subagents

/// The subagents a session started, each with its own time split. Tapping one opens it.
struct SubagentsCard: View {
    let children: [SessionSummary]
    var onSelect: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("Subagents")
                Text("\(children.count)").font(.eyebrow).foregroundStyle(.tertiary)
                Spacer()
                Text("Their time runs alongside the parent's Subagents time, so it isn't added to totals.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(children) { c in
                Button { onSelect?(c.id) } label: { SubagentRow(session: c) }
                    .buttonStyle(.plain)
            }
        }
        .surface()
    }
}

struct SubagentRow: View {
    let session: SessionSummary
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary).imageScale(.small)
                Text(session.title).font(.system(size: compact ? 12 : 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                Text(session.active.clock).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            if !compact {
                HStack(spacing: 6) {
                    if let t = session.agentType { Chip(text: t, symbol: "person.2") }
                    Chip(text: "\(session.toolCalls) tools")
                    if session.errors > 0 { Chip(text: "\(session.errors) errors", tint: .red) }
                    Spacer()
                }
            }
            CategoryBar(values: session.totals.byCategory, height: compact ? 3 : 5)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Notifications

/// Menu popover switch for finish / waiting notifications.
struct NotificationsToggle: View {
    private let notifier = Notifier.shared

    var body: some View {
        let blocked = notifier.enabled && !notifier.allowed
        HStack(spacing: 5) {
            Image(systemName: blocked ? "bell.slash" : (notifier.enabled ? "bell.fill" : "bell"))
                .foregroundStyle(blocked ? Color.orange : Color.secondary)
            Toggle("Notify", isOn: Binding(get: { notifier.enabled }, set: { notifier.enabled = $0 }))
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .help(blocked ? "Notifications are off for AgentLens in System Settings."
                      : "Notify when an agent finishes its turn or starts waiting on you")
    }
}
