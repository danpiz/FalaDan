import Foundation
import Testing

@testable import FalaDan

/// Whisper hallucinates on silence. Parakeet does not.
///
/// Hold the key, say nothing, and Parakeet returns an empty string — the empty
/// guard fires and nothing is pasted. Whisper instead emits one of a small,
/// well-known set of artifacts ("Thank you.", "you", "Thanks for watching!"),
/// which is *not* empty, so it sails through and gets pasted. The VAD
/// preprocessor exists partly to mitigate this but only engages on clips of 8
/// seconds or more, so a brief silent hold never reaches it.
///
/// Worse, a two-word artifact then reaches the cleanup model, which — asked to
/// clean something that isn't worth cleaning — replies "There is no text to
/// clean" and *that* lands at the cursor.
struct TranscriptSubstanceTests {
    /// Captured from Whisper's documented silence behaviour. `VADPreprocessor`'s
    /// own comments name the first two.
    static let silenceArtifacts = [
        "Thank you.",
        "Thanks for watching!",
        "Thank you for watching.",
        "you",
        "You.",
        "Bye.",
        "Please subscribe.",
        "[BLANK_AUDIO]",
        "[music]",
        "(Music)",
        "[silence]",
        "♪",
        ".",
        "...",
        "  Thank you!  ",
    ]

    @Test func whisperSilenceArtifactsCountAsNoSpeech() {
        for artifact in Self.silenceArtifacts {
            #expect(
                !TranscriptSubstance.hasSpeech(artifact, mode: .groq),
                "artifact reached the cursor: \(artifact)")
            #expect(
                !TranscriptSubstance.hasSpeech(artifact, mode: .multilingual),
                "artifact reached the cursor: \(artifact)")
        }
    }

    /// Parakeet returns empty rather than hallucinating, so the artifact list
    /// must not apply to it — a user who deliberately dictates "thank you" on
    /// the default model should get it.
    @Test func theDefaultModelIsNotFilteredForArtifacts() {
        #expect(TranscriptSubstance.hasSpeech("Thank you.", mode: .default))
        #expect(TranscriptSubstance.hasSpeech("you", mode: .default))
    }

    /// An empty transcript is no-speech on every model — the pre-existing
    /// behaviour this replaces.
    @Test func emptyIsNeverSpeech() {
        for mode in [TranscriptionMode.default, .multilingual, .groq, .custom] {
            #expect(!TranscriptSubstance.hasSpeech("", mode: mode))
            #expect(!TranscriptSubstance.hasSpeech("   \n ", mode: mode))
        }
    }

    /// The cost of the filter, stated as a test so it is a decision rather than
    /// a surprise: real dictation must survive, including short commands.
    @Test func realDictationSurvivesOnEveryModel() {
        let real = [
            "Thank you for sending that over, I'll take a look tomorrow.",
            "yes",
            "undo",
            "The meeting is at 4pm.",
            "you should probably check the logs first",
            "Bye for now, talk later.",
        ]
        for text in real {
            for mode in [TranscriptionMode.default, .multilingual, .groq, .custom] {
                #expect(
                    TranscriptSubstance.hasSpeech(text, mode: mode),
                    "swallowed real dictation on \(mode.rawValue): \(text)")
            }
        }
    }

    /// Second gate, and the one that is model-independent: never ask the cleanup
    /// model to clean something not worth cleaning. It answers conversationally
    /// — "There is no text to clean" — and the answer gets pasted.
    @Test func trivialTranscriptsAreNotSentToCleanup() {
        #expect(!TranscriptSubstance.isWorthCleaning(""))
        #expect(!TranscriptSubstance.isWorthCleaning("   "))
        #expect(!TranscriptSubstance.isWorthCleaning("you"))
        #expect(!TranscriptSubstance.isWorthCleaning("yes"))
        #expect(!TranscriptSubstance.isWorthCleaning("."))
        #expect(!TranscriptSubstance.isWorthCleaning("Undo."))
    }

    /// Anything with real structure still gets cleaned — the feature must not
    /// quietly stop working for short sentences.
    @Test func ordinaryTranscriptsAreStillCleaned() {
        #expect(TranscriptSubstance.isWorthCleaning("undo that"))
        #expect(TranscriptSubstance.isWorthCleaning("the meeting is at three pm"))
        #expect(TranscriptSubstance.isWorthCleaning("um so their going to deploy it"))
    }
}
