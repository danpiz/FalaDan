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
    /// per utterance — and it is what stops any transcript leaving the machine
    /// when no key is set.
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

    /// A log line describing the configuration without reproducing any of it.
    ///
    /// This ends up in the unified log at public privacy, which persists to disk
    /// and is swept into a sysdiagnose — so the rule here is that **no
    /// user-supplied string is ever echoed**, only facts derived from one.
    ///
    /// Three earlier versions of this tried to echo the model id and base URL
    /// while redacting anything key-shaped. That cannot be made to work. The
    /// realistic slip is a key pasted one line off in `.env` — where
    /// `LLM_BASE_URL=`, `LLM_API_KEY=` and `LLM_MODEL=` sit in a block — so
    /// every field has to be treated as possibly holding a key. And a key is not
    /// distinguishable from a model id by shape: a UUID-format token (real, for
    /// self-hosted gateways) has the same structure as an ordinary identifier.
    /// Every rule tried either leaked a real key format or blanked a real
    /// config value, usually both.
    ///
    /// So it reports set/unset instead, plus the base URL's host — parsed out by
    /// `URLComponents`, never the raw string, so a key in that field yields no
    /// host and reports `<none>`. That answers what this line exists to answer:
    /// was `.env` found, is cleanup configured, and which provider. A wrong model
    /// id surfaces separately as the `HTTP 404` in `diagnostic(for:)`.
    var description: String {
        return """
            EnvConfig(host: \(Self.host(of: llmBaseURL)), \
            key: \(Self.presence(of: llmAPIKey)), \
            model: \(Self.presence(of: llmModel)), \
            cleanup: \(llmCleanupEnabled), configured: \(isCleanupConfigured), \
            minHoldMS: \(minHoldMS), minTranscribeMS: \(minTranscribeMS))
            """
    }

    /// Whether a field is set, saying nothing about its contents.
    private static func presence(of value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? "<set>" : "<unset>"
    }

    /// The host of a base URL, and nothing else from it.
    ///
    /// Host only — not scheme, path, query or user-info, all of which are either
    /// uninteresting or places a credential can hide. A value that does not parse
    /// to a host is reported as `<none>` rather than echoed, which is what makes
    /// a key pasted into `LLM_BASE_URL=` safe: it has no host.
    ///
    /// `percentEncodedHost`, not `host`: the latter percent-*decodes*, so a host
    /// of `x%0A…` would put a newline — or a convincing forgery of this very line
    /// — into the unified log. The encoded form is also the honest one, being
    /// what was actually configured.
    ///
    /// The remaining echo is a host that is itself secret-shaped, which needs a
    /// key pasted *after* a scheme (`https://gsk_…`). Not defended against on
    /// purpose: telling a key from a hostname is the same unwinnable shape
    /// guess this design exists to avoid, and it would cost the diagnostic.
    static func host(of urlString: String) -> String {
        guard let host = URLComponents(string: urlString)?.percentEncodedHost,
            !host.isEmpty
        else {
            return "<none>"
        }
        return host
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
