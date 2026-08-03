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

    /// What a released hold should do with the recording it started.
    enum Release: Equatable {
        case transcribe
        case discard
    }

    /// The whole release decision, as a pure function so it can be tested
    /// without a recorder, an event tap, or a microphone.
    ///
    /// - Parameter heldFor: seconds the key was held, or `nil` when the press
    ///   was never observed — a release stranded by a registration teardown, or
    ///   one delivered after `FnStateMachine`'s stuck-down recovery. That case
    ///   transcribes rather than discards: the two failures are not symmetric,
    ///   and silently dropping speech the user actually said is far worse than
    ///   an unwanted paste they can undo.
    static func release(
        heldFor: TimeInterval?,
        minimum: TimeInterval = defaultMinimumHold
    ) -> Release {
        guard let heldFor else { return .transcribe }
        return shouldTranscribe(heldFor: heldFor, minimum: minimum) ? .transcribe : .discard
    }

    /// Whether a parked release belongs to the start now completing.
    ///
    /// A release can be recorded before the recorder is live, to be applied once
    /// it comes up. But one exit from the start flow leaves that window open
    /// without ever applying the release, so the *next* start — possibly one a
    /// different shortcut began — could consume it and be cut short. Stamping
    /// each release with the generation of the press that made it, and checking
    /// the stamp before applying, is what keeps them apart.
    ///
    /// Pure so the rule is testable; the counter itself lives on `AppState`.
    static func shouldApplyParkedRelease(parked: UInt64, current: UInt64) -> Bool {
        parked == current
    }
}
