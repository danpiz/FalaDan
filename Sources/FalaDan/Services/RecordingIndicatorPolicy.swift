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
