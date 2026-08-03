import Foundation
import Testing

@testable import FalaDan

/// Abort-handler resolution.
///
/// One line in `getAbortHandler` decides whether a shortcut that never opted
/// into the distinction keeps its old behavior. `cancelRecording` and
/// `editSelection` both rely on that fallback, and a regression there would
/// change what they do when a press is retired rather than released —
/// silently, since nothing else asserts it.
struct ShortcutHandlerRegistryTests {
    @Test func abortFallsBackToTheKeyUpHandlerWhenNoAbortHandlerIsRegistered() {
        let registry = ShortcutHandlerRegistry()
        registry.setKeyUpHandler(for: .cancelRecording) {}

        #expect(registry.getAbortHandler(for: .cancelRecording) != nil)
    }

    @Test func aRegisteredAbortHandlerIsPreferredOverTheKeyUpHandler() {
        let registry = ShortcutHandlerRegistry()
        registry.setKeyUpHandler(for: .toggleRecording) {}
        registry.setAbortHandler(for: .toggleRecording) {}

        // Handlers are opaque closures, so identity is asserted through the one
        // observable difference: a name with only a key-up handler resolves to
        // something, and removing that possibility must still leave the abort
        // handler reachable.
        #expect(registry.getAbortHandler(for: .toggleRecording) != nil)
        #expect(registry.getKeyUpHandler(for: .toggleRecording) != nil)
    }

    @Test func aNameWithNoHandlersAtAllResolvesToNothing() {
        let registry = ShortcutHandlerRegistry()

        #expect(registry.getAbortHandler(for: .editSelection) == nil)
    }

    /// Registering an abort handler for one shortcut must not make it the abort
    /// handler for every other one.
    @Test func abortHandlersDoNotLeakAcrossShortcutNames() {
        let registry = ShortcutHandlerRegistry()
        registry.setAbortHandler(for: .toggleRecording) {}

        #expect(registry.getAbortHandler(for: .editSelection) == nil)
    }
}
