import Foundation

/// Decides whether a transcript is worth pasting, and whether it is worth
/// cleaning.
///
/// Both questions exist because of one Whisper behaviour: it hallucinates on
/// silence. Hold the hotkey, say nothing, and Parakeet returns an empty string
/// — which the empty guard already handles. Whisper instead returns "Thank
/// you.", "you", or "Thanks for watching!", which is not empty, so without this
/// it gets pasted at the cursor.
///
/// `VADPreprocessor` was built partly to mitigate exactly this — its own
/// comments name the artifacts — but it only engages on clips of eight seconds
/// or more, and an accidental silent hold is a second or two.
enum TranscriptSubstance {
    /// Whisper's silence output, normalised to lowercase with surrounding
    /// punctuation and whitespace already stripped.
    ///
    /// Deliberately short. Every entry here is a phrase a user could in
    /// principle dictate on purpose, so each one is a small tax on real use;
    /// the list earns its place only by covering what Whisper actually emits.
    /// Words like "okay", "so" and "yeah" are *not* included even though
    /// Whisper sometimes produces them — they are far too plausible as
    /// deliberate one-word dictation, and cleanup would drop them harmlessly
    /// anyway.
    private static let silenceArtifacts: Set<String> = [
        "you",
        "thank you",
        "thanks",
        "thanks for watching",
        "thank you for watching",
        "thanks for watching!",
        "bye",
        "goodbye",
        "please subscribe",
        "subscribe",
        "subscribe to my channel",
    ]

    /// Whether the transcript contains speech worth pasting.
    ///
    /// - Parameter mode: the model that produced it. Artifact filtering applies
    ///   only to Whisper-family models — Parakeet returns empty on silence
    ///   rather than hallucinating, so filtering its output would tax real
    ///   dictation for no benefit.
    static func hasSpeech(_ text: String, mode: TranscriptionMode) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard mode.usesWhisperFamilyModel else { return true }

        // Non-speech markers Whisper emits for music, silence and noise. Matched
        // structurally rather than by listing every variant, because the set is
        // open-ended: [BLANK_AUDIO], (Music), [silence], ♪…♪.
        if isBracketedNonSpeech(trimmed) { return false }

        let normalised = normalise(trimmed)
        if normalised.isEmpty { return false }  // punctuation or symbols only
        return !silenceArtifacts.contains(normalised)
    }

    /// Whether a transcript should be sent to the cleanup model at all.
    ///
    /// Model-independent, and the gate that actually stops commentary reaching
    /// the cursor. Given something with nothing to clean, the model does the
    /// conversational thing and replies *about* the input — "There is no text to
    /// clean" — which is then pasted as though it were the dictation. The fix is
    /// not to detect that reply, which is another unwinnable shape guess, but to
    /// never ask the question.
    ///
    /// A single word needs no punctuation, no filler removal and no backtrack
    /// handling, so nothing is lost by skipping it.
    static func isWorthCleaning(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let words = trimmed.split { $0.isWhitespace }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        return words.count >= 2
    }

    /// True when the whole transcript is a bracketed or musical non-speech
    /// marker, with nothing else alongside it.
    private static func isBracketedNonSpeech(_ trimmed: String) -> Bool {
        if trimmed.allSatisfy({ $0 == "♪" || $0 == "♫" || $0.isWhitespace }) { return true }
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("<", ">")]
        for (open, close) in pairs where trimmed.hasPrefix(String(open)) {
            guard trimmed.hasSuffix(String(close)) else { continue }
            // Only when the brackets wrap the *entire* string — "(music) let's
            // begin" is a real transcript with a marker in front of it.
            let inner = trimmed.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { return true }
        }
        return false
    }

    /// Lowercased, with surrounding punctuation and whitespace removed, so
    /// "Thank you!" and "  thank you  " both reach the same key.
    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters
                .union(.whitespacesAndNewlines)
                .union(.symbols))
    }
}
