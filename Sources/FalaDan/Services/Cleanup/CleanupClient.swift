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
        let text =
            decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw CleanupClientError.emptyResponse }
        return text
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
