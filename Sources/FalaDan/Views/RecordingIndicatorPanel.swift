import AppKit
import SwiftUI

/// The floating pill, as an `NSPanel`.
///
/// Only the drawing lives here — *when* it appears is decided by
/// `RecordingIndicatorController`. Panel setup mirrors `ToastWindowController`.
/// The two are deliberately not shared: their lifetimes are unrelated, and the
/// indicator is stricter about input (see `present()`).
@MainActor
final class RecordingIndicatorPanel: RecordingIndicatorPresenting {
    private var panel: NSPanel?

    private let panelWidth: CGFloat = 140
    private let panelHeight: CGFloat = 44

    func present() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // FalaDan pastes into the frontmost application. A panel that accepts a
        // click or takes focus makes FalaDan frontmost, and the transcript lands
        // somewhere the user was not typing. `.nonactivatingPanel` with
        // `.borderless` already yields `canBecomeKey == false`; this makes the
        // pill inert to the mouse as well, so it cannot eat a click meant for
        // the app underneath.
        panel.ignoresMouseEvents = true

        panel.contentView = NSHostingView(
            rootView: RecordingIndicatorView()
                .frame(width: panelWidth, height: panelHeight)
        )

        position(panel)
        panel.alphaValue = 0
        // Never `makeKeyAndOrderFront` — see above.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        // Cleared before the fade rather than in its completion handler, so a
        // start arriving mid-fade presents a fresh panel instead of finding one
        // already on its way out and skipping. The animation closure captures
        // the local `panel`, not `self.panel`, so it can only ever order out the
        // window it was handed — never a newer one.
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Bottom centre of whichever screen holds the pointer — away from the text
    /// being dictated into, and clear of the toasts, which sit top centre.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panelWidth / 2
        let y = visibleFrame.minY + 80

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
