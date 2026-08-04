import Foundation
import Testing

@testable import FalaDan

/// Guards the one bug this phase actually shipped and then fixed.
///
/// `loadSelectedModel` returns early for modes with no local model to download.
/// When `.groq` was added, its arm was added to the *inner* switch but not to
/// the guard above it, so `.groq` fell through to `state = .loading` and then
/// returned — stuck loading forever, with recording refused and no way out.
///
/// A review caught it, and then caught something worse: reverting the fix still
/// passed all 249 tests. Nothing observed the coordinator's state for `.groq` at
/// all. This test exists so that undoing the guard fails loudly.
@MainActor
struct ModelLoadCoordinatorGroqTests {
    private func coordinator(remoteSettings: CustomProviderSettings) -> ModelLoadCoordinator {
        ModelLoadCoordinator(
            initialMode: .default,
            remoteSettings: .empty,
            parakeet: ParakeetProvider(),
            whisper: WhisperProvider(),
            toast: .shared
        )
    }

    private var configured: CustomProviderSettings {
        CustomProviderSettings(
            endpointURL: "https://api.groq.com/openai/v1",
            apiKey: "gsk_example",
            modelName: "whisper-large-v3-turbo"
        )
    }

    /// Selecting Groq must settle immediately — there is nothing to download.
    @Test func selectingGroqNeverStrandsTheLoadingState() {
        let loader = coordinator(remoteSettings: .empty)

        loader.loadSelectedModel(mode: .groq, remoteSettings: configured)
        #expect(loader.state == .ready, "configured Groq should be ready, not loading")

        loader.loadSelectedModel(mode: .groq, remoteSettings: .empty)
        #expect(loader.state == .idle, "unconfigured Groq should be idle, not loading")
    }

    /// The same property for `.custom`, which shares the guard. If someone
    /// narrows it back to one clause, one of these two tests fails whichever
    /// mode they leave out.
    @Test func selectingCustomNeverStrandsTheLoadingState() {
        let loader = coordinator(remoteSettings: .empty)

        loader.loadSelectedModel(mode: .custom, remoteSettings: configured)
        #expect(loader.state == .ready)

        loader.loadSelectedModel(mode: .custom, remoteSettings: .empty)
        #expect(loader.state == .idle)
    }
}
