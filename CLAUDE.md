# slack-rec

## Overview

macOS CLI that records a Slack call as three separate tracks: Slack's windows
(including screen-shared content), system audio output, and microphone input.
Built on ScreenCaptureKit, so no virtual audio driver is required.

## Tech Stack

- Swift 6 (language mode 5), SwiftPM
- ScreenCaptureKit — capture; AVFoundation — encoding
- swift-argument-parser — CLI
- swift-testing — tests
- ffmpeg (optional, runtime) — `--mux` only

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
executable is argument parsing and output formatting only.

| File | |
|---|---|
| `Recorder.swift` | Owns the `SCStream`, fans its three output types into three `TrackWriter`s. |
| `TrackWriter.swift` | One `AVAssetWriter` + input. Audio inputs are built from the first buffer's format description. |
| `TargetResolver.swift` | `CaptureTarget` → `SCContentFilter` plus pixel dimensions. |
| `ContentInventory.swift` | Read-only listing of windows and displays. |
| `Permissions.swift` | TCC preflight and status. |
| `Muxer.swift` | Builds and runs the optional ffmpeg merge. |
| `OutputPlan.swift`, `DurationSpec.swift` | Paths and `--for` parsing. |

Invariants worth preserving:

- All stream outputs use one serial queue, which is why `Recorder`'s writer
  table and session clock need no locking. Don't add a second queue.
- All three writers start their session at the *same* timestamp — the first
  buffer seen on any output. Per-writer session starts would silently destroy
  A/V sync.
- Non-`.complete` screen frames are discarded. Writing idle frames pads the
  video and drifts it against the audio.
- Slack is captured by application filter, never by a single window id: a
  huddle's screen-share is frequently a separate window.

## Permissions

Screen Recording and Microphone are granted by macOS to the *parent terminal
application*, not to this binary. After granting, the terminal must be
relaunched. `slack-rec doctor` reports the current state.

## Conventions

- No secrets and no env vars — this project has no `.env`.
- Never commit captures; `*.mov`, `*.mp4`, `*.m4a` are gitignored.
