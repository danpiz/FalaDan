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
}
