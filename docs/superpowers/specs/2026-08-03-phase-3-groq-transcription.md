# Phase 3 — Groq transcription as a switchable model

**Status:** Specified, not implemented.
**Supersedes:** the Phase 3 sketch in `2026-08-01-faladan-design.md` §5.4, which described
transcription provider config as `.env` keys without saying how the user would choose between
providers. It is a menu choice, not a config-only switch — see §2.

## 1. What we're building

A fourth row in the transcription model picker, **Groq**, sending audio to Groq's
`whisper-large-v3` / `whisper-large-v3-turbo` instead of transcribing on-device. Configured in
`.env`, chosen from the menu, switchable at any time without a relaunch.

## 2. Why it is a menu row and not just a config flag

The point is comparison. Parakeet is local, private, and free; Groq is faster and more accurate
on hard audio, but the recording leaves the machine. Neither is obviously right, and the
difference is only judgeable by flipping between them on real dictation — mumbling, accents,
background noise, technical vocabulary.

A config-only switch would make each comparison a file edit and a relaunch, which is enough
friction that the comparison does not get made. One click in a menu that is already open is not.

**This is a reversible experiment, not a migration.** Nothing about Parakeet changes, and
turning Groq off is selecting a different row.

## 3. Decisions

| Question | Decision | Why |
|---|---|---|
| Relationship to the existing `Custom` row | **A separate fourth row** | `Custom` stays exactly as it is. Groq becomes a named preset needing no typing — the whole value is that switching is one click. Two code paths that resemble each other is the accepted cost |
| Config source | **`.env`, new `STT_*` block** | Standing constraint: config lives in `.env`, not a settings UI. Keeps Groq's row zero-typing while `Custom` remains the type-it-yourself escape hatch |
| Key sharing with cleanup | **Separate `STT_API_KEY`** | Same key pasted twice when both are Groq, which is a real cost. Taken anyway: borrowing `LLM_API_KEY` when hosts match is implicit behaviour that reads as a bug later, and it forecloses pointing transcription and cleanup at different providers |
| Unconfigured state | **Row hidden entirely** | Consistent with cleanup, which silently no-ops when unconfigured. No dead controls |
| New transcription code | **None** | `CustomProvider` already posts to any OpenAI-compatible `/v1/audio/transcriptions`. Groq mode supplies it different settings. See §4.2 |
| Audio upload disclosure | **Badge on the row, plus README** | This is the one setting that ends the on-device guarantee. It must be visible at the point of choosing, not only in docs |

## 4. Architecture

### 4.1 `TranscriptionMode`

Add a case to `Sources/FalaDan/Models/TranscriptionMode.swift`:

```swift
case groq
```

`modelDisplayName` returns `"Groq"`. Raw value `"groq"`.

**Downgrade is already safe.** `TranscriptionModeStorage.load()` runs the stored string through
`TranscriptionMode(rawValue:)` and falls back to `.default` on nil, so a build without this case
reads a `"groq"` preference as Parakeet rather than failing. No migration needed in either
direction.

### 4.2 No new provider

`CustomProvider.transcribe(audioURL:settings:)` takes a `CustomProviderSettings` — endpoint, key,
model name — and posts multipart audio to a normalized
`/v1/audio/transcriptions`. Groq is such an endpoint. So Groq mode builds that struct from
`EnvConfig` rather than from `CustomProviderSettings.load()`:

```swift
extension EnvConfig {
    /// Groq transcription expressed as the settings `CustomProvider` already takes.
    /// Not persisted and never written to disk — built per call from `.env`.
    var sttProviderSettings: CustomProviderSettings {
        CustomProviderSettings(
            endpointURL: sttBaseURL,
            apiKey: sttAPIKey ?? "",
            modelName: sttModel ?? ""
        )
    }
}
```

`CustomEndpointNormalizer.normalize(_:canonicalPath:)` already resolves a base URL to the full
transcription path, so `STT_BASE_URL` takes the same shape as `LLM_BASE_URL`.

**Consequence for review:** this phase touches no networking, no multipart encoding, and no
audio handling. It is an enum case, a config block, a settings bridge, and a menu row.

### 4.3 Config

New keys, parsed in `EnvConfig` alongside the `LLM_*` block:

| Key | Default | Notes |
|---|---|---|
| `STT_BASE_URL` | `https://api.groq.com/openai/v1` | Any OpenAI-compatible transcription endpoint |
| `STT_API_KEY` | *(unset)* | Row hidden unless this and `STT_MODEL` are both set |
| `STT_MODEL` | *(unset)* | `whisper-large-v3-turbo` (faster) or `whisper-large-v3` (more accurate). Left blank on purpose, as with `LLM_MODEL` — hosted model ids get renamed and retired |

Gated by a property mirroring `isCleanupConfigured`:

```swift
var isGroqTranscriptionConfigured: Bool {
    guard let key = sttAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
          let model = sttModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
    else { return false }
    return true
}
```

`.env` is parsed once at launch, so **changing `STT_*` needs a relaunch**; changing which model
is *selected* does not. That asymmetry is correct — the experiment is the switching, and the
switching is live.

The launch log line gains `stt:` reporting `<set>`/`<unset>` and the STT host. Per the Phase 2
ruling in `EnvConfig.description`, **no user-supplied string is echoed** and no shape heuristic
is reintroduced — host via `URLComponents`, presence otherwise.

### 4.4 Model loading

`ModelLoadCoordinator` treats `.groq` exactly as it treats `.custom`: nothing to download, so
`loadSelectedModel` returns early and readiness is `isGroqTranscriptionConfigured ? .ready
: .idle`. `unload` is a no-op.

`startRecordingFlow`'s `guard isModelLoaded` has a `.custom` branch showing "Configure your
custom endpoint before recording." `.groq` needs its own, naming `.env` rather than the settings
UI.

### 4.5 The stale-selection case

Hiding the row when unconfigured leaves one gap worth specifying, because it strands the app:
select Groq, then remove `STT_API_KEY` and relaunch. The stored mode is `.groq`, the row is
hidden, and the user has no way to select anything else if the picker only lists valid rows.

**Resolution:** on launch, if the stored mode is `.groq` and `isGroqTranscriptionConfigured` is
false, fall back to `.default` and persist that. Log it at notice level. The user gets a working
app rather than a dead one, and the log says why. This must be a test.

### 4.6 Menu row

`Sources/FalaDan/Views/ModelPickerView.swift`, between Multilingual and Custom:

```
☁️  Groq                            Cloud
    whisper-large-v3-turbo
```

- Rendered only when `envConfig.isGroqTranscriptionConfigured`
- Subtitle is the configured `STT_MODEL`, so the user can see which one they are testing
- The **Cloud** badge occupies the slot Multilingual uses for its `874 MB` download size, and
  carries the same weight of meaning: this row costs you something the others do not

### 4.7 Privacy

Transcription mode is the **only** setting that sends audio off the machine. Cleanup sends
text; Custom and now Groq send the recording itself.

The README's "What leaves your machine" section already names Custom and must name Groq. The
existing sentence "with Parakeet or whisper.cpp, audio never leaves your Mac" stays accurate and
is the reason it was scoped that way in Phase 2.

## 5. Testing

Unit-testable, and where the risk actually is:

- `EnvConfig` parses `STT_*`; `isGroqTranscriptionConfigured` false for: unset key, unset model,
  whitespace-only either, key without model, model without key
- `sttProviderSettings` maps to a `CustomProviderSettings` whose `isConfigured` agrees
- `TranscriptionMode(rawValue: "groq")` round-trips; an unknown raw value still falls back
- **The §4.5 stale selection falls back to `.default` and persists** — the one case that
  otherwise strands the app
- `EnvConfig.description` echoes no `STT_*` value, tested the way Phase 2 tests `LLM_*`: every
  stray value through every field

Not unit-testable, so manual (§6):

- The row appears only when configured, and disappears when `.env` is emptied and the app relaunched
- Switching mid-session takes effect on the next dictation without a relaunch

## 6. Manual verification

1. No `STT_*` at all — row absent, Parakeet works exactly as now
2. Configure `STT_*`, relaunch — row present, subtitle shows the model id
3. Select Groq, dictate — text lands; compare accuracy against the same phrase on Parakeet
4. **The comparison this phase exists for:** dictate the same difficult passage on both, back to
   back, and decide whether the accuracy gain is worth the audio upload
5. Switch back to Default mid-session, dictate — no relaunch needed
6. Invalid `STT_API_KEY` — a clear failure. Unlike cleanup, there is **no raw text to fall back
   to**: transcription failing means no dictation at all, so this must surface to the user, not
   fail silently
7. Select Groq, remove `STT_API_KEY`, relaunch — falls back to Parakeet, app usable, log says why

## 7. Out of scope

- Retiring or changing the `Custom` row
- Any other transcription provider preset — the `Custom` row is the escape hatch
- Per-language or per-app model selection
- Falling back to Parakeet automatically when a Groq call fails. Tempting, and wrong for a
  comparison feature: silently substituting the other model is exactly what makes the two
  indistinguishable. Fail visibly

## 8. Task sketch

Small enough to be one plan, all `sonnet-alone` — nothing here touches the event tap, the paste
path, or `PasteboardService`.

1. `EnvConfig`: parse `STT_*`, add `isGroqTranscriptionConfigured`, extend `description` (test first)
2. `TranscriptionMode.groq` + `sttProviderSettings` bridge
3. `ModelLoadCoordinator` and `startRecordingFlow` handling, including the §4.5 fallback
4. `ModelPickerView` row, conditional rendering, Cloud badge
5. Routing `.groq` to `CustomProvider` with the env-derived settings
6. `.env.example` and README, including "What leaves your machine"
