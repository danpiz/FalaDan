import Foundation

/// Edit-mode backend for the `.gpt5Mini` / `.claudeHaiku45` model choices.
///
/// These used to post to the Anthropic / Codex inference endpoints using
/// tokens borrowed from the user's installed Claude Code / Codex CLIs,
/// impersonating those tools to get past the edge's identity checks. That
/// credential-reuse path has been deleted (Phase 2) and nothing has
/// replaced it — direct API access needs a key the user owns, which this
/// class does not have. Both model choices now fail with a clear error
/// pointing at `.custom` (`CustomEditProvider`), which posts to a
/// user-supplied endpoint with the user's own key and is unaffected.
@MainActor
final class EditModeProvider: Sendable {
    /// Selections above this size still proceed but the menu-bar status
    /// surfaces the char count so the user knows it'll take a while.
    static let softCharThreshold = 30_000

    /// Selections above this size are refused before we even hit the
    /// network — keeps edit mode focused on its "edit the bit you have
    /// selected" sweet spot and prevents runaway latency / cost on giant
    /// pastes.
    static let hardCharThreshold = 150_000

    static let systemPrompt = """
        You are an editing assistant. The user's instruction was spoken \
        aloud and converted to text by a speech-to-text model — it may \
        contain transcription errors, missing punctuation, homophone \
        mistakes, or words that don't quite match what was said. \
        Interpret the instruction charitably to capture what the user \
        actually meant, then apply it to the piece of text and return \
        only the edited result with no commentary, no labels, and no \
        surrounding quotes.
        """

    /// Wraps a raw transcript in the `<RAW_STT_OUTPUT>` tags the cleanup
    /// system prompt references.
    static func cleanupUserPrompt(transcript: String) -> String {
        """
        <RAW_STT_OUTPUT>
        \(transcript)
        </RAW_STT_OUTPUT>
        """
    }

    enum Error: LocalizedError {
        case backendRemoved(String)

        var errorDescription: String? {
            switch self {
            case .backendRemoved(let model):
                return
                    "\(model) used to run on credentials borrowed from another app's login — FalaDan no longer does that. Switch the edit model to Custom and supply your own API key."
            }
        }
    }

    func editText(
        instruction: String,
        selection: String,
        model: EditModeModel
    ) async throws -> String {
        throw Error.backendRemoved(model.rawValue)
    }
}
