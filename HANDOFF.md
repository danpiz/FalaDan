# HANDOFF — FalaDan

**State:** Phases 2–5 are code-complete and reviewed. **Three branches are unmerged and waiting
on Dan's manual verification.**
**Verified:** `./Scripts/verify.sh` passes on each branch. Latest (`phase-5/strip`): **239 tests
in 45 suites**.

## Branch stack — read this first

They are stacked, each branched off the last. Merge in order, or merge the tip once all three
manual passes are done.

```
main
 └── phase-4/recording-indicator   ← floating pill        (239 tests)
      └── phase-3/groq-transcription ← Groq as a model    (256 tests)
           └── phase-5/strip         ← deletions          (239 tests)
```

Phase 5's lower count is correct — the updater's tests went with the updater.

## What each branch does, and what Dan must check

### `phase-4/recording-indicator`

A pill at the bottom of the screen while recording, shown only after the hold clears
`MIN_HOLD_MS` so a brushed Fn never flashes it, and dismissed on all six paths a recording can
end.

1. Hold Fn two seconds — pill appears bottom centre, goes on release
2. **Brush Fn fifteen or twenty times** — must never flash, never stick
3. Hold, then Esc — pill goes, recording cancelled
4. Dictate into a **full-screen** app — pill visible over it, text still lands
5. **Focus check:** click into a text field in another app, dictate, confirm the caret does not
   move and the text arrives there. The panel must never take focus, or the paste goes nowhere

### `phase-3/groq-transcription`

A fourth model-picker row, **Groq**, configured by `STT_BASE_URL` / `STT_API_KEY` / `STT_MODEL`
in `.env`. Hidden unless both a key and a model are set.

1. No `STT_*` — row absent, Parakeet unchanged
2. Configure and relaunch — row present, subtitle shows the model id
3. **The point of the phase:** dictate the same difficult passage on Parakeet and on Groq, back
   to back, and decide whether the accuracy is worth the audio upload
4. Switch back to Default mid-session — no relaunch needed
5. Select Groq, remove the key, relaunch — falls back to Parakeet, app usable, log says why

### `phase-5/strip`

Deleted the `faladancli` target and its installer, Sparkle auto-update, and the Claude Code skill
manager. **Kept** text replacements, spoken symbols, usage stats and recording history — Dan's
call, made after using the app.

1. `just dev` — builds, installs, launches
2. `codesign -dv --verbose=2 /Applications/FalaDan.app 2>&1 | grep Authority` → wants
   `Authority=FalaDan Dev Signing`, **not** `Signature=adhoc`. Sparkle's framework shared the
   signing path, so this is the check that matters most here
3. **Text replacements still work** — add a rule in Settings and confirm it applies
4. Settings opens with no empty sections where the CLI, update and skill controls were
5. Hold Fn, dictate — text lands

## What was deleted, and how to get it back

`docs/removed-features.md` describes each removed subsystem — what it did, how it worked, and why
it went — written *before* deletion so it is accurate rather than reconstructed from a diff. Read
it before rebuilding any of them; the code itself is behind you in git.

## Diagnostics

```bash
# /usr/bin/log, not `log` — zsh has a builtin of that name that shadows it
/usr/bin/log show --predicate 'subsystem == "com.faladan.dev"' --last 5m | grep "Loaded config"
```

Prints the host, whether each key is set, and whether cleanup is configured. Nothing
user-supplied is echoed. This is the only way to tell "no `.env` found" from "cleanup ran and
changed nothing", since cleanup failure is silent by design.

## Things that will bite otherwise

- **`./Scripts/verify.sh` is the only verification command.** Bare `swift test` fails on this
  machine — Swift Testing's framework and its interop dylib sit in two unsearched directories.
- **Never reintroduce credential reuse.** This must keep printing nothing:
  `grep -rn --include="*.swift" -e "codex/auth" -e "claude-cli" -e "codex_cli" -e "OAuth" Sources/`
- **Do not reintroduce a shape heuristic in `EnvConfig.description`.** Three fix rounds tried to
  echo the model id and base URL while filtering anything key-shaped; each closed one hole and
  opened another. A key can land in any field, and a UUID-format token is structurally identical
  to an ordinary identifier. It now echoes no user-supplied string.
- **`Package.swift`'s `whisper` binary target points at `andyhtran/MiniWhisper` on purpose.** That
  is a real published artifact. "Fixing" it to this fork's URL gives a 404 and a dead build.
- **The `.env` fallback is cwd-relative, not repo-relative.** `just dev` launches from
  `/Applications`, so a repo-root `.env` is silently ignored. Use Application Support.
- **Model benchmark (Dan's key, real prompt):** `llama-3.3-70b-versatile` 0.51s (best) ·
  `llama-3.1-8b-instant` 0.48s (drops a clause) · `openai/gpt-oss-20b` 0.83s ·
  `qwen/qwen3.6-27b` 4.13s and emits `<think>` blocks.
- **Reasoning models paste their chain of thought** unless stripped. `stripReasoningBlocks`
  handles it. It searches the string directly — searching a `lowercased()` copy and reusing those
  indices corrupts or crashes on non-ASCII, which a review caught.

## Deferred, with reasons

- `AppState.toggleRecording()` still has no callers. It survived the strip, which was scoped to
  whole subsystems. It carries a precondition comment and is the one path that could apply a
  stale parked hold release — do not give it a caller without reading that comment.
- A fast double-brush during device open can show a spurious "Recording Too Short" toast.
- `MenuBarView.cleanupCharThreshold` lowered 30k → 4k by estimate, not measurement.
- A key pasted *after* a scheme (`https://gsk_…`) still echoes as the logged host. Defending it
  means guessing key-vs-hostname by shape, which is the trap above.
- `ModelLoadCoordinator`'s `guard mode != .custom, mode != .groq` is a non-exhaustive negative
  test. A fifth remote mode would compile while leaving it stale — which is exactly the bug Phase
  3 shipped once. Invert it to an exhaustive switch if a fifth mode is ever added.
- `CustomProviderError.serverError` puts the raw response body in a toast, and some providers
  echo a key fragment in 401 bodies. Transient UI only, never logged.
- `IntegrationSettingsPage` declares 500pt for content that is now much shorter.
- Orphaned `UserDefaults` keys from the updater (`autoUpdateEnabled`, `SU*`,
  `UpdateSimulatorScenario`). `just reset-settings` clears them.
- `~/Documents/FalaDan/skills/mw-replace/` is left on disk by the deleted skill manager. Nothing
  reads it; `rm -rf` when convenient.
