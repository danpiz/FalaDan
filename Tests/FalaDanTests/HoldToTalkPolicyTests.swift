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
