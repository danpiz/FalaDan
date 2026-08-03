import Foundation

/// User-selectable model for the edit-mode shortcut. `claude-*` and
/// `gpt-*` route through `EditModeProvider`, whose backend (borrowed
/// credentials from the user's installed Claude Code / Codex CLIs) has
/// been deleted — selecting either now fails with a clear error.
/// `.custom` routes through `CustomEditProvider` to a user-supplied
/// OpenAI-compatible chat-completions endpoint and is unaffected.
enum EditModeModel: String, Codable, CaseIterable, Sendable {
    case gpt5Mini = "gpt-5.4-mini"
    case claudeHaiku45 = "claude-haiku-4-5"
    case custom = "custom"

    var displayName: String { rawValue }

    var backend: EditModeBackend {
        switch self {
        case .claudeHaiku45: return .claudeCli
        case .gpt5Mini: return .codexCli
        case .custom: return .customApi
        }
    }
}

/// Which backend produced the edit. `.claudeCli` and `.codexCli` are
/// historical — the credential-reuse path that powered them was deleted.
/// `.customApi` posts to a user-supplied OpenAI-compatible
/// chat-completions endpoint with a bearer token.
enum EditModeBackend: String, Codable, Sendable {
    case claudeCli = "claude"
    case codexCli = "codex"
    case customApi = "custom-api"

    var displayName: String {
        switch self {
        case .claudeCli: return "Claude"
        case .codexCli: return "Codex"
        case .customApi: return "Custom"
        }
    }
}

/// Top-level mode for AI editing. The two underlying features are:
/// `selection` (the ⌥E shortcut → LLM-process selected text) and
/// `autoCleanup` (every Fn recording gets an LLM polish pass after
/// transcription before insertion). They share the Edit Model +
/// provider, so one picker drives both knobs.
///
/// When `selection` (or `both`) is active, a separate `voiceEdit`
/// toggle controls whether the selection shortcut records a voice
/// instruction first (voice edit) or immediately runs cleanup on the
/// selected text (default, no recording needed).
enum EditModeBehavior: String, Codable, CaseIterable, Sendable {
    case off
    case both
    case autoCleanup
    case selection

    var selectionEnabled: Bool {
        switch self {
        case .selection, .both: return true
        case .off, .autoCleanup: return false
        }
    }

    var autoCleanupEnabled: Bool {
        switch self {
        case .autoCleanup, .both: return true
        case .off, .selection: return false
        }
    }

    var isOff: Bool { self == .off }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .both: return "Both"
        case .autoCleanup: return "Cleanup"
        case .selection: return "Selection"
        }
    }
}

/// Settings for AI editing (selection + auto-cleanup).
enum EditModeSettings {
    private static let behaviorKey = "EditModeBehavior"
    private static let modelKey = "EditModeModel"
    private static let voiceEditKey = "EditModeVoiceEdit"

    static var behavior: EditModeBehavior {
        get {
            guard let raw = UserDefaults.standard.string(forKey: behaviorKey),
                  let behavior = EditModeBehavior(rawValue: raw)
            else {
                // Migrate legacy "voiceEdit" → "selection"
                if let raw = UserDefaults.standard.string(forKey: behaviorKey),
                   raw == "voiceEdit"
                {
                    UserDefaults.standard.set(
                        EditModeBehavior.selection.rawValue, forKey: behaviorKey)
                    UserDefaults.standard.set(true, forKey: voiceEditKey)
                    return .selection
                }
                return .off
            }
            return behavior
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: behaviorKey) }
    }

    static var model: EditModeModel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modelKey),
                  let model = EditModeModel(rawValue: raw)
            else {
                return .claudeHaiku45
            }
            return model
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modelKey) }
    }

    /// When true, the selection shortcut records a voice instruction
    /// before applying the edit. When false (default), it immediately
    /// runs cleanup on the selected text — no recording needed.
    static var voiceEdit: Bool {
        get { UserDefaults.standard.bool(forKey: voiceEditKey) }
        set { UserDefaults.standard.set(newValue, forKey: voiceEditKey) }
    }
}
