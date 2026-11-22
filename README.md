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
  Merge       On — one file named after the call
  Transcript  On — pick the engine by language

    Start recording

  Folder  ~/Library/Application Support/anyrec/Recordings

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
~/Library/Application Support/anyrec/Recordings/2026-07-25 13.14 Huddle with Costi – Slack
  Huddle with Costi – Slack – 2026-07-25 13.14.mp4   everything together — play this one
  Transcript.md       who said what, in order
  Summary.md          the summary, when there is one
  Tracks/system-audio.m4a    2251 buffers, 43 MB, peak  -8.1 dB
  Tracks/microphone.m4a      2251 buffers, 41 MB, peak -11.4 dB
  Data/               recording.json, who was in the call, the transcript's layers
  Cache/              what is worked out from the audio and can be deleted: the mix, waveform, still
```

A recording's folder is named after the call — when it started, the window's title, the
app — so it reads in Finder. Only the merged file, `Transcript.md` and `Summary.md` sit at
the top; the masters are in `Tracks/`, everything the app keeps about the recording in
`Data/` (`Data/Transcripts/` holds every version of the transcript, kept as JSON), and
anything that can be made again in `Cache/`. Subtitles are not kept as a file; they are
made from the current transcript when something needs them. Folders made by earlier
versions (flat, named `rec-YYYY-MM-DD-HHMMSS`, on the Desktop) are moved here by the app
at launch, and `anyrec transcribe`, `speakers` and `compress` bring the one folder they
work on up to date first. Nothing is deleted. Settings › Recording › Storage shows the
folder and can move it.

Separate tracks mean you can drop your own microphone, duck one side against the
other, or — see below — get a transcript that already knows who was talking.
The merged file is the one you double-click. ffmpeg makes it after the recording
(unless you pass `--no-mux`) and names it after the call: the window's title
without its unread counters or trailing app name, the app, and when it started.

A window is recorded into a 1920×1080 frame, its picture fitted inside at its own
proportions, so a call that starts in a small window and grows when someone shares their
screen keeps the share at full size. A display is recorded at its own resolution.

The picture is recorded as `screen.mov`, and exists only until the merge is checked.
The merge copies the video stream as it is (nothing is re-encoded) beside the mixed
audio; once the merged file is confirmed to hold every frame of `screen.mov` and the
whole mix, `screen.mov` is deleted, so the video is stored once, not twice. If the
merge fails, or ffmpeg is missing, `screen.mov` stays and plays as before.

The app then compresses the merged video once, in the background, about fifteen times
smaller at the same resolution: x265, every frame kept and checked before the file is
replaced, run only while nothing is being recorded and the Mac is plugged in (Settings ›
Recording). `anyrec compress` does the same for one recording. The audio tracks are never
touched.
Recordings made before this keep their `call.mp4` beside `screen.mov`, untouched.

Before mixing, both audio tracks are measured and balanced to the same loudness.
Your voice pauses and varies while call audio runs dense and continuous, so the
two peak alike but average around 13 dB apart — a raw sum leaves you inaudible
under whoever else is talking. The gain is static, so nothing is compressed, and
it is applied only to the merged file: the two audio tracks are never rewritten.

Headphones are still best. On speakers, your microphone records the call as well, so
a raw sum carries the far end twice: once cleanly and once through the room, which
sounds hollow and doubled. When the microphone bleeds like that, it is held down
whenever the call is talking, so every word survives once.

There is no echo cancellation at capture. macOS voice processing was tried and removed:
while it runs, macOS turns the microphone down for every app, the call included, so the
people on the call hear you much quieter.

The two audio tracks are also lined up before anything combines them. ScreenCaptureKit
does not stamp call audio and microphone the same way: on one speakerphone call the far
end's echo sat half a second *ahead* of the same words in the call track, which no room
can do. anyrec measures that offset from the echo and moves the call track to match
the microphone, the video and the call window's names. It does this in the merged file,
in the transcript's mix, and wherever the transcript compares the two tracks. Without an
echo (headphones) there is nothing to measure from, so nothing is moved.
`anyrec echo <folder>` prints the offset and how much echo each method leaves.

`screen.mov`, while it exists, deliberately carries no audio track. On its own it
plays silent — that is the design, not a fault.

The picture is optional. An audio-only recording (`--no-video`, or Record Audio
Only in the app) still asks you to pick the call's window, because the window is
where the call's sound, its title, the names of who is speaking and its mute
button come from — but no `screen.mov` is written. Everything else is the same:
both audio tracks, the merged file (here an `.m4a` of the mixed audio alone), the transcript,
speakers and the library.

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

Open the release DMG and drag AnyRec into Applications. You can also install the app with Homebrew.

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
Record Window, Record Audio Only and recent recordings; microphone, transcription
and stop-time preferences live in Settings. Both open macOS's own picker: point at
the window or display you want and recording starts on selection. Record Audio
Only keeps the sound, the window's title, the call's names and its mute, and no
picture. File › New Audio-Only Recording (⌥⌘N) and the Dock menu offer it too. The meters and the elapsed time take the
panel's place while it runs, and the time also shows beside the menu bar icon, so
a recording is visible with the panel shut.

Closing the recorded window automatically stops and saves the recording. Switching
apps, minimizing the window, muting or silence do not trigger this. If a call ends
but its window stays open, stop the recording manually.

After stopping, Done clears the saved panel. Merging and transcription continue in
the background, so another recording can start immediately. Each recording shows
its progress in the library and its detail page; In Progress lists pending work.
Local processing runs one recording at a time. Quitting waits for pending work.

The reminder above a detected Slack or Teams call has Record and Audio Only buttons
that start that window directly; the notification shown for other call apps has
Record and Record Audio Only, which open the window picker. Record Window in the
menu bar still opens the window picker.

Settings › General › Record Slack and Teams calls automatically (off by default)
skips the reminder: when a Slack or Teams call starts and its call window is found,
AnyRec starts recording that window, as video or audio only as chosen there, posts a
notification with Stop Recording, and stops 10 seconds after the call app lets go of
the microphone. Calls in other apps, and calls whose window can't be found, still
get the offer. A recording you started yourself is never stopped by it. AnyRec does
not tell the other people in the call that they are being recorded.

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
anyrec record --no-mux             # keep the tracks separate, and keep screen.mov
anyrec record --window 24619 --no-video   # audio only: no screen.mov
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

ffmpeg is what merges the tracks. Without it you still get all three, `screen.mov`
included, but no merged file — `anyrec doctor` and the recording banner both say so. The app and
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
| `compress` | Re-encode a recording's merged video about fifteen times smaller. |
| `sources` | Everything capturable — windows, displays, microphones — with the ids the flags take. |
| `doctor` | Permissions, ffmpeg, transcription engines, call apps with a window open. |
| `mcp` | Read-only MCP access to saved meetings, transcripts, participants and summaries. The app connects Claude Code, Claude Desktop, ChatGPT and Codex from Settings › AI Apps. [Setup and tools](docs/mcp.md). |

| Flag | Default | |
|---|---|---|
| `--output` | `~/Library/Application Support/anyrec/Recordings` | Directory each recording's folder is created in. |
| `--window` | — | The window id to capture. Required unless `--display` is given. |
| `--display` | — | The display to capture instead. |
| `--fps` | `30` | 1–60. |
| `--codec` | `hevc` | `h264` for players without HEVC. |
| `--[no-]mux` | on | Merge with ffmpeg afterwards into one file named after the call, which replaces `screen.mov` once it is verified. |
| `--[no-]video` | on | Record the picture. `--no-video` still needs `--window` or `--display`, for the sound, title, names and mute, and writes no `screen.mov`. |
| `--hide-cursor` | off | Leave the pointer out of the video. |
| `--[no-]system-audio` | on | The far side of the call. |
| `--[no-]microphone` | on | Your side. |
| `--mic` | system default | The input device id, from `anyrec sources`. |
| `--transcribe` | off | `auto`, `parakeet`, `apple`, `whisper` or `openai`, run once the tracks are closed. |
| `--summarize` | off | With `--transcribe`, write a summary. Sends the transcript text to `--provider`. |
| `--review` | off | With `--transcribe`, review the wording. Sends the transcript text to `--provider`. |
| `--provider` | `claude` | Who reviews and summarises: `claude`, `codex`, `openai` or `gemini`. |

## Transcripts

In the app, open a recording and choose **Generate Transcript…** in the Transcript
tab. Existing transcripts have **Regenerate Transcript…**, with an engine picker
for that run. Both actions are also in the recording's context menu and the
Recording menu. Processing continues in the library's **In Progress** view while
you record another call.

Regenerating keeps the current transcript visible until the replacement succeeds.
Each version has its own speaker names and summary; a replacement starts without
the previous summary. Automatic summaries run again when enabled in Settings.
Naming a voice or accepting a speaker correction changes only who said what: the
summary stays, with the new names filled in, and says when it is out of date.
The engine chosen for one recording does not change your default engine.

The engine transcribes both tracks mixed together, so the turns come back in the
order they were actually spoken. Who said each one is then settled by the tracks
themselves — whichever was louder while a line was said is whose line it is. No
guesswork, and no engine that has to be told there are two people:

```
anyrec transcribe                  # the newest recording
anyrec transcribe ~/Library/Application\ Support/anyrec/Recordings/2026-07-25\ 13.14\ Huddle\ with\ Costi\ –\ Slack
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

Each lettered voice is shown with a few short clips of it and numbered names worth
choosing: who the call window showed while it spoke, a saved voice that matches or
sounds close, a name it introduced itself by, and who else was in the call. Answer
with a number or type a name. The transcript is rewritten with the names in, and
each named voice is kept as a voiceprint in
`~/Library/Application Support/anyrec/voices/`. The next call that voice is on comes
back already named. There is no limit on how many people the library holds, and
nothing in it ever leaves the machine. The interactive screen asks the same question
right after a transcript. In the app, a recording's Speakers panel lists every
speaker with how it was named, clips that play only that speaker, the same names to
choose from, and the lines the review thinks are someone else's; clicking a speaker's
name on any transcript line changes that line or the whole voice.

```markdown
# 2026-07-25 13.14 Huddle with Costi – Slack

00:19 · English · transcribed by apple

**[00:00] Me:** Hi everyone, thanks for joining. I want to walk through the KNX
wiring plan for the Costi house before we get to the budget.

**[00:11] Call:** Sounds good. My main question is whether we keep the existing
Zigbee sensors or move everything to KNX.
```

You get `Transcript.md` (and `Summary.md`) at the top of the recording's folder,
rendered from the current version. The JSON — one source per engine run, the speakers,
the wording review, the summary — is in `Data/Transcripts/`, and `Data/transcription.json`
selects the active version; previous versions stay. Older unversioned recordings still
open normally. [The processing pipeline](docs/pipeline.md) shows the full flow.

Four engines:

| | | |
|---|---|---|
| `parakeet` | NVIDIA Parakeet TDT 0.6B v3, on CoreML | on your machine · ~150× realtime on Apple silicon, one 480 MB download, 25 languages including Romanian |
| `apple` | macOS 26 `SpeechAnalyzer` | on your machine · ~12× realtime, no setup, 10 languages — no Romanian |
| `whisper` | whisper.cpp, built in | on your machine · ~5× realtime, one 574 MB download, 99 languages including Romanian |
| `openai` | OpenAI's API | uploads the audio · your own key, no install, 99 languages |

`auto` is Parakeet once its model is here, whisper once its model is, and Apple
when it has a model for the language after that. Parakeet tells the language itself; for the other
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

`--summarize` hands the finished transcript to the provider chosen with
`--provider` (Claude Code by default), which pulls out an overview, decisions and
action items with the second each was said, in the language of the call. It is the
same structured summary the app writes, as JSON with a Markdown copy. Speakers
nobody has named are written as "Speaker B" and get their name when one is given.
`--review` corrects the wording first, and `--compare-engines` lets the review
compare the other on-device engines:

```
anyrec transcribe --summarize
anyrec transcribe --review --compare-engines --summarize --provider codex
```

Like `--engine openai`, this leaves your machine — the transcript text is sent
to the provider's company (Anthropic for Claude Code). Claude has no audio input, so it never sees the recording itself.
Everything else is local, and nothing is sent anywhere unless you ask for it by
name.

## Share and sync meetings

**Share** sends a finished summary to a Slack channel or person. Choose a recipient, then click **Send**. AnyRec includes the saved recording link when available. **File → Share Files…** opens the macOS picker for the playable recording and its notes.

**Sync** applies to the selected meeting. Choose a team folder that is already synced to Finder, such as a shared OneDrive or iCloud Drive folder. AnyRec remembers the destination for next time. While AnyRec is running, it updates the playable recording, transcript, and summary there. The folder’s existing permissions determine who can read them. The separate microphone and call tracks and the voiceprints stay local.

On another Mac, open **Shared with me → Connect team folder…** and pick that same folder in Finder. **Add to Library** keeps a read-only entry that follows the owner's changes. **Make a Copy** creates an independent recording with editable transcript text and speaker names and its own summary.

Use the arrow beside **Sync** to move a meeting or remove it from the shared folder. Linked entries disappear after the cloud provider syncs the change. Independent copies survive.

## Consent

Everyone on the call has to know it is being recorded. Under GDPR that is a
legal requirement, not an etiquette one: say it out loud or post it in the
channel before you start.

## How it works

One `SCStream` produces all three outputs — `.screen`, `.audio` and
`.microphone` — on a single serial queue, and each is written by its own
`AVAssetWriter`. All three writers share one session start timestamp, so the
offsets between the stamps ScreenCaptureKit gives each output survive into the files.
Those stamps do not always agree between call audio and microphone (60 ms on one call,
half a second on another), so the offset is measured afterwards from the echo and
corrected where the tracks are combined. The masters are never rewritten. Each
output's first buffer stamps against the host clock, and the audio devices' reported
latencies, are kept in `recording.json` to trace where the offset comes from.
`anyrec timing` plays a test signal through the speakers and measures the offset on
this Mac's devices without a call.

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
  summary reports the count; `--fps 24` usually clears it.

## Development

```
swift build
swift test
scripts/release.sh 0.4.0    # universal app DMG, CLI tarball and SHA256SUMS
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
