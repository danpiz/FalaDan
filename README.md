# FalaDan

A macOS menu bar app for system-wide dictation. Hold **Fn**, speak, release — the cleaned-up
transcription is pasted into whatever app is frontmost. Fast on-device transcription via
[Parakeet](https://github.com/FluidInference/FluidAudio) (English + 20 European languages) or
broader multilingual transcription via [whisper.cpp](https://github.com/ggml-org/whisper.cpp).

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange)

[Getting Started](#getting-started) · [Features](#features) · [Configuration](#configuration) · [Troubleshooting](#troubleshooting) · [Build](#build-commands)

## Getting Started

FalaDan has no published release — building from source is the only install path.

Requires macOS 14+ (Sonoma) and Swift 6+. CLI-only; no Xcode needed.

```bash
git clone https://github.com/danpiz/FalaDan.git
cd FalaDan
just dev
```

1. Grant microphone and accessibility permissions when prompted
2. Look for the FalaDan icon in your menu bar (top-right of your screen)
3. Hold **Fn**, speak, and release — the transcription is pasted into the frontmost app

Press **Escape** to cancel a recording. The shortcut is rebindable from the menu bar panel.

Contributors: run `./Scripts/setup-dev-signing.sh` once per machine. It creates a stable
self-signed identity so your Accessibility grant survives rebuilds instead of being voided by
ad-hoc signing on every `just dev` — see [Troubleshooting](#troubleshooting).

## Features

- **Auto-paste** — transcriptions go straight into whatever app you're using
- **Customizable hotkey** — change the hold-to-talk shortcut from the menu bar panel
- **Text replacements** — auto-correct words or phrases after transcription
- **Recording history** — browse and copy recent transcriptions
- **Usage stats** — track recordings, speaking time, word count, and average WPM
- **Multiple models** — switch between the default fast model (Parakeet: English + 20 European
  languages), multilingual auto-detect (whisper.cpp), and a custom OpenAI-compatible
  transcription endpoint
- **Optional LLM cleanup** — removes fillers, fixes homophones and punctuation, and applies
  spoken corrections like "scratch that", on every dictation
- **On-device transcription** — with Parakeet or whisper.cpp, audio never leaves your Mac

### What leaves your machine

Nothing, by default. Two things change that, and both are opt-in:

- **LLM cleanup**, if you configure it in `.env`, sends the transcript *text* — never the
  audio — to the provider you named.
- **Custom transcription mode**, if you select it in the model picker, uploads the **audio
  itself** to the endpoint you configured. The other two transcription models are local.

With no `.env` and the default model, FalaDan makes no network calls at all.

## Configuration

FalaDan reads settings from a `.env` file at
`~/Library/Application Support/FalaDan/.env`. It's parsed once at launch — there is no settings
UI for it, and it is never committed. Copy `.env.example` to get started:

```bash
mkdir -p "$HOME/Library/Application Support/FalaDan"
cp .env.example "$HOME/Library/Application Support/FalaDan/.env"
```

A `.env` in the current working directory is also read, as a second choice. That is only useful
when you launch the binary directly from a checkout — `just dev` installs to `/Applications` and
launches with `open`, so the working directory is `/` and a repo-root `.env` is *not* picked up.
Use the path above.

Changing `.env` takes effect on the next launch. To confirm what was loaded — the key is
redacted:

```bash
log show --predicate 'subsystem == "com.faladan.dev"' --last 5m | grep "Loaded config"
```

Everything in it is optional. With no `.env` at all, FalaDan runs fully offline and pastes the
raw transcript.

| Key | Default | Notes |
|---|---|---|
| `LLM_API_KEY` | *(unset)* | Cleanup is skipped entirely unless both this and `LLM_MODEL` are set |
| `LLM_MODEL` | *(unset)* | Model id for your provider; left blank on purpose — fill in a current one |
| `LLM_BASE_URL` | `https://api.groq.com/openai/v1` | Any OpenAI-compatible chat-completions endpoint: Groq, Google Gemini (via its OpenAI-compatibility layer), OpenAI, OpenRouter, Ollama, LM Studio. Anthropic's API is a different shape and is not supported |
| `LLM_CLEANUP` | *(on)* | Set to `off` to skip cleanup and always paste the raw transcript |
| `MIN_HOLD_MS` | `150` | Holds shorter than this are treated as an accidental tap and discarded; `0` disables the guard |
| `MIN_TRANSCRIBE_MS` | `300` | Recordings shorter than this are discarded — Whisper hallucinates filler on very short clips |

See `.env.example` for the full annotated file, including provider-specific examples.

## Troubleshooting

**Can't find the menu bar icon?**

macOS hides menu bar icons that don't fit near the clock. If you have many menu bar apps,
FalaDan's icon may be pushed out of view.

- **Hold ⌘ and drag** the FalaDan waveform icon closer to the clock to keep it visible
- Open **System Settings → Control Center → Menu Bar Only** and hide icons you don't need
- In FalaDan's settings, click **Open Menu Bar Settings** to jump there directly

FalaDan will show a hint about this the first few times it launches. You can also reopen the
app from Spotlight or the Dock to bring the popover back.

To re-test the hint (resets after 3 shows or manual dismiss):

```bash
defaults delete com.faladan.dev MenuBarVisibilityHintShownCount
defaults delete com.faladan.dev MenuBarVisibilityHintDismissed
just dev
```

**Hotkey does nothing?**

Almost always Accessibility, and almost always because the grant no longer matches the binary.
macOS remembers a grant by the app's *designated requirement*; under ad-hoc signing that pins a
cdhash which changes on every build, so each `just dev` voids the grant while System Settings
keeps showing the app ticked.

Run `./Scripts/setup-dev-signing.sh` once per machine to create a stable self-signed identity
that fixes this permanently. Confirm a build picked it up with:

```bash
codesign -dv --verbose=2 /Applications/FalaDan.app 2>&1 | grep Authority
# want: Authority=FalaDan Dev Signing    (NOT "Signature=adhoc")
```

If a grant is already stale, toggling it off and on does not help — the row itself is bound to
the dead signature. Run `just reset-tcc` and grant again.

## Build commands

```bash
./Scripts/verify.sh   # THE gate: build + test + clean-tree check
just dev               # Kill existing, build, package, and launch
just build             # Debug build only
just release           # Release build + .app bundle
just clean             # Remove build artifacts
```

Bare `swift test` does not work on a Command Line Tools install — always use
`./Scripts/verify.sh`.

## Release

Signing, notarization, and publishing require [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI):

```bash
brew install asc
```

See `just --list` for the full set of release recipes (`sign-and-notarize`, `github-release`,
`publish`, etc.). These use `.envrc` (see `.envrc.example`) for signing identity and release
configuration — a separate file from the `.env` above, which holds runtime app config instead.

## License

[MIT](LICENSE)

Forked from [MiniWhisper](https://github.com/andyhtran/MiniWhisper) (MIT), retained as the
`upstream` remote.
