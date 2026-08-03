import Foundation
import os.log

private let log = Logger(subsystem: Logger.subsystem, category: "Transcription")

private enum TranscriptDelivery: Sendable {
    case paste
    case copyOnly
}

extension AppState {
    // MARK: - Transcription

    /// Runs the LLM cleanup pass on a raw transcript.
    ///
    /// Returns the cleaned text plus history metadata, or `(rawText, nil)` when
    /// the caller opts out, cleanup is not configured, the transcript is empty,
    /// or the call fails.
    ///
    /// Failures are intentionally silent — the user gets the raw transcript
    /// pasted rather than being blocked on a model error. That mattered when
    /// cleanup was opt-in; it matters more now that it runs on every dictation,
    /// because an expired key would otherwise cost the user every word they say.
    func applyAutoCleanup(
        rawText: String, applyCleanup: Bool
    ) async -> (text: String, cleanup: RecordingCleanup?) {
        guard applyCleanup, !rawText.isEmpty else {
            return (rawText, nil)
        }

        // Second gate, deliberately redundant with the call site's. Callers that
        // pass `applyCleanup: true` unconditionally — re-transcribe-with-cleanup
        // in the history popover, for one — would otherwise reach the client and
        // take the throw-and-log path for what is simply an unconfigured app.
        // Skipping is the honest answer, and it is what the code this replaced
        // did for its own unconfigured case.
        guard envConfig.isCleanupConfigured else {
            return (rawText, nil)
        }

        let start = Date()

        // Surface the LLM phase as "Editing…" in the menu bar so the icon
        // shifts off `waveform.badge.ellipsis` (transcribing) onto
        // `wand.and.stars` (editing) for the duration of the cleanup call.
        isCleanupProcessing = true
        cleanupProcessingCharCount = rawText.count
        defer {
            isCleanupProcessing = false
            cleanupProcessingCharCount = 0
        }

        do {
            let cleaned = try await cleanupClient.cleanup(
                transcript: rawText, config: envConfig)
            let duration = Date().timeIntervalSince(start)
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (rawText, nil) }

            let cleanup = RecordingCleanup(
                rawText: rawText,
                cleanedText: trimmed,
                backendModel: (envConfig.llmModel ?? "unknown")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                cleanupDuration: duration
            )
            return (trimmed, cleanup)
        } catch {
            // Silent UX is intentional — fall back to the raw transcript so the
            // user isn't blocked. Now that cleanup runs on every dictation, this
            // is what stops a model outage or an expired key from costing the
            // user their words.
            //
            // Because the failure is invisible by design, this log line is the
            // only signal that anything is wrong — so it has to say something
            // useful. `localizedDescription` does not: `CleanupClientError`
            // deliberately has no `LocalizedError` conformance (that is what
            // keeps response bodies, which some providers echo a partial key
            // into, out of the log), so it renders as "error 2".
            //
            // Hence the switch: the status code and failure kind are the
            // actionable parts, and neither can carry a secret.
            log.error(
                "Cleanup failed: \(Self.diagnostic(for: error), privacy: .public)")
            return (rawText, nil)
        }
    }

    /// A loggable description of a cleanup failure that cannot leak a secret.
    ///
    /// Deliberately never includes the response body. A 401 body from several
    /// providers echoes back part of the key that was sent, and this line goes to
    /// the unified log where it outlives the session.
    static func diagnostic(for error: any Error) -> String {
        switch error {
        case CleanupClientError.serverError(let code, _):
            // The status code alone separates the cases worth acting on: 401 is
            // a bad key, 404 a retired model or wrong base URL, 429 a rate limit.
            return "HTTP \(code)"
        case CleanupClientError.notConfigured:
            return "not configured"
        case CleanupClientError.invalidEndpoint:
            return "invalid endpoint — check LLM_BASE_URL"
        case CleanupClientError.emptyResponse:
            return "empty response"
        case let urlError as URLError:
            // Distinguishes a timeout from no network, which is the difference
            // between "the model is slow" and "you are offline".
            return "URLError \(urlError.code.rawValue)"
        default:
            return error.localizedDescription
        }
    }

    /// Builds the formatter options from the current user settings.
    /// Snapshotted into a local so replacements + formatting see the
    /// same config across both halves of the pipeline.
    private func currentFormatterOptions() -> TranscriptionFormatter.Options {
        let rules = replacementSettings.enabled ? replacementSettings.enabledRules : []
        return TranscriptionFormatter.Options(
            replacementRules: rules,
            capitalization: FormattingSettings.capitalization,
            autoParagraph: FormattingSettings.autoParagraph,
            dropTrailingPunctuation: FormattingSettings.dropTrailingPunctuation,
            spokenSymbolsEnabled: SpokenSymbolsSettings.enabled,
            appendTrailingSpace: FormattingSettings.appendTrailingSpace
        )
    }

    private func applyPostProcessing(to text: String) -> String {
        TranscriptionFormatter.format(text, options: currentFormatterOptions())
    }

    private func deliverTranscript(_ text: String, delivery: TranscriptDelivery) {
        switch delivery {
        case .paste:
            pasteboard.copyAndPaste(text)
        case .copyOnly:
            if pasteboard.copy(text) {
                toast.showInfo(
                    title: "Transcript copied",
                    message: "Press ⌘V to paste.")
            } else {
                toast.showError(
                    title: "Copy Failed",
                    message: "Could not copy the transcript to the clipboard.")
            }
        }
    }

    /// Single choke point for VAD preprocessing: all three transcription entry
    /// points (fresh recording, re-transcribe cancelled, re-transcribe as new)
    /// funnel upload audio through here, and any failure inside the
    /// preprocessor falls back to the original WAV.
    private func preprocessForUpload(
        audioURL: URL,
        duration: TimeInterval,
        storageDir: URL
    ) async -> (url: URL, applied: Bool) {
        return await VADPreprocessor.shared.preprocess(
            audioURL: audioURL,
            durationSeconds: duration,
            recordingStorageDir: storageDir
        )
    }

    func transcribe(
        audioURL: URL, recordingId: String, duration: TimeInterval, sampleRate: Double,
        inputDeviceName: String, applyCleanup: Bool
    ) async {
        let storageDir = audioURL.deletingLastPathComponent()
        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: audioURL,
            duration: duration,
            storageDir: storageDir
        )

        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .default:
                result = try await parakeet.transcribe(audioURL: uploadURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: uploadURL)
            case .custom:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL, settings: customProviderSettings)
            }

            // Guard against stale callback: if the user rapid-tapped and started a new
            // recording while transcription was in-flight, the state has moved on.
            // Applying this result would desync state from the active recording.
            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(
                    title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            // Ordinary replacements shape what the cleanup model sees;
            // exact-case replacements run with formatting so declared names
            // survive global capitalization settings.
            let options = currentFormatterOptions()
            let withReplacements = TranscriptionFormatter.applyReplacements(
                to: result.text, options: options)
            let cleanupResult = await applyAutoCleanup(
                rawText: withReplacements, applyCleanup: applyCleanup)
            let finalText = TranscriptionFormatter.applyFormatting(
                to: cleanupResult.text, options: options)

            deliverTranscript(finalText, delivery: .paste)

            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64)
                ?? 0

            let recording = Recording(
                id: recordingId,
                createdAt: Date(),
                recording: RecordingInfo(
                    duration: duration,
                    sampleRate: sampleRate,
                    channels: 1,
                    fileSize: fileSize,
                    inputDevice: inputDeviceName,
                    vadApplied: vadApplied
                ),
                transcription: RecordingTranscription(
                    text: finalText,
                    segments: result.segments,
                    language: result.language,
                    model: result.model,
                    transcriptionDuration: result.duration
                ),
                configuration: RecordingConfiguration(
                    voiceModel: result.model,
                    language: result.language,
                    provider: transcriptionMode.rawValue
                ),
                status: .completed,
                cleanup: cleanupResult.cleanup
            )

            try recordingStore.saveWithExistingAudio(recording)
            analyticsStore.record(
                duration: duration,
                wordCount: result.text.split(separator: " ").count
            )
            recorder.reset()

        } catch {
            guard recorder.state == .processing else { return }
            recorder.reset()
            toast.showError(title: "Transcription Failed", message: error.localizedDescription)

            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64)
                ?? 0
            let recording = Recording(
                id: recordingId,
                createdAt: Date(),
                recording: RecordingInfo(
                    duration: duration,
                    sampleRate: sampleRate,
                    channels: 1,
                    fileSize: fileSize,
                    inputDevice: inputDeviceName,
                    vadApplied: vadApplied
                ),
                transcription: nil,
                configuration: RecordingConfiguration(
                    voiceModel: transcriptionMode.modelDisplayName,
                    // No detection result exists on failure; the app always
                    // requests auto-detect, so record the configuration
                    // rather than guessing a language.
                    language: "auto",
                    provider: transcriptionMode.rawValue
                ),
                status: .failed
            )
            try? recordingStore.saveFailedRecording(recording)
        }
    }

    func retranscribeSavedRecording(_ recording: Recording) async {
        // Source audio may have been compressed to CAF by the retention
        // sweep — decode it to a temp WAV so VAD + the providers (which
        // expect WAV) keep working unchanged.
        let prepared: (url: URL, isTemporary: Bool)
        do {
            prepared = try await ensureWAVForTranscription(recording.audioURL)
        } catch {
            recorder.reset()
            toast.showError(
                title: "Re-transcription Failed",
                message: "Could not decode audio: \(error.localizedDescription)")
            return
        }
        defer { cleanupTempAudio(prepared.url, isTemporary: prepared.isTemporary) }

        // Re-run VAD on the current raw WAV so the global toggle is the
        // source of truth. Overwrites any stale audio-vad.wav from the prior
        // run. No-op in the local modes — see `preprocessForUpload`.
        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: prepared.url,
            duration: recording.recording.duration,
            storageDir: recording.storageDirectory
        )

        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .default:
                result = try await parakeet.transcribe(audioURL: uploadURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: uploadURL)
            case .custom:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL, settings: customProviderSettings)
            }

            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(
                    title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            // Re-transcribing from history copies to the clipboard rather than
            // pasting, so it is a "get the text back" path, not a dictation.
            // Cleanup is skipped: it would spend an API call, and a second pass
            // over already-cleaned text is as likely to drift from what the user
            // said as to improve it.
            let cleanupResult = await applyAutoCleanup(
                rawText: result.text, applyCleanup: false)
            let finalText = applyPostProcessing(to: cleanupResult.text)

            deliverTranscript(finalText, delivery: .copyOnly)

            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: recording.audioURL.path)[.size]
                    as? Int64) ?? 0
            let updatedRecording = Recording(
                id: recording.id,
                createdAt: recording.createdAt,
                recording: RecordingInfo(
                    duration: recording.recording.duration,
                    sampleRate: recording.recording.sampleRate,
                    channels: recording.recording.channels,
                    fileSize: fileSize,
                    inputDevice: recording.recording.inputDevice,
                    vadApplied: vadApplied
                ),
                transcription: RecordingTranscription(
                    text: finalText,
                    segments: result.segments,
                    language: result.language,
                    model: result.model,
                    transcriptionDuration: result.duration
                ),
                configuration: RecordingConfiguration(
                    voiceModel: result.model,
                    language: result.language,
                    provider: transcriptionMode.rawValue
                ),
                status: .completed,
                cleanup: cleanupResult.cleanup
            )

            try recordingStore.saveWithExistingAudio(updatedRecording)
            analyticsStore.record(
                duration: recording.recording.duration,
                wordCount: result.text.split(separator: " ").count
            )
            recorder.reset()
        } catch {
            guard recorder.state == .processing else { return }
            recorder.reset()
            toast.showError(title: "Re-transcription Failed", message: error.localizedDescription)
        }
    }

    /// Creates a new recording entry by re-transcribing an existing completed
    /// recording's audio with the currently active model. Hard-links the audio
    /// file so both entries share the same bytes on disk.
    func retranscribeAsNewEntry(from source: Recording, applyCleanup: Bool = false) async {
        let newId = Recording.generateId()
        let newDir = Recording.baseDirectory.appendingPathComponent(newId)
        // Preserve the source's audio format (wav or caf) so the hard-link
        // metadata + on-disk extension stay in sync.
        let sourceFileName = source.audioFileName ?? "audio.wav"
        let newAudioURL = newDir.appendingPathComponent(sourceFileName)

        do {
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            // Hard-link avoids doubling disk usage; if one entry's audio is
            // retention-cleaned the other still works independently.
            try FileManager.default.linkItem(at: source.audioURL, to: newAudioURL)
        } catch {
            recorder.reset()
            toast.showError(
                title: "Re-transcription Failed",
                message: "Could not prepare audio: \(error.localizedDescription)")
            return
        }

        // If the source had been compressed, decode the hard-linked CAF
        // to a temp WAV before VAD + the providers see it.
        let prepared: (url: URL, isTemporary: Bool)
        do {
            prepared = try await ensureWAVForTranscription(newAudioURL)
        } catch {
            recorder.reset()
            toast.showError(
                title: "Re-transcription Failed",
                message: "Could not decode audio: \(error.localizedDescription)")
            return
        }
        defer { cleanupTempAudio(prepared.url, isTemporary: prepared.isTemporary) }

        let (uploadURL, vadApplied) = await preprocessForUpload(
            audioURL: prepared.url,
            duration: source.recording.duration,
            storageDir: newDir
        )

        do {
            let result: TranscriptionResult
            switch transcriptionMode {
            case .default:
                result = try await parakeet.transcribe(audioURL: uploadURL)
            case .multilingual:
                result = try await whisper.transcribe(audioURL: uploadURL)
            case .custom:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL, settings: customProviderSettings)
            }

            guard recorder.state == .processing else { return }

            guard !result.text.isEmpty else {
                recorder.reset()
                toast.showError(
                    title: "Empty Transcription", message: "No speech detected in recording.")
                return
            }

            let options = currentFormatterOptions()
            let withReplacements = TranscriptionFormatter.applyReplacements(
                to: result.text, options: options)
            let cleanupResult = await applyAutoCleanup(
                rawText: withReplacements, applyCleanup: applyCleanup)
            let finalText = TranscriptionFormatter.applyFormatting(
                to: cleanupResult.text, options: options)

            let fileSize =
                (try? FileManager.default.attributesOfItem(atPath: newAudioURL.path)[.size]
                    as? Int64) ?? 0
            let newRecording = Recording(
                id: newId,
                createdAt: Date(),
                recording: RecordingInfo(
                    duration: source.recording.duration,
                    sampleRate: source.recording.sampleRate,
                    channels: source.recording.channels,
                    fileSize: fileSize,
                    inputDevice: source.recording.inputDevice,
                    vadApplied: vadApplied
                ),
                transcription: RecordingTranscription(
                    text: finalText,
                    segments: result.segments,
                    language: result.language,
                    model: result.model,
                    transcriptionDuration: result.duration
                ),
                configuration: RecordingConfiguration(
                    voiceModel: result.model,
                    language: result.language,
                    provider: transcriptionMode.rawValue
                ),
                status: .completed,
                cleanup: cleanupResult.cleanup,
                audioFileName: source.audioFileName
            )

            try recordingStore.saveWithExistingAudio(newRecording)
            analyticsStore.record(
                duration: source.recording.duration,
                wordCount: result.text.split(separator: " ").count
            )
            recorder.reset()
        } catch {
            guard recorder.state == .processing else { return }
            recorder.reset()
            toast.showError(title: "Re-transcription Failed", message: error.localizedDescription)
        }
    }

    /// Returns a WAV URL ready for VAD + transcription. WAV inputs pass
    /// through; CAF inputs (recordings compressed by the retention sweep)
    /// are decoded to a temp WAV off the main actor. Caller is
    /// responsible for `cleanupTempAudio` after use.
    func ensureWAVForTranscription(_ source: URL) async throws -> (url: URL, isTemporary: Bool) {
        if source.pathExtension.lowercased() == "wav" {
            return (source, false)
        }
        return try await Task.detached(priority: .userInitiated) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("decode_\(UUID().uuidString).wav")
            try AudioDecoder.decodeToWAV(inputURL: source, outputURL: tempURL)
            return (tempURL, true)
        }.value
    }

    func cleanupTempAudio(_ url: URL, isTemporary: Bool) {
        guard isTemporary else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
