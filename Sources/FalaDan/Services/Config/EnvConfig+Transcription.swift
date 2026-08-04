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
    /// **Readiness does not re-check the key.** `CustomProviderSettings
    /// .isConfigured` tests only the endpoint and model name, so these settings
    /// report configured whenever a model is set — the base URL always has a
    /// default. What stops an unkeyed Groq from being selectable is
    /// `isGroqTranscriptionConfigured`, which gates both the picker row and the
    /// stale-selection fallback. Loosen that gate and `.groq` goes `.ready` with
    /// no key, the not-configured toast never fires, and every dictation dies on
    /// a 401 instead.
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
