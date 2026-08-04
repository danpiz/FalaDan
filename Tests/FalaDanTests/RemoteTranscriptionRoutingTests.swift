import Foundation
import Testing

@testable import FalaDan

/// Where a recording gets uploaded.
///
/// The most consequential mapping in the transcription path, and the one whose
/// failure is silent: swap the two remote arms and Groq dictation goes to the
/// user's private Custom endpoint while Custom dictation goes to Groq under
/// `STT_API_KEY`. Both requests succeed and return a transcript, so no toast,
/// no log and no crash would ever reveal it.
///
/// A whole-branch review swapped exactly those arms and watched all 251 tests
/// pass. That is what these assertions are for.
@MainActor
struct RemoteTranscriptionRoutingTests {
    private var env: EnvConfig {
        var c = EnvConfig.defaults
        c.sttBaseURL = "https://api.groq.com/openai/v1"
        c.sttAPIKey = "gsk_from_dotenv"
        c.sttModel = "whisper-large-v3-turbo"
        return c
    }

    private var custom: CustomProviderSettings {
        CustomProviderSettings(
            endpointURL: "https://private.example.com/v1",
            apiKey: "key_from_the_settings_ui",
            modelName: "some-local-model"
        )
    }

    private func settings(for mode: TranscriptionMode) -> CustomProviderSettings {
        AppState.remoteTranscriptionSettings(
            for: mode, envConfig: env, customSettings: custom)
    }

    /// Groq takes its endpoint and key from `.env`, never from the settings UI.
    @Test func groqUsesTheEnvConfiguredEndpoint() {
        let resolved = settings(for: .groq)
        #expect(resolved.endpointURL == "https://api.groq.com/openai/v1")
        #expect(resolved.apiKey == "gsk_from_dotenv")
        #expect(resolved.modelName == "whisper-large-v3-turbo")
    }

    /// Custom takes its endpoint and key from the settings UI, never from
    /// `.env` — a user's private endpoint must not start receiving audio
    /// because they configured Groq for something else.
    @Test func customUsesTheSettingsUIEndpoint() {
        let resolved = settings(for: .custom)
        #expect(resolved.endpointURL == "https://private.example.com/v1")
        #expect(resolved.apiKey == "key_from_the_settings_ui")
        #expect(resolved.modelName == "some-local-model")
    }

    /// Stated as its own assertion rather than left implied by the two above:
    /// this is the property that actually matters, and an arm swap breaks it
    /// while leaving both endpoints individually "valid".
    @Test func theTwoRemoteModesNeverShareAnEndpoint() {
        #expect(settings(for: .groq).endpointURL != settings(for: .custom).endpointURL)
        #expect(settings(for: .groq).apiKey != settings(for: .custom).apiKey)
    }

    /// The local models upload nothing, so they must resolve to settings that
    /// `CustomProvider` would refuse outright.
    @Test func localModesResolveToNothingUsable() {
        for mode in [TranscriptionMode.default, .multilingual] {
            let resolved = settings(for: mode)
            #expect(resolved.endpointURL.isEmpty, "\(mode.rawValue) resolved an endpoint")
            #expect(resolved.apiKey.isEmpty, "\(mode.rawValue) resolved a key")
            #expect(!resolved.isConfigured)
        }
    }
}
