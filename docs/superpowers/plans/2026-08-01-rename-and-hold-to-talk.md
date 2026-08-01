# FalaDan Phase 1: Rename + Hold-to-Talk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the MiniWhisper fork to FalaDan, then convert the recording hotkey from press-to-toggle to true hold-to-talk with an accidental-tap guard.

**Architecture:** The hold-to-talk delivery plumbing already exists — `ShortcutHandlerRegistry` stores separate keyDown/keyUp handlers, `CustomShortcutMonitor` exposes `onKeyDown`/`onKeyUp`, and both backends (Carbon `.pressed`/`.released` and the Fn modifier tap) already fire both edges. `HotkeyManager.setupEditSelection` uses `onKeyUp` in production today. The only thing missing is the wiring: `setupToggleRecording` registers a keyDown handler alone, which calls `toggleRecording()`. This plan adds the keyUp edge, a pure hold-duration policy, and makes Fn the default binding. **No event-tap code is modified.**

**Tech Stack:** Swift 6, SPM, Swift Testing (`import Testing`, `@Test`, `#expect`), AppKit, Carbon HIToolbox.

## Global Constraints

- Verification is **always** `./Scripts/verify.sh`. Never hand-compose `swift build` / `swift test` — bare `swift test` fails on this machine (Command Line Tools, no Xcode).
- macOS 14.0+, Swift 6.0+, SPM only. No Xcode, no `.xcodeproj`.
- Do **not** modify `Services/Hotkeys/CustomShortcutMonitor.swift`, `FnStateMachine.swift`, `ModifierTapMonitor.swift`, `EventTapRunLoop.swift`, `KeyDownObserver.swift`, `CarbonHotKeyCenter.swift`, or `Services/PasteboardService.swift`. These are `opus-supervised`; a task needing them is a task that must stop and return.
- Do **not** rename the `CustomShortcutName.toggleRecording` enum case. Its raw value is persisted in UserDefaults and referenced by the settings UI. Only its *behavior* changes.
- Never commit a `.env`.
- All 146 existing tests must stay green at every commit.

---

### Task 1: Rename MiniWhisper → FalaDan

**Executor:** `sonnet-alone`

**Files:**
- Rename: `Sources/MiniWhisper/` → `Sources/FalaDan/`
- Rename: `Sources/MiniWhisperCLI/` → `Sources/FalaDanCLI/`
- Rename: `Tests/MiniWhisperTests/` → `Tests/FalaDanTests/`
- Rename: `Sources/FalaDan/MiniWhisperApp.swift` → `Sources/FalaDan/FalaDanApp.swift`
- Rename: `Sources/FalaDan/Resources/MiniWhisper.entitlements` → `Sources/FalaDan/Resources/FalaDan.entitlements`
- Rename: `Sources/FalaDanCLI/MiniWhisperCLI.swift` → `Sources/FalaDanCLI/FalaDanCLI.swift`
- Modify: `Package.swift`, `justfile`, `Scripts/*.sh`

**Do NOT touch:** `docs/`, `CLAUDE.md`, `.claude/`, `wispr-clone-prd_1.md`, `LICENSE`, `README.md`, `appcast.xml`, `ReleaseNotes/`, `.github/`. These legitimately reference MiniWhisper as the upstream project, or are deleted in a later phase. A blind find-and-replace across them corrupts the attribution.

**Interfaces:**
- Consumes: nothing.
- Produces: module name `FalaDan` (so tests use `@testable import FalaDan`), executable products `FalaDan` and `faladancli`, bundle IDs `com.faladan.dev` / `com.faladan.app`.

- [ ] **Step 1: Move the directories and files with git mv**

```bash
git mv Sources/MiniWhisper Sources/FalaDan
git mv Sources/MiniWhisperCLI Sources/FalaDanCLI
git mv Tests/MiniWhisperTests Tests/FalaDanTests
git mv Sources/FalaDan/MiniWhisperApp.swift Sources/FalaDan/FalaDanApp.swift
git mv Sources/FalaDan/Resources/MiniWhisper.entitlements Sources/FalaDan/Resources/FalaDan.entitlements
git mv Sources/FalaDanCLI/MiniWhisperCLI.swift Sources/FalaDanCLI/FalaDanCLI.swift
```

- [ ] **Step 2: Rewrite the identifiers, scoped to code and build files only**

Order matters: the lowercase `miniwhisper` rule must run before the capitalised one would otherwise mangle `com.miniwhisper`.

```bash
FILES=$(git ls-files Sources Tests Scripts Package.swift justfile)
sed -i '' \
  -e 's/com\.miniwhisper/com.faladan/g' \
  -e 's/miniwhispercli/faladancli/g' \
  -e 's/MiniWhisper/FalaDan/g' \
  -e 's/miniwhisper/faladan/g' \
  $FILES
```

- [ ] **Step 3: Restore the whisper.xcframework download URL**

**This step is mandatory and the build fails without it.** `Package.swift`'s `binaryTarget` downloads the prebuilt whisper framework from a release asset on the *upstream* repo:

```
https://github.com/andyhtran/MiniWhisper/releases/download/whisper-xcframework-1.0/whisper.xcframework.zip
```

Step 2 rewrites that path to `andyhtran/FalaDan`, which does not exist — the fetch 404s and nothing compiles. That URL is an external address, not an identifier of ours, so put it back:

```bash
sed -i '' \
  -e 's#github.com/andyhtran/FalaDan#github.com/andyhtran/MiniWhisper#g' \
  Package.swift
```

Verify: `grep -n "andyhtran" Package.swift`
Expected: the URL reads `github.com/andyhtran/MiniWhisper/releases/download/whisper-xcframework-1.0/whisper.xcframework.zip`

Leave the `checksum` untouched — it hashes the downloaded artifact, which has not changed.

- [ ] **Step 4: Verify no stale references survive in code**

Run: `git ls-files Sources Tests Scripts justfile | xargs grep -in "miniwhisper" || echo "CLEAN"`
Expected: `CLEAN`

`Package.swift` is excluded from this check on purpose — it must still contain exactly one `miniwhisper`, the upstream download URL restored in Step 3.

- [ ] **Step 5: Confirm the UserDefaults shortcut key was renamed**

Run: `grep -n "storageKey" Sources/FalaDan/Models/CustomShortcut.swift`
Expected: `private static let storageKey = "FalaDanShortcuts"`

This intentionally orphans any previously saved MiniWhisper shortcuts — FalaDan is a different app with a different bundle ID, and falls back to `defaultShortcuts()`.

- [ ] **Step 6: Run the full gate**

Run: `./Scripts/verify.sh --dirty`
Expected: build succeeds, `Test run with 146 tests in 29 suites passed`, `VERIFY PASSED`

The first build after the rename re-downloads the whisper framework and recompiles everything; expect roughly four minutes.

If it fails with a download or checksum error on the `whisper` target, Step 3 was skipped or applied incorrectly.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Rename MiniWhisper to FalaDan

Mechanical rename across module, targets, bundle IDs, and scripts.
No behavior change; all 146 tests green."
```

**Done means:** `./Scripts/verify.sh --dirty` passes with 146 tests, `grep -in miniwhisper` over `Sources Tests Scripts justfile` returns nothing, `Package.swift` still points the binary target at `andyhtran/MiniWhisper`, and `docs/`, `CLAUDE.md`, `LICENSE`, and `README.md` are byte-for-byte unchanged (`git diff --name-only` confirms).

**Known and accepted:** `.github/workflows/ci.yml`, `appcast.xml`, `ReleaseNotes/`, and `Scripts/update-tap.sh` still reference MiniWhisper. CI and the release tooling are deleted in Phase 5; leaving them stale now avoids widening a mechanical rename into a packaging change.

---

### Task 2: HoldToTalkPolicy

**Executor:** `sonnet-alone`

A pure value type deciding whether a released hold was long enough to be a real dictation attempt. No dependencies, no I/O, no actor isolation — the entire point is that it is testable in isolation.

**Files:**
- Create: `Sources/FalaDan/Services/Hotkeys/HoldToTalkPolicy.swift`
- Create: `Tests/FalaDanTests/HoldToTalkPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum HoldToTalkPolicy` with `static let defaultMinimumHold: TimeInterval` (0.15) and `static func shouldTranscribe(heldFor: TimeInterval, minimum: TimeInterval) -> Bool`. Task 3 calls `shouldTranscribe`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FalaDanTests/HoldToTalkPolicyTests.swift`:

```swift
import Foundation
import Testing

@testable import FalaDan

/// Whether a released hold counts as dictation. A false positive costs an API
/// call and pastes noise at the cursor; a false negative silently drops speech
/// the user actually said, which is far worse.
struct HoldToTalkPolicyTests {
    @Test func aBrushedKeyIsDiscarded() {
        #expect(!HoldToTalkPolicy.shouldTranscribe(heldFor: 0.01, minimum: 0.15))
    }

    @Test func aDeliberateHoldTranscribes() {
        #expect(HoldToTalkPolicy.shouldTranscribe(heldFor: 1.2, minimum: 0.15))
    }

    @Test func holdExactlyAtTheThresholdTranscribes() {
        #expect(HoldToTalkPolicy.shouldTranscribe(heldFor: 0.15, minimum: 0.15))
    }

    @Test func justUnderTheThresholdIsDiscarded() {
        #expect(!HoldToTalkPolicy.shouldTranscribe(heldFor: 0.149, minimum: 0.15))
    }

    /// A clock that jumps backwards (NTP correction mid-hold) must not be read
    /// as a long hold, and must not crash.
    @Test func negativeElapsedTimeIsDiscarded() {
        #expect(!HoldToTalkPolicy.shouldTranscribe(heldFor: -3, minimum: 0.15))
    }

    /// A zero threshold disables the guard entirely, which is the documented
    /// way to opt out via MIN_HOLD_MS=0.
    @Test func zeroThresholdAcceptsAnyNonNegativeHold() {
        #expect(HoldToTalkPolicy.shouldTranscribe(heldFor: 0, minimum: 0))
    }

    @Test func defaultThresholdIs150Milliseconds() {
        #expect(HoldToTalkPolicy.defaultMinimumHold == 0.15)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./Scripts/verify.sh --dirty`
Expected: FAIL — compile error, `cannot find 'HoldToTalkPolicy' in scope`

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/FalaDan/Services/Hotkeys/HoldToTalkPolicy.swift`:

```swift
import Foundation

/// Decides whether a completed hold was a dictation attempt or a brushed key.
///
/// Under press-to-toggle a stray press was harmless — it started a recording the
/// user could see and stop. Under hold-to-talk the press and its release arrive
/// together, so without a floor every accidental brush of the key runs a full
/// transcribe-and-paste cycle: an API call, and noise inserted at the cursor in
/// whatever app happens to be focused.
enum HoldToTalkPolicy {
    /// Long enough to exclude a brushed key, short enough that a clipped
    /// one-word dictation still registers.
    static let defaultMinimumHold: TimeInterval = 0.15

    /// - Parameters:
    ///   - heldFor: seconds between key-down and key-up. Negative values are
    ///     treated as failures rather than trusted: the wall clock can step
    ///     backwards mid-hold, and a backwards jump says nothing about intent.
    ///   - minimum: floor below which the hold is discarded. Zero disables the
    ///     guard.
    static func shouldTranscribe(
        heldFor: TimeInterval,
        minimum: TimeInterval = defaultMinimumHold
    ) -> Bool {
        guard heldFor >= 0 else { return false }
        return heldFor >= minimum
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./Scripts/verify.sh --dirty`
Expected: `Test run with 153 tests in 30 suites passed`, `VERIFY PASSED`

- [ ] **Step 5: Commit**

```bash
git add Sources/FalaDan/Services/Hotkeys/HoldToTalkPolicy.swift Tests/FalaDanTests/HoldToTalkPolicyTests.swift
git commit -m "Add HoldToTalkPolicy to guard against accidental taps

Pure value type; 7 tests covering threshold boundaries, a backwards
clock, and the zero-threshold opt-out."
```

**Done means:** `./Scripts/verify.sh --dirty` reports 153 tests passing, and `HoldToTalkPolicy` has no imports beyond `Foundation`.

---

### Task 3: Wire hold-to-talk through HotkeyManager, AppState, and AppDelegate

**Executor:** `opus-supervised` — do not delegate. A mistake here means a recording that never stops, or a hotkey that silently stops firing, and no automated test catches either.

**Files:**
- Modify: `Sources/FalaDan/Services/Hotkeys/HotkeyManager.swift` (protocol at 6-11, `setupToggleRecording` at 58-62)
- Modify: `Sources/FalaDan/AppState.swift` (recording section, from line 159)
- Modify: `Sources/FalaDan/AppDelegate.swift` (`HotkeyDelegateImpl`, 380-411)

**Do NOT touch:** `CustomShortcutMonitor.swift`, `FnStateMachine.swift`, or any other file in `Services/Hotkeys/` beyond `HotkeyManager.swift`. The registry and both backends already deliver keyUp; nothing below `HotkeyManager` needs to change.

**Interfaces:**
- Consumes: `HoldToTalkPolicy.shouldTranscribe(heldFor:minimum:)` from Task 2. `CustomShortcutMonitor.onKeyDown(for:handler:)` / `.onKeyUp(for:handler:)`, both already present.
- Produces: `HotkeyManagerDelegate.hotkeyDidStartRecording()` and `.hotkeyDidStopRecording()`; `AppState.beginHoldToTalk()` and `AppState.endHoldToTalk()`.

**Note:** `AppState.toggleRecording()` is deliberately left in place. It becomes unused by the hotkey path but is kept so the menu bar and any UI affordance keep working; the strip phase decides its fate. Do not delete it, and do not rename the `.toggleRecording` shortcut name.

- [ ] **Step 1: Replace the toggle delegate method with start/stop**

In `Sources/FalaDan/Services/Hotkeys/HotkeyManager.swift`, change the protocol:

```swift
@MainActor
protocol HotkeyManagerDelegate: AnyObject {
    nonisolated func hotkeyDidStartRecording()
    nonisolated func hotkeyDidStopRecording()
    nonisolated func hotkeyDidCancelRecording()
    nonisolated func hotkeyDidToggleAutoCleanupRecording()
    nonisolated func hotkeyDidEditSelection()
}
```

- [ ] **Step 2: Register both edges for the recording shortcut**

In the same file, replace `setupToggleRecording()` and its call site in `start()`.

Change the `start()` body's first line from `setupToggleRecording()` to `setupHoldToTalkRecording()`, then replace the method:

```swift
    /// Hold-to-talk: the press starts recording and the release ends it.
    ///
    /// Both edges come from machinery that already exists — Carbon reports
    /// `.pressed`/`.released` for chords, and the modifier tap reports both for a
    /// bare Fn. The release is what makes this hold-to-talk rather than a toggle,
    /// so it must never be dropped: `CustomShortcutMonitor` guarantees a keyUp for
    /// every accepted keyDown, including presses stranded by a registration
    /// teardown, which is exactly why recording cannot be left running.
    private func setupHoldToTalkRecording() {
        shortcutMonitor.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.delegate?.hotkeyDidStartRecording()
        }
        shortcutMonitor.onKeyUp(for: .toggleRecording) { [weak self] in
            self?.delegate?.hotkeyDidStopRecording()
        }
    }
```

- [ ] **Step 3: Add the hold-to-talk entry points to AppState**

In `Sources/FalaDan/AppState.swift`, add a stored property next to the other recording state, and two methods immediately after `toggleRecording()`:

```swift
    /// When the current hold began, for the minimum-hold check on release.
    /// Uses the monotonic uptime clock rather than wall time so an NTP step
    /// mid-hold cannot turn a brushed key into a "long" hold.
    private var holdToTalkStartedAt: TimeInterval?

    /// Hotkey pressed. Starts recording immediately — latency here is felt
    /// directly as clipped first syllables.
    func beginHoldToTalk() {
        if editModeContext != nil { return }
        guard !recorder.state.isRecording else { return }

        holdToTalkStartedAt = ProcessInfo.processInfo.systemUptime
        cleanupRequestedForCurrentRecording = false
        startRecording()
    }

    /// Hotkey released. Transcribes a real hold; discards a brushed key.
    ///
    /// Discarding routes through `cancelRecording()` rather than
    /// `stopAndTranscribe()` so no API call is made and nothing is pasted.
    func endHoldToTalk() {
        if editModeContext != nil { return }

        let startedAt = holdToTalkStartedAt
        holdToTalkStartedAt = nil

        guard recorder.state.isRecording else { return }

        // No recorded start means the press was never seen — a release stranded
        // by a registration teardown, or a key-up delivered after a stuck-down
        // recovery. Transcribe rather than discard: the user did speak, and
        // silently dropping speech is the worse failure.
        guard let startedAt else {
            stopAndTranscribe()
            return
        }

        let held = ProcessInfo.processInfo.systemUptime - startedAt
        if HoldToTalkPolicy.shouldTranscribe(heldFor: held) {
            stopAndTranscribe()
        } else {
            cancelRecording()
        }
    }
```

- [ ] **Step 4: Update the delegate implementation**

In `Sources/FalaDan/AppDelegate.swift`, replace `hotkeyDidToggleRecording()` in `HotkeyDelegateImpl` with:

```swift
    nonisolated func hotkeyDidStartRecording() {
        Task { @MainActor in
            self.appState?.beginHoldToTalk()
        }
    }

    nonisolated func hotkeyDidStopRecording() {
        Task { @MainActor in
            self.appState?.endHoldToTalk()
        }
    }
```

- [ ] **Step 5: Run the gate**

Run: `./Scripts/verify.sh --dirty`
Expected: build succeeds, `Test run with 153 tests in 30 suites passed`, `VERIFY PASSED`

If the build fails with "does not conform to protocol 'HotkeyManagerDelegate'", a delegate method was missed — `HotkeyDelegateImpl` in `AppDelegate.swift` is the only conformer.

- [ ] **Step 6: Commit**

```bash
git add Sources/FalaDan/Services/Hotkeys/HotkeyManager.swift Sources/FalaDan/AppState.swift Sources/FalaDan/AppDelegate.swift
git commit -m "Convert recording hotkey from toggle to hold-to-talk

Register both edges for .toggleRecording: press starts, release stops.
Holds under HoldToTalkPolicy's threshold are cancelled rather than
transcribed, so a brushed key costs no API call and pastes nothing.

Uses systemUptime rather than wall time so a clock step mid-hold cannot
be read as a long hold. A release with no recorded press transcribes
rather than discards — dropping speech the user actually said is the
worse failure."
```

**Done means:** `./Scripts/verify.sh --dirty` passes with 153 tests, no file under `Services/Hotkeys/` other than `HotkeyManager.swift` and `HoldToTalkPolicy.swift` is modified (`git diff --name-only` confirms), and `AppState.toggleRecording()` still exists.

---

### Task 4: Make Fn the default recording key

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/Models/CustomShortcut.swift` (`defaultShortcuts()`, ~line 263)
- Create: `Tests/FalaDanTests/DefaultShortcutTests.swift`

**Interfaces:**
- Consumes: `CustomShortcut.isFnOnly`, `ShortcutBackend.classify(_:)`, both existing.
- Produces: nothing consumed by later tasks in this plan.

**Background:** Fn is key code 63. `CustomShortcut.isFnOnly` is true when the key code is Fn and no other modifier is set, and `ShortcutBackend.classify` returns `.modifierOnly` for exactly that case, routing it to the modifier tap that already handles both edges. Any *other* bare modifier returns `.unsupported(.modifierChord)` — the tap tracks only Fn — which is why Fn and not Right Option.

- [ ] **Step 1: Write the failing test**

Create `Tests/FalaDanTests/DefaultShortcutTests.swift`:

```swift
import Foundation
import Testing

@testable import FalaDan

/// The default recording binding has to reach the modifier tap, because that is
/// the only backend that reports a bare modifier's press and release. A default
/// that classified as anything else would leave hold-to-talk silently broken on
/// first launch.
struct DefaultShortcutTests {
    @Test func recordingDefaultsToBareFn() {
        let shortcut = CustomShortcutStorage.defaultShortcuts()[.toggleRecording]
        #expect(shortcut?.isFnOnly == true)
    }

    @Test func recordingDefaultRoutesToTheModifierTap() {
        let shortcut = CustomShortcutStorage.defaultShortcuts()[.toggleRecording]!
        #expect(ShortcutBackend.classify(shortcut) == .modifierOnly)
    }

    @Test func everyShortcutNameStillHasADefault() {
        let defaults = CustomShortcutStorage.defaultShortcuts()
        for name in CustomShortcutName.allCases {
            #expect(defaults[name] != nil)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./Scripts/verify.sh --dirty`
Expected: FAIL — `recordingDefaultsToBareFn` and `recordingDefaultRoutesToTheModifierTap` fail, because the default is currently ⌥W, which classifies as `.carbon`.

- [ ] **Step 3: Change the default**

In `Sources/FalaDan/Models/CustomShortcut.swift`, replace the `.toggleRecording` entry in `defaultShortcuts()`:

```swift
    static func defaultShortcuts() -> [CustomShortcutName: CustomShortcut] {
        [
            // Bare Fn, key code 63. The only bare modifier the tap tracks, and
            // the tap is the only backend that reports both edges of a modifier
            // press — which hold-to-talk requires.
            .toggleRecording: CustomShortcut(keyCode: 63),
            .cancelRecording: CustomShortcut(keyCode: UInt16(kVK_Escape)),  // Escape
            .autoCleanupRecording: CustomShortcut(keyCode: UInt16(kVK_ANSI_R), option: true),
            .editSelection: CustomShortcut(keyCode: UInt16(kVK_ANSI_E), option: true),
        ]
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./Scripts/verify.sh --dirty`
Expected: `Test run with 156 tests in 31 suites passed`, `VERIFY PASSED`

- [ ] **Step 5: Commit**

```bash
git add Sources/FalaDan/Models/CustomShortcut.swift Tests/FalaDanTests/DefaultShortcutTests.swift
git commit -m "Default the recording hotkey to bare Fn

Fn is the only bare modifier the tap tracks, and the tap is the only
backend reporting both edges of a modifier press. Tests assert the
default classifies as .modifierOnly so a future edit cannot silently
route it to Carbon and break hold-to-talk on first launch."
```

**Done means:** `./Scripts/verify.sh --dirty` reports 156 tests passing, and `ShortcutBackend.classify` of the default `.toggleRecording` shortcut is `.modifierOnly`.

---

### Task 5: Human verification and merge

**Executor:** `opus-supervised` — Dan performs the checks; Opus records the outcome.

**Files:** none modified unless a defect is found.

- [ ] **Step 1: Build and install the app**

Run: `just dev`
Expected: FalaDan launches and appears in the menu bar.

If `just` is not installed: `brew install just`.

- [ ] **Step 2: Grant permissions**

System Settings → Privacy & Security. Grant **Microphone**, **Accessibility**, and **Input Monitoring** to FalaDan. A rebuild can reset the Accessibility grant, which presents as the hotkey silently not firing.

- [ ] **Step 3: Dan verifies the three checkpoints**

Ask Dan directly; do not infer any of these from logs or tests.

1. **Hold-to-talk timing.** Hold Fn, speak, release. Does recording start and stop with the key, and does the start/stop timing *feel* right — no clipped first syllable, no lag after release?
2. **Tap guard.** Brush Fn quickly without speaking. Nothing should be transcribed and nothing pasted.
3. **End-to-end.** With the cursor in a third-party app (Notes, Slack), hold Fn, speak a sentence, release. Does the text land at the cursor, and is the prior clipboard restored?

- [ ] **Step 4: If all three pass, merge**

```bash
git checkout main
git merge --no-ff setup/scaffolding -m "Merge Phase 1: FalaDan rename and hold-to-talk"
./Scripts/verify.sh
git push -u origin main
```

- [ ] **Step 5: If any check fails, write HANDOFF.md**

Record which checkpoint failed, the exact observed behavior, and what was ruled out. Do not attempt a fix in the same turn as the failed verification — diagnose first, using `superpowers:systematic-debugging`.

**Done means:** Dan has confirmed all three checkpoints in his own words, or `HANDOFF.md` records the specific failure.

---

## Next plans (not in this document)

Written after Phase 1 merges, each needing its own read of the relevant sources:

- **Phase 2:** `.env` config loader (`EnvConfig`) and provider selection
- **Phase 3:** Groq/OpenAI transcription + LLM cleanup client; delete the OAuth stack and EditMode
- **Phase 4:** Floating recording indicator
- **Phase 5:** Strip — CLI target, Sparkle, replacement rules, spoken symbols, analytics, skill manager; README rewrite
