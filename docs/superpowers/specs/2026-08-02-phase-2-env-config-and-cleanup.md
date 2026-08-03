# FalaDan Phase 2 — Own Your Own Credentials

**Date:** 2026-08-02
**Owner:** Dan (danpiz)
**Supersedes:** the Phase 2 / Phase 3 split in `2026-08-01-faladan-design.md` §5.3–5.4

## 1. Goal

Make FalaDan use Dan's own API key, read from a `.env` file, and delete every path that
borrows credentials from another application. Along the way, LLM cleanup stops being an opt-in
second shortcut and becomes what happens to every dictation.

At the end of Phase 2 the app should: hold Fn → transcribe locally → clean up via Dan's key →
paste, with the OAuth stack gone from the binary.

## 2. Why this is one phase, not two

The original spec put the config loader in Phase 2 and the provider work plus OAuth deletion in
Phase 3. Reading the code showed that split does not survive contact:

- `applyAutoCleanup` reads `EditModeSettings.model` and calls `editModeProvider`. The new client
  cannot replace it without deleting EditMode, and EditMode cannot be deleted without a
  replacement client. They land together or not at all.
- A config loader alone ships nothing observable.

## 3. Current state, as found

**Cleanup is opt-in, not always-on.** `cleanupRequestedForCurrentRecording` is set in exactly
one place — `toggleAutoCleanupRecording()`, the `⌥R` shortcut. A plain hold-Fn dictation pastes
a raw transcript. PRD requirement #4 reads as though cleanup is part of the core path; it never
has been.

**The credential-reuse code is present but dormant.** `EditModeSettings.behavior` defaults to
`.off`, and FalaDan's bundle ID is new so UserDefaults are empty. Nothing reaches for
`~/.codex/auth.json` or sends `user-agent: claude-cli/…` unless AI Editing is switched on in
settings. Dormant is not deleted: it ships in the binary and is one toggle away.

**Graceful degradation already exists.** `applyAutoCleanup` documents its failures as
deliberately silent — "the user gets the raw transcript pasted instead of being blocked on a
model error" — and its `.custom` branch already skips the call outright when unconfigured. The
always-on design inherits this rather than inventing it.

**EditMode's blast radius is 16 files**, including the three largest SwiftUI files in the
project (`MenuBarView` 27KB, `SettingsWindowView` 25KB, `ModelPickerView` 18KB). This is not a
"delete a service" task.

## 4. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Scope | Config + OAuth/EditMode deletion + cleanup client, together | §2 — they are one change |
| Cleanup trigger | **Always on**, `⌥R` deleted | PRD requirement #4; a second shortcut is not what the app promises |
| LLM API shape | **OpenAI-compatible only** | One client covers Groq, OpenAI, **Google Gemini** (via its OpenAI-compatibility layer), OpenRouter, Ollama and local servers — provider choice becomes a base URL, not a code path. Anthropic's Messages API differs and is not worth a second parser in a phase about reducing surface area |
| Default provider | **Groq** | Cleanup latency sits between key-release and paste, where it is felt directly |
| Settings UI | **Kept**; `.env` overrides where a key is set | Deleting ~60KB of SwiftUI is its own project. Precedence keeps the model picker and mic selector working |
| Testing | **Keep extracting pure types** | The `HoldToTalkPolicy` pattern. No protocol-ised `AppState` seam — not worth refactoring code slated for deletion |

## 5. Architecture

### 5.1 EnvConfig

New `Services/Config/EnvConfig.swift`. A pure value type with no dependencies beyond
`Foundation`, parsed once at launch and never mutated.

Load order — first file found wins:
1. `~/Library/Application Support/FalaDan/.env`
2. `.env` at the repo root (development only)

```
LLM_BASE_URL       default https://api.groq.com/openai/v1
LLM_API_KEY        no default — absent disables cleanup
LLM_MODEL          no default — absent disables cleanup
LLM_CLEANUP        on|off, default on
MIN_HOLD_MS        default 150
MIN_TRANSCRIBE_MS  default 300
```

`LLM_MODEL` deliberately has **no default**. Hosted model identifiers are renamed and retired
on their own schedule, and a hardcoded default becomes a silent failure the day it is
deprecated. Requiring it means the failure is "you did not configure this", which is
actionable, instead of "the model you never chose no longer exists". `.env.example` carries a
working value and is easy to keep current; a compiled-in constant is not.

**Supported providers.** Because the client speaks the OpenAI chat-completions shape, provider
choice is entirely a matter of `LLM_BASE_URL` — no code path per provider:

| Provider | `LLM_BASE_URL` |
|---|---|
| Groq (default) | `https://api.groq.com/openai/v1` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai/` |
| OpenAI | `https://api.openai.com/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Ollama / LM Studio (local) | `http://localhost:11434/v1` |

Google's Gemini Flash models are reachable through Google's OpenAI-compatibility layer, so they
need no special casing — verified at
<https://ai.google.dev/gemini-api/docs/openai>. Anthropic is the notable exception, and the
reason it is out of scope: its Messages API is a different request and response shape.

`.env.example` ships the Groq configuration commented alongside a Gemini one, so switching
provider is uncommenting two lines.

Parsing rules, all of which are testable without a filesystem by parsing from a string:

- `KEY=value`, one per line. Surrounding whitespace trimmed. Matching single or double quotes
  around a value are stripped.
- Lines that are blank or start with `#` are ignored.
- A malformed line is skipped, not fatal.
- An unparseable or out-of-range numeric value falls back to its default rather than crashing.
- An absent file is not an error: every value takes its default.

**Precedence:** a key present in `.env` wins over the stored UserDefaults value. A key absent
falls through to the existing settings UI. This is what lets the UI survive.

**No hot reload.** Changing `.env` requires a relaunch, and that is stated in the README rather
than worked around.

**Secrets never get logged.** `EnvConfig`'s debug description redacts any value whose key ends
in `_KEY`.

### 5.2 CleanupClient

New `Services/Cleanup/CleanupClient.swift`. A `URLSession` client posting to
`{LLM_BASE_URL}/chat/completions` with `Authorization: Bearer {LLM_API_KEY}`, carrying
`CleanupPromptStore`'s existing prompt as the system message and the raw transcript as the user
message.

- **Cleanup is skipped entirely — and the raw transcript returned — unless `LLM_CLEANUP` is on
  and both `LLM_API_KEY` and `LLM_MODEL` are set.** This is what preserves the "fully offline
  when a local model is present" goal now that cleanup is on by default, and it is the reason
  a fresh install with no `.env` behaves exactly like Phase 1 rather than erroring on every
  dictation.
- Failures stay silent and fall back to raw text, as today. A cleanup outage must never cost
  the user their words.
- A timeout bounds the wait, because this sits between key-release and paste. Exceeding it
  returns raw text.

Request and response shaping are pure functions over strings, separate from the networking, so
they can be tested without a server.

### 5.3 Always-on cleanup

`applyCleanup` changes meaning from "the user pressed `⌥R`" to "cleanup is configured and
enabled". Concretely:

- `stopAndTranscribeFlow` passes `applyCleanup:` from config, not from
  `cleanupRequestedForCurrentRecording`.
- `cleanupRequestedForCurrentRecording`, `toggleAutoCleanupRecording()`, and the
  `.autoCleanupRecording` shortcut are deleted.
- `applyAutoCleanup` keeps its shape — the guard, the silent fallback, the history metadata —
  but calls `CleanupClient` instead of `EditModeProvider` / `CustomEditProvider`.
- `isEditModeProcessing` is **renamed, not deleted**, to `isCleanupProcessing`. It drives the
  menu bar's working indicator; deleting it loses the only signal that cleanup is running.

### 5.4 Deletions

`OAuthApiClient`, `OAuthCredentialStore`, `OAuthRefreshTrigger`, `AppState+EditMode`,
`EditModeProvider`, `CustomEditProvider`, `EditModeSettings`, `CustomEditProviderSettings`, the
`.editSelection` and `.autoCleanupRecording` shortcut names and their `HotkeyManager` setup, and
the EditMode sections of `SettingsWindowView`, `SettingsPopoverView`, `MenuBarView`, and
`ModelPickerView`.

Removing cases from `CustomShortcutName` is safe — `CustomShortcutStorage.loadAll` skips raw
values it does not recognise — but it silently orphans any custom binding, which the README
should mention.

**Order matters.** Delete inward-out, each step ending on a green build: the OAuth services
first (fewest dependents), then the EditMode services and models, then the shortcut wiring, then
the UI sections last. The UI files are the largest and the most likely to cascade, so they are
touched when nothing else still depends on the types being removed.

### 5.5 Phase 1 leftover: generation token

`startRecordingFlow`'s `guard !captureTransitionInFlight` sits above the `defer` that ends the
hold-to-talk start window, so a hold start bailing there leaves the window open and its release
can be consumed by the flow already running. Hoisting the `defer` makes it worse. The fix is a
generation counter incremented by `beginHoldToTalk`, stamped on the parked release, and checked
before it is applied.

Reaching the bug needs two starts within about one main-actor hop, so it is not urgent — but it
is in the state machine Phase 2 touches, and that machine broke twice already.

## 6. Testing

`./Scripts/verify.sh` green at every task boundary, as always.

New pure units get TDD-first tests: `.env` parsing (including malformed lines, quoted values,
absent file, out-of-range numbers), config precedence over UserDefaults, cleanup request and
response shaping, and the generation-token decision.

`CleanupClient`'s networking is exercised via a stubbed `URLProtocol`, which needs no server and
no key.

Not automatically testable, and therefore Dan's to verify: that cleanup actually improves the
transcript, that the added latency is acceptable, and that dictation still works with no `.env`
present at all.

## 7. Risks

**Latency becomes a felt property.** Cleanup now sits on every dictation, between key-release
and text appearing. Groq is the default for this reason. Worth measuring on Dan's own voice
early rather than discovering it at the end.

**The offline goal now depends on a code path, not on configuration.** With cleanup on by
default, "fully offline when a local model is present" is only true because a missing
`LLM_API_KEY` skips the call. That skip is load-bearing and must be tested.

**The deletion cascades into three large SwiftUI files.** Mitigated by the inward-out order in
§5.4 and by each step ending green.

## 8. Out of scope

- Deleting the settings UI (§4)
- Anthropic's Messages API (§4)
- Hot-reloading `.env` (§5.1)
- The transcription provider's own `.env` keys — Phase 3
- The floating recording indicator — Phase 4
- The CLI target, Sparkle, replacement rules, spoken symbols, analytics, skill manager — Phase 5
