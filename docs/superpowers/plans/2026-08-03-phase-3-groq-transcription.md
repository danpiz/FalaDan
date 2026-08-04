# Phase 3 — Groq Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fourth transcription model row, **Groq**, configured in `.env` and switchable from
the menu, so on-device Parakeet and cloud Groq can be compared on real dictation.

**Architecture:** No new networking. `CustomProvider` already posts multipart audio to any
OpenAI-compatible `/v1/audio/transcriptions`; Groq mode hands it a `CustomProviderSettings` built
from `EnvConfig` instead of one loaded from the settings UI.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-08-03-phase-3-groq-transcription.md` — §4.5 (the stale
selection) is the one non-obvious requirement.

**Branch base:** `phase-4/recording-indicator`. Baseline: **239 tests in 44 suites**.

## Global Constraints

- **`./Scripts/verify.sh` is the only verification command.** Bare `swift test` does not work on
  this machine. `--dirty` skips the clean-tree check mid-task.
- **Do not adjust a test file to match a number in this plan.** Counts are relative.
- **This phase sends audio off the machine.** That is the point, and it is also the one thing the
  README must be accurate about. The Groq row is the *only* new path by which a recording leaves
  the device.
- **No new networking code.** If a task has you writing a `URLRequest`, stop — `CustomProvider`
  already does it.
- **`EnvConfig.description` must not echo any user-supplied string.** Phase 2 settled this after
  three failed attempts at filtering key-shaped values; `STT_*` follows the same rule — presence
  and host only. Do not add a shape heuristic.
- Do not touch `CustomShortcutMonitor`, `FnStateMachine`, `ModifierTapMonitor`, `EventTapRunLoop`,
  `KeyDownObserver`, `CarbonHotKeyCenter`, `PasteboardService`, or anything added by Phase 4
  (`RecordingIndicator*`).
- `.env.example` must never contain a real key.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FalaDan/Services/Config/EnvConfig.swift` | **Modify.** Parse `STT_*`; `isGroqTranscriptionConfigured`; extend `description` |
| `Sources/FalaDan/Models/TranscriptionMode.swift` | **Modify.** Add `.groq` |
| `Sources/FalaDan/Services/Config/EnvConfig+Transcription.swift` | **Create.** `sttProviderSettings` bridge |
| `Sources/FalaDan/Features/ModelLoading/ModelLoadCoordinator.swift` | **Modify.** Treat `.groq` like `.custom` |
| `Sources/FalaDan/AppState.swift` | **Modify.** Resolve settings per mode; §4.5 fallback |
| `Sources/FalaDan/Features/Transcription/AppState+Transcription.swift` | **Modify.** Route `.groq` to `CustomProvider` |
| `Sources/FalaDan/Views/ModelPickerView.swift` | **Modify.** The conditional row |
| `.env.example`, `README.md` | **Modify.** New keys, and what leaves the machine |

---

### Task 1: `EnvConfig` learns `STT_*`

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/Services/Config/EnvConfig.swift`
- Test: `Tests/FalaDanTests/EnvConfigTests.swift`

**Do not touch:** anything else. In particular do not add a `TranscriptionMode` case yet.

**Interfaces produced:** `sttBaseURL: String`, `sttAPIKey: String?`, `sttModel: String?`,
`isGroqTranscriptionConfigured: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FalaDanTests/EnvConfigTests.swift`, inside the existing parsing suite:

```swift
    @Test func parsesTheSttBlock() {
        let c = EnvConfig.parse(
            """
            STT_BASE_URL=https://api.groq.com/openai/v1
            STT_API_KEY=gsk_example
            STT_MODEL=whisper-large-v3-turbo
            """)
        #expect(c.sttBaseURL == "https://api.groq.com/openai/v1")
        #expect(c.sttAPIKey == "gsk_example")
        #expect(c.sttModel == "whisper-large-v3-turbo")
        #expect(c.isGroqTranscriptionConfigured)
    }

    /// The row is hidden unless both are present, so every partial case must
    /// report unconfigured rather than half-working.
    @Test func groqTranscriptionNeedsBothAKeyAndAModel() {
        var keyOnly = EnvConfig.defaults
        keyOnly.sttAPIKey = "gsk_example"
        #expect(!keyOnly.isGroqTranscriptionConfigured)

        var modelOnly = EnvConfig.defaults
        modelOnly.sttModel = "whisper-large-v3"
        #expect(!modelOnly.isGroqTranscriptionConfigured)

        var blank = EnvConfig.defaults
        blank.sttAPIKey = "   "
        blank.sttModel = "whisper-large-v3"
        #expect(!blank.isGroqTranscriptionConfigured)

        var blankModel = EnvConfig.defaults
        blankModel.sttAPIKey = "gsk_example"
        blankModel.sttModel = "  "
        #expect(!blankModel.isGroqTranscriptionConfigured)

        #expect(!EnvConfig.defaults.isGroqTranscriptionConfigured)
    }

    @Test func sttBaseURLFallsBackToTheGroqDefault() {
        let c = EnvConfig.parse("STT_API_KEY=gsk_example")
        #expect(c.sttBaseURL == "https://api.groq.com/openai/v1")
    }
```

And into `EnvConfigRedactionTests`:

```swift
    /// `STT_*` follows the Phase 2 ruling: presence and host, never the value.
    @Test func noSttFieldEchoesItsValue() {
        for stray in [
            "gsk_" + String(repeating: "a1B2c3D4", count: 6),
            "3f2a91c4-7b8e-4d2f-9a10-6c5e8b4d2f71",
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        ] {
            var key = EnvConfig.defaults
            key.sttAPIKey = stray
            #expect(!key.description.contains(stray), "leaked via sttAPIKey")

            var model = EnvConfig.defaults
            model.sttModel = stray
            #expect(!model.description.contains(stray), "leaked via sttModel")

            var base = EnvConfig.defaults
            base.sttBaseURL = stray
            #expect(!base.description.contains(stray), "leaked via sttBaseURL")
        }
    }

    @Test func descriptionReportsSttPresence() {
        var configured = EnvConfig.defaults
        configured.sttAPIKey = "gsk_example"
        configured.sttModel = "whisper-large-v3-turbo"
        #expect(configured.description.contains("sttKey: <set>"))
        #expect(configured.description.contains("sttModel: <set>"))

        #expect(EnvConfig.defaults.description.contains("sttKey: <unset>"))
    }
```

- [ ] **Step 2: Run and watch them fail**

Run: `./Scripts/verify.sh --dirty`. Expected: compile failure, no `sttBaseURL`.

- [ ] **Step 3: Implement**

Add the three stored properties next to the `llm*` ones, with this doc comment on `sttModel`:

```swift
    /// OpenAI-compatible transcription endpoint. Sends **audio**, unlike the
    /// cleanup endpoint, which only ever sees text.
    var sttBaseURL: String
    var sttAPIKey: String?
    /// No default, for the same reason as `llmModel`: hosted model ids get
    /// renamed and retired, and a stale one here is worse than an empty one.
    var sttModel: String?
```

Add to `defaults`: `sttBaseURL: "https://api.groq.com/openai/v1"`, `sttAPIKey: nil`,
`sttModel: nil`. Add to the parser's switch, matching the `LLM_*` cases exactly:

```swift
            case "STT_BASE_URL": if !value.isEmpty { config.sttBaseURL = value }
            case "STT_API_KEY": config.sttAPIKey = value
            case "STT_MODEL": config.sttModel = value
```

Add the gate, mirroring `isCleanupConfigured`:

```swift
    /// Whether the Groq transcription row should exist at all.
    ///
    /// Both a key and a model are required. A half-configured endpoint would
    /// offer the user a row that fails every dictation — and unlike cleanup,
    /// a failed transcription has no raw text to fall back to.
    var isGroqTranscriptionConfigured: Bool {
        guard let key = sttAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty,
            let model = sttModel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !model.isEmpty
        else { return false }
        return true
    }
```

Extend `description`, adding to the existing interpolation — **presence and host only**:

```
sttHost: \(Self.host(of: sttBaseURL)), sttKey: \(Self.presence(of: sttAPIKey)), \
sttModel: \(Self.presence(of: sttModel)), \
```

- [ ] **Step 4: Run and watch them pass**

Run: `./Scripts/verify.sh --dirty`. Adds 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/FalaDan/Services/Config/EnvConfig.swift Tests/FalaDanTests/EnvConfigTests.swift
git commit -m "Parse the STT_* config block"
```

**Done means:** verify passes; `grep -n "sttModel" Sources/FalaDan/Services/Config/EnvConfig.swift`
shows it interpolated only via `presence(of:)`, never directly.

---

### Task 2: `.groq` mode and the settings bridge

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/Models/TranscriptionMode.swift`
- Create: `Sources/FalaDan/Services/Config/EnvConfig+Transcription.swift`
- Test: `Tests/FalaDanTests/TranscriptionModeTests.swift` (create if absent)

**Do not touch:** `AppState.swift`, `ModelPickerView.swift`, `ModelLoadCoordinator.swift`.

**Interfaces produced:** `TranscriptionMode.groq` (raw value `"groq"`),
`EnvConfig.sttProviderSettings: CustomProviderSettings`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing

@testable import FalaDan

struct TranscriptionModeGroqTests {
    @Test func groqRoundTripsThroughItsRawValue() {
        #expect(TranscriptionMode(rawValue: "groq") == .groq)
        #expect(TranscriptionMode.groq.rawValue == "groq")
        #expect(TranscriptionMode.groq.modelDisplayName == "Groq")
    }

    /// A build without this case must read a stored "groq" as the default
    /// rather than failing — and an unknown value must already do so today.
    @Test func anUnknownStoredModeFallsBackToDefault() {
        #expect(TranscriptionMode(rawValue: "not-a-mode") == nil)
    }

    /// Groq transcription reuses `CustomProvider`, so the bridge has to produce
    /// settings that provider considers usable.
    @Test func sttSettingsAreConfiguredWhenTheEnvIs() {
        var c = EnvConfig.defaults
        c.sttAPIKey = "gsk_example"
        c.sttModel = "whisper-large-v3-turbo"

        let settings = c.sttProviderSettings
        #expect(settings.endpointURL == "https://api.groq.com/openai/v1")
        #expect(settings.apiKey == "gsk_example")
        #expect(settings.modelName == "whisper-large-v3-turbo")
        #expect(settings.isConfigured)
    }

    @Test func sttSettingsAreUnconfiguredWhenTheEnvIs() {
        #expect(!EnvConfig.defaults.sttProviderSettings.isConfigured)
    }
}
```

- [ ] **Step 2: Run and watch them fail.**

- [ ] **Step 3: Implement**

In `TranscriptionMode.swift`, add `case groq` and extend `modelDisplayName` with
`case .groq: return "Groq"`.

Create `Sources/FalaDan/Services/Config/EnvConfig+Transcription.swift`:

```swift
import Foundation

extension EnvConfig {
    /// Groq transcription expressed as the settings `CustomProvider` already
    /// takes.
    ///
    /// The whole of Groq mode is this bridge: `CustomProvider` posts multipart
    /// audio to any OpenAI-compatible `/v1/audio/transcriptions`, and Groq is
    /// one. Nothing about the request differs — only where the configuration
    /// came from, `.env` rather than the settings UI.
    ///
    /// Built per call and never persisted: `.env` is the source of truth, and a
    /// copy on disk would be a second one.
    var sttProviderSettings: CustomProviderSettings {
        CustomProviderSettings(
            endpointURL: sttBaseURL,
            apiKey: sttAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            modelName: sttModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}
```

- [ ] **Step 4: Run and watch them pass.** Adds 4 tests.

- [ ] **Step 5: Fix every switch the new case breaks**

Adding an enum case will fail compilation wherever `TranscriptionMode` is switched
exhaustively. Run `./Scripts/verify.sh --dirty` and fix each site by treating `.groq` **exactly
as `.custom` is treated** — it is a remote OpenAI-compatible endpoint, same as custom. Do not
invent new behaviour; if a site's correct handling is not obvious from how `.custom` is handled
there, report BLOCKED rather than guessing.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add the groq transcription mode and its settings bridge"
```

**Done means:** verify passes; `TranscriptionMode` has four cases; no site treats `.groq`
differently from `.custom` except where a later task changes it.

---

### Task 3: Loading, routing, and the stale-selection fallback

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/AppState.swift`
- Modify: `Sources/FalaDan/Features/ModelLoading/ModelLoadCoordinator.swift`
- Modify: `Sources/FalaDan/Features/Transcription/AppState+Transcription.swift`
- Test: `Tests/FalaDanTests/TranscriptionModeTests.swift`

**Do not touch:** `ModelPickerView.swift`.

- [ ] **Step 1: Write the failing test for the fallback**

This is the requirement that keeps the app usable, so it is tested first:

```swift
    /// Select Groq, then remove `STT_API_KEY` and relaunch: the stored mode is
    /// `.groq`, but the row is hidden, so the user would have no way to pick
    /// anything else. Falling back keeps the app usable and the log says why.
    @Test func aStoredGroqModeFallsBackWhenUnconfigured() {
        #expect(
            TranscriptionMode.resolvingStoredMode(.groq, isGroqConfigured: false) == .default)
        #expect(
            TranscriptionMode.resolvingStoredMode(.groq, isGroqConfigured: true) == .groq)
        // Other modes are unaffected either way.
        #expect(
            TranscriptionMode.resolvingStoredMode(.multilingual, isGroqConfigured: false)
                == .multilingual)
        #expect(
            TranscriptionMode.resolvingStoredMode(.custom, isGroqConfigured: false) == .custom)
    }
```

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Implement the resolver**

In `TranscriptionMode.swift`:

```swift
    /// The mode to actually use, given what was stored and what `.env` provides.
    ///
    /// Groq's row is hidden when unconfigured, which strands anyone who selected
    /// it and then removed the key: the stored mode is `.groq`, the row is gone,
    /// and there is nothing to click. Falling back to the local default is the
    /// only outcome that leaves a working app.
    static func resolvingStoredMode(
        _ stored: TranscriptionMode, isGroqConfigured: Bool
    ) -> TranscriptionMode {
        guard stored == .groq, !isGroqConfigured else { return stored }
        return .default
    }
```

- [ ] **Step 4: Wire it in `AppState`**

Change the `transcriptionMode` initialiser to run the stored value through the resolver, and
persist plus log when it falls back. `envConfig` is declared above it, so it is available:

```swift
    var transcriptionMode: TranscriptionMode = {
        let stored = TranscriptionModeStorage.load()
        return stored
    }()
```

becomes a resolution performed in `init()` instead — add to `AppState.init()`, after
`envConfig` is available:

```swift
        let storedMode = TranscriptionModeStorage.load()
        let resolvedMode = TranscriptionMode.resolvingStoredMode(
            storedMode, isGroqConfigured: envConfig.isGroqTranscriptionConfigured)
        if resolvedMode != storedMode {
            log.notice(
                "Stored transcription mode \(storedMode.rawValue, privacy: .public) is not "
                    + "configured; falling back to \(resolvedMode.rawValue, privacy: .public)")
            TranscriptionModeStorage.save(resolvedMode)
        }
        transcriptionMode = resolvedMode
```

If `AppState.swift` has no `log` yet, add
`private let log = Logger(subsystem: Logger.subsystem, category: "AppState")` at file scope and
`import os.log`, matching `AppDelegate.swift`.

- [ ] **Step 5: Resolve settings per mode**

Add to `AppState`:

```swift
    /// Settings for whichever remote transcription endpoint a mode names.
    ///
    /// Groq and Custom are the same request to `CustomProvider`; they differ
    /// only in where the configuration comes from. The local models need none.
    func remoteTranscriptionSettings(for mode: TranscriptionMode) -> CustomProviderSettings {
        switch mode {
        case .groq: return envConfig.sttProviderSettings
        case .custom: return customProviderSettings
        case .default, .multilingual: return .empty
        }
    }
```

- [ ] **Step 6: `ModelLoadCoordinator`**

Rename the `customSettings:` parameter to `remoteSettings:` on `loadSelectedModel`,
`refreshCustomReadiness`, `initialState(for:)` and the initialiser, and make `.groq` behave as
`.custom` does: skip loading, and report `.ready` when the settings are configured.

```swift
        guard mode != .custom, mode != .groq else {
            state = Self.initialState(for: mode, remoteSettings: remoteSettings)
            return
        }
```

```swift
        case .custom, .groq:
            return remoteSettings.isConfigured ? .ready : .idle
```

Update every call site to pass `remoteTranscriptionSettings(for:)`.

- [ ] **Step 7: Route transcription**

There are **three** switch sites in `AppState+Transcription.swift` (near lines 185, 319, 438).
At each, change:

```swift
            case .custom:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL, settings: customProviderSettings)
```

to:

```swift
            case .custom, .groq:
                result = try await customProvider.transcribe(
                    audioURL: uploadURL,
                    settings: remoteTranscriptionSettings(for: transcriptionMode))
```

- [ ] **Step 8: The not-configured message**

`startRecordingFlow` shows "Configure your custom endpoint before recording." for `.custom`.
Add a `.groq` case naming `.env` instead: `"Set STT_API_KEY and STT_MODEL in .env before
recording."` This lives in `AppState+RecordingFlow.swift` — that file is otherwise not to be
touched; change only this message branch.

- [ ] **Step 9: Verify and commit**

Run: `./Scripts/verify.sh --dirty`. Adds 1 test.

```bash
git add -A
git commit -m "Load, route, and recover the groq transcription mode"
```

**Done means:** verify passes; `grep -rn "customProviderSettings" Sources/FalaDan/Features/`
shows no direct use in the transcribe switches.

---

### Task 4: The menu row

**Executor:** `sonnet-alone`

**Files:**
- Modify: `Sources/FalaDan/Views/ModelPickerView.swift`

- [ ] **Step 1: Add the conditional row**

Between the Multilingual row and the Custom row:

```swift
            // Hidden rather than disabled when unconfigured: the app has no
            // settings UI for this, so a visible-but-dead row would point at
            // nothing the user can act on from here.
            if appState.envConfig.isGroqTranscriptionConfigured {
                ModelRow(
                    icon: "cloud.fill",
                    title: "Groq",
                    subtitle: appState.envConfig.sttModel ?? "",
                    badge: "Cloud",
                    isSelected: appState.transcriptionMode == .groq
                ) {
                    appState.switchTranscriptionMode(to: .groq)
                }
            }
```

The `Cloud` badge takes the slot Multilingual uses for its download size, and carries the same
weight: this row costs you something the others do not — your audio leaves the machine.

- [ ] **Step 2: Verify and commit**

Run: `./Scripts/verify.sh --dirty`, then:

```bash
git add Sources/FalaDan/Views/ModelPickerView.swift
git commit -m "Offer Groq in the transcription model picker"
```

**Done means:** verify passes; the row is inside an `if
appState.envConfig.isGroqTranscriptionConfigured`.

---

### Task 5: Docs

**Executor:** `sonnet-alone`

**Files:**
- Modify: `.env.example`
- Modify: `README.md`

- [ ] **Step 1: `.env.example`**

After the LLM cleanup block, before the Timing block:

```
# --- Transcription (speech to text) --------------------------------------
# Optional. Adds a "Groq" row to the menu bar model picker, alongside the
# two local models. Unlike cleanup, which only ever sends text, this
# uploads your AUDIO to the endpoint below. The row is hidden unless both
# a key and a model are set.

# STT_BASE_URL=https://api.groq.com/openai/v1
# STT_API_KEY=
# STT_MODEL=whisper-large-v3-turbo
```

- [ ] **Step 2: README**

In "What leaves your machine", add a third bullet to the opt-in list:

```markdown
- **Groq transcription**, if you configure `STT_*` in `.env` and select it in the model picker,
  uploads the **audio** to Groq. The two local models never do.
```

Update the "Multiple models" feature bullet to mention it, and add the three `STT_*` keys to the
Configuration table with `STT_BASE_URL` defaulting to `https://api.groq.com/openai/v1` and the
other two unset.

- [ ] **Step 3: Verify and commit**

Run: `grep -nE "sk-|gsk_|AIza" .env.example` — expect no output. Then `./Scripts/verify.sh`.

```bash
git add .env.example README.md
git commit -m "Document Groq transcription"
```

**Done means:** full verify passes with a clean tree; no key in `.env.example`.

---

### Task 6: Manual verification — Dan

Not delegable. From the spec §6, and note step 4 is the point of the whole phase:

1. No `STT_*` — row absent, Parakeet unchanged
2. Configure `STT_*`, relaunch — row present, subtitle shows the model id
3. Select Groq, dictate — text lands
4. **Dictate the same difficult passage on both, back to back**, and decide whether the accuracy
   is worth the audio upload
5. Switch back to Default mid-session — no relaunch needed
6. Invalid `STT_API_KEY` — fails visibly. Unlike cleanup there is no raw text to fall back to
7. Select Groq, remove the key, relaunch — falls back to Parakeet, app usable, log says why
