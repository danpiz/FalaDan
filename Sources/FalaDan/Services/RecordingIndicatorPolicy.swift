import Foundation

/// Decides whether the recording indicator should be on screen.
///
/// Separated from the panel because the panel needs a window server and cannot
/// be unit-tested. This type is only the *decision*, though — the sequencing it
/// feeds (scheduling a show, calling one off when the recording ends before it
/// fires) lives in `RecordingIndicatorController`, which is tested through a
/// presenter seam rather than a real panel.
enum RecordingIndicatorPolicy {
    /// Two enums rather than one shared four-case `Action`: each function can
    /// only return two of the four, so a single type left both call sites with
    /// dead switch arms — and a dead arm that quietly does something is how a
    /// later policy change gets silently ignored instead of failing.
    enum StartAction: Equatable {
        /// Show after the given delay, unless cancelled first.
        case scheduleShow(TimeInterval)
        case showImmediately
    }

    enum EndAction: Equatable {
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
    static func onRecordingStarted(minimumHold: TimeInterval) -> StartAction {
        guard minimumHold > 0 else { return .showImmediately }
        return .scheduleShow(minimumHold)
    }

    /// A recording ended, by any route — transcribed, discarded, cancelled,
    /// interrupted, or the app quitting.
    ///
    /// - Parameters:
    ///   - isShowing: the panel is on screen.
    ///   - isPending: a delayed show is scheduled and has not fired.
    static func onRecordingEnded(isShowing: Bool, isPending: Bool) -> EndAction {
        (isShowing || isPending) ? .cancelAndHide : .ignore
    }
}
