import Foundation
import Testing

@testable import FalaDan

/// Counts what the controller asked for, so the sequencing can be checked
/// without a window server.
@MainActor
final class FakeIndicatorPresenter: RecordingIndicatorPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func present() { presentCount += 1 }
    func dismiss() { dismissCount += 1 }
}

/// A sleep the test controls: scheduled shows suspend here and stay suspended
/// until `fireAll()`.
///
/// This is what makes the cancellation actually observable. A real sleep, or a
/// fake one that never returns, leaves an orphaned task parked forever — so a
/// test asserting "nothing was presented" passes whether or not the task was
/// cancelled, which is no test at all. Releasing it and *then* checking is what
/// distinguishes a cancelled show from one that merely had not run yet.
@MainActor
final class ManualClock {
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var sleepCount: Int { waiting.count }

    func sleep(_ duration: TimeInterval) async {
        await withCheckedContinuation { waiting.append($0) }
    }

    func fireAll() {
        let resuming = waiting
        waiting = []
        for continuation in resuming { continuation.resume() }
    }

    /// Releases the oldest parked sleep only.
    ///
    /// Needed because firing everything at once hides a real bug: if two shows
    /// are left stacked, releasing both together lets the first present and the
    /// second no-op against `present()`'s idempotence guard, so a count of one
    /// looks correct. The damage only appears when the recording ends *between*
    /// the two.
    func fireOne() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}

/// The sequencing around the delayed show — the part carrying the real risk in
/// this feature, and the part a policy of pure functions cannot reach.
@MainActor
struct RecordingIndicatorControllerTests {
    /// Lets any resumed task run to its next suspension. Cheap, and bounded:
    /// the scheduled show has exactly one suspension point.
    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// The race this whole design exists to prevent: the recording ended while
    /// the show was still waiting out its delay. When that delay finally
    /// elapses, nothing may reach the screen.
    ///
    /// Verified by mutation: deleting `showTask?.cancel()` from
    /// `cancelPendingShow` must fail this test.
    @Test func endingDuringTheDelayNeverPresents() async {
        let presenter = FakeIndicatorPresenter()
        let clock = ManualClock()
        let controller = RecordingIndicatorController(
            presenter: presenter, sleep: clock.sleep)

        controller.recordingStarted(minimumHold: 0.15)
        await drain()
        #expect(controller.isPending)
        #expect(clock.sleepCount == 1, "the show should be parked in the clock")

        controller.recordingEnded()

        // Release the parked show. A cancelled one must return without drawing.
        clock.fireAll()
        await drain()

        #expect(presenter.presentCount == 0, "a cancelled show reached the screen")
        #expect(!controller.isPending)
        #expect(!controller.isShowing)
    }

    /// A hold that outlasts the delay is the ordinary case.
    @Test func aHoldPastTheDelayPresentsOnce() async {
        let presenter = FakeIndicatorPresenter()
        let clock = ManualClock()
        let controller = RecordingIndicatorController(
            presenter: presenter, sleep: clock.sleep)

        controller.recordingStarted(minimumHold: 0.15)
        await drain()
        clock.fireAll()
        await drain()

        #expect(presenter.presentCount == 1)
        #expect(controller.isShowing)
        #expect(!controller.isPending, "showTask should be cleared once it fires")

        controller.recordingEnded()
        #expect(presenter.dismissCount == 1)
        #expect(!controller.isShowing)
    }

    /// Two starts without an intervening end must leave one pending show, not
    /// two. A stacked second show outlives the recording: the first presents,
    /// the recording ends and dismisses it, and then the leftover fires against
    /// nothing — a pill on screen that nothing will take down.
    ///
    /// Named in the spec's test plan and previously unimplementable: it is a
    /// property of the controller's state, not of a pure decision function.
    ///
    /// The shows are released one at a time on purpose. Firing both together
    /// makes this pass against a broken implementation — the second present is
    /// swallowed by `present()`'s idempotence guard, so the count still reads
    /// one. Ending the recording *between* them is what exposes it.
    @Test func startingTwiceCannotStrandASecondShow() async {
        let presenter = FakeIndicatorPresenter()
        let clock = ManualClock()
        let controller = RecordingIndicatorController(
            presenter: presenter, sleep: clock.sleep)

        controller.recordingStarted(minimumHold: 0.15)
        await drain()
        controller.recordingStarted(minimumHold: 0.15)
        await drain()

        // Whatever the first parked show does, the recording is over by the
        // time any leftover is released.
        clock.fireOne()
        await drain()
        controller.recordingEnded()
        await drain()

        clock.fireOne()
        await drain()

        #expect(!controller.isShowing, "a stranded second show left the pill on screen")
        #expect(
            presenter.presentCount == presenter.dismissCount,
            "every present must be matched by a dismiss")
    }

    /// Fires on every discard, including brushes that never reached the delay.
    /// Must not dismiss something that was never shown.
    @Test func endingWithNothingPendingDoesNothing() async {
        let presenter = FakeIndicatorPresenter()
        let clock = ManualClock()
        let controller = RecordingIndicatorController(
            presenter: presenter, sleep: clock.sleep)

        controller.recordingEnded()
        await drain()

        #expect(presenter.presentCount == 0)
        #expect(presenter.dismissCount == 0)
    }

    /// `MIN_HOLD_MS=0` disables the hold guard, so there is no brush to suppress
    /// and nothing to wait for.
    @Test func aZeroMinimumPresentsWithoutScheduling() async {
        let presenter = FakeIndicatorPresenter()
        let clock = ManualClock()
        let controller = RecordingIndicatorController(
            presenter: presenter, sleep: clock.sleep)

        controller.recordingStarted(minimumHold: 0)
        await drain()

        #expect(presenter.presentCount == 1)
        #expect(!controller.isPending)
        #expect(clock.sleepCount == 0, "an immediate show should not wait on the clock")
    }

    /// Repeated ends — termination fires one unconditionally, and may follow a
    /// stop that already fired its own.
    @Test func endingTwiceDismissesOnlyOnce() async {
        let presenter = FakeIndicatorPresenter()
        let clock = ManualClock()
        let controller = RecordingIndicatorController(
            presenter: presenter, sleep: clock.sleep)

        controller.recordingStarted(minimumHold: 0.15)
        await drain()
        clock.fireAll()
        await drain()

        controller.recordingEnded()
        controller.recordingEnded()

        #expect(presenter.dismissCount == 1)
    }

    /// The brush cycle as Fn is actually used: many starts and ends inside the
    /// delay window, every one of them released afterwards. None may draw.
    @Test func repeatedBrushesNeverPresent() async {
        let presenter = FakeIndicatorPresenter()
        let clock = ManualClock()
        let controller = RecordingIndicatorController(
            presenter: presenter, sleep: clock.sleep)

        for _ in 0..<50 {
            controller.recordingStarted(minimumHold: 0.15)
            await Task.yield()
            controller.recordingEnded()
        }
        clock.fireAll()
        await drain()

        #expect(presenter.presentCount == 0)
        #expect(!controller.isShowing)
        #expect(!controller.isPending)
    }
}
