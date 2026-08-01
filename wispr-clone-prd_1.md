# PRD — System-Wide AI Dictation Tool (Wispr Flow clone)

**Base:** fork of [MiniWhisper](https://github.com/andyhtran/MiniWhisper) (MIT)
**Status:** draft, for Claude Code kickoff
**Owner:** Dan

## 1. Summary

A macOS menu bar app that transcribes speech to text anywhere on the system: hold a hotkey, talk, release, and the cleaned-up text lands at your cursor. MiniWhisper already solves most of the hard infrastructure for this (global hotkey capture, Accessibility-gated paste simulation, whisper.cpp integration, an LLM cleanup pass). This PRD scopes the fork: what stays as-is, what changes, and what's net-new.

## 2. Goals

- True hold-to-talk: recording starts on key-down, stops on key-up. No second press needed to stop.
- Local transcription by default (whisper.cpp), with a `.env`-configured fallback to Groq or OpenAI's hosted Whisper API.
- LLM cleanup pass (fillers, punctuation, casing) using a `.env` API key, not an OAuth-token-reuse path.
- Visible feedback while recording: a small floating indicator, not just a menu bar icon change.
- No accounts, no telemetry, fully offline when local model + whisper.cpp are present.

## 3. Non-goals

- Meeting/system-audio capture (that's the separate Granola-clone project).
- Multi-user support, cloud sync, or any server component.
- Editing arbitrary selected text via voice command (MiniWhisper's separate "Edit Mode" feature) — out of scope for v1, revisit later if useful.

## 4. What to reuse from MiniWhisper as-is

These components already do what the spec needs. Fork them, don't rewrite them:

- **`Services/PasteboardService.swift`** — save clipboard → write text → simulate ⌘V via `CGEvent` → restore clipboard after a delay. Matches the spec's paste requirement almost exactly.
- **whisper.cpp integration** (`Package.swift` binary target + `Services/WhisperProvider.swift`) — model download, checksum verification, on-device transcription. Keep as the local/offline path.
- **Menu bar app shell** (`AppDelegate.swift`, `Views/MenuBarView.swift`, `Views/MenuBarIcon.swift`) — base structure for the tray icon and its menu.
- **`Services/LaunchAtLoginManager.swift`** — already uses the modern `SMAppService` API.
- **Accessibility/Input Monitoring permission-request flow** and the entitlements file (unsandboxed, mic input, user-selected file read/write) — same permission model this spec needs.
- **`Services/CleanupPromptStore.swift`** default prompt — fixes homophones, adds punctuation, strips fillers, handles "scratch that"-style corrections. Close to exactly what the spec asks for; light editing only.

## 5. What needs to change

### 5.1 Hotkey model: toggle → hold-to-talk
Today, `Services/Hotkeys/FnStateMachine.swift` explicitly ignores hold duration and fires a single `toggleRecording()` call on key-up (see `AppDelegate.swift:390`). That needs to become two calls: `startRecording()` on key-down, `stopRecording()` on key-up. This touches:
- `FnStateMachine.swift` (or the equivalent for whatever key is chosen — Fn specifically has OS-level quirks around swallowed events that are worth keeping, just repointed to start/stop instead of toggle)
- The custom shortcut path in `CustomShortcutMonitor.swift` / `ShortcutHandlerRegistry.swift`, if a non-Fn key is also supported as the hold-to-talk trigger
- Whatever currently calls `appState.toggleRecording()`

### 5.2 Config: `.env` instead of Settings UI / Keychain
Current config lives in UserDefaults and (for the LLM step) reads OAuth tokens out of Keychain or `~/.codex/auth.json`, then spoofs Claude Code / Codex CLI identity headers to call Anthropic/OpenAI directly. **Don't carry this over.** Replace with:
- A `.env` file (project root or `~/Library/Application Support/<app>/.env`) holding `TRANSCRIPTION_PROVIDER`, `TRANSCRIPTION_API_KEY`, `LLM_API_KEY`, `WHISPER_MODEL_SIZE`.
- A straightforward `URLSession` call to the configured provider's own API using that key — no header spoofing, no CLI impersonation, no reuse of credentials that belong to a different app.

### 5.3 Transcription provider: add Groq, make model size selectable
`Services/CustomProvider.swift` already hits any OpenAI-compatible `/v1/audio/transcriptions` endpoint, which covers Groq's Whisper endpoint with no changes beyond pointing the base URL at it. Add:
- A `TRANSCRIPTION_PROVIDER=local|groq|openai` flag read from `.env`
- A `WHISPER_MODEL_SIZE=small|medium` option for the local path (currently the model is fixed at build/download time — needs to become a config value that picks which model file to download/load)

### 5.4 Floating recording indicator
Doesn't exist today — the only recording feedback is the menu bar icon state, via `ToastWindowController.swift` (currently used for error/info toasts, not a live recording indicator). Net-new work:
- Small always-on-top `NSPanel`, borderless, positioned near the cursor or a fixed screen corner
- Shows while recording, dismisses on stop
- Can likely reuse `ToastWindowController`'s panel-management pattern (creation, animation, dismiss) rather than building panel logic from scratch

## 6. Functional requirements

| # | Requirement | Source |
|---|---|---|
| 1 | Global hotkey, hold-to-talk (configurable key/shortcut) | New (5.1) |
| 2 | Record mic while key is held | Reuse `AudioRecorder.swift` |
| 3 | On release: transcribe via local whisper.cpp (small/medium, config-selectable) or Groq/OpenAI API per `.env` flag | Reuse + 5.3 |
| 4 | Pipe transcript through LLM cleanup (fillers, punctuation, casing) using `.env` key | Reuse prompt (4) + new client (5.2) |
| 5 | Paste result at cursor via clipboard + ⌘V, restore prior clipboard | Reuse `PasteboardService.swift` as-is |
| 6 | Floating indicator visible while recording | New (5.4) |
| 7 | Menu bar toggle for on/off | Reuse |
| 8 | Launch at login | Reuse `LaunchAtLoginManager.swift` |
| 9 | `.env`-based settings for hotkey, provider, model size | New (5.2) |
| 10 | No accounts, no telemetry; fully offline when local model present | Reuse (already true for the core path once 5.2 removes the OAuth/cloud dependency) |

## 7. Permissions (for README)

- **Microphone** — required, for recording.
- **Accessibility** — required, for simulating ⌘V and reading key events system-wide.
- **Input Monitoring** — required, for the global hotkey to work across apps.
- No Screen Recording permission needed (no system audio capture in this app).

## 8. Open questions

- Default hotkey: keep Fn, or default to a chosen combination (e.g. Right Option) to avoid the Fn-key OS-quirk handling entirely? Fn has known edge cases (macOS "🌐 to..." action, dropped key-up events on sleep/wake) that `FnStateMachine.swift` already works around — worth deciding whether that complexity is worth keeping or whether a simpler modifier key sidesteps it.
- Should the floating pill show a live waveform/level meter, or just a static "recording" state? Spec says "tiny," so probably static for v1.
- Model download UX for local whisper.cpp: same first-run flow as MiniWhisper (checksum-verified download), or bundle a small model in the app to work offline immediately on first launch?

## 9. Suggested build order

1. Fork repo, strip unrelated features (Edit Mode's OAuth path, custom replacement rules, skill manager) to reduce surface area.
2. Hold-to-talk rewire (5.1) — highest-risk change, do it first and confirm recording start/stop timing feels right.
3. `.env` config loader + Groq/OpenAI client swap-in (5.2, 5.3).
4. Floating indicator (5.4).
5. Trim README to match this app's actual feature set and permissions.
