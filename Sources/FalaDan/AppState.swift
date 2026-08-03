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
    let editModeProvider = EditModeProvider()
    let customEditProvider = CustomEditProvider()
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
    var customEditProviderSettings = CustomEditProviderSettings.load()
    var editModeBehavior: EditModeBehavior = EditModeSettings.behavior

    var selectionEnabled: Bool { editModeBehavior.selectionEnabled }
    var autoCleanupEnabled: Bool { editModeBehavior.autoCleanupEnabled }
    var voiceEditEnabled: Bool = EditModeSettings.voiceEdit
    var showMenuBarVisibilityHint = false

    var modelLoadState: ModelLoadState { modelLoader.state }

    /// Set while a voice-edit recording is active. Holds the captured
    /// selection + saved pasteboard so the second shortcut press can
    /// transcribe the voice instruction and apply it to the selection.
    /// When non-nil, the recorder is in `.recording` state but the
    /// normal toggle/cancel handlers route to the edit-mode flow
    /// instead of the standard transcribe-and-paste path.
    var editModeContext: EditModeContext?

    /// True when the active recording was started via the Auto-Cleanup
    /// shortcut. Read at transcription time to decide whether to run
    /// the LLM cleanup pass; reset on stop, cancel, and error.
    var cleanupRequestedForCurrentRecording: Bool = false

    /// True while the edit-mode flow is in its post-recording phase
    /// (transcribing the instruction + invoking the edit provider). Used
    /// by the menu bar icon + status text to render edit-specific state
    /// instead of the generic "Transcribing…" treatment.
    var isEditModeProcessing = false

    /// Character count of the current edit-mode selection. Used by the
    /// menu bar status text to surface scale for larger edits — only
    /// shown when above `EditModeProvider.softCharThreshold`.
    var editModeProcessingCharCount: Int = 0

    struct EditModeContext: Sendable {
        let selectedText: String
        let savedPasteboard: PasteboardService.SavedPasteboardContents?
        let recordingId: String
    }

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
            cleanupRequestedForCurrentRecording = false
            if editModeContext == nil, let recordingId {
                saveInterruptedRecording(interruption, recordingId: recordingId)
            } else if let context = editModeContext {
                editModeContext = nil
                pasteboard.restoreSavedPasteboard(context.savedPasteboard)
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
    private var pendingHoldRelease: HoldToTalkPolicy.Release?

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
    func toggleRecording() {
        // Edit-mode recording uses the same recorder. Don't let the normal
        // toggle shortcut hijack it — the user has to press the edit
        // shortcut again (or Esc) to end an edit recording.
        if editModeContext != nil { return }

        if recorder.state.isRecording {
            stopAndTranscribe()
        } else {
            cleanupRequestedForCurrentRecording = false
            startRecording()
        }
    }

    /// Hotkey pressed. Starts recording immediately — latency here is felt
    /// directly as clipped first syllables.
    func beginHoldToTalk() {
        if editModeContext != nil { return }

        // A start already in flight — from the auto-cleanup shortcut, or from
        // `toggleRecording()` if a UI affordance ever calls it again — owns both
        // the recording and its cleanup intent. Bail before
        // touching either. Checking `captureTransitionInFlight` as well as
        // `isRecording` matters because the gap between them is exactly the
        // CoreAudio device-open window: during it a recording is being started
        // but does not yet report itself as recording, and clearing
        // `cleanupRequestedForCurrentRecording` there would silently disable the
        // cleanup pass on someone else's recording.
        guard !recorder.state.isRecording, !captureTransitionInFlight else { return }

        // Below the guard, deliberately. A press that bails above must not
        // destroy a release parked against the start it just declined to touch:
        // that start is still resolving and still needs its decision. Clearing
        // it there let a fast double-brush transcribe when the first release had
        // already said discard.
        pendingHoldRelease = nil

        holdToTalkStartedAt = ProcessInfo.processInfo.systemUptime
        holdToTalkStartInFlight = true
        cleanupRequestedForCurrentRecording = false
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

        if editModeContext != nil { return }

        let held = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
        let decision = HoldToTalkPolicy.release(heldFor: held)

        if recorder.state.isRecording {
            applyHoldRelease(decision)
            return
        }

        // Park only against a start this press actually initiated. A release
        // with nothing to stop must evaporate here, or the next recording to
        // start — possibly one begun by a different shortcut entirely — would
        // consume the stale intent and be cut down immediately.
        guard holdToTalkStartInFlight else { return }
        pendingHoldRelease = decision
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

        if editModeContext != nil { return }

        if recorder.state.isRecording {
            applyHoldRelease(.discard)
            return
        }

        guard holdToTalkStartInFlight else { return }
        pendingHoldRelease = .discard
    }

    /// Applies a release that arrived before the recorder was live, if one did.
    ///
    /// Called by `startRecordingFlow` once the recorder is up. Returns whether a
    /// pending release was consumed.
    @discardableResult
    func applyPendingHoldRelease() -> Bool {
        guard let decision = pendingHoldRelease else { return false }
        pendingHoldRelease = nil
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
    /// One exit is *not* covered: `guard !captureTransitionInFlight` sits above
    /// the `defer`, so a hold start bailing there leaves the window open and its
    /// release can be consumed by the flow already running. Reaching that needs
    /// two starts within about one main-actor hop. Hoisting the `defer` would not
    /// fix it and would make things worse — a second flow bailing at that guard
    /// would then clear a live hold's window. The real fix is a generation token
    /// on the parked release; deferred rather than bolted on here.
    func endHoldToTalkStartWindow() {
        holdToTalkStartInFlight = false
        pendingHoldRelease = nil
    }

    /// Auto-cleanup recording shortcut: starts/stops a normal recording
    /// but flags it so the LLM cleanup pass runs on the transcript
    /// before insertion. Pressing this while another recording is in
    /// flight just stops it — the cleanup intent is fixed at start time.
    func toggleAutoCleanupRecording() {
        if editModeContext != nil { return }

        if recorder.state.isRecording {
            stopAndTranscribe()
        } else {
            cleanupRequestedForCurrentRecording = true
            startRecording()
        }
    }

    func startRecording() {
        Task { await startRecordingFlow() }
    }

    func stopAndTranscribe() {
        Task { await stopAndTranscribeFlow() }
    }

    func cancelRecording() {
        // Esc cancels whichever flow is active. Edit-mode cancel restores
        // the saved pasteboard and bails without transcribing.
        if editModeContext != nil {
            cancelEditModeRecording()
            return
        }
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

    /// Which shortcuts are registered depends on which features are switched
    /// on, so a settings change has to re-derive them. A shortcut for a
    /// disabled feature must end up unregistered — that is what lets the chord
    /// reach the focused app instead of being swallowed.
    func refreshShortcutRegistrations() {
        CustomShortcutMonitor.shared.refresh()
    }

}
