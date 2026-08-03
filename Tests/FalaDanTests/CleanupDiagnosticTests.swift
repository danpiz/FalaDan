import Foundation
import Testing

@testable import FalaDan

/// The cleanup-failure log line.
///
/// Cleanup runs on every dictation and fails silently by design, so this string
/// is the only evidence a user or maintainer ever gets that something is wrong.
/// It has to be specific enough to act on, and it must never carry a secret —
/// several providers echo part of the submitted key back in a 401 body.
@MainActor
struct CleanupDiagnosticTests {
    @Test func reportsTheStatusCodeForServerErrors() {
        let d = AppState.diagnostic(for: CleanupClientError.serverError(401, "whatever"))
        #expect(d.contains("401"))
    }

    /// The single most important assertion here: a response body must never
    /// reach the log, because a 401 body can contain a prefix of the API key.
    @Test func neverIncludesTheResponseBody() {
        let body = "invalid api key sk-live-abc123"
        let d = AppState.diagnostic(for: CleanupClientError.serverError(401, body))
        #expect(!d.contains("sk-live-abc123"))
        #expect(!d.contains(body))
    }

    @Test func distinguishesTheFailureKinds() {
        #expect(AppState.diagnostic(for: CleanupClientError.notConfigured) != "")
        #expect(
            AppState.diagnostic(for: CleanupClientError.notConfigured)
                != AppState.diagnostic(for: CleanupClientError.emptyResponse))
        #expect(
            AppState.diagnostic(for: CleanupClientError.invalidEndpoint)
                != AppState.diagnostic(for: CleanupClientError.emptyResponse))
    }

    /// A bad endpoint is the one failure whose fix is a specific `.env` key, so
    /// the line names it rather than leaving the user to guess.
    @Test func namesTheConfigKeyForAnInvalidEndpoint() {
        #expect(AppState.diagnostic(for: CleanupClientError.invalidEndpoint)
            .contains("LLM_BASE_URL"))
    }

    /// Timeout and offline are different problems with different fixes, and both
    /// arrive as URLError — so the code has to survive into the log.
    @Test func reportsTheUnderlyingCodeForNetworkFailures() {
        let timedOut = URLError(.timedOut)
        #expect(
            AppState.diagnostic(for: timedOut)
                .contains(String(URLError.Code.timedOut.rawValue)))

        #expect(
            AppState.diagnostic(for: URLError(.notConnectedToInternet))
                != AppState.diagnostic(for: timedOut))
    }
}
