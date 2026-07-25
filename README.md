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
  Transcript  On — pick the engine by language

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
  transcript-apple.md who said what, in order
  transcript-apple.srt subtitles for call.mp4
```

Separate tracks mean you can drop your own microphone, duck one side against the
other, or — see below — get a transcript that already knows who was talking.
`call.mp4` is the one you double-click; ffmpeg produces it after the recording,
unless you pass `--no-mux`.

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
ok   apple speech, 10 languages, on-device
ok   whisper at /opt/homebrew/bin/whisper-cli
ok   whisper model ggml-large-v3-turbo-q5_0.bin
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
| `transcribe` | Transcribe a recording. Defaults to the newest one. |
| `mics` | Input devices and the ids `--mic` accepts. |
| `doctor` | Permissions, ffmpeg, transcription engines, running call apps. |

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
| `--transcribe` | off | `auto`, `apple` or `whisper`, run after the recording. |

## Transcripts

Because your microphone and the call are already separate files, the transcript
knows who spoke without any diarisation guesswork:

```
slack-rec transcribe                  # the newest recording
slack-rec transcribe ~/Desktop/CallRec\ Recordings/slack-call-2026-07-25-131411
slack-rec transcribe --engine whisper --language ro
slack-rec record --for 45m --transcribe auto
```

```markdown
# slack-call-2026-07-25-131411

00:19 · English · transcribed by apple

**[00:00] Me:** Hi everyone, thanks for joining. I want to walk through the KNX
wiring plan for the Costi house before we get to the budget.

**[00:11] Call:** Sounds good. My main question is whether we keep the existing
Zigbee sensors or move everything to KNX.
```

You get `transcript-<engine>.md` and a matching `.srt` you can drop onto
`call.mp4`.

Two engines, both running entirely on your machine:

| | | |
|---|---|---|
| `apple` | macOS 26 `SpeechAnalyzer` | ~12× realtime, no setup, 10 languages — no Romanian |
| `whisper` | whisper.cpp | ~5× realtime, needs a model, 99 languages including Romanian |

`auto` detects the spoken language first and picks accordingly: Apple when it has
a model for that language, whisper otherwise. Detection needs whisper installed;
without it, `auto` assumes English.

For whisper, install the binary and put a model where slack-rec looks for it:

```
brew install whisper-cpp
cd ~/Library/Application\ Support/slack-rec/models
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
curl -LO https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
```

The second one is voice-activity detection, and it matters more than its size
suggests: each track is silent while the other person talks, and without VAD
whisper stretches its first segment across that silence — which puts the turns
in the wrong order. It also skips the silence instead of transcribing it.

### Summaries

`--summarize` hands the finished transcript to `claude -p`, which cleans up
mishearings and pulls out decisions and action items in the language of the call:

```
slack-rec transcribe --summarize
```

This is the one part of the tool that leaves your machine — the transcript text
is sent to Anthropic. Claude has no audio input, so it never sees the recording
itself. Everything else, transcription included, is local.

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
