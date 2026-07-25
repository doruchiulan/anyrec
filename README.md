# slack-rec

Records a call on macOS as three separate tracks: the app's windows (including
whatever is being screen-shared), the audio the call plays back, and your
microphone.

Slack, Teams, Zoom, Meet, Webex, Discord, WhatsApp, Telegram, FaceTime and calls
running in a browser are all recognised — or point it at any window or display
yourself.

Everything runs through ScreenCaptureKit. There is no virtual audio driver to
install, no BlackHole, no Aggregate Device to wire up in Audio MIDI Setup.

```
slack-rec
```

```
  slack-rec

› Capture     Auto — first call app running
  Microphone  MacBook Pro Microphone (system default)
  Call audio  On
  Stop        when I press q
  Merge       On — call.mp4

    Start recording

  Folder  ~/Desktop/CallRec Recordings

  ↑↓ move   ←→ change   ⏎ open   r record   q quit
```

Recording shows live meters, so you know your microphone is live before the call
is over rather than after:

```
  ● REC  00:04:12

  Slack (2 windows)
  4112×2658 · 30 fps · 7554 frames

  call audio  ████████████████·|······················   -14.2  max  -8.1
  microphone  ██████████·············|················   -22.6  max -11.4
```

```
~/Desktop/CallRec Recordings/slack-call-2026-07-25-131411
  screen.mov          81043 frames, 1.4 GB     video only, no audio
  system-audio.m4a    2251 buffers, 43 MB, peak  -8.1 dB
  microphone.m4a      2251 buffers, 41 MB, peak -11.4 dB
  call.mp4            everything together — play this one
```

Separate tracks mean you can drop your own microphone, duck one side against the
other, or transcribe the two voices independently. `call.mp4` is the one you
double-click; ffmpeg produces it after the recording, unless you pass `--no-mux`.

`screen.mov` deliberately carries no audio track. On its own it plays silent —
that is the design, not a fault.

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
ok   Slack, Zoom
```

## Usage

`slack-rec` with no arguments opens the interactive screen above. Everything it
does is also a flag, for scripts and for terminals that are not a tty — where it
falls back to `record` automatically.

```
slack-rec record                      # first call app found, both audio sides, until Ctrl-C
slack-rec record --for 1h30m          # stop on a deadline instead
slack-rec record --bundle-id us.zoom.xos
slack-rec record --no-microphone      # capture only what the call plays back
slack-rec record --display 0          # a whole display rather than an app
slack-rec record --window 24619       # one specific window
slack-rec record --mic BuiltInMicrophoneDevice
slack-rec record --no-mux             # keep the tracks separate, skip call.mp4
```

Without `--bundle-id`, `--window` or `--display`, it picks the call app that is
running — a dedicated client ahead of a browser. `slack-rec apps` shows what it
can see and marks the ones it recognises.

ffmpeg is what merges the tracks. Without it you still get all three, but no
`call.mp4` — `slack-rec doctor` and the recording banner both say so.

```
brew install ffmpeg
```

Ctrl-C is handled: the writers finalise their files rather than leaving you a
truncated `.mov`.

| Command | |
|---|---|
| `tui` | The interactive screen. The default, so plain `slack-rec` opens it. |
| `record` | Capture from flags alone, no interaction. |
| `apps` | Applications with capturable windows, call apps first and marked `*`. |
| `windows` | Call apps' capturable windows and their ids. `--all` for every app. |
| `displays` | Capturable displays and their indices. |
| `mics` | Input devices and the ids `--mic` accepts. |
| `doctor` | Permissions, ffmpeg, and which call apps are running. |

| Flag | Default | |
|---|---|---|
| `--output` | `~/Desktop/CallRec Recordings` | Directory the timestamped folder is created in. |
| `--bundle-id` | auto | The app to capture, e.g. `com.tinyspeck.slackmacgap`. |
| `--for` | — | `90s`, `45m`, `1h30m`. Without it, runs until Ctrl-C. |
| `--fps` | `30` | 1–60. |
| `--codec` | `h264` | `hevc` gives smaller files and costs more CPU. |
| `--[no-]mux` | on | Merge into `call.mp4` with ffmpeg afterwards. |
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

An app is captured by application filter rather than by window id. A huddle's
screen-share often opens as its own window, and a filter pinned to one window
would miss it.

The meters read the same `CMSampleBuffer`s on their way to disk, so what they
show is what is being written — not a second, separate tap.

There is no output-device setting, because there is nothing to route:
ScreenCaptureKit takes the app's audio before it reaches any output device.
Whether your headphones are connected makes no difference to the recording.

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
