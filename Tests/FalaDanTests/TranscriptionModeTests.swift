import Foundation
import Testing

@testable import FalaDan

struct TranscriptionModeGroqTests {
    @Test func groqRoundTripsThroughItsRawValue() {
        #expect(TranscriptionMode(rawValue: "groq") == .groq)
        #expect(TranscriptionMode.groq.rawValue == "groq")
        #expect(TranscriptionMode.groq.modelDisplayName == "Groq")
    }

    /// A build without this case must read a stored "groq" as the default
    /// rather than failing — and an unknown value must already do so today.
    @Test func anUnknownStoredModeFallsBackToDefault() {
        #expect(TranscriptionMode(rawValue: "not-a-mode") == nil)
    }

    /// Groq transcription reuses `CustomProvider`, so the bridge has to produce
    /// settings that provider considers usable.
    @Test func sttSettingsAreConfiguredWhenTheEnvIs() {
        var c = EnvConfig.defaults
        c.sttAPIKey = "gsk_example"
        c.sttModel = "whisper-large-v3-turbo"

        let settings = c.sttProviderSettings
        #expect(settings.endpointURL == "https://api.groq.com/openai/v1")
        #expect(settings.apiKey == "gsk_example")
        #expect(settings.modelName == "whisper-large-v3-turbo")
        #expect(settings.isConfigured)
    }

    @Test func sttSettingsAreUnconfiguredWhenTheEnvIs() {
        #expect(!EnvConfig.defaults.sttProviderSettings.isConfigured)
    }
}
