import AppKit
import Foundation
import Observation
import UserNotifications

@Observable
@MainActor
final class AppState: Sendable {
    let recorder = AudioRecorder()
    let deviceManager = AudioDeviceManager()
    let parakeet = ParakeetProvider()
    let whisper = WhisperProvider()
    let customProvider = CustomProvider()
    let recordingStore = RecordingStore()
    let analyticsStore = AnalyticsStore()
    let permissions = PermissionsManager()
    let pasteboard = PasteboardService()
    let toast = ToastWindowController.shared

    @ObservationIgnored private lazy var modelLoader = ModelLoadCoordinator(
        initialMode: transcriptionMode,
        customSettings: customProviderSettings,
        parakeet: parakeet,
        whisper: whisper,
        toast: toast
    )

    /// Read once at launch. Changing `.env` requires a relaunch — reloading
    /// mid-session would let a recording start under one configuration and
    /// finish under another.
    let envConfig = EnvConfig.load()
    let cleanupClient = CleanupClient()

    var replacementSettings = ReplacementSettings.load()
    var transcriptionMode: TranscriptionMode = TranscriptionModeStorage.load()
    var customProviderSettings = CustomProviderSettings.load()
    var showMenuBarVisibilityHint = false

    var modelLoadState: ModelLoadState { modelLoader.state }

    /// True while the live-dictation cleanup pass is running (the LLM
    /// polish step after transcription, before paste). Used by the menu
    /// bar icon + status text to render "Editing…" instead of the
    /// generic "Transcribing…" treatment.
    var isCleanupProcessing = false

    /// Character count of the text currently being run through cleanup.
    /// Used by the menu bar status text to surface scale for larger
    /// passes — only shown above a threshold (see
    /// `RecordingHeaderView.cleanupCharThreshold` in `MenuBarView`).
    var cleanupProcessingCharCount: Int = 0

    let maxRecordingDuration: TimeInterval = 600.0  // 10 minutes
    var warningDuration: TimeInterval { maxRecordingDuration * 0.8 }  // 8 minutes

    var warningShown = false
    var durationCheckTimer: Timer?
    var currentRecordingId: String?
    var captureTransitionInFlight = false

    var onRecordingStarted: (() -> Void)?
    var onRecordingEnded: (() -> Void)?

    var isModelLoaded: Bool { modelLoadState.isReady }

    init() {
        recorder.onRecordingInterrupted = { [weak self] interruption in
            guard let self else { return }
            let recordingId = currentRecordingId
            stopDurationChecks()
            onRecordingEnded?()
            currentRecordingId = nil
            captureTransitionInFlight = false
            if let recordingId {
                saveInterruptedRecording(interruption, recordingId: recordingId)
            }
            toast.showError(title: "Recording Failed", message: interruption.message)
            recorder.reset()
        }

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let appState = Unmanaged<AppState>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    appState.replacementSettings = ReplacementSettings.load()
                }
            },
            "com.faladan.config-changed" as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Initialization

    func preloadModel() {
        modelLoader.loadSelectedModel(
            mode: transcriptionMode,
            customSettings: customProviderSettings
        )
    }

    func switchTranscriptionMode(to mode: TranscriptionMode) {
        guard mode != transcriptionMode else { return }

        if recorder.state.isRecording {
            toast.showError(
                title: "Cannot Switch", message: "Stop recording before switching models.")
            return
        }

        if recorder.state == .processing {
            return
        }

        modelLoader.unload(mode: transcriptionMode)

        transcriptionMode = mode
        TranscriptionModeStorage.save(mode)
        modelLoader.loadSelectedModel(
            mode: transcriptionMode,
            customSettings: customProviderSettings
        )
    }

    func refreshCustomTranscriptionReadiness() {
        guard transcriptionMode == .custom else { return }
        modelLoader.refreshCustomReadiness(customSettings: customProviderSettings)
    }

    // MARK: - Recording

    /// When the current hold-to-talk press began, for the minimum-hold check on
    /// release. Uses the monotonic uptime clock rather than wall time so an NTP
    /// step mid-hold cannot turn a brushed key into a "long" hold.
    private var holdToTalkStartedAt: TimeInterval?

    /// A release that arrived before the recorder was live, waiting to be
    /// applied the moment it is.
    ///
    /// The recorder only reports `.recording` after an async CoreAudio device
    /// open, which can take longer than the hold itself — so acting on observed
    /// recorder state would drop the release entirely and leave the microphone
    /// running with nothing left to stop it. Recording the *intent* instead
    /// makes the decision independent of how long the hardware took.
    private var pendingHoldRelease: (decision: HoldToTalkPolicy.Release, generation: UInt64)?

    /// Incremented on every hold-to-talk press, and stamped onto any release
    /// parked against that press.
    ///
    /// Defence in depth, and honestly labelled as such: **on the hotkey path this
    /// check cannot currently fail.** `beginHoldToTalk` clears
    /// `pendingHoldRelease` three lines before it bumps this counter, with no
    /// suspension point between, so a parked release always carries the current
    /// generation. What actually keeps a stale release from cutting short someone
    /// else's recording is that clear, plus `endHoldToTalkStartWindow()`.
    ///
    /// It is kept because it is cheap and it states the invariant those two rely
    /// on. It is not, however, a general guard: a start that does not run through
    /// `beginHoldToTalk` neither clears the parked release nor bumps this counter,
    /// so a stale release *matches* and gets applied. `toggleRecording()` is that
    /// path — see the precondition on it. Unreachable today only because nothing
    /// calls it.
    ///
    /// Wrapping addition: a counter that trapped on overflow would crash the
    /// hotkey path, and only equality is ever compared.
    private var holdGeneration: UInt64 = 0

    /// Whether a hold-to-talk start *this object initiated* is still resolving.
    ///
    /// Only such a start may have a release parked against it. Without this,
    /// a release with nothing to stop — a hold pressed while the model is still
    /// loading, or a key-up stranded by `releaseStrandedPresses` with no press
    /// behind it — would park an intent that the next recording to start, very
    /// possibly one begun by a different shortcut, would consume and be killed by.
    private var holdToTalkStartInFlight = false

    /// Kept for the menu bar and any UI affordance that starts a recording
    /// without a key to hold. The hotkey path is `beginHoldToTalk` /
    /// `endHoldToTalk` and no longer routes through here.
    ///
    /// **Precondition for any future caller:** clear `pendingHoldRelease` before
    /// starting. Unlike `beginHoldToTalk`, this path neither clears a parked
    /// release nor bumps `holdGeneration`, so a release parked by an earlier hold
    /// still matches the current generation and `applyPendingHoldRelease` would
    /// apply it — stopping or discarding the recording this call just began. The
    /// generation check does not catch it; see `holdGeneration`.
    ///
    /// Currently uncalled, which is the only reason that is theoretical. Retained
    /// for the strip phase to decide; do not give it a caller without resolving
    /// this first.
    func toggleRecording() {
        if recorder.state.isRecording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    /// Hotkey pressed. Starts recording immediately — latency here is felt
    /// directly as clipped first syllables.
    func beginHoldToTalk() {
        // A start already in flight — from `toggleRecording()` if a UI
        // affordance ever calls it again — owns the recording. Bail before
        // touching it. Checking `captureTransitionInFlight` as well as
        // `isRecording` matters because the gap between them is exactly the
        // CoreAudio device-open window: during it a recording is being started
        // but does not yet report itself as recording.
        guard !recorder.state.isRecording, !captureTransitionInFlight else { return }

        // Below the guard, deliberately. A press that bails above must not
        // destroy a release parked against the start it just declined to touch:
        // that start is still resolving and still needs its decision. Clearing
        // it there let a fast double-brush transcribe when the first release had
        // already said discard.
        pendingHoldRelease = nil

        holdToTalkStartedAt = ProcessInfo.processInfo.systemUptime
        holdGeneration &+= 1
        holdToTalkStartInFlight = true
        startRecording()
    }

    /// Hotkey released. Transcribes a real hold; discards a brushed key.
    ///
    /// Discarding routes through `discardRecording()` rather than
    /// `stopAndTranscribe()` so no API call is made and nothing is pasted — and
    /// not through `cancelRecording()`, which is Esc's flow and deliberately
    /// keeps the audio and a history row.
    ///
    /// The recorder may not be live yet — a hold shorter than the CoreAudio
    /// device open resolves here first. In that case the decision is parked and
    /// `startRecordingFlow` applies it as soon as the recorder comes up, so a
    /// brushed key cannot leave a microphone running.
    func endHoldToTalk() {
        // Cleared before the edit-mode guard so a stale timestamp cannot leak
        // into an unrelated later hold.
        let startedAt = holdToTalkStartedAt
        holdToTalkStartedAt = nil

        let held = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
        let decision = HoldToTalkPolicy.release(heldFor: held, minimum: envConfig.minHold)

        if recorder.state.isRecording {
            applyHoldRelease(decision)
            return
        }

        // Park only against a start this press actually initiated. A release
        // with nothing to stop must evaporate here, or the next recording to
        // start — possibly one begun by a different shortcut entirely — would
        // consume the stale intent and be cut down immediately.
        guard holdToTalkStartInFlight else { return }
        pendingHoldRelease = (decision, holdGeneration)
    }

    /// Runs a release decision against a live recorder.
    ///
    /// Discarding goes to `discardRecording()`, not `cancelRecording()`: the user
    /// never asked for this recording, so it should leave no history row and no
    /// audio file behind. Esc keeps its own flow, which preserves both.
    func applyHoldRelease(_ decision: HoldToTalkPolicy.Release) {
        switch decision {
        case .transcribe: stopAndTranscribe()
        case .discard: discardRecording()
        }
    }

    func discardRecording() {
        Task { await discardRecordingFlow() }
    }

    /// The hotkey turned out to be a modifier for another chord — Fn+← and the
    /// like — not a dictation press.
    ///
    /// Discards unconditionally, with no elapsed-time check: however long Fn was
    /// held, the user was navigating, not talking. Without this the hold clears
    /// the minimum-hold threshold on any deliberate pause before the chord, and
    /// ambient room audio gets transcribed and pasted into the very app being
    /// navigated.
    func abortHoldToTalk() {
        holdToTalkStartedAt = nil

        if recorder.state.isRecording {
            applyHoldRelease(.discard)
            return
        }

        guard holdToTalkStartInFlight else { return }
        pendingHoldRelease = (.discard, holdGeneration)
    }

    /// Applies a release that arrived before the recorder was live, if one did.
    ///
    /// Called by `startRecordingFlow` once the recorder is up. Returns whether a
    /// pending release was consumed.
    @discardableResult
    func applyPendingHoldRelease() -> Bool {
        guard let parked = pendingHoldRelease else { return false }
        pendingHoldRelease = nil
        // Belongs to an earlier press whose start never completed — applying it
        // would cut short the recording now starting.
        guard HoldToTalkPolicy.shouldApplyParkedRelease(
            parked: parked.generation, current: holdGeneration)
        else { return false }
        let decision = parked.decision
        applyHoldRelease(decision)
        return true
    }

    /// Ends the hold-to-talk start window, dropping any release still parked
    /// against it.
    ///
    /// Called from `startRecordingFlow`'s `defer`, so it covers the early returns
    /// that never begin a recording — model still loading, no audio device, a
    /// non-idle recorder — as well as the success and failure paths. A parked
    /// release that outlives its start has nothing to act on and must not survive
    /// to meet the next one.
    ///
    /// `startRecordingFlow`'s `guard !captureTransitionInFlight` sits above the
    /// `defer` and so is not covered here — but a *hold* start cannot reach it:
    /// `beginHoldToTalk` checks the same flag first and bails before starting a
    /// flow at all, which is why the press that would have hit it never bumps
    /// `holdGeneration`. Its parked release stays owned by the flow already
    /// running, and that flow's own `defer` clears it.
    ///
    /// Hoisting the `defer` above the guard was the obvious fix and the wrong
    /// one: a second flow bailing there would then clear a live hold's window,
    /// which is the same bug pointing the other way.
    func endHoldToTalkStartWindow() {
        holdToTalkStartInFlight = false
        pendingHoldRelease = nil
    }

    func startRecording() {
        Task { await startRecordingFlow() }
    }

    func stopAndTranscribe() {
        Task { await stopAndTranscribeFlow() }
    }

    func cancelRecording() {
        Task { await cancelRecordingFlow() }
    }

    func retranscribe(_ recording: Recording) {
        guard recorder.state.isIdle else {
            toast.showError(
                title: "Busy", message: "Wait for the current recording/transcription to finish.")
            return
        }
        guard recording.canRetranscribe else {
            toast.showError(
                title: "Cannot Re-transcribe", message: "Audio file is no longer available.")
            return
        }

        recorder.state = .processing

        Task {
            await retranscribeSavedRecording(recording)
        }
    }

    /// Re-transcribe a completed recording with the currently active model,
    /// creating a new history entry. Does not auto-paste — the user copies
    /// from the new history row manually.
    func retranscribeAsNew(_ recording: Recording, applyCleanup: Bool = false) {
        guard recorder.state.isIdle else {
            toast.showError(
                title: "Busy", message: "Wait for the current recording/transcription to finish.")
            return
        }
        guard recording.canRetranscribeAsNew else {
            toast.showError(
                title: "Cannot Re-transcribe", message: "Audio file is no longer available.")
            return
        }

        recorder.state = .processing

        Task {
            await retranscribeAsNewEntry(from: recording, applyCleanup: applyCleanup)
        }
    }

    // MARK: - Shortcuts

    func reloadShortcuts() {
        CustomShortcutMonitor.shared.reloadShortcuts()
    }

}
