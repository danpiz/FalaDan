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
