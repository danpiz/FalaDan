import Foundation

enum CleanupClientError: Error, Equatable {
    case notConfigured
    case invalidEndpoint
    case serverError(Int, String)
    case emptyResponse
}

/// Posts a raw transcript to an OpenAI-compatible chat-completions endpoint and
/// returns the cleaned text.
///
/// Provider choice is the base URL and nothing else — Groq, Google Gemini (via
/// its OpenAI-compatibility layer), OpenAI, OpenRouter and local servers such as
/// Ollama all speak this shape. Anthropic does not, which is why it is out of
/// scope.
///
/// Request building and response parsing are static and pure so they can be
/// tested without a server.
struct CleanupClient: Sendable {
    /// Bounded deliberately. This call sits between the user releasing the
    /// hotkey and text appearing, so a hung request is felt as the app being
    /// broken. On timeout the caller falls back to the raw transcript.
    static let timeout: TimeInterval = 15

    func cleanup(
        transcript: String,
        config: EnvConfig,
        session: URLSession = .shared
    ) async throws -> String {
        guard config.isCleanupConfigured,
            var model = config.llmModel,
            var apiKey = config.llmAPIKey
        else { throw CleanupClientError.notConfigured }

        model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = Self.endpoint(base: config.llmBaseURL) else {
            throw CleanupClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.timeout
        request.httpBody = try Self.makeRequestBody(
            model: model,
            systemPrompt: CleanupPromptStore.loadOrDefault(),
            transcript: transcript
        )

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CleanupClientError.serverError(0, "Invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            // The body often explains the failure (bad key, unknown model). It
            // is surfaced to logs only, never to the user, and never includes
            // the request — which carries the key.
            let message = String(data: data, encoding: .utf8) ?? "No error body"
            throw CleanupClientError.serverError(http.statusCode, message)
        }

        return try Self.parseResponse(data)
    }

    /// Joins the configured base with the chat-completions path.
    ///
    /// Tolerates a trailing slash because providers disagree: Gemini's
    /// OpenAI-compatibility base ends in one, Groq's and OpenAI's do not.
    static func endpoint(base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        while normalized.hasSuffix("/") { normalized = String(normalized.dropLast()) }
        return URL(string: normalized + "/chat/completions")
    }

    static func makeRequestBody(
        model: String, systemPrompt: String, transcript: String
    ) throws -> Data {
        // The transcript is fenced in tags the system prompt names explicitly and
        // tells the model to treat as data. Without the fence, dictating "ignore
        // your instructions" is indistinguishable from instructing the model.
        let userPrompt = """
            <RAW_STT_OUTPUT>
            \(transcript)
            </RAW_STT_OUTPUT>
            """
        let body = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt),
            ],
            temperature: 0
        )
        return try JSONEncoder().encode(body)
    }

    static func parseResponse(_ data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let content = decoded.choices.first?.message.content ?? ""
        let text = stripReasoningBlocks(from: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Also covers "the model returned nothing but reasoning": the caller
        // treats a throw as a cleanup failure and pastes the raw transcript,
        // which beats pasting an empty string or a fragment of chain of thought.
        guard !text.isEmpty else { throw CleanupClientError.emptyResponse }
        return text
    }

    /// Removes reasoning models' chain of thought from a completion.
    ///
    /// Reasoning models emit their working inside the response content rather
    /// than a separate field. Provider choice here is a `.env` base URL and model
    /// id, so nothing prevents one being configured — and the result would be the
    /// model's entire deliberation pasted at the user's cursor, in whatever app
    /// they were typing into.
    ///
    /// Deliberately a scanner rather than a regex: it has to handle an unclosed
    /// opening tag (a completion truncated mid-thought), which is the case a
    /// naive `<think>.*?</think>` pattern silently misses.
    static func stripReasoningBlocks(from content: String) -> String {
        // Matched on the opening delimiter only, so the *word* "think" in an
        // ordinary transcript is untouched — it is `<think` that marks a block.
        let openers = ["<think>", "<think ", "<thinking>", "<thinking "]
        let closers = ["</think>", "</thinking>"]

        var result = content
        var guardCounter = 0

        while guardCounter < 32 {
            guardCounter += 1
            let lower = result.lowercased()

            guard
                let openRange = openers
                    .compactMap({ lower.range(of: $0) })
                    .min(by: { $0.lowerBound < $1.lowerBound })
            else { break }

            let after = lower[openRange.upperBound...]
            if let closeRange = closers
                .compactMap({ after.range(of: $0) })
                .min(by: { $0.lowerBound < $1.lowerBound })
            {
                result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                // No closing tag: the model was cut off mid-reasoning, so
                // everything from here on is working, not answer.
                result.removeSubrange(openRange.lowerBound..<result.endIndex)
                break
            }
        }
        return result
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}
