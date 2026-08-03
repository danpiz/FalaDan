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

    /// A zero threshold disables the guard entirely. This backs `MIN_HOLD_MS=0`
    /// from the `.env` config, wired in AppState.endHoldToTalk.
    @Test func zeroThresholdAcceptsAnyNonNegativeHold() {
        #expect(HoldToTalkPolicy.shouldTranscribe(heldFor: 0, minimum: 0))
    }

    @Test func defaultThresholdIs150Milliseconds() {
        #expect(HoldToTalkPolicy.defaultMinimumHold == 0.15)
    }
}

/// The release decision, including the case the recorder cannot answer: a
/// release whose press was never observed.
struct HoldToTalkReleaseTests {
    @Test func aDeliberateHoldTranscribes() {
        #expect(HoldToTalkPolicy.release(heldFor: 1.2, minimum: 0.15) == .transcribe)
    }

    @Test func aBrushedKeyDiscards() {
        #expect(HoldToTalkPolicy.release(heldFor: 0.02, minimum: 0.15) == .discard)
    }

    /// An unobserved press means a stranded release or a stuck-down recovery.
    /// Transcribing risks an unwanted paste; discarding throws away speech.
    /// Only one of those is recoverable by the user.
    @Test func anUnobservedPressTranscribesRatherThanDiscards() {
        #expect(HoldToTalkPolicy.release(heldFor: nil, minimum: 0.15) == .transcribe)
    }

    /// A nil hold is not silently treated as a zero-length one — that would
    /// invert the previous case and drop the speech.
    @Test func anUnobservedPressIsNotTreatedAsAZeroLengthHold() {
        #expect(HoldToTalkPolicy.release(heldFor: 0, minimum: 0.15) == .discard)
        #expect(HoldToTalkPolicy.release(heldFor: nil, minimum: 0.15) == .transcribe)
    }

    @Test func aBackwardsClockDiscards() {
        #expect(HoldToTalkPolicy.release(heldFor: -3, minimum: 0.15) == .discard)
    }
}

/// Whether a parked release still belongs to the recording that is starting.
///
/// `startRecordingFlow`'s `captureTransitionInFlight` guard sits *above* the
/// `defer` that closes the hold window, so a hold start bailing there leaves the
/// window open — and its release can then be consumed by the flow already
/// running, cutting short a recording a different press began. Matching
/// generations is what tells the two apart.
///
/// Hoisting the `defer` does not fix this and introduces the mirror bug: a second
/// flow bailing at that guard would clear a live hold's window instead.
struct HoldReleaseGenerationTests {
    @Test func aReleaseFromTheCurrentPressApplies() {
        #expect(HoldToTalkPolicy.shouldApplyParkedRelease(parked: 7, current: 7))
    }

    @Test func aReleaseFromAnEarlierPressIsDiscarded() {
        #expect(!HoldToTalkPolicy.shouldApplyParkedRelease(parked: 6, current: 7))
    }

    /// Defensive: a parked generation ahead of the current one cannot happen by
    /// construction, and if it ever did the safe reading is "not mine".
    @Test func aGenerationAheadOfCurrentIsDiscarded() {
        #expect(!HoldToTalkPolicy.shouldApplyParkedRelease(parked: 8, current: 7))
    }

    /// The counter wraps rather than trapping, because a trap would crash the
    /// hotkey path. Only equality is ever compared, so wrapping is harmless —
    /// but a release parked before a wrap must still not match after it.
    @Test func wrappingDoesNotMakeStaleReleasesMatch() {
        #expect(!HoldToTalkPolicy.shouldApplyParkedRelease(parked: .max, current: 0))
    }
}
