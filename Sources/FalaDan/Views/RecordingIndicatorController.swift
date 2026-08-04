import AppKit
import SwiftUI

/// Floating pill shown while a dictation is being recorded.
///
/// Panel setup mirrors `ToastWindowController`. The two are deliberately not
/// shared: their lifetimes are unrelated, and the indicator carries a delay and
/// a cancellation rule that a toast has no use for.
@MainActor
final class RecordingIndicatorController {
    static let shared = RecordingIndicatorController()

    private var panel: NSPanel?
    private var showTask: Task<Void, Never>?

    /// Invalidates a delayed show that is still waiting when the recording ends.
    ///
    /// Cancelling `showTask` is very probably sufficient on the main actor. The
    /// generation is kept anyway: "very probably" is the reasoning that produced
    /// the Phase 1 hot-mic race, and a show that fires after its recording has
    /// gone leaves a pill on screen with nothing left to take it down.
    private var generation: UInt64 = 0

    private let panelWidth: CGFloat = 140
    private let panelHeight: CGFloat = 44

    var isShowing: Bool { panel != nil }
    var isPending: Bool { showTask != nil }

    func recordingStarted(minimumHold: TimeInterval) {
        switch RecordingIndicatorPolicy.onRecordingStarted(minimumHold: minimumHold) {
        case .showImmediately:
            cancelPendingShow()
            present()
        case .scheduleShow(let delay):
            scheduleShow(after: delay)
        case .cancelAndHide, .ignore:
            break
        }
    }

    func recordingEnded() {
        switch RecordingIndicatorPolicy.onRecordingEnded(
            isShowing: isShowing, isPending: isPending)
        {
        case .cancelAndHide:
            cancelPendingShow()
            dismiss()
        case .ignore, .showImmediately, .scheduleShow(_):
            // `onRecordingEnded` only ever returns the two cases above; the rest
            // are here because the switch must be exhaustive. Bump anyway: an
            // in-flight show that already passed its cancellation check must not
            // survive this call.
            generation &+= 1
        }
    }

    private func scheduleShow(after delay: TimeInterval) {
        cancelPendingShow()
        generation &+= 1
        let mine = generation
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self, mine == self.generation else { return }
            self.showTask = nil
            self.present()
        }
    }

    private func cancelPendingShow() {
        generation &+= 1
        showTask?.cancel()
        showTask = nil
    }

    private func present() {
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
        // somewhere the user was not typing.
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

    private func dismiss() {
        guard let panel else { return }
        // Cleared before the animation, not in its completion: `isShowing` must
        // report false the moment the decision is made, or a start arriving
        // mid-fade would see a panel that is on its way out and skip presenting.
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
