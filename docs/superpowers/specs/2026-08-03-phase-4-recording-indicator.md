# Phase 4 — Floating recording indicator

**Status:** Specified, not implemented.
**Refines:** `2026-08-01-faladan-design.md` §5.5, which specified the panel but not the two
things that actually make this phase risky: the delayed show, and the focus constraint (§4.3, §5).

## 1. What we're building

A borderless pill, bottom centre of the screen, visible while a dictation is being recorded.
Non-interactive and click-through. It appears only once a hold has proven itself deliberate, and
it disappears on every path a recording can end.

## 2. Why

The menu bar icon is currently the only signal that FalaDan is listening. It is small, it may be
hidden entirely if the menu bar is crowded, and it is nowhere near where you are looking while
dictating. "Is it recording?" is the question the app most often fails to answer.

## 3. Decisions

| Question | Decision | Why |
|---|---|---|
| Position | **Bottom centre** | Away from the text you are dictating into, and the convention macOS dictation and Wispr Flow both use. Toasts are top centre, so an error and the indicator can coexist during one dictation without overlapping — which the interruption path (§4.5) actually does |
| When it appears | **After `MIN_HOLD_MS`** | Fn is pressed constantly as a modifier. Recording starts on key-down, so an instant pill would flash on every brush — and a centred pill is far more intrusive than the menu bar glyph that already made this visible |
| Interaction | **None; click-through** | `ignoresMouseEvents`, never key, never main. Esc already cancels. See §4.3 — this is a correctness requirement, not a simplification |
| Content | **Static pill** | Live level metering is v2 per the design's out-of-scope list. Elapsed time is deferred — see §7 |
| Show/hide logic | **Policy for the decision, controller for the sequencing, panel behind a protocol** | Only the drawing needs a window server. Splitting it out puts the delay-and-cancel race — the whole risk — under test rather than under manual inspection. See §4.4 |

## 4. Architecture

### 4.1 Existing foundation

Two pieces already exist and neither needs changing:

`ToastWindowController` is the working model for panel lifecycle — borderless
`.nonactivatingPanel`, `.floating` level, `collectionBehavior = [.canJoinAllSpaces,
.fullScreenAuxiliary]`, clear background, positioned on the screen containing the mouse. Copy its
shape; do not try to share code with it. Their lifetimes are unrelated and the coupling would
cost more than the duplication.

`AppState.onRecordingStarted` / `onRecordingEnded` are already wired and already fire from
**every** path. This is what makes the disappearance guarantee reachable:

| Path | Site |
|---|---|
| Recording began | `AppState+RecordingFlow.swift:65` |
| Stop and transcribe | `AppState+RecordingFlow.swift:86` |
| Discard (brushed key, sub-threshold hold) | `AppState+RecordingFlow.swift:216` |
| Cancel (Esc) | `AppState+RecordingFlow.swift:237` |
| Device interruption | `AppState.swift:71` |
| App termination | `AppState+Termination.swift:15` |

`AppDelegate` currently assigns these to notify `HotkeyManager`. The indicator has to be added
**alongside** the existing assignment, not in place of it — overwriting either closure silently
breaks Esc-to-cancel validity tracking.

### 4.2 The delayed show is the risky part

Deferring the appearance creates a stuck-indicator race with the same shape as the Phase 1
hot-mic bug, pointing the other way:

```
key-down    → recording starts → schedule "show" in 150ms
key-up @80ms → recording discarded → hide
   … 70ms later the scheduled show fires …
   → pill appears, with no recording behind it, and nothing left to hide it
```

That is a permanently stuck indicator, and it is the exact failure the design's manual
verification exists to catch.

**Resolution.** `hide()` must cancel the pending show, not merely order out a panel that is not
yet on screen. A `Task` handle, cancelled on every end.

**Cancellation alone is sufficient, and this is worth stating precisely because an earlier draft
of this spec got it wrong.** A `Task {}` created inside a `@MainActor` method inherits main-actor
isolation, so the scheduled work has exactly one suspension point — the sleep. Nothing can
interleave between the cancellation check and `present()`. This spec previously claimed a
generation counter was "load-bearing here in a way it was not in `AppState`"; a review disproved
that across 4,000 fuzzed interleavings, and the counter has been removed rather than left to
imply a guarantee it never provided. Do not reintroduce one here without a demonstrated
interleaving that cancellation misses.

**The sequencing is testable and must be tested.** Only the *panel* needs a window server; the
state machine does not. `RecordingIndicatorController` takes a `RecordingIndicatorPresenting` and
an injectable sleep, so the whole race runs against a fake in-process. A first attempt at these
tests passed against a deliberately broken implementation twice over — once because dropping the
task handle left the orphan unobservable, and once because releasing two stacked shows together
let `present()`'s idempotence guard hide the second. Both are recorded in the test comments.
Verify new tests here by mutation, not by reading.

`recordingEnded()` must be safe to call when nothing is showing — it is invoked on paths where
the indicator never appeared, which is the common case for brushes.

### 4.3 Focus is a correctness constraint, not a preference

The panel must **never become key or main**, and must ignore mouse events.

This is not about polish. FalaDan pastes into the frontmost application. A panel that takes focus
makes *FalaDan* the frontmost application, and the transcript lands in the wrong place or nowhere
at all. The panel appears while a recording is live, which is precisely when the eventual paste
target is being determined.

Required: `.nonactivatingPanel` in the style mask, `orderFrontRegardless()` rather than
`makeKeyAndOrderFront`, `ignoresMouseEvents = true`, and `canBecomeKey` / `canBecomeMain`
overridden to `false` if an `NSPanel` subclass is used.

**This makes the panel-configuration task `opus-supervised`**, despite the phase looking like
pure UI. It does not touch `PasteboardService` or the event tap, but getting it wrong breaks the
paste path just as thoroughly, and no test would catch it.

### 4.4 Where the logic lives

Three layers, split by what can be tested:

```swift
// Pure decision. Two enums, not one shared four-case Action: each function can
// return only two of them, and a single type leaves both call sites with dead
// switch arms that quietly do something.
enum RecordingIndicatorPolicy {
    enum StartAction: Equatable { case scheduleShow(TimeInterval), showImmediately }
    enum EndAction: Equatable { case cancelAndHide, ignore }

    static func onRecordingStarted(minimumHold: TimeInterval) -> StartAction
    static func onRecordingEnded(isShowing: Bool, isPending: Bool) -> EndAction
}

// Sequencing. Testable: takes a presenter and an injectable sleep.
@MainActor protocol RecordingIndicatorPresenting: AnyObject {
    func present()
    func dismiss()
}

@MainActor final class RecordingIndicatorController {
    init(presenter: any RecordingIndicatorPresenting,
         sleep: @escaping @MainActor (TimeInterval) async -> Void = ...)
}

// Drawing. Not testable, and the only part that is not.
@MainActor final class RecordingIndicatorPanel: RecordingIndicatorPresenting
```

### 4.5 Interaction with the interruption path

`AppState.swift:71` fires `onRecordingEnded()` and then shows an error toast. The pill dismisses
bottom centre while the toast appears top centre. This is the case that decided the position, and
it should be checked by eye once (§6.4).

### 4.6 Config

The delay reuses `MIN_HOLD_MS` rather than adding a key. They are the same quantity by
definition: the threshold below which a press is not a dictation. Setting `MIN_HOLD_MS=0`
disables the hold guard and correspondingly makes the indicator immediate — consistent, and worth
a line in `.env.example`.

## 5. Testing

`RecordingIndicatorPolicy` — the decision:

- Started schedules a show delayed by the configured minimum hold
- `MIN_HOLD_MS=0` yields an immediate show; a negative does too, rather than a delay that never
  elapses

`RecordingIndicatorController` — the sequencing, against a fake presenter and a manual clock:

- **Ended during the delay window never presents.** The §4.2 race and the most important test here
- **Started twice cannot strand a second show.** Release the shows one at a time and end the
  recording between them; firing both together passes against a broken implementation
- Ended with nothing pending neither presents nor dismisses
- Ended twice dismisses once
- Fifty brushes in a row present nothing

**Verify each of these by mutation before trusting it.** Deleting `showTask?.cancel()` must fail
the first; deleting `cancelPendingShow()` from `scheduleShow` must fail the second; deleting
`dismiss()`'s `isShowing` guard must fail. Two earlier drafts of these tests passed against
implementations broken in exactly those ways.

Not testable, and therefore manual (§6): everything the panel does — position, focus behaviour,
whether it is visible over a full-screen app. Per `CLAUDE.md`, the indicator appearing and *always*
disappearing is one of the three things no test reaches; the seam above moves most of that
guarantee into the suite, but the drawing itself stays a manual check.

## 6. Manual verification

1. Hold Fn for two seconds — pill appears bottom centre, disappears on release
2. **Brush Fn repeatedly and rapidly** — the pill must never flash, and must never be left on
   screen. Do this fifteen or twenty times; the race in §4.2 is timing-dependent and will not
   show up in three
3. Hold, then press Esc — pill disappears, recording cancelled
4. Unplug the microphone mid-recording — pill disappears bottom centre, error toast appears top
   centre, neither overlaps
5. **Dictate into a full-screen app** — pill must be visible over it, and the text must still land
6. **Confirm focus is not stolen:** click into a text field in another app, dictate, and check the
   caret stays where it was and the text arrives there
7. Quit the app mid-recording — no orphaned panel
8. Two displays: pill appears on the screen holding the pointer

## 7. Out of scope

- Live waveform or level metering — v2 per the design's out-of-scope list, though metering already
  exists upstream and would be cheap to wire later
- Elapsed-time readout. Tempting, since a 10-minute cap and an 8-minute warning already exist and
  currently surface only as a toast — but a static pill is the smaller first version, and whether
  the number is wanted is easier to judge with the pill in hand
- Any click, drag, or hover behaviour (§4.3)
- User-configurable position

## 8. Task sketch

One plan, four tasks:

1. `RecordingIndicatorPolicy` — pure, test-first, including the cancel-during-delay case
   (`sonnet-alone`)
2. `RecordingIndicatorWindow` / controller — panel construction and positioning
   (**`opus-supervised`**, §4.3)
3. Wiring into `AppDelegate` alongside the existing `HotkeyManager` callbacks, without replacing
   them (`sonnet-alone`)
4. `.env.example` note on `MIN_HOLD_MS` doubling as the indicator delay; README (`sonnet-alone`)
