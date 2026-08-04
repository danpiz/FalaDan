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

    /// Select Groq, then remove `STT_API_KEY` and relaunch: the stored mode is
    /// `.groq`, but the row is hidden, so the user would have no way to pick
    /// anything else. Falling back keeps the app usable and the log says why.
    @Test func aStoredGroqModeFallsBackWhenUnconfigured() {
        #expect(
            TranscriptionMode.resolvingStoredMode(.groq, isGroqConfigured: false) == .default)
        #expect(
            TranscriptionMode.resolvingStoredMode(.groq, isGroqConfigured: true) == .groq)
        // Other modes are unaffected either way.
        #expect(
            TranscriptionMode.resolvingStoredMode(.multilingual, isGroqConfigured: false)
                == .multilingual)
        #expect(
            TranscriptionMode.resolvingStoredMode(.custom, isGroqConfigured: false) == .custom)
    }
}
