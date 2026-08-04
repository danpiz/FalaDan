# Removed features

Subsystems deleted from FalaDan in the Phase 5 strip, recorded here so they can be rebuilt
deliberately rather than reconstructed from a diff.

**This is a description of what was removed and why, not an argument for putting it back.** Each
was working code at the time of deletion. If you want one again, read its section, then read the
commit named at the end of it — the code is not gone, it is behind you in git.

Everything here was inherited from [MiniWhisper](https://github.com/andyhtran/MiniWhisper) (MIT)
at the fork. None of it was written for FalaDan.

## What was NOT removed

Listed first, because the obvious assumption is wrong. These survived the strip and are live:

- **Text replacements** — user-defined find/replace applied after transcription
- **Spoken symbols** — say "open paren", get `(`. Off by default
- **Usage stats** — local counters for recordings, speaking time, words, average WPM
- **Recording history** — the last 500 transcripts, on disk, with re-transcribe

---

## 1. `faladancli` — the command-line target

**Size:** ~2,990 lines across 12 files in `Sources/FalaDanCLI/`. About a fifth of the codebase.

**What it was:** a second executable, shipped inside the app bundle at
`Contents/Resources/faladancli`, that transcribed **audio files** from a terminal. Entirely
separate from hold-to-talk dictation — it shared the model providers and nothing else.

Its real audience was AI agents, not humans. The bare help text led with:

```
Start here (for AI agents):
  faladancli skills get core
  faladancli skills get timestamps
  faladancli skills list --json
```

**Commands:**

| Command | Purpose |
|---|---|
| `transcribe <audio>` | Transcribe a file with Parakeet or Whisper. Supported `--from`/`--to` and `--offset`/`--duration` range clipping, mutually exclusive within each pair |
| `models status` | Local model readiness |
| `models install parakeet\|whisper` | Download a model without launching the app |
| `paths` | Where models, skills and binaries live |
| `doctor` | Diagnose a broken local setup |
| `skills list [--json]` / `skills get <name>` | Print version-matched guides written for an agent to read |
| `skill status` / `skill install [--apply]` | Install a discovery stub so an agent finds the CLI |
| `version`, `--help`, `--help --full` | |

**Notable pieces worth knowing about if rebuilding:**

- `AudioRangeClipper.swift` — resolved a range request against a file's real duration and
  rejected contradictory flags (`--from` with `--offset`). Self-contained and reusable.
- `TranscribeRendering.swift` — output formatting, including timed transcripts.
- `WhisperCLITranscriber.swift` — a whisper.cpp path independent of the app's provider.
- `Console.swift` — stdout/stderr conventions and exit codes (`2` for usage errors).

**Why removed:** FalaDan is a dictation app. Batch file transcription for agents is a different
product that happened to share a repo. Nothing in the menu bar app called into it.

**If you rebuild it:** it does not need to live in this repo. It is genuinely standalone, and the
only coupling was the shared model-download paths.

---

## 2. `CLIInstallManager`

**Size:** one file, `Sources/FalaDan/Services/CLIInstallManager.swift`.

**What it was:** the Settings-window control that put `faladancli` on your `PATH`. It copied the
bundled binary to a managed location and symlinked it into the user's local bin directory.

Careful about a few things worth preserving if this is ever rebuilt:

- **Conflict detection.** It refused to clobber a symlink or file it did not create, checking
  ownership before touching anything (`isOurSymlink`, `conflictingItemExists`).
- **Hash-based staleness.** Compared a sha256 of the bundled binary against the installed one, so
  "installed" and "up to date" were different states.
- Offered `uninstall()` and `revealInstallLocation()` rather than leaving orphans.

**Why removed:** it installs the CLI, and the CLI is gone. Orphaned by section 1.

---

## 3. Sparkle auto-update

**Size:** ~742 lines across 9 files in `Sources/FalaDan/Updater/`, plus `Views/UpdateBanner.swift`,
a section of `Views/SettingsWindowView.swift`, and build-script plumbing.

**What it was:** in-app update checking against an appcast, with a menu bar banner when an update
was available.

**Architecture, which was better than it needed to be:**

- `UpdaterProviding` — the protocol, so the rest of the app never saw Sparkle
- `SparkleUpdaterController` / `DisabledUpdaterController` — real and null implementations
- `UpdaterFactory` — chose between them at launch, requiring **both** a non-empty `SUFeedURL`
  **and** a Developer ID signature. A `just dev` build got the null one on both counts
- `UpdateState`, `UpdateDriver`, `UpdaterDefaults`, `UpdaterEnvironment`
- `UpdateSimulator` — drove the UI through happy/failure scenarios via
  `defaults write com.faladan.dev UpdateSimulatorScenario happy`, so the update UI could be
  tested without publishing anything. The nicest piece here

**Build-side plumbing that went with it:** `ENABLE_SPARKLE` in `Package.swift`, `SUFeedURL` and
`SUEnableAutomaticChecks` in `Scripts/build-app.sh`, `Scripts/make-appcast.sh`,
`Scripts/verify-appcast.sh`, `Scripts/test-update-flow.sh`, `appcast.xml`, and the
`SU_PUBLIC_ED_KEY` in `version.env`.

**Why removed:** no FalaDan release has ever been published, and updating means running
`just dev`. Deleting it also retired a real problem: `SU_PUBLIC_ED_KEY` was still **upstream's**
Ed25519 public key, inherited at the fork. FalaDan trusted a key it did not hold the private half
of — so it could not sign an update it would itself accept, while upstream could produce one.

**If you rebuild it:** generate a keypair first (`generate_keys` from sparkle-tools), and keep
`UpdaterFactory`'s two-gate check — it is what kept dev builds from ever polling.

---

## 4. `ClaudeSkillManager` and the `mw-replace` skill

**Size:** one file plus `Sources/FalaDan/Resources/skills/mw-replace/SKILL.md`.

**What it was:** shipped a Claude Code skill that let an agent **add a text replacement rule** to
FalaDan by voice or chat. You could say "replace clod with Claude" to Claude Code and it would
append the rule to FalaDan's config and ping the app to reload it.

The skill's own description:

> Add a text replacement rule to FalaDan by appending a find/replace pair to its config and
> pinging the app to reload. Use when the user asks to replace one phrase with another, fix a
> recurring mis-transcription, or says things like "X → Y" or "replace X with Y".

**How it worked, which is the part worth keeping:**

- The app bundle carried the canonical `SKILL.md`
- An editable copy went to `~/Documents/FalaDan/skills/mw-replace/SKILL.md`
- When toggled on, a real copy was installed to `~/.claude/skills/mw-replace/`
- Truth was **hash-based, not version-numbered**: a `.mw-sha` marker file held the sha256 of
  whatever the app last wrote. Comparing bundled hash, active-file hash and marker distinguished
  "unmodified", "user-edited", and "stale" — so it never overwrote an edit the user had made
- Reload was signalled by a Darwin notification, `com.faladan.config-changed`, which
  `AppState` still observes

**Note the `mw-` prefix.** This was MiniWhisper's, never renamed for FalaDan.

**Why removed:** never enabled, and it is the only feature that wrote into `~/.claude/`.

**Important:** the feature it drove — **text replacements — was NOT removed.** Rules are still
live and still editable in Settings. What went is the agent-facing way to add them. The Darwin
notification `AppState` listens for is also still there, so a rebuild has a working reload path.

---

## Rebuilding any of this

1. Find the deletion commit for the section you want (`git log --oneline --diff-filter=D` will
   find the files).
2. `git show <commit>^:<path>` prints the file as it was.
3. Read this document's section first — it records *why* it went, which is the part the diff
   cannot tell you.

The strip was reviewed and every deletion landed on a green `./Scripts/verify.sh`.
