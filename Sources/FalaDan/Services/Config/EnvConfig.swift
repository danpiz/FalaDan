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
    var isCleanupConfigured: Bool {
        guard llmCleanupEnabled else { return false }
        guard let key = llmAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else { return false }
        guard let model = llmModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else { return false }
        return true
    }

    var minHold: TimeInterval { TimeInterval(minHoldMS) / 1000 }
    var minTranscribe: TimeInterval { TimeInterval(minTranscribeMS) / 1000 }

    /// Redacts anything that could be a credential. This type ends up in log
    /// lines and crash reports, which persist to disk and get swept into a
    /// sysdiagnose.
    ///
    /// Redacting `llmAPIKey` is not sufficient on its own. The other two string
    /// fields are opaque user-supplied text, and the realistic slip is pasting a
    /// key into the wrong line of a file where `LLM_API_KEY=` and `LLM_MODEL=`
    /// sit next to each other. A misplaced key must not become a log entry.
    var description: String {
        let trimmedKey = llmAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (trimmedKey?.isEmpty == false) ? "<redacted>" : "<unset>"
        return """
            EnvConfig(baseURL: \(Self.redactingCredentials(in: llmBaseURL)), key: \(key), \
            model: \(llmModel.map(Self.redactingSecretShape) ?? "<unset>"), \
            cleanup: \(llmCleanupEnabled), \
            minHoldMS: \(minHoldMS), minTranscribeMS: \(minTranscribeMS))
            """
    }

    /// Blanks a value that looks like an API key rather than a model id.
    ///
    /// Matched on prefix, which covers the providers this app documents, plus a
    /// length backstop for the ones it does not: model ids are human-readable and
    /// short (`llama-3.3-70b-versatile` is 23 characters), and nothing legitimate
    /// runs to 40 unbroken non-space characters.
    static func redactingSecretShape(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["sk-", "sk_", "gsk_", "xai-", "AIza", "Bearer "]
        if prefixes.contains(where: { trimmed.hasPrefix($0) }) { return "<redacted>" }
        if trimmed.count >= 40, !trimmed.contains(" ") { return "<redacted>" }
        return value
    }

    /// Strips the query string and any user-info component from a URL.
    ///
    /// Some providers take the key as `?api_key=`, and a URL can carry
    /// `https://user:secret@host`. Neither is how this app authenticates — it
    /// sends a bearer header — but the base URL is whatever the user typed.
    static func redactingCredentials(in urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return redactingSecretShape(urlString)
        }
        let hadSecret = components.query != nil || components.password != nil
        components.query = nil
        components.user = nil
        components.password = nil
        guard let stripped = components.string else { return "<redacted>" }
        return hadSecret ? stripped + "<redacted-query>" : stripped
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
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // First separator only: a value may legitimately contain '='.
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            let value = unquote(
                line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines))

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

    /// Strips one layer of matching quotes, then trims again.
    ///
    /// The caller trims before calling, but quotes shield whatever is inside
    /// them from that pass — so `KEY="value  "` would otherwise keep its
    /// trailing spaces and be sent as part of the credential.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
            first == last, first == "\"" || first == "'"
        else { return value }
        return String(value.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
