# slack-rec

## Overview

macOS CLI that records a call as three separate tracks: one window or display,
system audio output, and microphone input. Built on ScreenCaptureKit, so no
virtual audio driver is required. Windows belonging to Slack, Teams, Zoom, Meet,
Discord and browsers are listed first; everything else follows.

Running it with no arguments opens a TUI (setup screen, interactive capture and
microphone pickers, live meters). `record` is the same thing driven by flags,
and is what a non-tty falls back to.

An optional pass turns the two audio tracks into a speaker-labelled transcript,
with macOS 26's on-device `SpeechAnalyzer`, with whisper.cpp, or — for people who
would rather bring a key than a model — with OpenAI's API.

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
| `TargetResolver.swift` | `CaptureTarget` → `SCContentFilter` plus pixel dimensions. |
| `CallApps.swift` | The bundle-id registry that orders windows and puts the `*` marks in `sources`. |
| `ContentInventory.swift` | Read-only listing of windows and displays, filtered to what apps actually draw. |
| `AudioLevel.swift`, `LevelMonitor.swift` | Peak/RMS off the raw buffers; lock-guarded hand-off to the UI. |
| `MeterScale.swift` | Pure dBFS → bar/zone/verdict math. The tested part of the meters. |
| `Permissions.swift` | TCC preflight and status. |
| `Muxer.swift` | Builds and runs the optional ffmpeg merge. |
| `LoudnessMatch.swift` | Measures both audio tracks and balances them for the merge. |
| `SpeakerBleed.swift` | Spots the call re-entering through the microphone, and stops the merge amplifying it. |
| `Shell.swift` | Child processes, via temp files rather than pipes. |
| `OutputPlan.swift` | The recording folder and the three track paths. |
| `Transcription/Transcript.swift` | `Utterance`, turn folding, Markdown and SRT rendering. The tested part. |
| `Transcription/TranscriptionService.swift` | Language detection, engine choice, per-track runs, merge. |
| `Transcription/AppleTranscriber.swift` | macOS 26 `SpeechAnalyzer`, `@available`-gated. |
| `Transcription/WhisperTranscriber.swift` | `whisper-cli`, model discovery, JSON parsing. |
| `Transcription/OpenAITranscriber.swift` | The hosted API, behind the user's own key. Multipart upload, `verbose_json` parsing. |
| `Transcription/AudioChunks.swift` | Re-encodes and splits a track to fit the API's 25 MB limit, keeping each part's offset. |
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
- A capture target is a window or a display, never an application. Application
  filters record the whole display with everything else masked out, which is a
  display recording wearing a disguise. The cost is that a huddle and its
  screen-share are separate windows: record the display to get both.
- Only windows in layer 0 and at least 120px on a side are offered. macOS shares
  wallpaper backstops, the menu bar, the Dock, every Control Center status item
  and the recording indicator, and none of them is a recording target.
- The meters read the buffers already on their way to disk. Never add a second
  audio tap to feed the UI.
- Nothing slow may run between `enterRawMode` and the first frame: the alternate
  screen is already blank by then, so the wait reads as a hung, black terminal.
  The first `AudioDevices.inputs()` cold-starts AVFoundation and has been measured
  at 2.5 s, which is why it happens before raw mode.
- Child processes must not inherit the terminal's stdin while raw mode is on —
  ffmpeg is run with `-nostdin` and `/dev/null` for exactly this reason.
- The TUI is keyboard-only. Alternate scroll is turned off on entry (`?1007l`)
  because terminals otherwise translate the wheel into arrow-key bytes that are
  identical to a real arrow key, and cursor keys are forced to normal mode
  (`?1l`) so arrows always arrive as CSI.
- Escape sequences the TUI does not use are swallowed whole, never reported as
  `.escape`. `.escape` quits the setup screen and stops a recording, and a mouse
  wheel emits sequences constantly.
- Raw mode owns SIGINT/SIGTERM/SIGHUP: `Terminal.readKey` reports them as
  `.interrupt` so every loop exits through the same path and the writers
  finalise. A loop that reads stdin directly would lose the recording — the
  files end up `ftyp`+`mdat` with no `moov`, which nothing can open.
- There is no output-device setting to add: ScreenCaptureKit taps app audio
  before any output device.
- The loudness match applies only to `call.mp4`. The three tracks are the masters
  and are never rewritten — the mix is the disposable, regenerable artefact.
- Balance by loudness, never by peak: speech peaks as high as continuous call
  audio and averages ~13 dB below it, so peak-matching leaves the mic buried.
- Speaker bleed is checked before the mic is boosted. On speakers the far end is
  already in the mic track, and raising it doubles an echo the mix cannot undo.
  Bleed is detected as the microphone running *louder* while the call speaks —
  turn-taking makes that figure negative, so the sign alone separates the cases.
- `sources` lists microphones even when Screen Recording is denied. Enumerating
  input devices needs no grant, so it must not be gated behind one.
- Transcription is a separate, optional pass over files that are already closed.
  It must never be able to fail a recording: `TranscriptRun` swallows its errors
  and points at `slack-rec transcribe` instead.
- Speakers come from which file a line was in, never from diarisation. Keeping
  the tracks separate is what makes attribution free — and is exactly why speaker
  bleed misattributes: the echoed far end is *in* the microphone file.
- Bleed is therefore checked by the transcription pass too, before the engines
  run, and the note goes into the Markdown above the lines it casts doubt on. Do
  not try to strip the echoed lines: an engine fuses a real reply and an echoed
  one into a single segment, so dropping them deletes the user's own words.
- whisper needs the silero VAD model, or its first segment spans the leading
  silence and starts at 0 — which interleaves the two tracks in the wrong order.
- Nothing leaves the machine unless it was asked for by name. `--engine openai`
  and `--summarize` are the only two that do, and both say so wherever they are
  offered. `auto` must stay local-only: falling back to an upload because a model
  was missing would ship a call off the machine by accident.
- `openai` uses `whisper-1` and that is not configurable. It is the only model the
  API returns timestamps for, and without timestamps the two tracks cannot be
  interleaved — `gpt-4o-transcribe` answers in prose, which is useless here.
- The OpenAI key is read from `OPENAI_API_KEY` or the key file, never stored, and
  never put in an error: only the response body reaches `engineFailed`.
- Language detection is skipped for remote engines. Running whisper locally to
  label an upload defeats the point of not having whisper installed, so the
  engine reports what it heard and `Transcript` takes the answer from there.

## Permissions

Screen Recording and Microphone are granted by macOS to the *parent terminal
application*, not to this binary. After granting, the terminal must be
relaunched. `slack-rec doctor` reports the current state.

## Conventions

- No secrets in the repo and no `.env`. The one key the tool reads is the user's
  own, from `OPENAI_API_KEY` or `~/Library/Application Support/slack-rec/openai-key`.
- Never commit captures; `*.mov`, `*.mp4`, `*.m4a` are gitignored.
