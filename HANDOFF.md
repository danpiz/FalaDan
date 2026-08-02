# HANDOFF — FalaDan Phase 1

**State:** code complete, blocked on manual verification by Dan.
**Branch:** `setup/scaffolding`, 13 commits ahead of `main`. Working tree clean.
**Verified:** `./Scripts/verify.sh` — build clean, **165 tests in 33 suites passing**.

## What Phase 1 did

Forked `andyhtran/MiniWhisper` → `danpiz/FalaDan`, renamed everything, and converted the
recording hotkey from press-to-toggle to true hold-to-talk on the bare **Fn** key, with a
150 ms minimum-hold guard so a brushed key is discarded rather than transcribed.

Design: `docs/superpowers/specs/2026-08-01-faladan-design.md`
Plan: `docs/superpowers/plans/2026-08-01-rename-and-hold-to-talk.md`
Full execution record incl. every review finding and ruling:
`.superpowers/sdd/2026-08-01-rename-and-hold-to-talk/progress.md`

## What Dan needs to do next

```bash
brew install just      # not currently installed
just dev               # builds, signs, installs to /Applications, launches
```

Then grant **Microphone**, **Accessibility**, and **Input Monitoring** in System Settings →
Privacy & Security. A rebuild can silently reset the Accessibility grant, which presents as
the hotkey simply not firing.

Four checks. Nothing automated reaches any of them.

1. **Hold-to-talk timing.** Hold Fn, speak, release. Does recording start and stop with the
   key, with no clipped first syllable and no lag after release?
2. **Tap guard.** Brush Fn quickly without speaking. Nothing transcribed, nothing pasted, and
   — this is the part that was broken and fixed — **no "Canceled recording" row in history**.
3. **Fn as a modifier.** Hold Fn for a beat, then press `←`. Nothing should be transcribed or
   pasted. This was the last bug found; it previously pasted ambient room audio into whatever
   app you were navigating.
4. **End to end.** Cursor in Notes or Slack, hold Fn, speak a sentence, release. Text lands at
   the cursor, prior clipboard restored.

If all four pass:

```bash
git checkout main
git merge --no-ff setup/scaffolding -m "Merge Phase 1: FalaDan rename and hold-to-talk"
./Scripts/verify.sh
git push -u origin main
```

If any fail, record which one and the exact observed behavior here, and diagnose with
`superpowers:systematic-debugging` before attempting a fix.

## Things worth knowing before touching this code

- **`./Scripts/verify.sh` is the only verification command.** Bare `swift test` fails on this
  machine: Command Line Tools ships Swift Testing's framework and its interop dylib in two
  different unsearched directories, so it fails first at compile and then at dlopen.
- **Never reintroduce credential reuse.** Upstream reads OAuth tokens from the Keychain and
  `~/.codex/auth.json` and spoofs Claude Code / Codex CLI identity headers. That path is
  deliberately deleted. All API access uses Dan's own keys from `.env`.
- **Fn, not Right Option.** The bare-modifier tap is Fn-only by design; any other bare modifier
  would mean generalizing four files inside the event tap.

## Deferred, with reasons

- **Generation token on the parked hold release.** One `startRecordingFlow` exit sits above the
  `defer` that closes the hold window, so a hold start bailing there can have its release
  consumed by the flow already running. Reaching it needs two starts within ~one main-actor
  hop. Documented in `AppState.swift`, not papered over. Phase 2.
- **Edit mode's 0.5 s floor** is now stricter than recording's 0.3 s. Edit mode is deleted in
  Phase 3.
- **`AppState.toggleRecording()`** has no remaining call site. Retained deliberately; the strip
  phase decides its fate.
- `.github/workflows/ci.yml`, `appcast.xml`, `ReleaseNotes/`, and the MiniWhisper wordmark
  still carry the old name — all deleted or rewritten in Phase 5.
- `Package.swift` intentionally keeps one `andyhtran/MiniWhisper` URL: the upstream
  whisper.xcframework release asset. **Rewriting it breaks the build.**

## Then: Phase 2

`.env` config loader (`EnvConfig`) and provider selection. Needs its own spec read and plan —
see the "Next plans" section at the end of the Phase 1 plan.
