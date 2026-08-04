import Foundation

/// Whatever puts the indicator on screen and takes it off again.
///
/// Exists so the sequencing below can be tested. The real implementation is an
/// `NSPanel` and needs a window server; the interesting behaviour is not the
/// drawing but the timing, and that should not be verifiable only by hand.
@MainActor
protocol RecordingIndicatorPresenting: AnyObject {
    func present()
    func dismiss()
}

/// Drives the recording indicator: schedules its appearance, and calls that off
/// when the recording ends before it ever appears.
///
/// The delayed show is the whole problem. A recording begins on Fn key-down, and
/// most of them end milliseconds later when the key comes up under the hold
/// threshold — so the show is deferred, and a deferred show can outlive the
/// recording that asked for it:
///
///     key-down     → recording starts → schedule show in 150ms
///     key-up @80ms → recording discarded → hide
///     … 70ms later the scheduled show fires …
///     → pill on screen, no recording behind it, nothing left to dismiss it
///
/// Cancelling the pending task closes that, and it is sufficient on its own:
/// `Task {}` created in a `@MainActor` method inherits main-actor isolation, so
/// the only suspension point in the scheduled work is the sleep. Nothing can
/// interleave between the cancellation check and `present()`.
///
/// An earlier version carried a generation counter alongside the cancellation,
/// with a comment implying it was doing work. It was not — no interleaving
/// reached it, exactly as a review found for `AppState.holdGeneration`. It has
/// been removed rather than left to imply a guarantee it never provided.
@MainActor
final class RecordingIndicatorController {
    static let shared = RecordingIndicatorController(presenter: RecordingIndicatorPanel())

    private let presenter: any RecordingIndicatorPresenting
    private let sleep: @MainActor (TimeInterval) async -> Void

    private var showTask: Task<Void, Never>?
    private(set) var isShowing = false

    var isPending: Bool { showTask != nil }

    /// - Parameter sleep: injectable so a test can hold a scheduled show open,
    ///   release it on command, and watch what a *cancelled* one does when it
    ///   finally resumes. Waiting out a real 150ms and hoping is how a timing
    ///   test comes to fail on a loaded machine for no reason — and, worse, how
    ///   it comes to pass against a broken implementation.
    init(
        presenter: any RecordingIndicatorPresenting,
        sleep: @escaping @MainActor (TimeInterval) async -> Void = {
            try? await Task.sleep(for: .seconds($0))
        }
    ) {
        self.presenter = presenter
        self.sleep = sleep
    }

    func recordingStarted(minimumHold: TimeInterval) {
        switch RecordingIndicatorPolicy.onRecordingStarted(minimumHold: minimumHold) {
        case .showImmediately:
            cancelPendingShow()
            present()
        case .scheduleShow(let delay):
            scheduleShow(after: delay)
        }
    }

    func recordingEnded() {
        switch RecordingIndicatorPolicy.onRecordingEnded(
            isShowing: isShowing, isPending: isPending)
        {
        case .cancelAndHide:
            cancelPendingShow()
            dismiss()
        case .ignore:
            // Reachable: quitting while a cleanup pass runs fires this with no
            // recording and nothing on screen. Nothing to do — and nothing to
            // cancel either, since `.ignore` implies `showTask == nil`.
            break
        }
    }

    private func scheduleShow(after delay: TimeInterval) {
        // A second start with the first still pending replaces it rather than
        // stacking: two pending shows would present twice, and the second
        // present would be the one nothing cancels.
        cancelPendingShow()
        showTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.showTask = nil
            self.present()
        }
    }

    private func cancelPendingShow() {
        showTask?.cancel()
        showTask = nil
    }

    private func present() {
        guard !isShowing else { return }
        isShowing = true
        presenter.present()
    }

    private func dismiss() {
        guard isShowing else { return }
        isShowing = false
        presenter.dismiss()
    }
}
