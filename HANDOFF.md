# HANDOFF — FalaDan Phase 2

**State:** Tasks 1–10 done. Final whole-branch review done, five fix rounds applied.
Only **Task 11 — Dan's manual verification** remains, then the branch is ready to merge.
**Branch:** `phase-2/env-config-and-cleanup`, off `main` @ `28318c2`. Working tree clean.
**Verified:** `./Scripts/verify.sh` — **226 tests in 42 suites passing**, at `35237f4`.

## What Phase 2 did

FalaDan now uses Dan's own API key from a `.env` file, cleans up **every** dictation through an
OpenAI-compatible LLM, and contains no code that borrows another application's credentials.

The phase's goal check — this must keep printing nothing:

```bash
grep -rn --include="*.swift" -e "codex/auth" -e "claude-cli" -e "codex_cli" -e "OAuth" Sources/
```

Spec: `docs/superpowers/specs/2026-08-02-phase-2-env-config-and-cleanup.md`
Plan: `docs/superpowers/plans/2026-08-02-phase-2-env-config-and-cleanup.md`
Full execution record — every review finding, every ruling, every deferred minor:
`.superpowers/sdd/2026-08-02-phase-2-env-config-and-cleanup/progress.md` (git-ignored)

## Done

| Task | Outcome |
|---|---|
| 1. `EnvConfig` | 1 fix round — guard was not self-sufficient |
| 2. `CleanupClient` | 1 fix round — quoted values leaked whitespace into the key |
| 3. Always-on cleanup | 1 fix round — failure log said only "error 2" |
| 4. Delete `⌥R` shortcut | clean |
| 5. Delete OAuth stack | clean — **phase goal met** |
| 6. Delete EditMode (18 files) | clean — found a stranded Keychain key |
| 7. Rename flag, tidy UI, sweep key | 1 fix round — migration gave up on failure |
| 8. Wire `MIN_HOLD_MS` / `MIN_TRANSCRIBE_MS` | clean |
| 9. Generation token | clean at the time; the final review corrected its comments |
| 10. `.env.example`, README, docs | clean |
| — | Out of plan: strip `<think>` reasoning blocks |
| — | Final whole-branch review: 1 Critical, 3 Important, 5 fix rounds |

## Remaining — Task 11, Dan at the keyboard

In this order:

1. **Move `.env` aside first and dictate with no config at all.** Most important check in the
   phase: cleanup is on by default, so `isCleanupConfigured` returning false is the only thing
   stopping a failed network call per utterance. Behaviour must be identical to Phase 1.
2. Restore `.env`, dictate *"um so the meeting is at three pm scratch that four pm and their
   going to deploy it"* — expect *"The meeting is at 4pm, and they're going to deploy it."*
3. **Judge the latency.** Measured at ~0.5s with `llama-3.3-70b-versatile`. Only Dan can say
   whether that feels right; if not, the answer is a faster model or `LLM_CLEANUP=off`, not code.
4. Set an invalid key and confirm dictation still pastes raw text with no dialog. Then check
   the log says `HTTP 401` rather than `error 2`.
5. Dictate a proper noun (*"tell Sarah the meeting moved to Lisbon"*) — `applyFormatting` runs
   *after* cleanup, so with `capitalization == .casual` it can lowercase what cleanup correctly
   capitalised. Pre-existing ordering, now universal.

New in the final review — a diagnostic that did not exist before:

```bash
# /usr/bin/log, not `log` — zsh has a builtin of that name that shadows it
/usr/bin/log show --predicate 'subsystem == "com.faladan.dev"' --last 5m | grep "Loaded config"
```

Prints host, whether the key and model are set, and whether cleanup is configured. Nothing
user-supplied is echoed. This is the only way to tell "no `.env` found" from "cleanup ran and
changed nothing", since cleanup failure is silent by design.

**Then** `superpowers:finishing-a-development-branch`.

## Needs Dan's decision — before any release

`version.env`'s `SU_PUBLIC_ED_KEY` is **upstream's** Sparkle public key, inherited at the fork
and never changed. Dan cannot sign an update this app would accept; upstream could produce one
(they could not deliver it — the feed is under Dan's control now). Run `generate_keys` from
sparkle-tools and replace it before publishing anything. `appcast.xml` is empty and says so.

Not urgent: no release exists, and an unsigned or wrongly-signed update fails closed — Sparkle
rejects it.

## Dan's environment, already set up

- `~/Library/Application Support/FalaDan/.env`, mode 600 — Groq key, `llama-3.3-70b-versatile`
- Local signing identity exists, so Accessibility survives rebuilds. Verify with:
  `codesign -dv --verbose=2 /Applications/FalaDan.app 2>&1 | grep Authority` → want
  `Authority=FalaDan Dev Signing`, **not** `Signature=adhoc`

## Things that will bite otherwise

- **`./Scripts/verify.sh` is the only verification command.** Bare `swift test` fails on this
  machine — Swift Testing's framework and its interop dylib sit in two unsearched directories.
- **Never reintroduce credential reuse.** The grep at the top is the guard.
- **Do not reintroduce a shape heuristic in `EnvConfig.description`.** Three fix rounds tried to
  echo the model id and base URL while filtering anything key-shaped; each closed one hole and
  opened another. A key can land in any field, and a UUID-format token is structurally identical
  to an ordinary identifier — there is no rule to find. It now echoes no user-supplied string.
- **The `.env` fallback is cwd-relative, not repo-relative.** `just dev` launches from
  `/Applications` with `open`, so a repo-root `.env` is silently ignored.
- **Model benchmark (Dan's key, real prompt):** `llama-3.3-70b-versatile` 0.51s (best, nothing
  dropped) · `llama-3.1-8b-instant` 0.48s (drops a clause) · `openai/gpt-oss-20b` 0.83s ·
  `qwen/qwen3.6-27b` 4.13s and emits `<think>` blocks.
- **Reasoning models paste their chain of thought** unless stripped. `stripReasoningBlocks`
  handles it; there is a verbatim-capture fixture in `CleanupReasoningFixtureTests.swift`. It
  searches the string directly — searching a `lowercased()` copy and reusing those indices is
  the bug the final review caught, and it corrupts or crashes on non-ASCII.

## Deferred, with reasons

- Edit mode's old 0.5s floor is gone with the feature; recording's floor is now `.env`-driven.
- `MenuBarView.cleanupCharThreshold` lowered 30k → 4k by estimate, not measurement.
- `unrelatedShortcutsAllSurvive` asserts a count a duplicate name would also satisfy.
- `AppState.toggleRecording()` still has no callers. Retained deliberately for the strip phase —
  but it now carries a precondition, and it is the one path that could apply a stale parked
  release. Do not give it a caller without reading that comment.
- A fast double-brush during device open can show a spurious "Recording Too Short" toast. Design
  intent is that a brush leaves no trace; nothing is pasted and no history row is written.
- A key pasted *after* a scheme (`https://gsk_…`) still echoes as the logged host. Defending it
  means guessing key-vs-hostname by shape, which is the trap above.
- `llmModel` renders verbatim in the History popover via `RecordingCleanup.backendModel`.
- Leftovers from the fork: `ReleaseNotes/MiniWhisper-1.10.0.html`,
  `.github/MiniWhisper-wordmark.svg`, and an "Andy Tran" copyright in the Info.plist.
