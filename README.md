# anyrec

Records a call on macOS as three separate tracks: a window or a display, the
audio the call plays back, and your microphone.

Windows belonging to Slack, Teams, Zoom, Meet, Webex, Discord, WhatsApp,
Telegram, FaceTime and browsers are offered first; anything else with a window
is one keystroke further down.

Everything runs through ScreenCaptureKit. There is no virtual audio driver to
install, no BlackHole, no Aggregate Device to wire up in Audio MIDI Setup.

```
anyrec
```

```
  anyrec

› Capture     Slack — Huddle with Costi
  Microphone  MacBook Pro Microphone (system default)
  Call audio  On
  Stop        when I press q
  Merge       On — call.mp4
  Transcript  On — pick the engine by language

    Start recording

  Folder  ~/Desktop/AnyRec Recordings

  ↑↓ move   ←→ change   ⏎ open   r record   q quit
```

Recording shows live meters, so you know your microphone is live before the call
is over rather than after:

```
  ● REC  00:04:12

  Huddle with Costi
  3024×1964 · 30 fps · 7554 frames

  call audio  ████████████████·|······················   -14.2  max  -8.1
  microphone  ██████████·············|················   -22.6  max -11.4
```

```
~/Desktop/AnyRec Recordings/rec-2026-07-25-131411
  screen.mov          81043 frames, 1.4 GB     video only, no audio
  system-audio.m4a    2251 buffers, 43 MB, peak  -8.1 dB
  microphone.m4a      2251 buffers, 41 MB, peak -11.4 dB
  call.mp4            everything together — play this one
  transcript-apple-<id>.md  who said what, in order
  transcript-apple-<id>.srt subtitles for call.mp4
```

Separate tracks mean you can drop your own microphone, duck one side against the
other, or — see below — get a transcript that already knows who was talking.
`call.mp4` is the one you double-click; ffmpeg produces it after the recording,
unless you pass `--no-mux`.

Before mixing, both audio tracks are measured and balanced to the same loudness.
Your voice pauses and varies while call audio runs dense and continuous, so the
two peak alike but average around 13 dB apart — a raw sum leaves you inaudible
under whoever else is talking. The gain is static, so nothing is compressed, and
it is applied only to `call.mp4`: the three recorded tracks are never rewritten.

Wear headphones. On speakers, your microphone records the call as well, so
`call.mp4` carries the far end twice — once cleanly and once through the room a
few milliseconds later, which sounds hollow and phasey. anyrec detects this
and leaves the microphone gain alone rather than amplifying the echo, but it
cannot undo it. The transcript is unaffected: an echo is always quieter than
what caused it, so an echoed line still scores for the caller. Only headphones
fix the audio.

`screen.mov` deliberately carries no audio track. On its own it plays silent —
that is the design, not a fault.

## Install

```
brew install doruchiulan/tap/anyrec
```

Or from source, which needs the Xcode Command Line Tools:

```
git clone git@github.com:doruchiulan/anyrec.git
cd anyrec && swift build -c release
cp .build/release/anyrec /usr/local/bin/
```

Requires macOS 15.2 or later. Microphone capture arrived in ScreenCaptureKit with
Sequoia, and 15.2 is where a content filter began reporting what is in it, which
is how the menu bar app reads back the window you point at. Neither has a
fallback on older systems.

### The menu bar app

The same recorder, without a terminal open:

```
brew install --cask doruchiulan/tap/anyrec-app
```

Or build it from this repository:

```
scripts/bundle-app.sh release
cp -R dist/AnyRec.app /Applications
open /Applications/AnyRec.app
```

It is a regular Mac app — a Dock icon and a library window of every recording — with
a small helper in the menu bar for starting one from anywhere. The helper shows
Record Window and recent recordings; microphone, transcription and stop-time
preferences live in Settings. Record Window opens macOS's own picker: point at
the window or display you want and recording starts on selection. The meters and the elapsed time take the
panel's place while it runs, and the time also shows beside the menu bar icon, so
a recording is visible with the panel shut.

Closing the recorded window automatically stops and saves the recording. Switching
apps, minimizing the window, muting or silence do not trigger this. If a call ends
but its window stays open, stop the recording manually.

After stopping, Done clears the saved panel. Merging and transcription continue in
the background, so another recording can start immediately. Each recording shows
its progress in the library and its detail page; In Progress lists pending work.
Local processing runs one recording at a time. Quitting waits for pending work.

The reminder above a detected Slack or Teams call has a Record button that starts
that window directly. Record Window in the menu bar still opens the window picker.

The first launch opens a two-step welcome window: grant Screen Recording,
Microphone, Accessibility and Notifications, then download an on-device
transcription engine if you want one. All four permissions must be granted,
including any required restart, before setup can finish or recording can start. Finishing
setup opens the recordings library. Other preferences use their defaults and can
be changed in Settings. Nothing is fetched before you choose it, and download
buttons show the size. The CLI is a separate install, not a prerequisite.

## Permissions

macOS grants Screen Recording and Microphone access to the *application* that
asks — the terminal you run `anyrec` from, or `AnyRec.app` itself. Enable both
under System Settings → Privacy & Security, then quit and reopen it; the grant
only applies to newly launched processes.

`AnyRec.app` is signed with a Developer ID, so its grants survive a rebuild. A
machine without that identity in its keychain falls back to an ad-hoc signature,
which changes every build — and macOS then asks again after each one.

```
anyrec doctor
```

```
ok   Screen Recording
ok   Microphone
ok   ffmpeg at /opt/homebrew/bin/ffmpeg
ok   apple speech, on-device, and only these languages
    Cantonese, Chinese, English, French, German, Italian, Japanese, Korean, Portuguese, Spanish
ok   whisper built in
ok   whisper model ggml-large-v3-turbo-q5_0.bin
ok   OpenAI key found — --engine openai uploads the audio
ok   Slack, Zoom
```

## Usage

`anyrec` with no arguments opens the interactive screen above. Everything it
does is also a flag, for scripts and for terminals that are not a tty — where it
falls back to `record` automatically.

```
anyrec record --window 24619       # one window, both audio sides, until Ctrl-C
anyrec record --display 0          # a whole display instead
anyrec record --no-microphone      # capture only what the call plays back
anyrec record --mic BuiltInMicrophoneDevice
anyrec record --no-mux             # keep the tracks separate, skip call.mp4
```

`record` needs `--window` or `--display`; there is no default, because recording
the wrong thing is worse than recording nothing. `anyrec sources` lists what
you can point it at, each beside the flag that selects it.

```
Windows                                             --window
* Slack
      24619   1512×982    Huddle with Costi
      24601   1728×1117   QLAN Smart Homes - Slack
* Google Chrome
      814     1920×1065   Meet — Casa Costi

Displays                                            --display
  0       3456×2234

Microphones                                         --mic
* MacBook Pro Microphone
      BuiltInMicrophoneDevice
```

Windows sit under the app that owns them, call apps first. Only windows apps
actually draw are listed — not the menu bar, the Dock, Control Center's status
items or the recording indicator, all of which macOS shares just as willingly.

A screen-share arrives as its own window, so a huddle and the screen being shared
are two entries: record the share, or record the display and get both.

Call apps only, by default; `--all` widens it to every window.

A window recording ends when its window does. Resize or move it as much as you
like — the frame follows — but close it and capture stops there, with everything
up to that point written, merged and ready to transcribe.

ffmpeg is what merges the tracks. Without it you still get all three, but no
`call.mp4` — `anyrec doctor` and the recording banner both say so. The app and
the setup screen fetch a static build when there is none (no Homebrew needed),
or install your own:

```
brew install ffmpeg
```

Ctrl-C is handled: the writers finalise their files rather than leaving you a
truncated `.mov`.

| Command | |
|---|---|
| `tui` | The interactive screen. The default, so plain `anyrec` opens it. |
| `record` | Capture from flags alone, no interaction. |
| `transcribe` | Transcribe a recording. Defaults to the newest one. |
| `speakers` | Put names to the voices in a transcript. They are remembered for the next call. |
| `sources` | Everything capturable — windows, displays, microphones — with the ids the flags take. |
| `doctor` | Permissions, ffmpeg, transcription engines, call apps with a window open. |

| Flag | Default | |
|---|---|---|
| `--output` | `~/Desktop/AnyRec Recordings` | Directory the timestamped folder is created in. |
| `--window` | — | The window id to capture. Required unless `--display` is given. |
| `--display` | — | The display to capture instead. |
| `--fps` | `30` | 1–60. |
| `--codec` | `h264` | `hevc` gives smaller files and costs more CPU. |
| `--[no-]mux` | on | Merge into `call.mp4` with ffmpeg afterwards. |
| `--hide-cursor` | off | Leave the pointer out of the video. |
| `--[no-]system-audio` | on | The far side of the call. |
| `--[no-]microphone` | on | Your side. |
| `--mic` | system default | The input device id, from `anyrec sources`. |
| `--transcribe` | off | `auto`, `parakeet`, `apple`, `whisper` or `openai`, run once the tracks are closed. |

## Transcripts

In the app, open a recording and choose **Generate Transcript…** in the Transcript
tab. Existing transcripts have **Regenerate Transcript…**, with an engine picker
for that run. Both actions are also in the recording's context menu and the
Recording menu. Processing continues in the library's **In Progress** view while
you record another call.

Regenerating keeps the current transcript visible until the replacement succeeds.
Each version has its own speaker names and summary; a replacement starts without
the previous summary. Automatic summaries run again when enabled in Settings.
The engine chosen for one recording does not change your default engine.

The engine transcribes both tracks mixed together, so the turns come back in the
order they were actually spoken. Who said each one is then settled by the tracks
themselves — whichever was louder while a line was said is whose line it is. No
guesswork, and no engine that has to be told there are two people:

```
anyrec transcribe                  # the newest recording
anyrec transcribe ~/Desktop/AnyRec\ Recordings/rec-2026-07-25-131411
anyrec transcribe --engine whisper --language ro
anyrec transcribe --engine openai   # OpenAI's API, with your own key
```

The interactive screen can run it for you the moment a recording stops — the
`Transcript` row. `record` always leaves that to a separate `transcribe` call.

### Who is who on the call

The far end is one stream, so "Call" is everyone else at once until the speaker
model is fetched — 22 MB, from the `Speakers` row, from Settings in the menu bar
app, or with `anyrec speakers --download`. With it, every transcript tells the
other voices apart on your machine, whichever engine wrote the words, and labels
them Speaker A, Speaker B and so on. Name a letter once:

```
anyrec speakers                    # asks about each lettered voice in the newest recording
anyrec speakers --name A=John --name B=Sarah
```

The transcript is rewritten with the names in, and each named voice is kept as a
voiceprint in `~/Library/Application Support/anyrec/voices/`. The next call that
voice is on comes back already named. There is no limit on how many people the
library holds, and nothing in it ever leaves the machine. The interactive screen
and the menu bar app ask the same question right after a transcript.

```markdown
# rec-2026-07-25-131411

00:19 · English · transcribed by apple

**[00:00] Me:** Hi everyone, thanks for joining. I want to walk through the KNX
wiring plan for the Costi house before we get to the budget.

**[00:11] Call:** Sounds good. My main question is whether we keep the existing
Zigbee sensors or move everything to KNX.
```

You get `transcript-<engine>-<id>.md`, a matching `.srt` you can drop onto
`call.mp4`, and `.json` data. `.transcription.json` selects the active version;
previous files remain in the recording folder. Older unversioned recordings still
open normally. [The processing pipeline](docs/pipeline.md) shows the full flow.

Four engines:

| | | |
|---|---|---|
| `parakeet` | NVIDIA Parakeet TDT 0.6B v3, on CoreML | on your machine · ~150× realtime on Apple silicon, one 480 MB download, 25 languages including Romanian |
| `apple` | macOS 26 `SpeechAnalyzer` | on your machine · ~12× realtime, no setup, 10 languages — no Romanian |
| `whisper` | whisper.cpp, built in | on your machine · ~5× realtime, one 574 MB download, 99 languages including Romanian |
| `openai` | OpenAI's API | uploads the audio · your own key, no install, 99 languages |

`auto` is Parakeet once its model is here, Apple when it has a model for the
language, whisper after that. Parakeet tells the language itself; for the other
two, `auto` detects it first, which needs whisper installed — without it, `auto`
assumes English. It never picks `openai` — nothing leaves your machine unless you
name the engine that does.

Parakeet needs nothing installed. Choose it — in the app's panel or Settings, or
on the setup screen's Transcript row with ⏎ — and the model is fetched, with
ffmpeg beside it when there is none.

Apple is the engine that can be ready and still have nothing to say: pick it for
a call in a language it has no model for and the transcript fails rather than
degrades. Put the Transcript row on `apple` and press ⏎ to see which languages
this Mac has, or run `anyrec doctor`.

whisper is built in; it needs a model. Run `anyrec` with no arguments, put the
Transcript row on `whisper`, and press ⏎: it says how large the download is and
fetches it once you say go. Nothing is downloaded until you do.

To do it by hand instead:

```
cd ~/Library/Application\ Support/anyrec/models
curl -LO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
curl -LO https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
```

The second one is voice-activity detection, and it matters more than its size
suggests: without it whisper stretches its first segment across the silence
before anyone speaks, which drags every timestamp after it out of place.

### Bring your own OpenAI key

If you would rather not keep a model on disk, `--engine openai` uses OpenAI's
API with your key and nothing of ours. Run `anyrec` with no arguments, put
the Transcript row on `openai`, and press ⏎ to paste one. It is checked with
OpenAI before it is saved, so a bad paste is caught now rather than after the
call it was meant to transcribe, and it is never drawn back to the screen — this
is a tool for recording screens, so it assumes its own is being recorded too.

By hand, either way round:

```
export OPENAI_API_KEY=sk-…
anyrec transcribe --engine openai
```

Or, to keep it out of every process your shell launches:

```
printf %s sk-… > ~/Library/Application\ Support/anyrec/openai-key
```

This one uploads the audio. Everyone on a call has agreed to being
recorded; whether they have agreed to the recording being sent to OpenAI is a
separate question, and worth asking before you use it on someone else's voice.
`anyrec doctor` tells you whether a key is set.

It runs `gpt-4o-transcribe-diarize`, which labels speakers and timestamps their
segments. AnyRec keeps those assignments, including the label for your own voice.
When the local speaker model is installed, AnyRec extracts voiceprints from clean
passages to recognise people you've named before. This does not rerun diarization
or replace OpenAI's speaking turns. Without the local model, speakers can still
be named manually, but their voices cannot be remembered across recordings.

`--no-diarize` falls back to `whisper-1` and the plain `Me`/`Call` split. Either
way the audio is trimmed to where the talking is, and anything still over the
API's 25 MB limit is split and stitched back onto one clock.

### Summaries

`--summarize` hands the finished transcript to `claude -p`, which cleans up
mishearings and pulls out decisions and action items in the language of the call:

```
anyrec transcribe --summarize
```

Like `--engine openai`, this leaves your machine — the transcript text is sent
to Anthropic. Claude has no audio input, so it never sees the recording itself.
Everything else is local, and nothing is sent anywhere unless you ask for it by
name.

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
scripts/release.sh 0.4.0    # universal app + CLI archives and SHA256SUMS
scripts/bundle-app.sh       # dist/AnyRec.app
```

`AnyRecKit` is the whole application — what a recording is, what it does, and
what this machine can do. `anyrec` and `AnyRecBar` are renderers over it and
know nothing about each other, so a third interface is a third renderer rather
than a third copy of the recording flow.

`scripts/release.sh` uses the configured Developer ID when available, with an
ad-hoc fallback for local builds. The GitHub release workflow requires signing
and notarization. See [GitHub release setup](docs/github-releases.md) for secrets,
version tags, and publishing instructions.

## License

MIT
