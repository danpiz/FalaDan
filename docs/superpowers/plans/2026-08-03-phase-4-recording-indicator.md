# Phase 4 — Recording Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a floating pill while FalaDan is recording, appearing only once a hold proves
deliberate and disappearing on every path a recording can end.

**Architecture:** A pure policy type decides *whether* to show; an `NSPanel` controller does the
showing. The policy is unit-tested; the panel is verified by hand. Wiring hangs off the existing
`AppState.onRecordingStarted` / `onRecordingEnded` callbacks, which already fire from all six
exit paths.

**Tech Stack:** Swift 6, SwiftUI in an `NSHostingView`, AppKit `NSPanel`, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-03-phase-4-recording-indicator.md` — read §4.2 and §4.3
before Task 2.

## Global Constraints

- **`./Scripts/verify.sh` is the only verification command.** Bare `swift test` does not work on
  this machine. `--dirty` skips the clean-tree check mid-task.
- **Do not adjust a test file to match a number in this plan.** Test counts here are relative
  ("adds 6 tests"); the absolute total is whatever the suite reports. Baseline at branch point:
  **226 tests in 42 suites**.
- **The panel must never become key or main, and must ignore mouse events.** FalaDan pastes into
  the frontmost application; a panel that takes focus makes FalaDan frontmost and the transcript
  lands in the wrong place. This is correctness, not polish.
- **Never replace the existing `onRecordingStarted` / `onRecordingEnded` closures** — they notify
  `HotkeyManager` so Esc-to-cancel knows when it is valid. Add to them.
- Do not touch `CustomShortcutMonitor`, `FnStateMachine`, `ModifierTapMonitor`,
  `EventTapRunLoop`, `KeyDownObserver`, `CarbonHotKeyCenter`, or `PasteboardService`.
- Config lives in `.env`. This phase adds **no new key** — the delay reuses `MIN_HOLD_MS`.
- Match the surrounding comment density and naming. Comments explain *why*, not *what*.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FalaDan/Services/RecordingIndicatorPolicy.swift` | **Create.** Pure decision logic: show now, show later, or cancel |
| `Sources/FalaDan/Views/RecordingIndicatorView.swift` | **Create.** The pill's SwiftUI body |
| `Sources/FalaDan/Views/RecordingIndicatorController.swift` | **Create.** `NSPanel` lifecycle, delayed show, cancellation |
| `Sources/FalaDan/AppDelegate.swift` | **Modify.** Own the controller; extend the two callbacks |
| `Tests/FalaDanTests/RecordingIndicatorPolicyTests.swift` | **Create.** Policy tests |
| `.env.example`, `README.md` | **Modify.** Note `MIN_HOLD_MS` doubles as the indicator delay |

---

### Task 1: `RecordingIndicatorPolicy`

**Executor:** `sonnet-alone`

**Files:**
- Create: `Sources/FalaDan/Services/RecordingIndicatorPolicy.swift`
- Test: `Tests/FalaDanTests/RecordingIndicatorPolicyTests.swift`

**Do not touch:** anything else.

**Interfaces:**
- Consumes: nothing.
- Produces: `RecordingIndicatorPolicy.Action` (`.scheduleShow(TimeInterval)`, `.showImmediately`,
  `.cancelAndHide`, `.ignore`), `onRecordingStarted(minimumHold:)`,
  `onRecordingEnded(isShowing:isPending:)`. Task 2 calls both.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FalaDanTests/RecordingIndicatorPolicyTests.swift`:

```swift
import Foundation
import Testing

@testable import FalaDan

/// The indicator's decision logic, separated from the panel so it can be tested
/// at all. The panel itself is verified by hand — see the spec's §6.
struct RecordingIndicatorPolicyTests {
    @Test func anOrdinaryHoldSchedulesADelayedShow() {
        #expect(
            RecordingIndicatorPolicy.onRecordingStarted(minimumHold: 0.15)
                == .scheduleShow(0.15))
    }

    /// `MIN_HOLD_MS=0` documents "no hold guard", so there is no brush to
    /// suppress and nothing to wait for.
    @Test func aZeroMinimumShowsImmediately() {
        #expect(RecordingIndicatorPolicy.onRecordingStarted(minimumHold: 0) == .showImmediately)
    }

    /// A negative value cannot come from the parser, which rejects them, but the
    /// policy is a pure function and should not depend on that.
    @Test func aNegativeMinimumShowsImmediately() {
        #expect(RecordingIndicatorPolicy.onRecordingStarted(minimumHold: -1) == .showImmediately)
    }

    /// The race this phase exists to avoid: the recording ended while the show
    /// was still waiting out the delay. The pending show must be cancelled, or
    /// it fires with no recording behind it and nothing left to dismiss it.
    @Test func endingDuringTheDelayWindowCancelsThePendingShow() {
        #expect(
            RecordingIndicatorPolicy.onRecordingEnded(isShowing: false, isPending: true)
                == .cancelAndHide)
    }

    @Test func endingWhileVisibleHides() {
        #expect(
            RecordingIndicatorPolicy.onRecordingEnded(isShowing: true, isPending: false)
                == .cancelAndHide)
    }

    /// Fires on every discard, including brushes that never reached the delay.
    /// Must be a no-op rather than an error.
    @Test func endingWithNothingShowingIsIgnored() {
        #expect(
            RecordingIndicatorPolicy.onRecordingEnded(isShowing: false, isPending: false)
                == .ignore)
    }
}
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `./Scripts/verify.sh --dirty`
Expected: compile failure — `RecordingIndicatorPolicy` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Sources/FalaDan/Services/RecordingIndicatorPolicy.swift`:

```swift
import Foundation

/// Decides whether the recording indicator should be on screen.
///
/// Separated from the panel for two reasons. The panel cannot be unit-tested —
/// it needs a window server — and the interesting behaviour is not the drawing
/// but the timing: a recording can end before the indicator was ever shown, and
/// a show still waiting out its delay has to be called off rather than left to
/// fire into an empty state.
enum RecordingIndicatorPolicy {
    enum Action: Equatable {
        /// Show after the given delay, unless cancelled first.
        case scheduleShow(TimeInterval)
        case showImmediately
        /// Drop any pending show and take the panel down.
        case cancelAndHide
        case ignore
    }

    /// A recording started. The indicator waits out the minimum hold before
    /// appearing.
    ///
    /// Fn is pressed constantly as a modifier and a recording begins on
    /// key-down, so showing immediately would flash a centred pill on every
    /// brush. Waiting for the same threshold that decides whether the hold was a
    /// dictation means only deliberate holds ever draw anything.
    ///
    /// - Parameter minimumHold: seconds a hold must last to count, from
    ///   `MIN_HOLD_MS`. Zero disables the hold guard and so also the delay;
    ///   negatives cannot come from the parser but are treated the same way
    ///   rather than turned into a delay that never elapses.
    static func onRecordingStarted(minimumHold: TimeInterval) -> Action {
        guard minimumHold > 0 else { return .showImmediately }
        return .scheduleShow(minimumHold)
    }

    /// A recording ended, by any route — transcribed, discarded, cancelled,
    /// interrupted, or the app quitting.
    ///
    /// - Parameters:
    ///   - isShowing: the panel is on screen.
    ///   - isPending: a delayed show is scheduled and has not fired.
    static func onRecordingEnded(isShowing: Bool, isPending: Bool) -> Action {
        (isShowing || isPending) ? .cancelAndHide : .ignore
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `./Scripts/verify.sh --dirty`
Expected: all pass. Adds 6 tests in 1 new suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/FalaDan/Services/RecordingIndicatorPolicy.swift \
        Tests/FalaDanTests/RecordingIndicatorPolicyTests.swift
git commit -m "Add RecordingIndicatorPolicy"
```

**Done means:** `./Scripts/verify.sh` passes, 6 new tests, `RecordingIndicatorPolicy` compiles
with no reference to AppKit.

---

### Task 2: The panel

**Executor:** `opus-supervised` — the controller is implemented by the orchestrator, not
delegated. A panel that takes focus breaks the paste target and no test catches it.

**Files:**
- Create: `Sources/FalaDan/Views/RecordingIndicatorView.swift`
- Create: `Sources/FalaDan/Views/RecordingIndicatorController.swift`

**Do not touch:** `ToastWindowController.swift` — it is the model to copy, not to share code with.

**Interfaces:**
- Consumes: `RecordingIndicatorPolicy`.
- Produces: `RecordingIndicatorController.shared`, `recordingStarted(minimumHold:)`,
  `recordingEnded()`. Task 3 calls both.

- [ ] **Step 1: The view**

Create `Sources/FalaDan/Views/RecordingIndicatorView.swift`:

```swift
import SwiftUI

/// The pill itself. Deliberately static — a level meter is v2.
struct RecordingIndicatorView: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text("Recording")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color.black.opacity(0.78))
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
```

- [ ] **Step 2: The controller**

Create `Sources/FalaDan/Views/RecordingIndicatorController.swift`. Modelled on
`ToastWindowController`'s panel handling; see the spec §4.2 for why both the task handle and the
generation are kept.

```swift
import AppKit
import SwiftUI

/// Floating pill shown while a dictation is being recorded.
///
/// Panel setup mirrors `ToastWindowController`. The two are deliberately not
/// shared: their lifetimes are unrelated, and the indicator carries a delay and
/// a cancellation rule that a toast has no use for.
@MainActor
final class RecordingIndicatorController {
    static let shared = RecordingIndicatorController()

    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?

    /// Invalidates a delayed show that is still waiting when the recording ends.
    ///
    /// Cancelling `showTask` is very probably sufficient on the main actor. The
    /// generation is kept anyway: "very probably" is the reasoning that produced
    /// the Phase 1 hot-mic race, and a show that fires after its recording has
    /// gone leaves a pill on screen with nothing left to take it down.
    private var generation: UInt64 = 0

    private let panelWidth: CGFloat = 140
    private let panelHeight: CGFloat = 44

    var isShowing: Bool { panel != nil }
    var isPending: Bool { showTask != nil }

    func recordingStarted(minimumHold: TimeInterval) {
        switch RecordingIndicatorPolicy.onRecordingStarted(minimumHold: minimumHold) {
        case .showImmediately:
            cancelPendingShow()
            present()
        case .scheduleShow(let delay):
            scheduleShow(after: delay)
        case .cancelAndHide, .ignore:
            break
        }
    }

    func recordingEnded() {
        switch RecordingIndicatorPolicy.onRecordingEnded(
            isShowing: isShowing, isPending: isPending)
        {
        case .cancelAndHide:
            cancelPendingShow()
            dismiss()
        case .ignore, .showImmediately, .scheduleShow(_):
            // `onRecordingEnded` only ever returns the two cases above; the rest
            // are here because the switch must be exhaustive. Bump anyway: an
            // in-flight show that already passed its cancellation check must not
            // survive this call.
            generation &+= 1
        }
    }

    private func scheduleShow(after delay: TimeInterval) {
        cancelPendingShow()
        generation &+= 1
        let mine = generation
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self, mine == self.generation else { return }
            self.showTask = nil
            self.present()
        }
    }

    private func cancelPendingShow() {
        generation &+= 1
        showTask?.cancel()
        showTask = nil
    }

    private func present() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // FalaDan pastes into the frontmost application. A panel that accepts a
        // click or takes focus makes FalaDan frontmost, and the transcript lands
        // somewhere the user was not typing.
        panel.ignoresMouseEvents = true

        panel.contentView = NSHostingView(
            rootView: RecordingIndicatorView()
                .frame(width: panelWidth, height: panelHeight)
        )

        position(panel)
        panel.alphaValue = 0
        // Never `makeKeyAndOrderFront` — see above.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.panel = panel
    }

    private func dismiss() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Bottom centre of whichever screen holds the pointer — away from the text
    /// being dictated into, and clear of the toasts, which sit top centre.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panelWidth / 2
        let y = visibleFrame.minY + 80

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

- [ ] **Step 3: Build and verify nothing regressed**

Run: `./Scripts/verify.sh --dirty`
Expected: pass, same test count as after Task 1 (no new tests — the panel is not unit-testable).

- [ ] **Step 4: Commit**

```bash
git add Sources/FalaDan/Views/RecordingIndicatorView.swift \
        Sources/FalaDan/Views/RecordingIndicatorController.swift
git commit -m "Add the recording indicator panel"
```

**Done means:** builds clean; `ignoresMouseEvents` is set; `orderFrontRegardless` is used and
`makeKeyAndOrderFront` appears nowhere; `.nonactivatingPanel` is in the style mask.

---

### Task 3: Wiring

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/AppDelegate.swift` (the `onRecordingStarted` / `onRecordingEnded`
  assignment, around line 248)

**Do not touch:** `AppState.swift`, `AppState+RecordingFlow.swift`, or anything under
`Services/Hotkeys/`. The callbacks already fire from every path; this task only listens.

**Interfaces:**
- Consumes: `RecordingIndicatorController.shared`, `appState.envConfig.minHold`.

- [ ] **Step 1: Extend the existing closures**

The current code reads:

```swift
        // Wire up recording state changes so HotkeyManager knows when cancel is valid
        appState.onRecordingStarted = { [weak manager] in
            manager?.recordingDidStart()
        }
        appState.onRecordingEnded = { [weak manager] in
            manager?.recordingDidEnd()
        }
```

Replace with:

```swift
        // Wire up recording state changes so HotkeyManager knows when cancel is
        // valid, and so the floating indicator follows the recording.
        //
        // Both concerns share these closures — the indicator is added to them,
        // never in place of the manager calls, which is what keeps Esc-to-cancel
        // knowing whether a recording is live.
        let minimumHold = appState.envConfig.minHold
        appState.onRecordingStarted = { [weak manager] in
            manager?.recordingDidStart()
            RecordingIndicatorController.shared.recordingStarted(minimumHold: minimumHold)
        }
        appState.onRecordingEnded = { [weak manager] in
            manager?.recordingDidEnd()
            RecordingIndicatorController.shared.recordingEnded()
        }
```

`minimumHold` is read once here rather than inside the closure because `envConfig` is immutable
and parsed once at launch — capturing the value avoids retaining `appState` in the closure.

- [ ] **Step 2: Build and verify**

Run: `./Scripts/verify.sh --dirty`
Expected: pass, test count unchanged from Task 2.

- [ ] **Step 3: Confirm both call sites survived**

Run: `grep -n "recordingDidStart\|recordingDidEnd" Sources/FalaDan/AppDelegate.swift`
Expected: both appear exactly once. If either is missing, Esc-to-cancel is broken.

- [ ] **Step 4: Commit**

```bash
git add Sources/FalaDan/AppDelegate.swift
git commit -m "Show the recording indicator while recording"
```

**Done means:** `./Scripts/verify.sh` passes; `recordingDidStart` and `recordingDidEnd` are both
still called; the indicator calls sit alongside them.

---

### Task 4: Docs

**Executor:** `sonnet-alone`

**Files:**
- Modify: `.env.example` — note that `MIN_HOLD_MS` also delays the indicator
- Modify: `README.md` — mention the indicator in Features

**Do not touch:** anything under `Sources/` or `Tests/`.

- [ ] **Step 1: `.env.example`**

The file currently has:

```
# Hold shorter than this is treated as an accidental tap and discarded.
# 0 disables the guard.
# MIN_HOLD_MS=150
```

Replace those three comment lines with:

```
# Hold shorter than this is treated as an accidental tap and discarded.
# Also how long FalaDan waits before showing the recording pill, so a
# brushed key never flashes it. 0 disables both.
# MIN_HOLD_MS=150
```

- [ ] **Step 2: README**

Add one bullet to the Features list, after the "Multiple models" bullet:

```markdown
- **Recording indicator** — a pill at the bottom of the screen while FalaDan is listening,
  shown only once a hold is long enough to count as dictation
```

- [ ] **Step 3: Verify and commit**

Run: `./Scripts/verify.sh`
Expected: PASSED, clean tree.

```bash
git add .env.example README.md
git commit -m "Document the recording indicator"
```

**Done means:** `./Scripts/verify.sh` passes with a clean tree.

---

### Task 5: Manual verification — Dan

Not delegable. From the spec §6:

1. Hold Fn two seconds — pill appears bottom centre, disappears on release
2. **Brush Fn rapidly, fifteen or twenty times** — never flashes, never sticks. The §4.2 race is
   timing-dependent and will not appear in three tries
3. Hold, then Esc — pill goes, recording cancelled
4. Unplug the mic mid-recording — pill goes bottom centre, error toast appears top centre
5. Dictate into a **full-screen** app — pill visible over it, text still lands
6. **Focus check:** click into a text field in another app, dictate, confirm the caret does not
   move and the text arrives there
7. Quit mid-recording — no orphaned panel
8. Two displays — pill appears on the screen holding the pointer
