# slack-rec

Records a Slack call on macOS as three separate tracks: the Slack windows
(including whatever is being screen-shared), the audio the call plays back, and
your microphone.

Everything runs through ScreenCaptureKit. There is no virtual audio driver to
install, no BlackHole, no Aggregate Device to wire up in Audio MIDI Setup.

```
slack-rec record --for 45m --mux
```

```
/Users/you/Recordings/slack-call-2026-07-25-131411
  screen.mov          81043 frames, 1.4 GB
  system-audio.m4a    2251 buffers, 43 MB
  microphone.m4a      2251 buffers, 41 MB
  call.mp4            (with --mux)
```

Separate tracks mean you can drop your own microphone, duck one side against the
other, or transcribe the two voices independently. `--mux` folds them into a
single `call.mp4` when you just want something playable.

## Install

```
brew install doruchiulan/tap/slack-rec
```

Or from source, which needs the Xcode Command Line Tools:

```
git clone git@github.com:doruchiulan/slack-recorder.git
cd slack-recorder && swift build -c release
cp .build/release/slack-rec /usr/local/bin/
```

Requires macOS 15 or later. Microphone capture arrived in ScreenCaptureKit with
Sequoia; there is no fallback on older systems.

## Permissions

macOS grants Screen Recording and Microphone access to the *terminal
application* you run `slack-rec` from, not to the binary. Enable both under
System Settings → Privacy & Security, then quit and reopen your terminal — the
grant only applies to newly launched processes.

```
slack-rec doctor
```

```
ok   Screen Recording
ok   Microphone
ok   ffmpeg at /opt/homebrew/bin/ffmpeg
ok   Slack is running
```

## Usage

```
slack-rec record                      # Slack's windows, both audio sides, until Ctrl-C
slack-rec record --for 1h30m          # stop on a deadline instead
slack-rec record --no-microphone      # capture only what the call plays back
slack-rec record --display 0          # a whole display rather than Slack
slack-rec record --window 24619       # one specific window
slack-rec record --mic BuiltInMicrophoneDevice
```

Ctrl-C is handled: the writers finalise their files rather than leaving you a
truncated `.mov`.

| Command | |
|---|---|
| `record` | Capture. The default subcommand, so `slack-rec --for 30m` works. |
| `windows` | Slack's capturable windows and their ids. `--all` for every app. |
| `displays` | Capturable displays and their indices. |
| `mics` | Input devices and the ids `--mic` accepts. |
| `doctor` | Permissions, ffmpeg, and whether Slack is running. |

| Flag | Default | |
|---|---|---|
| `--output` | `~/Recordings` | Directory the timestamped folder is created in. |
| `--for` | — | `90s`, `45m`, `1h30m`. Without it, runs until Ctrl-C. |
| `--fps` | `30` | 1–60. |
| `--codec` | `h264` | `hevc` gives smaller files and costs more CPU. |
| `--mux` | off | Merge into `call.mp4` with ffmpeg afterwards. |
| `--hide-cursor` | off | Leave the pointer out of the video. |
| `--[no-]system-audio` | on | The far side of the call. |
| `--[no-]microphone` | on | Your side. |

## Consent

Everyone on the call has to know it is being recorded. Under GDPR that is a
legal requirement, not an etiquette one: say it out loud or post it in the
channel before you start.

## How it works

One `SCStream` produces all three outputs — `.screen`, `.audio` and
`.microphone` — on a single serial queue, and each is written by its own
`AVAssetWriter`. All three writers share one session start timestamp, so the
relative offsets between video, call audio and your voice survive into the
files and the tracks line up without further work.

Slack is captured by application filter rather than by window id. A huddle's
screen-share often opens as its own window, and a filter pinned to one window
would miss it.

Two things worth knowing:

- Only frames ScreenCaptureKit marks complete are written. A static screen
  produces no frames, so the video track can end earlier than the audio. Since
  everything is timestamped, this shows up as a held last frame rather than
  drift.
- Buffers are dropped rather than queued if the encoder falls behind. The
  summary reports the count; `--fps 24` or `--codec hevc` usually clears it.

## Development

```
swift build
swift test
scripts/release.sh 0.1.0    # universal binary, signed, tarball + sha256
```

`scripts/release.sh` ad-hoc signs by default. Swap the `-` identity for a
Developer ID if you ever want to notarize and ship outside Homebrew.

## License

MIT
