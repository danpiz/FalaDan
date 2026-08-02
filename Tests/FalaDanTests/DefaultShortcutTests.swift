import Foundation
import Testing

@testable import FalaDan

/// The default recording binding has to reach the modifier tap, because that is
/// the only backend that reports a bare modifier's press and release. A default
/// that classified as anything else would leave hold-to-talk silently broken on
/// first launch.
struct DefaultShortcutTests {
    @Test func recordingDefaultsToBareFn() {
        let shortcut = CustomShortcutStorage.defaultShortcuts()[.toggleRecording]
        #expect(shortcut?.isFnOnly == true)
    }

    @Test func recordingDefaultRoutesToTheModifierTap() {
        let shortcut = CustomShortcutStorage.defaultShortcuts()[.toggleRecording]!
        #expect(ShortcutBackend.classify(shortcut) == .modifierOnly)
    }

    @Test func everyShortcutNameStillHasADefault() {
        let defaults = CustomShortcutStorage.defaultShortcuts()
        for name in CustomShortcutName.allCases {
            #expect(defaults[name] != nil)
        }
    }
}
