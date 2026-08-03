# FalaDan Phase 2 Implementation Plan — Own Your Own Credentials

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** FalaDan reads Dan's own API key from a `.env` file, cleans up every dictation through an OpenAI-compatible LLM, and no longer contains any code that borrows credentials from another application.

**Architecture:** A pure `EnvConfig` value type parsed once at launch, and a `CleanupClient` posting to an OpenAI-compatible `/chat/completions` endpoint. Both replace the existing `EditModeProvider` / `CustomEditProvider` / OAuth stack, which is then deleted. `CustomEditProvider` is already an OpenAI-compatible client, so the new client is a rewrite of proven code keyed off config instead of UserDefaults.

**Tech Stack:** Swift 6, SPM, Swift Testing (`import Testing`, `@Test`, `#expect`), URLSession, AppKit.

**Spec:** `docs/superpowers/specs/2026-08-02-phase-2-env-config-and-cleanup.md`

## Global Constraints

- Verification is **always** `./Scripts/verify.sh --dirty` mid-task, `./Scripts/verify.sh` at a task boundary. Never hand-compose `swift build` / `swift test` — bare `swift test` fails on this machine (Command Line Tools, no Xcode).
- macOS 14.0+, Swift 6.0+, SPM only. No Xcode, no `.xcodeproj`.
- Do **not** modify `Services/Hotkeys/CustomShortcutMonitor.swift`, `FnStateMachine.swift`, `ModifierTapMonitor.swift`, `EventTapRunLoop.swift`, `KeyDownObserver.swift`, `CarbonHotKeyCenter.swift`, or `Services/PasteboardService.swift` unless a task names them explicitly. They are `opus-supervised`.
- **Never commit a `.env`.** `.gitignore` already excludes it. `.env.example` is the only committed config file, and it must contain no real key.
- **Never log a secret.** Anything read from a key ending `_KEY` is redacted in descriptions and log lines.
- Baseline at the start of this plan is **165 tests in 33 suites**.
- **Do not adjust a test file to match a number in this plan.** Where a task names an expected
  total it is a sanity check, not a target: the suite must grow by exactly the number of `@Test`
  cases you added, and no existing test may start being skipped. If your actual count differs
  from the stated one, report the real number and carry on — the plan's arithmetic is the thing
  that is wrong, not your run.
- `AppState.toggleRecording()` has no callers and is retained deliberately — do not delete it.

---

### Task 1: EnvConfig

**Executor:** `sonnet-alone`

The config type. Pure and dependency-free so the whole thing is testable by parsing strings — no filesystem, no network.

**Files:**
- Create: `Sources/FalaDan/Services/Config/EnvConfig.swift`
- Create: `Tests/FalaDanTests/EnvConfigTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct EnvConfig` with `parse(_:)`, `load()`, `isCleanupConfigured`, `minHold`, `minTranscribe`, and the stored properties below. Tasks 2, 3 and 8 all consume it.

- [ ] **Step 1: Write the failing test**

Create `Tests/FalaDanTests/EnvConfigTests.swift`:

```swift
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
    /// \r would otherwise make every key miss its case, silently yielding
    /// defaults with no error surfaced.
    @Test func handlesCarriageReturnLineEndings() {
        let config = EnvConfig.parse("LLM_MODEL=crlf\r\nMIN_HOLD_MS=200\r\n")
        #expect(config.llmModel == "crlf")
        #expect(config.minHoldMS == 200)
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
    /// hold on its own: the settings UI feeds these fields when a `.env` key is
    /// absent, and those values are not guaranteed trimmed.
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./Scripts/verify.sh --dirty`
Expected: FAIL — compile error, `cannot find 'EnvConfig' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/FalaDan/Services/Config/EnvConfig.swift`:

```swift
import Foundation

/// Runtime configuration, read once at launch from a `.env` file.
///
/// Config lives in a file rather than the settings UI so API keys never enter
/// UserDefaults and are never synced anywhere. Values absent from the file fall
/// through to the defaults here, and — for anything the settings UI also owns —
/// the caller falls back to the stored UserDefaults value. That is what lets the
/// existing UI keep working instead of being deleted.
///
/// Parsed once and never mutated: changing `.env` requires a relaunch. Reloading
/// mid-session would mean a recording could start under one config and finish
/// under another.
struct EnvConfig: Equatable, Sendable, CustomStringConvertible {
    /// OpenAI-compatible chat-completions base URL. Provider choice is entirely
    /// this value — Groq, Gemini, OpenAI, OpenRouter and local servers all speak
    /// the same shape.
    var llmBaseURL: String
    var llmAPIKey: String?
    /// No default on purpose. Hosted model ids get renamed and retired, so a
    /// compiled-in constant turns into a silent failure the day it is deprecated;
    /// requiring it makes the failure "you did not configure this" instead.
    var llmModel: String?
    var llmCleanupEnabled: Bool
    var minHoldMS: Int
    var minTranscribeMS: Int

    static let defaults = EnvConfig(
        llmBaseURL: "https://api.groq.com/openai/v1",
        llmAPIKey: nil,
        llmModel: nil,
        llmCleanupEnabled: true,
        minHoldMS: 150,
        minTranscribeMS: 300
    )

    /// Whether to attempt the cleanup call at all.
    ///
    /// Load-bearing. Cleanup runs on every dictation now, so this is the only
    /// thing standing between an unconfigured install and a failing network call
    /// per utterance — and it is what keeps the app fully offline when no key is
    /// set.
    /// Trims inside the guard rather than trusting the caller. `parse()` already
    /// trims, but the settings UI feeds these same fields when a `.env` key is
    /// absent, and a whitespace-only value from a text field must not read as
    /// configured.
    var isCleanupConfigured: Bool {
        guard llmCleanupEnabled else { return false }
        guard let key = llmAPIKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty
        else { return false }
        guard let model = llmModel?.trimmingCharacters(in: .whitespaces), !model.isEmpty
        else { return false }
        return true
    }

    var minHold: TimeInterval { TimeInterval(minHoldMS) / 1000 }
    var minTranscribe: TimeInterval { TimeInterval(minTranscribeMS) / 1000 }

    /// Redacts the API key. This type ends up in log lines and crash reports.
    var description: String {
        let key = (llmAPIKey?.isEmpty == false) ? "<redacted>" : "<unset>"
        return """
            EnvConfig(baseURL: \(llmBaseURL), key: \(key), \
            model: \(llmModel ?? "<unset>"), cleanup: \(llmCleanupEnabled), \
            minHoldMS: \(minHoldMS), minTranscribeMS: \(minTranscribeMS))
            """
    }

    // MARK: - Loading

    /// Searched in order; the first file that exists wins.
    static var searchPaths: [URL] {
        var paths: [URL] = []
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            paths.append(support.appendingPathComponent("FalaDan/.env"))
        }
        // Development convenience: a .env beside the sources when running from a
        // checkout. Never present in an installed app.
        paths.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env"))
        return paths
    }

    /// An absent file is not an error — it means "use the defaults", which is a
    /// fully working offline configuration.
    static func load() -> EnvConfig {
        for url in searchPaths {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return parse(contents)
            }
        }
        return defaults
    }

    // MARK: - Parsing

    static func parse(_ contents: String) -> EnvConfig {
        var config = defaults

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            // `.whitespacesAndNewlines`, not `.whitespaces`: a file saved with
            // CRLF endings leaves a trailing \r on every line after splitting on
            // \n, and "LLM_MODEL\r" matches no case below — so the whole file
            // would parse to defaults, silently and with no error.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // First separator only: a value may legitimately contain '='.
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            let value = unquote(
                line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))

            switch key {
            case "LLM_BASE_URL": if !value.isEmpty { config.llmBaseURL = value }
            case "LLM_API_KEY": config.llmAPIKey = value
            case "LLM_MODEL": config.llmModel = value
            case "LLM_CLEANUP": config.llmCleanupEnabled = parseBool(value)
            case "MIN_HOLD_MS":
                config.minHoldMS = parseMilliseconds(value, default: defaults.minHoldMS)
            case "MIN_TRANSCRIBE_MS":
                config.minTranscribeMS =
                    parseMilliseconds(value, default: defaults.minTranscribeMS)
            default: continue  // Unknown keys are ignored, not an error.
            }
        }
        return config
    }

    /// Strips one layer of matching quotes. Unmatched quotes are part of the
    /// value — stripping those would corrupt a key that contains one.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
            first == last, first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Anything not recognisably falsy stays enabled: a typo must not silently
    /// switch cleanup off, because the symptom would be indistinguishable from
    /// the model simply doing nothing.
    private static func parseBool(_ value: String) -> Bool {
        !["off", "false", "0", "no"].contains(value.lowercased())
    }

    /// Zero is valid — it is the documented way to disable a threshold. Negative
    /// and unparseable values fall back rather than becoming zero, since silently
    /// disabling a guard is worse than ignoring a typo.
    private static func parseMilliseconds(_ value: String, default fallback: Int) -> Int {
        guard let parsed = Int(value), parsed >= 0 else { return fallback }
        return parsed
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass. 21 new `@Test` cases across 3 new suites (≈186 in 36).

- [ ] **Step 5: Commit**

```bash
git add Sources/FalaDan/Services/Config/EnvConfig.swift Tests/FalaDanTests/EnvConfigTests.swift
git commit -m "Add EnvConfig for .env-based runtime configuration

Pure value type, parsed from a string so the whole parser is testable
without a filesystem. Keys absent from .env fall back to defaults that
constitute a working offline configuration.

isCleanupConfigured is the load-bearing one: cleanup runs on every
dictation after this phase, so it is the only thing between an
unconfigured install and a failed network call per utterance."
```

**Done means:** `./Scripts/verify.sh --dirty` passes with 21 new tests, `EnvConfig` imports nothing beyond `Foundation`, and no test touches the filesystem.

---

### Task 2: CleanupClient

**Executor:** `sonnet-alone`

The OpenAI-compatible client. `Sources/FalaDan/Services/CustomEditProvider.swift` is the working reference — read it first; this is that code keyed off `EnvConfig` instead of `CustomEditProviderSettings`, with the request and response shaping pulled out as pure functions.

**Files:**
- Create: `Sources/FalaDan/Services/Cleanup/CleanupClient.swift`
- Create: `Tests/FalaDanTests/CleanupClientTests.swift`
- Read for reference, do not modify: `Sources/FalaDan/Services/CustomEditProvider.swift`

**Interfaces:**
- Consumes: `EnvConfig` (Task 1). `CleanupPromptStore.loadOrDefault()` and `EditModeProvider.cleanupUserPrompt(transcript:)` already exist — but **do not call `EditModeProvider`**, it is deleted in Task 6. Inline the `<RAW_STT_OUTPUT>` wrapper as shown.
- Produces: `CleanupClient.cleanup(transcript:config:session:)`, plus `CleanupClient.makeRequestBody(...)` and `CleanupClient.parseResponse(_:)`. Task 3 calls `cleanup`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FalaDanTests/CleanupClientTests.swift`:

```swift
import Foundation
import Testing

@testable import FalaDan

/// Request and response shaping are pure, so they are tested directly rather
/// than through a network round trip.
struct CleanupClientShapingTests {
    @Test func requestBodyCarriesModelSystemPromptAndTranscript() throws {
        let data = try CleanupClient.makeRequestBody(
            model: "test-model", systemPrompt: "SYSTEM", transcript: "hello world")
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] as? String == "test-model")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "SYSTEM")
        #expect(messages[1]["role"] as? String == "user")
        let user = try #require(messages[1]["content"] as? String)
        #expect(user.contains("hello world"))
    }

    /// The transcript is wrapped in tags the prompt tells the model to treat as
    /// data. Without the wrapper, a dictation containing an instruction could be
    /// followed as one.
    @Test func transcriptIsWrappedInRawOutputTags() throws {
        let data = try CleanupClient.makeRequestBody(
            model: "m", systemPrompt: "s", transcript: "delete everything")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("RAW_STT_OUTPUT"))
    }

    /// Temperature 0: cleanup should be reproducible, not creative.
    @Test func temperatureIsZero() throws {
        let data = try CleanupClient.makeRequestBody(
            model: "m", systemPrompt: "s", transcript: "t")
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["temperature"] as? Double == 0)
    }

    @Test func parsesTheFirstChoiceContent() throws {
        let body = Data(#"{"choices":[{"message":{"content":"Cleaned text."}}]}"#.utf8)
        #expect(try CleanupClient.parseResponse(body) == "Cleaned text.")
    }

    @Test func trimsSurroundingWhitespaceFromTheResponse() throws {
        let body = Data(#"{"choices":[{"message":{"content":"  spaced  "}}]}"#.utf8)
        #expect(try CleanupClient.parseResponse(body) == "spaced")
    }

    @Test func throwsOnAnEmptyChoicesArray() {
        let body = Data(#"{"choices":[]}"#.utf8)
        #expect(throws: CleanupClientError.self) { try CleanupClient.parseResponse(body) }
    }

    @Test func throwsOnWhitespaceOnlyContent() {
        let body = Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8)
        #expect(throws: CleanupClientError.self) { try CleanupClient.parseResponse(body) }
    }

    @Test func throwsOnMalformedJSON() {
        #expect(throws: (any Error).self) { try CleanupClient.parseResponse(Data("nope".utf8)) }
    }
}

/// Endpoint construction, which differs per provider only by base URL. Gemini's
/// OpenAI-compatibility base ends in a slash and OpenAI's does not, so joining
/// has to tolerate both without producing a double slash.
struct CleanupClientEndpointTests {
    @Test func appendsChatCompletionsToABaseWithoutTrailingSlash() {
        #expect(
            CleanupClient.endpoint(base: "https://api.groq.com/openai/v1")?.absoluteString
                == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test func doesNotDoubleTheSlashWhenTheBaseHasOne() {
        #expect(
            CleanupClient.endpoint(base: "https://generativelanguage.googleapis.com/v1beta/openai/")?
                .absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    }

    @Test func returnsNilForAnUnusableBase() {
        #expect(CleanupClient.endpoint(base: "") == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./Scripts/verify.sh --dirty`
Expected: FAIL — `cannot find 'CleanupClient' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/FalaDan/Services/Cleanup/CleanupClient.swift`:

```swift
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
            let model = config.llmModel,
            let apiKey = config.llmAPIKey
        else { throw CleanupClientError.notConfigured }

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
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass. 11 new `@Test` cases across 2 new suites (≈197 in 38).

- [ ] **Step 5: Commit**

```bash
git add Sources/FalaDan/Services/Cleanup/CleanupClient.swift Tests/FalaDanTests/CleanupClientTests.swift
git commit -m "Add CleanupClient for OpenAI-compatible cleanup calls

Rewrite of CustomEditProvider keyed off EnvConfig instead of UserDefaults,
with request building and response parsing extracted as pure statics so
both are testable without a server.

Provider choice is the base URL alone, which covers Groq, Gemini via its
OpenAI-compatibility layer, OpenAI, OpenRouter and local servers. The
endpoint join tolerates a trailing slash because Gemini's base has one and
Groq's does not.

Timeout is bounded at 15s: this call sits between key-release and paste,
so a hung request reads as the app being broken."
```

**Done means:** `./Scripts/verify.sh --dirty` passes with 11 new tests, and no test in `CleanupClientTests` performs real network I/O.

---

### Task 3: Route cleanup through EnvConfig, always on

**Executor:** `opus-supervised` — do not delegate. This changes what happens to every dictation, and a mistake means either no cleanup at all or a failed network call per utterance.

**Files:**
- Modify: `Sources/FalaDan/AppState.swift` (add the config property; keep `toggleRecording()`)
- Modify: `Sources/FalaDan/Features/Transcription/AppState+Transcription.swift` (`applyAutoCleanup`)
- Modify: `Sources/FalaDan/Features/Recording/AppState+RecordingFlow.swift` (the `applyCleanup` snapshot)

**Interfaces:**
- Consumes: `EnvConfig` (Task 1), `CleanupClient` (Task 2).
- Produces: `AppState.envConfig`, consumed by Task 8.

**What changes conceptually:** `applyCleanup` stops meaning "the user pressed ⌥R" and starts meaning "cleanup is configured and enabled". `applyAutoCleanup` keeps its shape — the guard, the silent fallback, the `RecordingCleanup` metadata — and only swaps its provider.

- [ ] **Step 1: Add the config and the client to AppState**

Both go next to the existing stored services. Task 2's `CleanupClient` is a stateless `struct`,
so it is constructed directly rather than injected.

```swift
    /// Read once at launch. Changing `.env` requires a relaunch — reloading
    /// mid-session would let a recording start under one config and finish
    /// under another.
    let envConfig = EnvConfig.load()
    let cleanupClient = CleanupClient()
```

- [ ] **Step 2: Point `applyAutoCleanup` at CleanupClient**

Replace the `EditModeSettings.model` switch with a single call. Keep `isEditModeProcessing` for now — it is renamed in Task 7, and doing both at once makes the diff hard to review.

```swift
        do {
            let cleaned = try await cleanupClient.cleanup(
                transcript: rawText, config: envConfig)
            let duration = Date().timeIntervalSince(start)
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (rawText, nil) }

            let cleanup = RecordingCleanup(
                rawText: rawText,
                cleanedText: trimmed,
                backendModel: envConfig.llmModel ?? "unknown",
                cleanupDuration: duration
            )
            return (trimmed, cleanup)
        } catch {
            // Silent by design — the user gets the raw transcript rather than
            // losing their words to a model outage. Logged so device logs still
            // capture it. The error is never surfaced in the UI.
            log.error("Cleanup failed: \(error.localizedDescription, privacy: .public)")
            return (rawText, nil)
        }
```

- [ ] **Step 3: Make cleanup always-on at the call site**

In `stopAndTranscribeFlow`, replace the `cleanupRequestedForCurrentRecording` snapshot:

```swift
        // Cleanup now runs on every dictation rather than behind a second
        // shortcut. `isCleanupConfigured` is what keeps an unconfigured install
        // working offline: with no key, the call is skipped and the raw
        // transcript is pasted, exactly as before this phase.
        let applyCleanup = envConfig.isCleanupConfigured
```

- [ ] **Step 4: Run the gate**

Run: `./Scripts/verify.sh --dirty`
Expected: build succeeds, all tests pass, no change in count — this task adds none

`cleanupRequestedForCurrentRecording` is now written but never read. It is removed in Task 4 — leaving it here keeps this diff to one concern.

- [ ] **Step 5: Commit**

```bash
git add Sources/FalaDan/AppState.swift Sources/FalaDan/Features/Transcription/AppState+Transcription.swift Sources/FalaDan/Features/Recording/AppState+RecordingFlow.swift
git commit -m "Run cleanup on every dictation, via EnvConfig and CleanupClient

applyCleanup changes meaning from 'the user pressed the auto-cleanup
shortcut' to 'cleanup is configured and enabled'. The provider switch on
EditModeSettings.model is replaced by a single CleanupClient call.

Silent fallback to the raw transcript is preserved deliberately: a model
outage must never cost the user their words."
```

**Done means:** `./Scripts/verify.sh --dirty` passes with the count unchanged, `applyAutoCleanup` no longer references `EditModeSettings` or `customEditProvider`, and the silent-fallback `catch` still returns `(rawText, nil)`.

---

### Task 4: Delete the auto-cleanup shortcut

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/AppState.swift` — delete `toggleAutoCleanupRecording()` and `cleanupRequestedForCurrentRecording`
- Modify: `Sources/FalaDan/Services/Hotkeys/HotkeyManager.swift` — delete `setupAutoCleanupRecording()`, its `start()` call, and `hotkeyDidToggleAutoCleanupRecording()` from the protocol
- Modify: `Sources/FalaDan/AppDelegate.swift` — delete `hotkeyDidToggleAutoCleanupRecording()`
- Modify: `Sources/FalaDan/Models/CustomShortcut.swift` — delete the `.autoCleanupRecording` case and its entry in `defaultShortcuts()`
- Modify: `Sources/FalaDan/Views/MenuBarView.swift`, `Sources/FalaDan/Views/SettingsWindowView.swift` — delete rows referencing `.autoCleanupRecording`

**Do NOT touch:** anything else in `Services/Hotkeys/`. `HotkeyManager.swift` is the only file there in scope.

- [ ] **Step 1: Find every reference**

Run: `grep -rn --include="*.swift" -e "autoCleanupRecording" -e "cleanupRequestedForCurrentRecording" Sources/ Tests/`
Every hit is either deleted or, for `Tests/`, updated.

- [ ] **Step 2: Delete them, then check nothing survives**

Run: `grep -rn --include="*.swift" -e "autoCleanupRecording" -e "cleanupRequestedForCurrentRecording" Sources/ Tests/ || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 3: Confirm the remaining shortcut defaults still hold**

`Tests/FalaDanTests/DefaultShortcutTests.swift` asserts every `CustomShortcutName` has a default. Removing a case keeps that true; do not weaken the test.

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass, count unchanged

Removing an enum case is safe for persisted data — `CustomShortcutStorage.loadAll` skips raw values it does not recognise — but any binding Dan had customised for it is silently orphaned.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Delete the auto-cleanup shortcut

Cleanup runs on every dictation now, so a second shortcut to request it
has nothing left to do. Removes the shortcut name, its handler chain, and
the cleanupRequestedForCurrentRecording flag that is now written and never
read."
```

**Done means:** the grep in Step 2 prints `CLEAN`, and `./Scripts/verify.sh --dirty` passes with the count unchanged.

---

### Task 5: Delete the OAuth credential-reuse stack

**Executor:** `sonnet-alone`

The reason this whole phase exists. These files read OAuth tokens from the Keychain and `~/.codex/auth.json`, then send `user-agent: claude-cli/…` and `originator: codex_cli_rs` to impersonate other applications.

**Files:**
- Delete: `Sources/FalaDan/Services/OAuthApiClient.swift`
- Delete: `Sources/FalaDan/Services/OAuthCredentialStore.swift`
- Delete: `Sources/FalaDan/Services/OAuthRefreshTrigger.swift`
- Modify: whichever files fail to compile afterwards — expected to be `EditModeProvider.swift` and `AppDelegate.swift`

- [ ] **Step 1: See what depends on them first**

Run: `grep -rn --include="*.swift" -e "OAuthApiClient" -e "OAuthCredentialStore" -e "OAuthRefreshTrigger" Sources/ Tests/`

- [ ] **Step 2: Delete the three files and fix the fallout**

```bash
git rm Sources/FalaDan/Services/OAuthApiClient.swift \
       Sources/FalaDan/Services/OAuthCredentialStore.swift \
       Sources/FalaDan/Services/OAuthRefreshTrigger.swift
```

Then remove references until it builds. `EditModeProvider` is deleted entirely in Task 6 — if it is the only thing blocking, delete it now and note that in the commit rather than writing throwaway code to keep it compiling.

- [ ] **Step 3: Verify nothing reaches for another app's credentials**

Run: `grep -rn --include="*.swift" -e "codex/auth" -e "claude-cli" -e "codex_cli" -e "OAuth" Sources/ || echo "CLEAN"`
Expected: `CLEAN`

This is the check that matters most in Phase 2. If it does not print `CLEAN`, the phase's goal is not met.

- [ ] **Step 4: Run the gate**

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass, count unchanged

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Delete the OAuth credential-reuse stack

Read OAuth tokens from the Keychain and ~/.codex/auth.json, then spoofed
claude-cli and codex_cli_rs identity headers to call Anthropic and OpenAI
as though it were those tools. Dormant by default but shipping, and one
settings toggle from running.

All API access now uses Dan's own key from .env."
```

**Done means:** the Step 3 grep prints `CLEAN`, and `./Scripts/verify.sh --dirty` passes.

---

### Task 6: Delete EditMode services and models

**Executor:** `sonnet-alone`

**Files:**
- Delete: `Sources/FalaDan/Features/EditMode/AppState+EditMode.swift`
- Delete: `Sources/FalaDan/Services/EditModeProvider.swift` (if Task 5 has not already)
- Delete: `Sources/FalaDan/Services/CustomEditProvider.swift`
- Delete: `Sources/FalaDan/Models/EditModeSettings.swift`
- Delete: `Sources/FalaDan/Models/CustomEditProviderSettings.swift`
- Modify: `AppState.swift`, `AppDelegate.swift`, `HotkeyManager.swift`, `AppState+Termination.swift`, `CustomShortcut.swift` — remove `editModeContext`, `editSelection`, and the `.editSelection` shortcut

**Interfaces:**
- `CleanupPromptStore` **stays** — it holds the system prompt `CleanupClient` uses.
- `editModeContext` guards in `beginHoldToTalk` / `endHoldToTalk` / `abortHoldToTalk` are deleted with it. Those guards exist only because edit mode shared the recorder.

- [ ] **Step 1: Map the blast radius**

Run: `grep -rln --include="*.swift" -e "EditMode" -e "editModeContext" -e "editSelection" -e "CustomEditProvider" Sources/`

Expect roughly a dozen files. UI files are Task 7 — if a UI file is the only thing left failing, stop and leave it for that task rather than editing it here.

- [ ] **Step 2: Delete the five files, then fix non-UI callers**

- [ ] **Step 3: Run the gate**

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass, count unchanged

If the only remaining errors are in `Views/`, that is expected — finish them here rather than leaving the build broken, and note it in the commit. A task must never end on a red build.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Delete EditMode

Out of scope for v1 per the design spec, and the only remaining consumer
of the OAuth stack. Its recorder-sharing is also why beginHoldToTalk and
endHoldToTalk carried editModeContext guards, which go with it.

CleanupPromptStore stays: it holds the system prompt CleanupClient uses."
```

**Done means:** `grep -rn --include="*.swift" "EditMode" Sources/ || echo CLEAN` prints `CLEAN`, and the gate passes.

---

### Task 7: Rename the processing flag and tidy the settings UI

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/AppState.swift` — `isEditModeProcessing` → `isCleanupProcessing`, `editModeProcessingCharCount` → `cleanupProcessingCharCount`
- Modify: `Sources/FalaDan/Views/MenuBarIcon.swift` — the `isEditModeProcessing` parameter
- Modify: `Sources/FalaDan/Views/MenuBarView.swift`, `SettingsWindowView.swift`, `Popovers/SettingsPopoverView.swift`, `ModelPickerView.swift` — remove any remaining AI-Editing UI

**Note:** the flag is **renamed, not deleted**. It drives the menu bar's working indicator; deleting it removes the only signal that cleanup is running.

- [ ] **Step 1: Rename**

```bash
git ls-files Sources | grep -v '\.icns$' | xargs sed -i '' \
  -e 's/isEditModeProcessing/isCleanupProcessing/g' \
  -e 's/editModeProcessingCharCount/cleanupProcessingCharCount/g'
```

Pipe to `xargs`; do not use `FILES=$(...)` with unquoted `$FILES` — zsh does not word-split, and the sed silently does nothing.

- [ ] **Step 2: Remove leftover AI-Editing UI**

Run: `grep -rn --include="*.swift" -e "AI Editing" -e "Edit Mode" -e "editMode" Sources/Views/ || echo "CLEAN"`

- [ ] **Step 3: Run the gate**

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass, count unchanged. `MenuBarIconTests` exercises the icon states — if it references the old name, update it.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Rename the edit-mode processing flag to cleanup

Renamed rather than deleted: it drives the menu bar's working indicator,
which is the only signal that a cleanup call is in flight."
```

**Done means:** no `isEditModeProcessing` anywhere, the gate passes, and the menu bar still shows a distinct working state.

---

### Task 8: Wire MIN_HOLD_MS and MIN_TRANSCRIBE_MS

**Executor:** `sonnet-alone`

Both thresholds are currently hardcoded. `HoldToTalkPolicy.shouldTranscribe` already takes `minimum:` and only ever receives its default.

**Files:**
- Modify: `Sources/FalaDan/AppState.swift` — pass `envConfig.minHold` at the `HoldToTalkPolicy.release` call site
- Modify: `Sources/FalaDan/Features/Recording/AppState+RecordingFlow.swift` — replace the literal `0.3` with `envConfig.minTranscribe`
- Modify: `Tests/FalaDanTests/HoldToTalkPolicyTests.swift` — update the comment that says `MIN_HOLD_MS` is not yet wired

- [ ] **Step 1: Pass the configured minimum**

In `endHoldToTalk`:

```swift
        let decision = HoldToTalkPolicy.release(heldFor: held, minimum: envConfig.minHold)
```

- [ ] **Step 2: Use the configured transcription floor**

In `stopAndTranscribeFlow`, replace `guard duration >= 0.3` with `guard duration >= envConfig.minTranscribe`.

- [ ] **Step 3: Run the gate**

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass, count unchanged

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Wire MIN_HOLD_MS and MIN_TRANSCRIBE_MS to EnvConfig

Both thresholds were hardcoded; HoldToTalkPolicy has taken a minimum:
parameter since Phase 1 that only ever received its default."
```

**Done means:** neither threshold is a literal in `AppState` or `AppState+RecordingFlow`, and the gate passes.

---

### Task 9: Generation token on the parked hold release

**Executor:** `opus-supervised` — do not delegate. This is the state machine that broke twice in Phase 1.

**Files:**
- Modify: `Sources/FalaDan/AppState.swift`
- Modify: `Sources/FalaDan/Features/Recording/AppState+RecordingFlow.swift`
- Create: tests alongside `HoldToTalkPolicyTests` for the pure part

**The bug (documented in `AppState.endHoldToTalkStartWindow`'s comment):** `startRecordingFlow`'s `guard !captureTransitionInFlight` sits above the `defer` that ends the hold window, so a hold start bailing there leaves the window open and its release can be consumed by the flow already running. Hoisting the `defer` makes it worse — a second flow bailing at that guard would then clear a live hold's window.

**The fix:** a generation counter incremented by `beginHoldToTalk`, stamped onto the parked release, and compared before it is applied. A release whose generation does not match the current one is discarded.

- [ ] **Step 1: Write the failing test**

Add to `Tests/FalaDanTests/HoldToTalkPolicyTests.swift`:

```swift
/// Whether a parked release still belongs to the recording that is starting.
///
/// One `startRecordingFlow` exit sits above the `defer` that closes the hold
/// window, so a hold start bailing there can leave its release to be consumed by
/// the flow already running — cutting short a recording that a different press
/// started. Matching generations is what tells the two apart.
struct HoldReleaseGenerationTests {
    @Test func aReleaseFromTheCurrentPressApplies() {
        #expect(HoldToTalkPolicy.shouldApplyParkedRelease(parked: 7, current: 7))
    }

    @Test func aReleaseFromAnEarlierPressIsDiscarded() {
        #expect(!HoldToTalkPolicy.shouldApplyParkedRelease(parked: 6, current: 7))
    }

    /// Defensive: a parked generation ahead of the current one cannot happen by
    /// construction, and if it ever does the safe reading is "not mine".
    @Test func aGenerationAheadOfCurrentIsDiscarded() {
        #expect(!HoldToTalkPolicy.shouldApplyParkedRelease(parked: 8, current: 7))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./Scripts/verify.sh --dirty`
Expected: FAIL — `shouldApplyParkedRelease` does not exist.

- [ ] **Step 3: Add the pure comparison**

In `Sources/FalaDan/Services/Hotkeys/HoldToTalkPolicy.swift`:

```swift
    /// Whether a parked release belongs to the start now completing.
    ///
    /// Pure so the rule is testable; the counter it compares lives on `AppState`.
    static func shouldApplyParkedRelease(parked: UInt64, current: UInt64) -> Bool {
        parked == current
    }
```

- [ ] **Step 4: Stamp and check the generation**

In `AppState`:

- Add `private var holdGeneration: UInt64 = 0`.
- In `beginHoldToTalk`, immediately before setting `holdToTalkStartInFlight = true`, increment it: `holdGeneration &+= 1`. Wrapping addition, because a counter that traps on overflow would be a crash in the hotkey path; wrapping is harmless since only equality is ever compared.
- Change `pendingHoldRelease` to carry the generation alongside the decision, e.g.
  `private var pendingHoldRelease: (decision: HoldToTalkPolicy.Release, generation: UInt64)?`,
  and stamp `holdGeneration` when parking in `endHoldToTalk` and `abortHoldToTalk`.
- In `applyPendingHoldRelease()`, consume only when
  `HoldToTalkPolicy.shouldApplyParkedRelease(parked: parked.generation, current: holdGeneration)`.
  A non-matching release is discarded, not applied.

- [ ] **Step 5: Run the gate and update the stale comment**

`endHoldToTalkStartWindow`'s doc comment describes the bug as unfixed. Update it to describe what the code now does.

Run: `./Scripts/verify.sh --dirty`
Expected: all tests pass, 3 new `@Test` cases.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Scope a parked hold release to the press that started it

startRecordingFlow's captureTransitionInFlight guard sits above the defer
that closes the hold window, so a hold start bailing there could leave its
release to be consumed by the flow already running — cutting short a
recording a different press had started.

Stamps each parked release with a generation counter incremented per press
and discards any release whose generation no longer matches. Hoisting the
defer would not have fixed this and would have introduced the mirror bug."
```

**Done means:** the gate passes, and no comment in `AppState` still describes the generation race as outstanding.

---

### Task 10: `.env.example`, README, and docs

**Executor:** `sonnet-alone`

**Files:**
- Create: `.env.example`
- Modify: `README.md` — replace MiniWhisper's feature list with FalaDan's
- Modify: `CLAUDE.md` — note that `.env` config is now live
- Delete: `HANDOFF.md` if Phase 2 is complete and nothing is blocked

- [ ] **Step 1: Write `.env.example`**

```bash
# FalaDan configuration.
# Copy to ~/Library/Application Support/FalaDan/.env and fill in a key.
# Everything here is optional: with no .env at all, FalaDan runs fully
# offline using the local Whisper model and pastes the raw transcript.

# --- LLM cleanup -------------------------------------------------------
# Cleans up every dictation: removes fillers, fixes homophones and
# punctuation, and applies spoken corrections like "scratch that".
# Skipped entirely unless both a key and a model are set.

# Groq (default — fastest, which matters because this runs between
# releasing the hotkey and the text appearing)
LLM_BASE_URL=https://api.groq.com/openai/v1
LLM_API_KEY=
LLM_MODEL=

# Google Gemini, via its OpenAI-compatibility layer
# LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai/
# LLM_API_KEY=
# LLM_MODEL=gemini-3.6-flash

# OpenAI
# LLM_BASE_URL=https://api.openai.com/v1

# Local (Ollama, LM Studio) — keeps everything on-device
# LLM_BASE_URL=http://localhost:11434/v1
# LLM_API_KEY=unused
# LLM_MODEL=llama3.2

# Set to off to skip cleanup entirely and paste the raw transcript.
# LLM_CLEANUP=off

# --- Timing ------------------------------------------------------------
# Hold shorter than this is treated as an accidental tap and discarded.
# 0 disables the guard.
# MIN_HOLD_MS=150

# Recordings shorter than this are discarded — Whisper hallucinates
# filler on very short clips.
# MIN_TRANSCRIBE_MS=300
```

Model ids are deliberately blank or commented: they get renamed and retired, and a stale value here is worse than an empty one.

- [ ] **Step 2: Rewrite the README** for FalaDan's actual features — hold-Fn dictation, local Whisper, optional LLM cleanup, `.env` config, **two** permissions (Microphone and Accessibility, not Input Monitoring), and `./Scripts/setup-dev-signing.sh` for contributors.

- [ ] **Step 3: Verify no secret is committed**

Run: `grep -nE "sk-|gsk_|AIza" .env.example || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 4: Run the gate and commit**

**Done means:** `.env.example` exists with no real key, the README describes FalaDan rather than MiniWhisper, and `git status` is clean.

---

### Task 11: Human verification

**Executor:** `opus-supervised` — Dan performs the checks; Opus records the outcome.

- [ ] **Step 1: Verify the offline path first, before adding any key**

```bash
just dev
```

With no `.env`, hold Fn and dictate. Text must land, unchanged, exactly as in Phase 1. **This is the most important check in the phase** — it proves the skip path works and that a fresh install is not broken by cleanup being on by default.

- [ ] **Step 2: Add a key and verify cleanup**

Create `~/Library/Application Support/FalaDan/.env` from `.env.example` with a real Groq or Gemini key and model, then relaunch.

Dictate, deliberately, with fillers and a correction:

> "um so the meeting is at three pm scratch that four pm and their going to deploy it"

Expected: *"The meeting is at 4pm, and they're going to deploy it."*

- [ ] **Step 3: Judge the latency**

Does the gap between releasing Fn and text appearing feel acceptable? This is the risk the spec flags, and only Dan can rule on it. If it does not, the answer is a faster model or `LLM_CLEANUP=off`, not a code change.

- [ ] **Step 4: Verify the failure path**

Set `LLM_API_KEY` to a deliberately invalid value and relaunch. Dictation must still paste the raw transcript, with no error dialog. A cleanup outage must never cost words.

**Done means:** Dan has confirmed all four in his own words, or `HANDOFF.md` records the specific failure.

---

## Notes for the orchestrator

- Tasks 5 and 6 are where the build is most likely to cascade. Both say to finish the fallout rather than end on a red build.
- Task 3 is the only one that changes behaviour for every dictation. Review it hardest.
- The Phase 1 pattern held: the pure types (`EnvConfig`, `CleanupClient` shaping, the generation comparison) carry the tests, and `AppState` carries the wiring that only human verification reaches.
