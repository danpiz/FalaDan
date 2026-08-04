# Phase 5 — Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete three inherited subsystems FalaDan does not use — the CLI target and its
installer, Sparkle auto-update, and the Claude Code skill manager — leaving a smaller app that
does exactly one thing.

**Architecture:** Pure deletion. No behaviour changes, no refactors, no "while I'm here". Each
task removes one subsystem and ends on a green `./Scripts/verify.sh`.

**Record:** `docs/removed-features.md` describes each subsystem and why it went, written before
deletion. **Do not delete or shorten it** — it is the deliverable that makes these reversible.

**Branch base:** `phase-3/groq-transcription`. Baseline: **256 tests in 47 suites**.

## Global Constraints

- **`./Scripts/verify.sh` is the only verification command.** Bare `swift test` does not work on
  this machine. `--dirty` skips the clean-tree check mid-task.
- **Deletion only.** If a task tempts you to improve surviving code, don't. A strip phase that
  also refactors is a strip phase whose review cannot tell the two apart.
- **The test count will fall.** That is expected and correct — tests for deleted code go with it.
  Record the new count; never edit a test to preserve a number, and never delete a test whose
  subject survives.
- **These features are explicitly NOT being removed** and must still work at the end: text
  replacements, spoken symbols, usage stats, recording history. If a deletion breaks one, you
  have cut too wide.
- Do not touch `CustomShortcutMonitor`, `FnStateMachine`, `ModifierTapMonitor`, `EventTapRunLoop`,
  `KeyDownObserver`, `CarbonHotKeyCenter`, `PasteboardService`, or any `RecordingIndicator*` file.
- `AppState+RecordingFlow.swift` and the hold-to-talk path in `AppState.swift` are
  `opus-supervised`. No task here should need them; if one seems to, report BLOCKED.
- Keep `Sources/FalaDan/Resources/skills/` out of the app bundle only via `Scripts/build-app.sh`'s
  existing conditional — see Task 3.

---

### Task 1: Delete the CLI target and its installer

**Executor:** `sonnet-alone`

**Files:**
- Delete: `Sources/FalaDanCLI/` (entire directory, 12 files)
- Delete: `Sources/FalaDan/Services/CLIInstallManager.swift`
- Modify: `Package.swift` — drop the `faladancli` product and the `FalaDanCLI` target
- Modify: `justfile` — drop `swift build --product faladancli`
- Modify: `Scripts/build-app.sh` — drop the CLI copy into `Contents/Resources/`
- Modify: `Sources/FalaDan/Views/SettingsWindowView.swift` — remove the CLI install section
- Modify: `Sources/FalaDan/AppDelegate.swift` — remove any `CLIInstallManager` reference

**Do not touch:** `ClaudeSkillManager.swift` (Task 3 owns it), anything under `Updater/` (Task 2).

- [ ] **Step 1: Find every reference before deleting anything**

```bash
grep -rn "FalaDanCLI\|faladancli\|CLIInstallManager\|CLI_NAME" \
  --include="*.swift" --include="*.sh" --include="Package.swift" --include="justfile" \
  Sources/ Tests/ Scripts/ Package.swift justfile
```

Write the list into your report. Every hit must be resolved by the end of this task.

- [ ] **Step 2: Delete the target directory and the installer**

```bash
git rm -r Sources/FalaDanCLI
git rm Sources/FalaDan/Services/CLIInstallManager.swift
```

- [ ] **Step 3: `Package.swift`**

Remove the `faladancli` product line and the whole `FalaDanCLI` executable target. Leave the
`whisper` binary target alone — the app uses it, and **its URL must keep pointing at
`andyhtran/MiniWhisper`**, which is a real published artifact, not a stale fork reference.

- [ ] **Step 4: `justfile` and `Scripts/build-app.sh`**

Drop `swift build --product faladancli` from the `build` recipe. In `build-app.sh`, remove the
lines that copy the CLI into `Contents/Resources/` and any `install_name_tool` call that targets
it. Leave the `whisper.framework` handling intact.

- [ ] **Step 5: The UI**

Remove the CLI install/uninstall section from `SettingsWindowView.swift` and any
`CLIInstallManager.shared` call in `AppDelegate.swift`. Remove now-unused imports.

- [ ] **Step 6: Verify no reference survives**

Re-run the Step 1 grep. Expected: no output.

- [ ] **Step 7: Run the gate and commit**

Run: `./Scripts/verify.sh --dirty`, then:

```bash
git add -A
git commit -m "Delete the faladancli target and its installer"
```

**Done means:** the Step 1 grep is silent, `./Scripts/verify.sh` passes, and `just build`
succeeds. Report the new test count.

---

### Task 2: Delete Sparkle auto-update

**Executor:** `sonnet-alone`

**Files:**
- Delete: `Sources/FalaDan/Updater/` (9 files)
- Delete: `Sources/FalaDan/Views/UpdateBanner.swift`
- Delete: `Scripts/make-appcast.sh`, `Scripts/verify-appcast.sh`, `Scripts/test-update-flow.sh`
- Delete: `appcast.xml`
- Modify: `Package.swift` — drop the Sparkle dependency, its product, and `ENABLE_SPARKLE`
- Modify: `Scripts/build-app.sh` — drop `SUFeedURL`, `SUEnableAutomaticChecks`, Sparkle framework
  embedding
- Modify: `Scripts/sign-dev-app.sh` — drop Sparkle framework signing
- Modify: `justfile` — drop the `sparkle` recipe group and `test-update`
- Modify: `Sources/FalaDan/Views/SettingsWindowView.swift`, `Views/MenuBarView.swift`,
  `AppDelegate.swift` — remove update UI and wiring
- Modify: `version.env` — remove `SU_PUBLIC_ED_KEY`
- Delete: any test file whose subject is the updater

**Do not touch:** `Scripts/verify.sh`, `Scripts/setup-dev-signing.sh`, `Scripts/sign-dev-app.sh`
beyond the Sparkle framework lines. Signing must keep working — it is what makes Accessibility
grants survive a rebuild.

- [ ] **Step 1: Find every reference**

```bash
grep -rn "Sparkle\|SUFeedURL\|SUEnableAutomaticChecks\|SU_PUBLIC_ED_KEY\|appcast\|Updater\|UpdateBanner" \
  --include="*.swift" --include="*.sh" --include="*.env" --include="Package.swift" --include="justfile" \
  Sources/ Tests/ Scripts/ Package.swift justfile version.env
```

Record the list. Note that `UpdaterEnvironment` may be injected into the SwiftUI environment —
follow it to every consumer before deleting.

- [ ] **Step 2: Delete the code, scripts and appcast**

- [ ] **Step 3: `Package.swift`**

Remove the Sparkle `.package(...)` dependency, the `.product(name: "Sparkle", ...)` from the
FalaDan target's dependencies, and `.define("ENABLE_SPARKLE")` from its `swiftSettings`. Leave
`.enableExperimentalFeature("StrictConcurrency")`.

After editing, delete `Package.resolved` and let the next build regenerate it:
`rm -f Package.resolved`.

- [ ] **Step 4: Build scripts**

In `build-app.sh` remove the `SUFeedURL` / `SUEnableAutomaticChecks` Info.plist keys and the
Sparkle framework copy. In `sign-dev-app.sh` remove the Sparkle framework signing step. **Both
scripts must still sign the app itself** — verify after with:

```bash
codesign -dv --verbose=2 /Applications/FalaDan.app 2>&1 | grep Authority
```

That check belongs in Task 4's manual list, not here; just do not remove the signing.

- [ ] **Step 5: The UI**

Remove the update banner, the Settings "Check for Updates" section, and any menu bar item. Remove
`UpdaterEnvironment` from the SwiftUI environment chain and every `@Environment` that reads it.

- [ ] **Step 6: Tests**

Delete test files whose subject is the updater (`Updater factory`, `Update state`, the
auto-update-preference tests). **Do not delete a test that also covers something surviving** —
read each before removing it.

- [ ] **Step 7: Verify no reference survives, run the gate, commit**

Re-run the Step 1 grep. Expected: no output, except `docs/removed-features.md`, which describes
this deletion and is excluded from the grep paths above.

```bash
git add -A
git commit -m "Delete Sparkle auto-update"
```

**Done means:** grep silent, `./Scripts/verify.sh` passes, `just dev` builds and launches.
Report the new test count.

---

### Task 3: Delete the Claude Code skill manager

**Executor:** `sonnet-alone`

**Files:**
- Delete: `Sources/FalaDan/Services/ClaudeSkillManager.swift`
- Delete: `Sources/FalaDan/Resources/skills/` (the `mw-replace` skill)
- Modify: `Scripts/build-app.sh` — drop the conditional that copies `skills/` into the bundle
- Modify: `Sources/FalaDan/Views/SettingsWindowView.swift` — remove the skill toggle
- Modify: `Sources/FalaDan/AppDelegate.swift` — remove any `ClaudeSkillManager` reference

**Do not touch:** anything to do with text replacements. `ReplacementRule`,
`ReplacementProcessor`, `ReplacementsView` and `ReplacementSettings` all **survive** — the skill
was one way to add a rule, not the rules themselves.

**Keep the Darwin notification.** `AppState.init()` observes `com.faladan.config-changed` to reload replacement settings when the file changes on
disk. That observer stays: editing the config file by hand should still reload.

- [ ] **Step 1: Find every reference**

```bash
grep -rn "ClaudeSkillManager\|mw-replace\|skills" \
  --include="*.swift" --include="*.sh" Sources/ Tests/ Scripts/
```

Sort the hits into "skill manager" and "everything else". The CLI's `skills` command is already
gone with Task 1; anything remaining that is not the skill manager must survive.

- [ ] **Step 2: Delete the manager and the bundled skill**

- [ ] **Step 3: Build script and UI**

Remove the `if [ -d "Sources/FalaDan/Resources/skills" ]` block from `build-app.sh` and the
Settings toggle.

- [ ] **Step 4: Confirm replacements still work**

```bash
grep -rn "com.faladan.config-changed" Sources/FalaDan/
```
Expected: still present in `AppState.swift`.

Run the replacement tests specifically and confirm they pass.

- [ ] **Step 5: Run the gate and commit**

```bash
git add -A
git commit -m "Delete the Claude Code skill manager"
```

**Done means:** grep shows no `ClaudeSkillManager` or `mw-replace`; `ReplacementProcessorTests`
still passes; `./Scripts/verify.sh` passes. Report the new test count.

---

### Task 4: Documentation and final sweep

**Executor:** `sonnet-alone`

**Files:**
- Modify: `README.md` — remove CLI, auto-update and skill references; keep the surviving features
- Modify: `CLAUDE.md` — note the strip is done and point at `docs/removed-features.md`
- Modify: `justfile` — remove any recipe left orphaned by Tasks 1-3
- Delete: `ReleaseNotes/MiniWhisper-1.10.0.html`, `.github/MiniWhisper-wordmark.svg` — fork
  leftovers, unreferenced

- [ ] **Step 1: Sweep for orphans**

```bash
just --list
```
Every recipe listed must still work. Remove any that reference a deleted script.

```bash
grep -rn "MiniWhisper" --include="*.md" --include="*.swift" --include="*.sh" . \
  | grep -v "^./.build" | grep -v removed-features
```
Surviving hits should be only: the fork attribution in `README.md` and `CLAUDE.md`, the `upstream`
remote, and `Package.swift`'s whisper xcframework URL — that last one is a real published artifact
and **must not change**.

- [ ] **Step 2: README**

Remove the CLI section, any auto-update mention, and the skill toggle. The Features list keeps
text replacements, spoken symbols, usage stats and recording history. Add one line pointing at
`docs/removed-features.md`.

- [ ] **Step 3: `CLAUDE.md`**

Add a line under the standing constraints noting the strip is complete and that
`docs/removed-features.md` records what went and why.

- [ ] **Step 4: Verify and commit**

Run: `./Scripts/verify.sh` (full, clean-tree check included).

```bash
git add -A
git commit -m "Update docs after the strip"
```

**Done means:** full verify passes with a clean tree; `just --list` shows no broken recipe.

---

### Task 5: Manual verification — Dan

Not delegable. The strip touched packaging and signing, so:

1. `just dev` — builds, installs, launches
2. `codesign -dv --verbose=2 /Applications/FalaDan.app 2>&1 | grep Authority` → wants
   `Authority=FalaDan Dev Signing`, **not** `Signature=adhoc`. If this regressed, Accessibility
   grants stop surviving rebuilds
3. Hold Fn, dictate — text lands
4. **Text replacements still work** — add a rule in Settings and confirm it applies
5. Settings window opens with no empty sections where the CLI, update and skill controls were
6. No crash on launch from a missing bundled resource
