# FalaDan

macOS menu bar app for system-wide dictation. Hold a key, talk, release, and cleaned-up text
lands at the cursor. No accounts, no telemetry, fully offline when a local model is present.

Fork of [MiniWhisper](https://github.com/andyhtran/MiniWhisper) (MIT), retained as the
`upstream` remote.

**Read `docs/superpowers/specs/2026-08-01-faladan-design.md` before proposing changes.** It is
the source of truth and supersedes `wispr-clone-prd_1.md`.

## Toolchain

CLI-only — no Xcode. macOS 14.0+, Swift 6.0+, SPM. `just` is the task runner.

```bash
./Scripts/verify.sh           # THE gate: build + test + clean-tree check
./Scripts/verify.sh --dirty   # same, minus the clean-tree check (mid-task)
just dev                      # kill existing, build, package, launch
just build                    # debug build
just clean                    # remove build artifacts
```

**Never hand-compose the build/test commands — run `./Scripts/verify.sh`.** Bare `swift test`
does not work on a Command Line Tools install: Swift Testing's framework and its interop dylib
sit in two different unsearched directories, so it fails first at compile time and then at
dlopen. The script supplies both paths. See its header comment.

## Standing constraints

**Never reintroduce credential reuse.** Upstream reads OAuth tokens from the Keychain and
`~/.codex/auth.json`, then spoofs Claude Code / Codex CLI identity headers to call Anthropic and
OpenAI. That entire path is deliberately deleted. All API access uses Dan's own keys, read from
`.env`, against each provider's documented API. No header spoofing, no CLI impersonation, no
borrowing another app's credentials.

**Config lives in `.env`, not a settings UI.** `~/Library/Application Support/FalaDan/.env`,
falling back to `$PWD/.env`. Parsed once at launch into an immutable struct. Never commit a
real `.env`. This is live as of Phase 2 — see `.env.example` for every supported key and its
default.

The fallback is cwd-relative, not repo-relative, so it does **not** fire under `just dev`: that
installs to `/Applications` and launches with `open`, giving the app a working directory of `/`.
Put the file in Application Support. `AppDelegate` logs the parsed config (key redacted) at
launch — that line is the only way to tell "no `.env` found" from "cleanup ran and changed
nothing", since cleanup failure is silent by design.

**Keep the app working.** Strategy is rewire-first, strip-last. Behavior changes land one at a
time on a running app; dead subsystems are deleted at the end. `./Scripts/verify.sh` must pass
at every task boundary — including throughout the strip phase.

## Orchestration

Opus plans and reviews. Sonnet executes. This is a design constraint, not a preference — see
`.claude/skills/faladan-orchestration/SKILL.md` for the full protocol, and follow it for any
non-trivial work.

The short version: every plan task carries a file allowlist, a do-not-touch list, an executor
tag (`sonnet-alone` / `opus-supervised`), a test written first, and a checkable "done means".
Anything touching the CGEvent tap, the Accessibility paste path, or `PasteboardService` is
`opus-supervised` and never delegated — a subtly wrong change there silently breaks system-wide
input and no test catches it. Write `HANDOFF.md` before ending a turn that is blocked on Dan or
stops mid-plan.

## Manual verification

Three things no test reaches. Ask Dan; do not claim them yourself.

1. Hold-to-talk start/stop timing *feels* right
2. The recording indicator appears, and always disappears — including on the discard path
3. Text actually lands in a third-party app

## Permissions

FalaDan needs exactly **two**: **Microphone** and **Accessibility**. That is what
`PermissionsManager` checks, and it is the whole list.

**Input Monitoring is not required.** It is the weaker grant that lets *listen-only* event taps
work in apps without Accessibility. FalaDan's Fn tap is a modifying tap — it swallows the Fn
press so macOS does not fire its own 🌐 action — and modifying taps need Accessibility, which
subsumes Input Monitoring. The original PRD listed three permissions; the implementation says
two.

### When the hotkey does nothing

Almost always Accessibility, and almost always because the grant no longer matches the binary.
macOS remembers a grant by the app's *designated requirement*. Under ad-hoc signing that pins a
cdhash which changes on every build, so each `just dev` voids the grant while System Settings
keeps showing the app ticked.

`Scripts/setup-dev-signing.sh` creates a stable self-signed identity that fixes this
permanently — run it once per machine. `Scripts/sign-dev-app.sh` then finds it by name, with no
environment variable to set. Confirm a build picked it up with:

```bash
codesign -dv --verbose=2 /Applications/FalaDan.app 2>&1 | grep Authority
# want: Authority=FalaDan Dev Signing    (NOT "Signature=adhoc")
```

If a grant is already stale, toggling it off and on does not help — the row itself is bound to
the dead signature. Run `just reset-tcc` and grant again.
