# FalaDan — Design

**Date:** 2026-08-01
**Owner:** Dan (danpiz)
**Base:** fork of [MiniWhisper](https://github.com/andyhtran/MiniWhisper) (MIT)
**Supersedes:** `wispr-clone-prd_1.md` (retained as the originating PRD)

## 1. What we're building

A macOS menu bar app for system-wide dictation. Hold a key, talk, release, and cleaned-up
text lands at the cursor. No accounts, no telemetry, fully offline when a local model is
present.

MiniWhisper already solves the hard infrastructure: global hotkey capture via a CGEvent tap,
Accessibility-gated paste simulation, whisper.cpp integration, and an LLM cleanup pass. This
document scopes the fork.

## 2. Upstream reality check

The PRD assumed a small codebase. It is not: **127 Swift files**, including several
subsystems the PRD never mentions.

| Subsystem | Files | Disposition |
|---|---|---|
| `MiniWhisperCLI` target | ~15 (incl. 29KB `SkillsCommand`) | Delete |
| Sparkle auto-updater | 9 + appcast + notarize/sign scripts | Delete |
| EditMode + OAuth credential reuse | ~6 | Delete |
| Replacement rules, spoken symbols, analytics | ~8 | Delete |
| `ClaudeSkillManager`, `CLIInstallManager` | 2 | Delete |
| `ParakeetProvider` (second local ASR engine) | 2 | **Keep** — selectable via `.env` |
| Hotkey layer (`Services/Hotkeys/`) | 11 | Keep, rewire |
| `PasteboardService`, `AudioRecorder`, `WhisperProvider`, `LaunchAtLoginManager` | 4 | Keep as-is |

Two consequences drive the whole plan:

1. **Stripping is the largest and riskiest task, not a warm-up.** Everything routes through
   `AppState`, so deletions cascade. It is the worst possible opening move for a delegated
   executor.
2. **The regression net already exists.** 20 XCTest files, including `FnStateMachineTests`,
   `ShortcutBackendTests`, and `HotKeyPressTrackerTests` — direct coverage of the layer being
   rewired. `MeterNormalizationTests` also confirms audio level metering is already built,
   making a v2 waveform indicator cheap.

**Toolchain:** SPM + `just`, CLI-only (no Xcode). macOS 14.0+, Swift 6.0+.

## 3. Strategy: rewire first, strip last

Get the forked app **building and running unchanged** before touching anything. Then make
behavior changes one at a time against a working app, each ending on a green build and green
tests. Delete dead subsystems **last**, as independent mechanical removals, once nothing
depends on them.

This is the inverse of the PRD's suggested order. The reason: every task stays small,
independently verifiable, and safe to delegate, and every review is a clean bounded diff
rather than archaeology across a broken build.

Cost accepted: dead code is carried for the duration of the rewire phase.

## 4. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Default hotkey | **Fn** | Reversed from an earlier Right Option decision after reading the hotkey layer. See 5.2 — the bare-modifier tap is Fn-only by design, so Right Option would mean building a generalized modifier mechanism inside the event tap before hold-to-talk could ship at all. Fn's OS quirks are already solved and unit-tested here. |
| Recording indicator | **Static pill, v1** | Matches the PRD's "tiny" framing. Live level meter deferred to v2 — cheap, since metering exists. |
| Local model delivery | **Download on first run** | Reuses MiniWhisper's checksum-verified download unchanged. Zero new work. |
| Parakeet | **Keep, selectable** | Faster and more accurate than whisper-small on English. Worth A/B-ing on Dan's own voice. |
| Sparkle updater | **Cut** | Personal tool rebuilt locally with `just dev`. Recoverable later via `git checkout upstream/main -- Sources/FalaDan/Updater`. |
| Minimum hold threshold | **~150ms, tunable** | Not in the PRD. True hold-to-talk means a stray Option tap fires a ~10ms recording, costing an API call and pasting noise. Presses under threshold are discarded silently. |
| Cleanup LLM provider | **Fully configurable, no default** | `LLM_PROVIDER` + `LLM_MODEL` in `.env`. No opinionated default. |
| Rename timing | **Early, isolated commit** | Pure mechanical churn, trivially reviewable as a diff. Everything afterward speaks in FalaDan terms. |

## 5. Architecture

### 5.1 Repo

Fork `andyhtran/MiniWhisper` → `danpiz/FalaDan`. Clone to `/Users/danpiz/Dev/ClaudeCode/FalaDan`,
retaining `upstream` as a remote for future fixes. The existing `wispr-clone-prd_1.md` and
`docs/` are preserved into the clone.

**Baseline gate (human):** `just build`, `swift test`, `just dev`, grant Microphone /
Accessibility / Input Monitoring, and confirm dictation works end to end. No code changes
before this passes. This baseline is what every later task is measured against.

**Rename:** `MiniWhisper` → `FalaDan` across module name, `Package.swift` targets, bundle ID,
entitlements filename, and `Scripts/`. One commit, no behavior change.

### 5.2 Hold-to-talk

**The delivery plumbing already exists.** `ShortcutHandlerRegistry` holds separate keyDown and
keyUp handlers; `CustomShortcutMonitor` exposes `onKeyDown`/`onKeyUp`; both the Carbon backend
(`.pressed` / `.released`) and the modifier tap already fire both edges, and
`HotkeyManager.setupEditSelection` already uses `onKeyUp` in production. What is missing is not
the mechanism but the wiring: `setupToggleRecording` registers **only** a keyDown handler,
which calls `toggleRecording()`.

The change is therefore small:

- `HotkeyManager` registers **both** edges for the recording shortcut, delegating
  `hotkeyDidStartRecording()` on down and `hotkeyDidStopRecording()` on up.
- `AppState` gains hold-to-talk entry points that start on down and stop-and-transcribe on up,
  replacing `toggleRecording()` on this path.
- A new **hold-duration policy** — a pure value type, no dependencies — decides whether an
  up-edge transcribes or discards, comparing elapsed time against the configured threshold.

**Fn stays the bare-modifier key.** The tap is Fn-only by design: `ShortcutBackend.classify`
returns `.modifierOnly` only for `shortcut.isFnOnly`, and any other bare modifier is
`.unsupported(.modifierChord)` ("the modifier tap only tracks Fn on its own").
`CustomShortcutMonitor.handleModifierEvent` hard-guards on `FnKeyCode.isFnKey`. Supporting a
different bare modifier would mean generalizing `FnStateMachine`, `ShortcutMatcher`,
`ShortcutBackend`, and `CustomShortcutMonitor` — all inside the event tap — before hold-to-talk
could ship. Not worth it: Fn's quirks are already handled and tested here.

`FnStateMachine`'s stuck-down recovery is preserved and matters *more* under hold-to-talk, since
a dropped key-up now means a recording that never stops. Its comment that hold duration is
"deliberately irrelevant" is no longer true of the system and must be updated.

Touches: `Services/Hotkeys/HotkeyManager.swift`, `AppDelegate.swift`, `AppState.swift`,
plus a new hold-duration policy file. `FnStateMachine` and `CustomShortcutMonitor` are
**not** modified.

### 5.3 Config

New `Services/Config/EnvConfig.swift`. Loads from
`~/Library/Application Support/FalaDan/.env`, falling back to a repo-root `.env` in dev.
Parsed once at launch into an immutable struct. No hot reload in v1.

```
TRANSCRIPTION_PROVIDER=local|groq|openai
TRANSCRIPTION_API_KEY=
WHISPER_MODEL_SIZE=small|medium
LOCAL_ENGINE=whisper|parakeet
LLM_PROVIDER=groq|openai|anthropic
LLM_API_KEY=
LLM_MODEL=
HOTKEY=right_option
MIN_HOLD_MS=150
```

Missing or malformed values fall back to documented defaults rather than crashing; an invalid
provider name is surfaced as a menu bar error toast. Absent keys for a cloud provider disable
that path rather than failing at transcription time.

This is a pure, dependency-free, highly testable unit — the ideal first delegated task.

### 5.4 Providers

`CustomProvider` already hits any OpenAI-compatible `/v1/audio/transcriptions` endpoint, which
covers Groq unchanged beyond a base URL. Provider selection reads from `EnvConfig`.

The LLM cleanup path is rewritten: the OAuth credential-reuse stack
(`OAuthApiClient`, `OAuthCredentialStore`, `OAuthRefreshTrigger`) is deleted and replaced with
a plain `URLSession` client authenticating with `LLM_API_KEY` against the configured provider's
own API. **No header spoofing, no CLI impersonation, no reuse of another app's credentials** —
this is a standing constraint, not a one-time cleanup.

EditMode (`AppState+EditMode`, `EditModeProvider`, `CustomEditProvider`, and their settings
models) is the OAuth stack's only other consumer, so it is deleted **in this slice**, not
deferred to the strip phase. This is the one deletion that happens during the rewire phase,
and it is bounded: EditMode is already out of scope for v1.

`CleanupPromptStore`'s existing default prompt is kept with light editing.

### 5.5 Recording indicator

New `Views/RecordingIndicatorWindow.swift`, modeled on `ToastWindowController`'s existing
NSPanel management (creation, animation, dismiss). Borderless always-on-top panel, static
pill, fixed screen position. Shown on recording start, dismissed on stop — including on the
discard path, so a sub-threshold tap never leaves a stuck indicator.

### 5.6 Strip phase

Independent deletions, each its own task, each ending on a green build and green tests: the
CLI target (`FalaDanCLI` post-rename) → Sparkle updater → replacement rules → spoken symbols →
analytics → `ClaudeSkillManager` / `CLIInstallManager`. Then README rewrite.

EditMode is not in this list — it is deleted earlier, in 5.4, because the OAuth removal
requires it.

## 6. Orchestration model

Opus plans and reviews. Sonnet executes. This is a first-class design constraint, not a
workflow preference.

The protocol is a port of Dan's existing `fable-token-efficiency` skill from PeritoX,
**retargeted one tier down** — that skill orchestrates with Fable and executes with Opus; this
one orchestrates with Opus and executes with Sonnet. It ships as a project skill at
`.claude/skills/faladan-orchestration/SKILL.md`. Fable is not designed into the loop, but
remains available as a manual escalation for a moment that genuinely warrants it.

**Every task in the implementation plan specifies:**

- An explicit **file allowlist** and a **do-not-touch list**
- An **executor tag**: `sonnet-alone` or `opus-supervised`
- The **test that must pass**, written first, as literal code where possible
- **One verification command** with its expected output
- A checkable **"done means"** statement — never "make it work"
- Scope small enough that all relevant context fits comfortably: roughly ≤3 files, ≤150
  changed lines

**Execution:** `superpowers:subagent-driven-development` — one fresh-context Sonnet subagent per
task, each instructed explicitly: *perform only work you can fully evaluate and understand; if
anything is ambiguous or beyond confident evaluation, stop and return it rather than guessing.*
Opus reviews each completed task via `superpowers:requesting-code-review` before the next
starts, and takes subagent pushback seriously — a subagent catching a planning mistake is a
feature, so verify the claim rather than dismissing it.

**`opus-supervised`, never delegated:** anything touching the CGEvent tap, the Accessibility
paste path, or `PasteboardService`. A subtly wrong change there silently breaks system-wide
input and is not reachable by automated tests.

**Canonical verification gate:** `Scripts/verify.sh` — `swift build` → `swift test` → `just
package` → clean `git status`. Every subagent return is verified by running this one command,
never by hand-composing the steps. Task-specific checks are additive, not substitutes.

**Usage-limit fallback ladder.** When a subagent dies on a usage limit (returns ~0 tokens,
"stalled", or empty): check `git status` first — partial work is often already on disk, and a
blind redispatch either wastes tokens or clobbers progress. Resume via `SendMessage` if the
agent still holds context; start fresh if it returned nothing. Step down a tier rather than
stopping, and note which model was used.

**HANDOFF.md** at the project root is written or updated before ending any turn that is blocked
on Dan or that stops mid-plan: current state and what was verified, which plan blocks are
done / in progress / pending, open decisions with a recommendation, and exact next steps. A
fresh session must be able to resume from HANDOFF.md alone — this is what makes clearing
context between phases cheap.

**Human checkpoints** — where no automated check reaches:

1. Baseline verification, before any change
2. After hold-to-talk: does the start/stop timing *feel* right
3. After the indicator: does it look right, and does it always disappear
4. End to end: does text actually land in a third-party app

## 7. Testing

The existing XCTest suite is the regression net. `swift test` must be green at every task
boundary — non-negotiable, including throughout the strip phase.

New units are TDD-first: env parsing, provider selection, hold-duration policy. Each is written
as a pure function or value type specifically so it is testable without a running app.

Surfaces that cannot be unit-tested — event tap, paste simulation, NSPanel presentation — get
explicit manual verification steps written into the plan, performed by Dan at the human
checkpoints above.

## 8. Permissions (for README)

- **Microphone** — recording
- **Accessibility** — simulating ⌘V, reading key events system-wide
- **Input Monitoring** — global hotkey across apps
- No Screen Recording (no system-audio capture)

## 9. Out of scope for v1

- Meeting / system-audio capture (separate project)
- Voice-commanded editing of selected text (upstream "Edit Mode")
- Multi-user, cloud sync, any server component
- Settings UI — `.env` is the config surface
- Live waveform / level meter in the indicator (**v2**; metering already exists upstream)
- Auto-update (**recoverable from `upstream/main` if ever needed**)
