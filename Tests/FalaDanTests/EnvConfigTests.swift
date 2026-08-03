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

    /// Quotes shield their contents from the line-level trim, so the value has
    /// to be trimmed again after they are stripped — otherwise the whitespace
    /// ends up inside the Authorization header.
    @Test func trimsInsideQuotes() {
        #expect(EnvConfig.parse(#"LLM_API_KEY="sk-abc  ""#).llmAPIKey == "sk-abc")
        #expect(EnvConfig.parse("LLM_MODEL='  m  '").llmModel == "m")
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

    /// Newlines count as blank too. The parser trims with
    /// `.whitespacesAndNewlines`, and this guard has to agree with it — a value
    /// that is only a newline must not read as a usable key.
    @Test func newlineOnlyValuesDoNotCountAsConfigured() {
        var c = EnvConfig.defaults
        c.llmAPIKey = "\n"
        c.llmModel = "m"
        #expect(!c.isCleanupConfigured)
    }

    /// A whitespace-only key is unset, not redacted — the log line should say so.
    @Test func descriptionReportsAWhitespaceOnlyKeyAsUnset() {
        var c = EnvConfig.defaults
        c.llmAPIKey = "   "
        #expect(c.description.contains("<unset>"))
    }
}

/// Secrets must never reach a log line or a crash report.
///
/// The invariant is stronger than "the key field is redacted": no user-supplied
/// string is echoed at all, from any field. Three versions of this tried to echo
/// the model id and base URL while filtering out anything key-shaped, and each
/// one both leaked a real key format and blanked a real config value. A
/// UUID-format token and an ordinary identifier are the same shape; there is no
/// rule to find.
struct EnvConfigRedactionTests {
    /// The whole contract, in one test: whatever goes into any string field,
    /// none of it comes back out.
    ///
    /// The strays are every documented provider's key format plus the ones that
    /// defeated a shape rule — UUID (longest run 12), dashed hex, AWS-style
    /// base64 with separators, and a dot-separated token. Each is tried in every
    /// field, because a mis-paste lands wherever the cursor was.
    @Test func noFieldEchoesItsValueIntoTheDescription() {
        let strays = [
            "gsk_" + String(repeating: "a1B2c3D4", count: 6),
            "sk-proj-" + String(repeating: "Xy9Z", count: 10),
            "sk-ant-api03-" + String(repeating: "Zq4", count: 20),
            "AIzaSyD" + String(repeating: "k3J", count: 11),
            "sk-or-v1-" + String(repeating: "9f", count: 32),
            "xai-" + String(repeating: "Qw7", count: 16),
            "hf_" + String(repeating: "Lm2", count: 12),
            "r8_" + String(repeating: "Pd8", count: 12),
            "3f2a91c4-7b8e-4d2f-9a10-6c5e8b4d2f71",
            "a1b2c3d4-e5f6a7b8-c9d0e1f2-a3b4c5d6-e7f8a9b0",
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "eyJhbGci.eyJzdWIiOiIx.dBjftJeZ4CVP",
        ]
        for stray in strays {
            var model = EnvConfig.defaults
            model.llmModel = stray
            #expect(!model.description.contains(stray), "leaked via model: \(stray)")

            var key = EnvConfig.defaults
            key.llmAPIKey = stray
            #expect(!key.description.contains(stray), "leaked via key: \(stray)")

            var base = EnvConfig.defaults
            base.llmBaseURL = stray
            #expect(!base.description.contains(stray), "leaked via baseURL: \(stray)")
        }
    }

    /// A key pasted into `LLM_BASE_URL=` parses as a relative path, so it has no
    /// host — which is exactly why reporting the host is safe where echoing the
    /// string was not.
    @Test func aBareKeyInTheBaseURLFieldHasNoHost() {
        #expect(EnvConfig.host(of: "gsk_" + String(repeating: "a1B2", count: 13)) == "<none>")
        #expect(EnvConfig.host(of: "") == "<none>")
        #expect(EnvConfig.host(of: "   ") == "<none>")
        #expect(EnvConfig.host(of: "not a url at all") == "<none>")
    }

    /// The host is the diagnostic payload — "which provider am I talking to" —
    /// and must survive for the endpoints this app documents, including ones
    /// whose path carries a long account id.
    @Test func theHostSurvivesForRealEndpoints() {
        #expect(EnvConfig.host(of: "https://api.groq.com/openai/v1") == "api.groq.com")
        #expect(
            EnvConfig.host(of: "https://generativelanguage.googleapis.com/v1beta/openai/")
                == "generativelanguage.googleapis.com")
        #expect(EnvConfig.host(of: "http://localhost:11434/v1") == "localhost")
        #expect(
            EnvConfig.host(of: "https://gateway.ai.cloudflare.com/v1/0123456789abcdef/gw/openai")
                == "gateway.ai.cloudflare.com")
    }

    /// Credentials a URL can carry — query parameters and user-info — are not
    /// part of the host, so they cannot ride along.
    @Test func hostDropsCredentialsCarriedInTheURL() {
        let query = "https://api.example.com/v1?api_key=sk-SECRET123"
        #expect(EnvConfig.host(of: query) == "api.example.com")

        let userInfo = "https://dan:hunter2@api.example.com/v1"
        #expect(EnvConfig.host(of: userInfo) == "api.example.com")

        var c = EnvConfig.defaults
        c.llmBaseURL = userInfo
        #expect(!c.description.contains("hunter2"))
        #expect(!c.description.contains("dan"))
    }

    /// Set/unset still has to be reported accurately, or the line says nothing.
    @Test func descriptionReportsPresenceAccurately() {
        var configured = EnvConfig.defaults
        configured.llmAPIKey = "gsk_realkey"
        configured.llmModel = "llama-3.3-70b-versatile"
        #expect(configured.description.contains("key: <set>"))
        #expect(configured.description.contains("model: <set>"))
        #expect(configured.description.contains("configured: true"))

        let bare = EnvConfig.defaults
        #expect(bare.description.contains("key: <unset>"))
        #expect(bare.description.contains("model: <unset>"))
        #expect(bare.description.contains("configured: false"))
    }
}
