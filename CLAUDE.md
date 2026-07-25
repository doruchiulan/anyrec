# slack-rec

## Overview

macOS CLI that records a call as three separate tracks: the app's windows
(including screen-shared content), system audio output, and microphone input.
Built on ScreenCaptureKit, so no virtual audio driver is required. Slack, Teams,
Zoom, Meet, Discord and browsers are recognised automatically; any window or
display can be targeted explicitly.

Running it with no arguments opens a TUI (setup screen, interactive capture and
microphone pickers, live meters). `record` is the same thing driven by flags,
and is what a non-tty falls back to.

An optional pass turns the two audio tracks into a speaker-labelled transcript,
either with macOS 26's on-device `SpeechAnalyzer` or with whisper.cpp.

## Tech Stack

- Swift 6 (language mode 5), SwiftPM
- ScreenCaptureKit — capture; AVFoundation — encoding
- swift-argument-parser — CLI
- swift-testing — tests
- ffmpeg (runtime) — merges the tracks into `call.mp4`; on by default, degrades
  to a warning plus the separate tracks when absent
- Speech (macOS 26) — `SpeechAnalyzer`/`SpeechTranscriber`, optional
- whisper.cpp (runtime, optional) — `whisper-cli` plus a ggml model in
  `~/Library/Application Support/slack-rec/models`

Requires macOS 15+. `SCStreamConfiguration.captureMicrophone` and
`SCStreamOutputType.microphone` are Sequoia APIs with no fallback.

## Commands

```
swift build                 # debug
swift test                  # swift-testing suites
swift build -c release
scripts/release.sh <ver>    # universal + ad-hoc signed + tarball + sha256
./.build/debug/slack-rec doctor
```

## Architecture

`SlackRecKit` holds everything testable and framework-facing; the `slack-rec`
executable is argument parsing, the TUI, and output formatting only.

| File | |
|---|---|
| `Recorder.swift` | Owns the `SCStream`, fans its three output types into three `TrackWriter`s. |
| `TrackWriter.swift` | One `AVAssetWriter` + input. Audio inputs are built from the first buffer's format description. |
| `TargetResolver.swift` | `CaptureTarget` → `SCContentFilter` plus pixel dimensions; auto-detects the running call app. |
| `CallApps.swift` | The bundle-id registry behind auto-detection and the `*` marks in `apps`. |
| `ContentInventory.swift` | Read-only listing of applications, windows and displays. |
| `AudioLevel.swift`, `LevelMonitor.swift` | Peak/RMS off the raw buffers; lock-guarded hand-off to the UI. |
| `MeterScale.swift` | Pure dBFS → bar/zone/verdict math. The tested part of the meters. |
| `Permissions.swift` | TCC preflight and status. |
| `Muxer.swift` | Builds and runs the optional ffmpeg merge. |
| `Shell.swift` | Child processes, via temp files rather than pipes. |
| `OutputPlan.swift`, `DurationSpec.swift` | Paths and `--for` parsing. |
| `Transcription/Transcript.swift` | `Utterance`, turn folding, Markdown and SRT rendering. The tested part. |
| `Transcription/TranscriptionService.swift` | Language detection, engine choice, per-track runs, merge. |
| `Transcription/AppleTranscriber.swift` | macOS 26 `SpeechAnalyzer`, `@available`-gated. |
| `Transcription/WhisperTranscriber.swift` | `whisper-cli`, model discovery, JSON parsing. |
| `Transcription/Summarizer.swift` | The `claude -p` pass over the finished text. |
| `slack-rec/TUI/` | `Terminal` (raw mode, keys), `Picker`, `SetupScreen`, `RecordingScreen`, `TUISession`. |

Invariants worth preserving:

- All stream outputs use one serial queue, which is why `Recorder`'s writer
  table and session clock need no locking. Don't add a second queue.
- All three writers start their session at the *same* timestamp — the first
  buffer seen on any output. Per-writer session starts would silently destroy
  A/V sync.
- Non-`.complete` screen frames are discarded. Writing idle frames pads the
  video and drifts it against the audio.
- An app is captured by application filter, never by a single window id: a
  huddle's screen-share is frequently a separate window.
- The meters read the buffers already on their way to disk. Never add a second
  audio tap to feed the UI.
- Child processes must not inherit the terminal's stdin while raw mode is on —
  ffmpeg is run with `-nostdin` and `/dev/null` for exactly this reason.
- Raw mode owns SIGINT/SIGTERM/SIGHUP: `Terminal.readKey` reports them as
  `.interrupt` so every loop exits through the same path and the writers
  finalise. A loop that reads stdin directly would lose the recording — the
  files end up `ftyp`+`mdat` with no `moov`, which nothing can open.
- There is no output-device setting to add: ScreenCaptureKit taps app audio
  before any output device.
- Transcription is a separate, optional pass over files that are already closed.
  It must never be able to fail a recording: `TranscriptRun` swallows its errors
  and points at `slack-rec transcribe` instead.
- Speakers come from which file a line was in, never from diarisation. Keeping
  the tracks separate is what makes attribution free.
- whisper needs the silero VAD model, or its first segment spans the leading
  silence and starts at 0 — which interleaves the two tracks in the wrong order.
- Everything transcribes locally. `--summarize` is the single exception and says
  so wherever it is offered; Claude has no audio input, so it only ever sees
  text.

## Permissions

Screen Recording and Microphone are granted by macOS to the *parent terminal
application*, not to this binary. After granting, the terminal must be
relaunched. `slack-rec doctor` reports the current state.

## Conventions

- No secrets and no env vars — this project has no `.env`.
- Never commit captures; `*.mov`, `*.mp4`, `*.m4a` are gitignored.
