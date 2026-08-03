import Foundation
import Testing

@testable import FalaDan

/// Parsing is tested against strings rather than files: the file lookup is two
/// lines, and everything that can actually go wrong lives in the parser.
struct EnvConfigParsingTests {
    @Test func anEmptyFileYieldsDefaults() {
        let config = EnvConfig.parse("")
        #expect(config == EnvConfig.defaults)
    }

    @Test func readsEveryKnownKey() {
        let config = EnvConfig.parse("""
            LLM_BASE_URL=https://example.test/v1
            LLM_API_KEY=sk-test-123
            LLM_MODEL=some-model
            LLM_CLEANUP=off
            MIN_HOLD_MS=250
            MIN_TRANSCRIBE_MS=500
            """)
        #expect(config.llmBaseURL == "https://example.test/v1")
        #expect(config.llmAPIKey == "sk-test-123")
        #expect(config.llmModel == "some-model")
        #expect(config.llmCleanupEnabled == false)
        #expect(config.minHoldMS == 250)
        #expect(config.minTranscribeMS == 500)
    }

    @Test func ignoresCommentsAndBlankLines() {
        let config = EnvConfig.parse("""
            # a comment
              # an indented comment

            LLM_MODEL=kept
            """)
        #expect(config.llmModel == "kept")
    }

    @Test func trimsWhitespaceAroundKeysAndValues() {
        let config = EnvConfig.parse("  LLM_MODEL  =  spaced-out  ")
        #expect(config.llmModel == "spaced-out")
    }

    @Test func stripsMatchingQuotes() {
        #expect(EnvConfig.parse(#"LLM_API_KEY="quoted""#).llmAPIKey == "quoted")
        #expect(EnvConfig.parse("LLM_API_KEY='quoted'").llmAPIKey == "quoted")
    }

    /// A lone quote is part of the value, not a delimiter — stripping it would
    /// silently corrupt a key that legitimately contains one.
    @Test func doesNotStripUnmatchedQuotes() {
        #expect(EnvConfig.parse(#"LLM_API_KEY="unmatched"#).llmAPIKey == #""unmatched"#)
    }

    /// A value containing '=' must survive: split on the first separator only.
    @Test func keepsEqualsSignsInsideValues() {
        #expect(EnvConfig.parse("LLM_API_KEY=abc=def==").llmAPIKey == "abc=def==")
    }

    @Test func skipsMalformedLinesWithoutDiscardingGoodOnes() {
        let config = EnvConfig.parse("""
            this line has no equals sign
            =novalue
            LLM_MODEL=survived
            """)
        #expect(config.llmModel == "survived")
    }

    @Test func unknownKeysAreIgnored() {
        let config = EnvConfig.parse("SOMETHING_ELSE=whatever\nLLM_MODEL=kept")
        #expect(config.llmModel == "kept")
    }

    /// A garbled number must not crash and must not become zero — zero would
    /// silently disable the accidental-tap guard.
    @Test func unparseableNumbersFallBackToDefaults() {
        let config = EnvConfig.parse("MIN_HOLD_MS=not-a-number")
        #expect(config.minHoldMS == EnvConfig.defaults.minHoldMS)
    }

    @Test func negativeNumbersFallBackToDefaults() {
        #expect(EnvConfig.parse("MIN_HOLD_MS=-50").minHoldMS == EnvConfig.defaults.minHoldMS)
    }

    /// Zero is explicitly allowed — it is the documented way to disable the
    /// minimum-hold guard, and must not be confused with "unset".
    @Test func zeroIsAcceptedForThresholds() {
        #expect(EnvConfig.parse("MIN_HOLD_MS=0").minHoldMS == 0)
    }

    @Test func cleanupFlagAcceptsCommonSpellings() {
        #expect(EnvConfig.parse("LLM_CLEANUP=off").llmCleanupEnabled == false)
        #expect(EnvConfig.parse("LLM_CLEANUP=false").llmCleanupEnabled == false)
        #expect(EnvConfig.parse("LLM_CLEANUP=0").llmCleanupEnabled == false)
        #expect(EnvConfig.parse("LLM_CLEANUP=OFF").llmCleanupEnabled == false)
        #expect(EnvConfig.parse("LLM_CLEANUP=on").llmCleanupEnabled == true)
    }

    /// An unrecognised value must not silently disable cleanup.
    @Test func anUnrecognisedCleanupValueLeavesItEnabled() {
        #expect(EnvConfig.parse("LLM_CLEANUP=maybe").llmCleanupEnabled == true)
    }

    /// A .env saved with Windows line endings must still parse — the trailing
    /// \r would otherwise make every key miss its case and silently yield
    /// defaults.
    @Test func handlesCarriageReturnLineEndings() {
        #expect(EnvConfig.parse("LLM_MODEL=crlf\r\n").llmModel == "crlf")
        #expect(EnvConfig.parse("MIN_HOLD_MS=200\r\n").minHoldMS == 200)
    }
}

/// Whether the cleanup call should be attempted at all. This is the single
/// condition keeping FalaDan usable offline now that cleanup is on by default —
/// if it ever returns true without real config, every dictation hits a failing
/// network call.
struct EnvConfigCleanupGateTests {
    private func config(key: String?, model: String?, enabled: Bool = true) -> EnvConfig {
        var c = EnvConfig.defaults
        c.llmAPIKey = key
        c.llmModel = model
        c.llmCleanupEnabled = enabled
        return c
    }

    @Test func configuredWhenKeyAndModelAreBothPresent() {
        #expect(config(key: "k", model: "m").isCleanupConfigured)
    }

    @Test func notConfiguredWithoutAKey() {
        #expect(!config(key: nil, model: "m").isCleanupConfigured)
    }

    @Test func notConfiguredWithoutAModel() {
        #expect(!config(key: "k", model: nil).isCleanupConfigured)
    }

    @Test func notConfiguredWhenExplicitlyDisabled() {
        #expect(!config(key: "k", model: "m", enabled: false).isCleanupConfigured)
    }

    /// A key present but blank is the same as absent — an empty assignment in
    /// .env must not count as configuration.
    @Test func blankValuesDoNotCountAsConfigured() {
        #expect(!EnvConfig.parse("LLM_API_KEY=\nLLM_MODEL=m").isCleanupConfigured)
    }

    /// Set directly rather than through `parse()`, which trims. The guard has to
    /// hold on its own: settings-UI values reach these fields without going
    /// through the parser.
    @Test func whitespaceOnlyValuesDoNotCountAsConfigured() {
        var c = EnvConfig.defaults
        c.llmAPIKey = "   "
        c.llmModel = "m"
        #expect(!c.isCleanupConfigured)

        c.llmAPIKey = "k"
        c.llmModel = "\t "
        #expect(!c.isCleanupConfigured)
    }
}

/// Secrets must never reach a log line or a crash report.
struct EnvConfigRedactionTests {
    @Test func descriptionRedactsTheApiKey() {
        var c = EnvConfig.defaults
        c.llmAPIKey = "sk-super-secret-value"
        #expect(!c.description.contains("sk-super-secret-value"))
    }

    @Test func descriptionStillShowsNonSecrets() {
        var c = EnvConfig.defaults
        c.llmModel = "some-model"
        #expect(c.description.contains("some-model"))
    }
}
