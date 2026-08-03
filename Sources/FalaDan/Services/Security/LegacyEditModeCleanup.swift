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
/// Runs until the Keychain item is provably gone, gated by `hasRunKey` —
/// not "runs once," but "keeps trying once per launch until it succeeds."
/// `hasRunKey` is set only after `SecItemDelete` reports `errSecSuccess` or
/// `errSecItemNotFound` (item already gone); any other status leaves it
/// unset so the next launch retries. `SecItemDelete` against the app's own
/// item is local, synchronous, and non-prompting, so retrying costs
/// essentially nothing — and a transient failure is the one case where
/// giving up would leave the credential stranded forever, which is exactly
/// what this migration exists to prevent. A missing Keychain item is the
/// normal outcome for most installs, which never configured the old
/// custom edit endpoint — not a failure worth surfacing.
///
/// The UserDefaults sweep below is unconditional regardless of the
/// Keychain outcome: those removals cannot fail, so there is no reason to
/// hold them hostage to a Keychain retry.
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
        let deleted = (status == errSecSuccess || status == errSecItemNotFound)

        if !deleted {
            // Only the OSStatus — it carries no secret material.
            log.error("Legacy edit-mode keychain cleanup returned unexpected status \(status)")
        }

        orphanedDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }

        // Marked done only once the key is provably gone. SecItemDelete against
        // our own item is local and non-prompting, so retrying next launch is
        // nearly free — and a transient failure is the one case where giving up
        // would leave the credential stranded forever, which is the exact
        // outcome this migration exists to prevent.
        if deleted {
            defaults.set(true, forKey: hasRunKey)
        }
    }
}
