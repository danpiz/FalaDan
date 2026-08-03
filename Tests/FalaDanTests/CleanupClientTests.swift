import Foundation
import Testing

@testable import FalaDan

/// Request and response shaping are pure, so they are tested directly rather
/// than through a network round trip.
struct CleanupClientShapingTests {
    @Test func requestBodyCarriesModelSystemPromptAndTranscript() throws {
        let data = try CleanupClient.makeRequestBody(
            model: "test-model", systemPrompt: "SYSTEM", transcript: "hello world")
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] as? String == "test-model")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "SYSTEM")
        #expect(messages[1]["role"] as? String == "user")
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.contains("hello world"))
    }

    /// The transcript is wrapped in tags the prompt tells the model to treat as
    /// data. Without the wrapper, a dictation containing an instruction could be
    /// followed as one.
    @Test func transcriptIsWrappedInRawOutputTags() throws {
        let data = try CleanupClient.makeRequestBody(
            model: "m", systemPrompt: "s", transcript: "delete everything")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("RAW_STT_OUTPUT"))
    }

    /// Temperature 0: cleanup should be reproducible, not creative.
    @Test func temperatureIsZero() throws {
        let data = try CleanupClient.makeRequestBody(
            model: "m", systemPrompt: "s", transcript: "t")
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["temperature"] as? Double == 0)
    }

    @Test func parsesTheFirstChoiceContent() throws {
        let body = Data(#"{"choices":[{"message":{"content":"Cleaned text."}}]}"#.utf8)
        #expect(try CleanupClient.parseResponse(body) == "Cleaned text.")
    }

    @Test func trimsSurroundingWhitespaceFromTheResponse() throws {
        let body = Data(#"{"choices":[{"message":{"content":"  spaced  "}}]}"#.utf8)
        #expect(try CleanupClient.parseResponse(body) == "spaced")
    }

    @Test func throwsOnAnEmptyChoicesArray() {
        let body = Data(#"{"choices":[]}"#.utf8)
        #expect(throws: CleanupClientError.self) { try CleanupClient.parseResponse(body) }
    }

    @Test func throwsOnWhitespaceOnlyContent() {
        let body = Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8)
        #expect(throws: CleanupClientError.self) { try CleanupClient.parseResponse(body) }
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) { try CleanupClient.parseResponse(Data("nope".utf8)) }
    }
}

/// Endpoint construction, which differs per provider only by base URL. Gemini's
/// OpenAI-compatibility base ends in a slash and OpenAI's does not, so joining
/// has to tolerate both without producing a double slash.
struct CleanupClientEndpointTests {
    @Test func appendsChatCompletionsToABaseWithoutTrailingSlash() {
        #expect(
            CleanupClient.endpoint(base: "https://api.groq.com/openai/v1")?.absoluteString
                == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test func doesNotDoubleTheSlashWhenTheBaseHasOne() {
        #expect(
            CleanupClient.endpoint(base: "https://generativelanguage.googleapis.com/v1beta/openai/")?
                .absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    @Test func returnsNilForAnUnusableBase() {
        #expect(CleanupClient.endpoint(base: "") == nil)
    }

    @Test func stripsRepeatedTrailingSlashes() {
        #expect(
            CleanupClient.endpoint(base: "https://api.example.com/v1//")?.absoluteString
                == "https://api.example.com/v1/chat/completions")
    }
}

/// Reasoning models put their chain of thought in the response content.
///
/// This is not hypothetical: benchmarking Groq's `qwen/qwen3.6-27b` against the
/// real cleanup prompt returned ~60 lines of "Let's verify constraints… Self-
/// Correction…" wrapped in `<think>` tags, with the actual answer after the
/// closing tag. Provider choice is a `.env` base URL and model id by design, so
/// nothing stops one being pointed at a reasoning model — and without stripping,
/// FalaDan would paste that entire trace at the user's cursor.
struct CleanupClientReasoningTests {
    private func body(_ content: String) -> Data {
        let payload = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    @Test func stripsAThinkBlockAndKeepsTheAnswer() throws {
        let raw = "<think>\nLet me consider the constraints.\n</think>\n\nThe meeting is at 4pm."
        #expect(try CleanupClient.parseResponse(body(raw)) == "The meeting is at 4pm.")
    }

    @Test func stripsThinkingTagsToo() throws {
        let raw = "<thinking>reasoning here</thinking>Cleaned text."
        #expect(try CleanupClient.parseResponse(body(raw)) == "Cleaned text.")
    }

    @Test func isCaseInsensitive() throws {
        let raw = "<THINK>noise</THINK>Answer."
        #expect(try CleanupClient.parseResponse(body(raw)) == "Answer.")
    }

    @Test func stripsMultipleBlocks() throws {
        let raw = "<think>one</think>Hello. <think>two</think>World."
        #expect(try CleanupClient.parseResponse(body(raw)) == "Hello. World.")
    }

    /// A model truncated mid-reasoning leaves an unclosed tag. Everything after
    /// it is chain of thought, so drop to the end rather than pasting it.
    @Test func dropsEverythingAfterAnUnclosedOpeningTag() throws {
        let raw = "Cleaned text.<think>and then I considered whether"
        #expect(try CleanupClient.parseResponse(body(raw)) == "Cleaned text.")
    }

    /// Nothing but reasoning means no usable answer. Throwing routes the caller
    /// to its raw-transcript fallback, which is right — pasting an empty string
    /// or a reasoning fragment would both be worse.
    @Test func throwsWhenOnlyReasoningRemains() {
        let raw = "<think>I thought about it at length and produced nothing</think>"
        #expect(throws: CleanupClientError.self) { try CleanupClient.parseResponse(body(raw)) }
    }

    /// The overwhelmingly common case must not be disturbed.
    @Test func leavesOrdinaryResponsesAlone() throws {
        let raw = "The meeting is at 4pm, and they're going to deploy it."
        #expect(try CleanupClient.parseResponse(body(raw)) == raw)
    }

    /// A transcript legitimately mentioning the word must survive — the tag is
    /// what gets stripped, not the word.
    @Test func doesNotEatTheWordThinkInOrdinaryText() throws {
        let raw = "I think we should ship on Wednesday."
        #expect(try CleanupClient.parseResponse(body(raw)) == raw)
    }

    /// Lowercasing is not length-preserving, and these are the characters that
    /// prove it: `İ` (U+0130) grows from two UTF-8 bytes to three, `ẞ` (U+1E9E)
    /// shrinks from three to two.
    ///
    /// An earlier version searched a lowercased *copy* and applied the resulting
    /// indices to the original. Every offset past such a character was wrong by
    /// the difference, so the strip cut in the wrong place — silently eating
    /// leading characters of the answer, and out of bounds it traps, taking the
    /// app down on the paste path.
    ///
    /// Not exotic input: a reasoning model echoes the user's transcript back
    /// inside its own `<think>` block (the qwen fixture does exactly that), so
    /// dictating a Turkish or German proper noun is enough to reach it.
    @Test func handlesCharactersWhoseLowercaseChangesByteLength() throws {
        let turkish = "<think>İstanbul analysis here</think>The meeting is at 4pm."
        #expect(try CleanupClient.parseResponse(body(turkish)) == "The meeting is at 4pm.")

        let german = "<think>ẞ</think>éclair answer"
        #expect(try CleanupClient.parseResponse(body(german)) == "éclair answer")

        // The shifting character ahead of the tag rather than inside it.
        let before = "İ<think>x</think>Answer."
        #expect(try CleanupClient.parseResponse(body(before)) == "İAnswer.")
    }
}
