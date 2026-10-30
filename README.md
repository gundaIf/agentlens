# AgentLens

A macOS menu bar app that shows what your Claude Code and Cowork agents are doing now, and where their time went.

## Run

```
./build.sh && open AgentLens.app
```

Builds with the Xcode Command Line Tools alone; full Xcode isn't required. There's no Dock icon. Look for the eye in the menu bar.

- `AgentLens --dump`: prints the computed stats in the terminal
- `AgentLens --snapshot <dir>`: renders the menu and dashboard to PNGs offscreen
- `AgentLens.app/Contents/MacOS/AgentLens --film <dir>`: opens and closes the real menu bar dropdown once (6s after launch) and saves frames of the animation, then quits. It shows on screen briefly. Frames are approximate: the system takes about 100ms to draw a new window the first time.
- `AgentLens --install-hooks` / `--uninstall-hooks`: shows the `~/.claude/settings.json` diff and asks y/N before writing (same as the dashboard button)
- `AGENTLENS_HOME=<dir>` points every path (transcripts, settings, events) at another home folder, for testing

## What it reads

| Agent | Transcripts |
|---|---|
| Claude Code (CLI, IDE, desktop Code tab) | `~/.claude/projects/<project>/<session>.jsonl` |
| Cowork | `~/Library/Application Support/Claude/local-agent-mode-sessions/*/*/local_<id>/.claude/projects/*/*.jsonl` (title from `local_<id>.json`) |
| Grok (the `grok` coding agent) | `~/.grok/sessions/<cwd>/<id>/`: `events.jsonl` gives exact phases (model, tool, permission prompt), `chat_history.jsonl` the prompts, `hunk_records.jsonl` the files changed, `summary.json` the title |
| ChatGPT app (its built-in Codex agent) and the `codex` CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`: each step is an `item_completed` event with exact start/end times (reasoning, reply, command, file change, web search); turns from `task_started`/`task_complete`; titles from `~/.codex/session_index.jsonl`. The current ChatGPT app identifies as `com.openai.codex`. Plain chats never reach `~/.codex`; they're followed through the window (below) as **ChatGPT chat**. |
| AI apps without local logs (Muse, Grok Bot, Perplexity, if installed) | Time in use only: AgentLens records when the app is frontmost and you've touched the keyboard or mouse in the last 5 minutes, appending to `~/Library/Application Support/AgentLens/app-usage.jsonl`. Grok Bot's local helper log (`~/.grokbot/local-exec-daemon.log`) records only connection events, not agent actions, so it isn't used. Muse, Grok Bot and ChatGPT can also be followed by reading their windows through the Accessibility API once you click **Connect** and allow AgentLens in System Settings. |

Files are polled every 2s, and only newly appended bytes are parsed. Nothing leaves the machine.

**History.** Claude Code deletes its session logs after 30 days (`cleanupPeriodDays`). So history isn't lost with them, AgentLens hard-links every Claude Code and Cowork log (with subagent files and Cowork titles) into `~/Library/Application Support/AgentLens/archive/`. While the original exists, the link is the same file, so it uses no extra space and sees every append. When Claude Code deletes the original, the link survives and AgentLens reads the session from the archive. Turn this off in Settings → Advanced → Keep history.

**Subagents.** Subagent work is read from `<session>/subagents/agent-<id>.jsonl`, with the description and agent type from `agent-<id>.meta.json`. Older transcripts write it inline as `isSidechain: true` lines, which are grouped by `agentId`. Each subagent becomes a child row under its session in the sidebar, and the session page gets a Subagents card. Each child has its own category breakdown and workflow. Subagents run alongside the parent's `Agent` call, so their time isn't added to the totals again.

## Following Muse, Grok Bot and ChatGPT (Accessibility)

Muse, Grok Bot and ChatGPT chats live online, so AgentLens follows them by reading their window. ChatGPT's window sessions are labelled **ChatGPT chat**. When one overlaps a Codex session from `~/.codex` (a Codex task shows in the window too), only the Codex version is kept, since its timing is exact. Click **Connect** next to the app in the menu bar dropdown. AgentLens opens Privacy & Security → Accessibility; switch AgentLens on there, and it starts following within two seconds (no restart). If it still says Connect after you switched it on, an entry from an older build is in the way: select AgentLens, click −, then Connect again. The dropdown explains this if it happens.

This should only happen once. `build.sh` signs the app with a requirement that names just its bundle id (`local.agentlens`), not the default ad-hoc hash that changes on every build, so macOS treats new builds as the same app and keeps the permission. Check it with `AgentLens.app/Contents/MacOS/AgentLens --ax-status`.

The reader isn't specific to either app. It looks for signals every chat app shows:

- **Conversation:** the window title. A new title starts a new session.
- **Prompt:** the message box had text and then emptied. Only its first line is kept (up to 120 characters).
- **Answering:** a Stop/Cancel button or a progress indicator is showing, or the reply text is still changing. The turn ends after 3 quiet seconds.
- **Steps:** short status texts ending in "…" ("Searching…", "Making…"), mapped to activities by their verb.

Events go to `~/Library/Application Support/AgentLens/windows/<bundle id>.jsonl`; reply text is never stored. `AgentLens --selftest-windows` runs the logic on a made-up conversation. To see an app's window structure while tuning the reader, run `open -n AgentLens.app --args --ax-structure <bundle id> <file>` (roles, button names and short labels; longer text appears only as its length).

**Signing.** Ad-hoc signatures change with every build, and macOS then treats AgentLens as a new app and drops its Accessibility permission. `build.sh` signs with an **AgentLens Dev** certificate when one exists (Keychain Access → Certificate Assistant → Create a Certificate…, Self Signed Root, Code Signing), which keeps permissions across builds.

## Hooks (optional, Claude Code only)

The Overview has an **Install hooks…** button. It shows the exact `settings.json` diff and writes nothing until you confirm. It adds one command hook to `PreToolUse`, `PostToolUse`, `Notification`, `Stop` and `SubagentStop`, saves a backup as `settings.json.agentlens-backup`, and keeps your other settings and hooks. The hook is `~/Library/Application Support/AgentLens/hook.pl` (Perl ships with macOS). It appends one line per call to `events.jsonl` in the same folder: time, event, session id, tool name and id, notification type. It prints nothing and always exits 0, so it can't block or change a tool call. Restart running Claude Code sessions to pick it up. **Remove hooks…** takes out only the AgentLens entries.

With hooks installed:

- **Permission prompts.** The wait after a `permission_prompt` notification counts as **Waiting on you** instead of the tool. The live state says "Needs permission: Bash". `--dump` shows it as "of which permission prompts".
- **Exact tool times.** `PreToolUse` and `PostToolUse` mark where each tool starts and ends. `Stop` marks the end of the turn.

Without hooks, everything falls back to the transcript method below. Cowork sessions don't run your `~/.claude/settings.json` hooks, so they always use the transcript method.

## Notifications

The menu popover has a switch for macOS notifications when an agent **finishes its turn** or **starts waiting on you** (a question, plan approval, or a permission prompt if hooks are installed). Clicking a notification opens that session. macOS asks for permission the first time you turn it on. This only works from `AgentLens.app`; the bare `.build` binary has no bundle id.

## How time is counted

The gap between two consecutive transcript events is credited to whatever the agent was doing:

- a tool call is pending and a permission prompt is showing (hooks only) → **Waiting on you**
- a tool call is pending → that tool's category (Shell, Reading, Editing, Browser, Web, Subagents, Waiting on you, Other), capped at 30 min
- mid-turn with no tool pending → **Thinking** (model generating, including writing file contents), capped at 10 min
- after `end_turn` → idle, not counted

So "active time" is real agent work, not how long a session stayed open. A **chunk** is one user prompt and everything done in response. Its **steps** are runs of the same category.

## Known limits

- Without hooks, a tool waiting on a permission prompt counts as that tool running.
- With hooks, there's no event for "you approved", so the approved tool's own run time until `PostToolUse` also counts as permission wait. For quick tools this is noise. A long command approved after a prompt is over-counted as waiting.
- A permission prompt raised inside a subagent counts as waiting on the parent session, not the child.

## Sources

- `Transcript.swift`: incremental JSONL reader and parser
- `Analyzer.swift`: time attribution, chunks, steps, aggregates
- `Store.swift`: discovery and polling
- `Hooks.swift`: hook installer (settings diff, hook script) and `events.jsonl` reader
- `Notifier.swift`: finish / waiting notifications
- `HooksAndSubagentsViews.swift`: hooks panel and diff sheet, subagent rows, notification switch
- `GrokSessions.swift`: Grok session reader
- `CodexSessions.swift`: ChatGPT/Codex session reader
- `AppUsage.swift`, `AppsViews.swift`: AI app usage tracking and its views
- `AXInspect.swift`, `WindowSessions.swift`: Accessibility access and the window reader for Muse, Grok Bot and ChatGPT
- `Theme.swift`, `Logo.swift`, `Visuals.swift`: thermal-HUD design system, logo and icon, charts
- `MenuView.swift`: menu bar popover
- `DashboardView.swift`: dashboard window
