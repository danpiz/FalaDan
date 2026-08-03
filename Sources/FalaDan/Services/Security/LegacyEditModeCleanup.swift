import Foundation
import Security
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "LegacyEditModeCleanup")

/// One-time sweep of state stranded by the deleted edit-selection feature
/// (voice-driven text editing via an external CLI/LLM backend, removed in
/// Phase 2). Its settings type and API key accessors are gone, but two
/// things outlive them on an existing install:
///
/// - The custom edit endpoint's API key, still sitting in the login
///   keychain under account `"custom-edit"`, with no code left to read,
///   rotate, or clear it.
/// - A handful of now-inert UserDefaults keys the old settings type used.
///
/// `CustomProviderAPIKeyStore` no longer knows about the `"custom-edit"`
/// account at all (its only live account is the transcription key), so the
/// Keychain query is duplicated here rather than routed through it.
///
/// Runs once per install, gated by `hasRunKey`, so a clean install — and
/// every launch after the first on an existing one — never pays for a
/// Keychain call it has no reason to make. A missing Keychain item
/// (`errSecItemNotFound`) is the normal outcome for most installs, which
/// never configured the old custom edit endpoint — not a failure worth
/// surfacing.
enum LegacyEditModeCleanup {
    private static let hasRunKey = "LegacyEditModeCleanupDidRun"

    /// Matches the service name `CustomProviderAPIKeyStore` still uses for
    /// the live transcription key; the edit key shared the same Keychain
    /// service, distinguished only by account.
    private static let service = "FalaDan Custom Provider API Keys"
    private static let editAccount = "custom-edit"

    /// UserDefaults keys the deleted edit-mode settings type used to own.
    /// Exact names taken from the type's implementation before deletion.
    private static let orphanedDefaultsKeys = [
        "EditModeBehavior",
        "EditModeModel",
        "EditModeVoiceEdit",
        "CustomEditProviderSettings",
    ]

    /// Call once from the launch path, before anything else touches
    /// UserDefaults or the Keychain for these keys.
    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hasRunKey) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: editAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            // Never log the key itself — only the OSStatus, which carries
            // no secret material. Best-effort: an unexpected status here
            // still means the flag below gets set, since this must not
            // turn into a Keychain prompt/call repeated on every launch.
            log.error("Legacy edit-mode keychain cleanup returned unexpected status \(status)")
        }

        orphanedDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }

        defaults.set(true, forKey: hasRunKey)
    }
}
