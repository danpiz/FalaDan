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

    /// Redacts the API key. This type ends up in log lines and crash reports.
    var description: String {
        let trimmedKey = llmAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (trimmedKey?.isEmpty == false) ? "<redacted>" : "<unset>"
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
