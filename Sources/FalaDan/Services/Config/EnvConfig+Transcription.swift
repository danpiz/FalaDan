import Foundation

extension EnvConfig {
    /// Groq transcription expressed as the settings `CustomProvider` already
    /// takes.
    ///
    /// The whole of Groq mode is this bridge: `CustomProvider` posts multipart
    /// audio to any OpenAI-compatible `/v1/audio/transcriptions`, and Groq is
    /// one. Nothing about the request differs — only where the configuration
    /// came from, `.env` rather than the settings UI.
    ///
    /// Built per call and never persisted: `.env` is the source of truth, and a
    /// copy on disk would be a second one.
    var sttProviderSettings: CustomProviderSettings {
        CustomProviderSettings(
            endpointURL: sttBaseURL,
            apiKey: sttAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            modelName: sttModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
