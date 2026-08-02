import AppKit
import Foundation

extension AppState {
    // MARK: - Recording Flow

    func startRecordingFlow() async {
        guard !captureTransitionInFlight else { return }
        captureTransitionInFlight = true
        // Covers every exit below, not just the catch: this method returns early
        // on a model that is still loading, a missing audio device, and a
        // non-idle recorder, none of which start a recording. A hold-to-talk
        // release parked against any of those has nothing to act on, and must
        // not survive to be consumed by the next recording that does start.
        defer {
            captureTransitionInFlight = false
            endHoldToTalkStartWindow()
        }

        guard recorder.state.isIdle else { return }
        guard isModelLoaded else {
            if transcriptionMode == .custom {
                toast.showError(
                    title: "Not Configured",
                    message: "Configure your custom endpoint before recording.")
            } else if let message = modelLoadState.failureMessage {
                toast.showError(title: "Model Load Failed", message: message)
            } else {
                toast.showError(
                    title: "Model Not Ready",
                    message: "Please wait for the model to finish loading.")
            }
            return
        }

        let recordingId = Recording.generateId()
        currentRecordingId = recordingId
        warningShown = false

        guard let resolvedDevice = deviceManager.resolveRecordingDevice() else {
            toast.showError(title: "Recording Failed", message: "No audio input device available")
            recorder.reset()
            currentRecordingId = nil
            return
        }

        if resolvedDevice.requestedMode == .specificDevice
            && resolvedDevice.didFallbackToSystemDefault
        {
            toast.show(
                ToastMessage(
                    type: .warning,
                    title: "Mic Unavailable",
                    message: "Selected mic not found, using system default"
                ))
        }

        let dir = Recording.baseDirectory.appendingPathComponent(recordingId)
        let audioURL = dir.appendingPathComponent("audio.wav")
        saveInProgressRecording(id: recordingId, inputDeviceName: resolvedDevice.resolvedDeviceName)

        do {
            try await recorder.startRecording(to: audioURL, resolvedDevice: resolvedDevice)
            startDurationChecks()
            onRecordingStarted?()
            // The hotkey may already have been released while the device was
            // opening. Apply that decision now, or the microphone stays live
            // with no release left to stop it.
            applyPendingHoldRelease()
        } catch {
            recordingStore.discard(id: recordingId)
            toast.showError(title: "Recording Failed", message: error.localizedDescription)
            recorder.reset()
            currentRecordingId = nil
        }
    }

    func stopAndTranscribeFlow() async {
        guard !captureTransitionInFlight else { return }
        captureTransitionInFlight = true
        defer { captureTransitionInFlight = false }

        guard recorder.state.isRecording else { return }

        stopDurationChecks()
        onRecordingEnded?()

        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        let inputDeviceName = recorder.actualInputDeviceName

        // Whisper hallucinates filler on very short clips, so there is still a
        // floor — but it is now a hardware floor, not an intent one.
        //
        // This guard used to be 1.0s, on the reasoning that a sub-second clip
        // was "nearly always an accidental toggle double-tap". Hold-to-talk
        // removed that failure mode: an accidental press is now caught at the
        // release by HoldToTalkPolicy's minimum-hold check, before any recording
        // is kept. Leaving the floor at 1.0s would have made that check
        // decorative — every hold between 0.15s and 1.0s passed the policy and
        // then died here with an error toast, so a deliberate short word
        // ("yes", "undo") could not be dictated at all.
        guard duration >= 0.3 else {
            let recordingId = currentRecordingId
            await recorder.cancelRecording()
            recorder.reset()
            if let recordingId {
                recordingStore.discard(id: recordingId)
            }
            currentRecordingId = nil
            toast.showError(
                title: "Recording Too Short",
                message: "Nothing transcribed — try again and speak a bit longer.")
            return
        }

        guard let audioURL = await recorder.stopRecording() else {
            if let id = currentRecordingId {
                recordingStore.discardIfStillInProgress(id: id)
            }
            recorder.reset()
            currentRecordingId = nil
            return
        }

        let recordingId = currentRecordingId ?? Recording.generateId()
        currentRecordingId = nil

        // Snapshot + clear the cleanup flag before running transcribe.
        // Whether the recording was started via the Auto-Cleanup shortcut
        // is fixed at start time; stopping doesn't change the intent.
        let applyCleanup = cleanupRequestedForCurrentRecording
        cleanupRequestedForCurrentRecording = false

        await transcribe(
            audioURL: audioURL,
            recordingId: recordingId,
            duration: duration,
            sampleRate: sampleRate,
            inputDeviceName: inputDeviceName,
            applyCleanup: applyCleanup
        )
    }

    private func saveInProgressRecording(id: String, inputDeviceName: String) {
        let recording = Recording(
            id: id,
            createdAt: Date(),
            recording: RecordingInfo(
                duration: 0,
                sampleRate: 0,
                channels: 1,
                fileSize: 0,
                inputDevice: inputDeviceName
            ),
            transcription: nil,
            configuration: RecordingConfiguration(
                voiceModel: transcriptionMode.modelDisplayName,
                language: "auto",
                provider: transcriptionMode.rawValue
            ),
            status: .recording
        )
        try? recordingStore.saveMetadataOnly(recording)
    }

    func saveInterruptedRecording(_ interruption: InterruptedRecording, recordingId: String) {
        let fileSize: Int64
        if let url = interruption.audioURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
        {
            fileSize = size
        } else {
            fileSize = 0
        }
        let recording = Recording(
            id: recordingId,
            createdAt: Date(),
            recording: RecordingInfo(
                duration: interruption.duration,
                sampleRate: interruption.sampleRate,
                channels: 1,
                fileSize: fileSize,
                inputDevice: interruption.inputDeviceName
            ),
            transcription: nil,
            configuration: RecordingConfiguration(
                voiceModel: transcriptionMode.modelDisplayName,
                language: "auto",
                provider: transcriptionMode.rawValue
            ),
            status: .failed
        )
        try? recordingStore.saveFailedRecording(recording)
    }

    func cancelRecordingFlow() async {
        guard !captureTransitionInFlight else { return }
        captureTransitionInFlight = true
        defer { captureTransitionInFlight = false }

        guard recorder.state.isRecording else { return }

        cleanupRequestedForCurrentRecording = false
        stopDurationChecks()
        onRecordingEnded?()

        let duration = recorder.currentDuration
        let sampleRate = recorder.actualSampleRate
        let inputDeviceName = recorder.actualInputDeviceName
        let recordingId = currentRecordingId ?? Recording.generateId()
        currentRecordingId = nil

        guard let audioURL = await recorder.stopRecording() else {
            recordingStore.discardIfStillInProgress(id: recordingId)
            recorder.reset()
            return
        }
        recorder.reset()

        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        let recording = Recording(
            id: recordingId,
            createdAt: Date(),
            recording: RecordingInfo(
                duration: duration,
                sampleRate: sampleRate,
                channels: 1,
                fileSize: fileSize,
                inputDevice: inputDeviceName
            ),
            transcription: nil,
            configuration: RecordingConfiguration(
                voiceModel: transcriptionMode.modelDisplayName,
                language: "en",
                provider: transcriptionMode.rawValue
            ),
            status: .cancelled
        )

        do {
            try recordingStore.saveWithExistingAudio(recording)
        } catch {
            toast.showError(title: "Cancel Save Failed", message: error.localizedDescription)
        }
    }
}
