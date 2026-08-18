# anyrec

## Overview

macOS tool that records a call as three separate tracks: one window or display,
system audio output, and microphone input. Built on ScreenCaptureKit, so no
virtual audio driver is required. Windows belonging to Slack, Teams, Zoom, Meet,
Discord and browsers are listed first; everything else follows.

It ships as two front ends over one library. `anyrec` with no arguments opens a
TUI (setup screen, interactive capture and microphone pickers, live meters);
`anyrec record` is the same thing driven by flags, and is what a non-tty falls
back to. `AnyRec.app` is a menu bar app over the same Kit, offering the settings
worth a panel and leaving the rest at their defaults.

An optional pass turns the two audio tracks into a speaker-labelled transcript,
with macOS 26's on-device `SpeechAnalyzer`, with whisper.cpp, or — for people who
would rather bring a key than a model — with OpenAI's API.

## Tech Stack

- Swift 6 (language mode 5), SwiftPM
- ScreenCaptureKit — capture; AVFoundation — encoding
- swift-argument-parser — CLI
- SwiftUI `MenuBarExtra` — the menu bar app
- swift-testing — tests
- ffmpeg (runtime) — merges the tracks into `call.mp4`; on by default, degrades
  to a warning plus the separate tracks when absent
- Speech (macOS 26) — `SpeechAnalyzer`/`SpeechTranscriber`, optional
- whisper.cpp (runtime, optional) — `whisper-cli` plus a ggml model in
  `~/Library/Application Support/anyrec/models`

Requires macOS 15.2+. `SCStreamConfiguration.captureMicrophone` and
`SCStreamOutputType.microphone` are Sequoia APIs with no fallback, and
`SCContentFilter.includedWindows` — what the menu bar's system picker is read back
through — is 15.2.

## Commands

```
swift build                 # debug
swift test                  # swift-testing suites
swift build -c release
scripts/release.sh <ver>    # universal, signed: CLI tarball + app zip + sha256s
scripts/bundle-app.sh       # dist/AnyRec.app — the menu bar app
./.build/debug/anyrec doctor
```

## Architecture

`AnyRecKit` is the whole application: what a recording is, what it does, and what
this machine can do. `anyrec` is argument parsing, the TUI and output formatting;
`AnyRecBar` is a menu bar app. Each is a renderer over the same Kit, never another
copy of the flow, and they do not depend on each other — anything two interfaces
need belongs in the Kit. `AnyRecKit` is the only shared library; don't add a
second one for "UI-common" code.

| File | |
|---|---|
| `Session/RecordingConfiguration.swift` | What a recording is before it starts. Every interface edits one of these. |
| `Session/RecordingSession.swift` | One recording, start to finish: stream, folder, merge, transcript. |
| `Session/TranscriptPass.swift` | The optional pass over closed files. Returns an outcome; never throws. |
| `Readiness/Readiness.swift` | What is installed and available here, and the single `Advisory` worth showing for a configuration. |
| `Capture/CaptureCatalogue.swift` | Every recordable window and display, in the order worth offering them. What the terminal picks from. |
| `Capture/PickedContent.swift` | What macOS's content picker handed back, read as a `CaptureTarget`. The inverse of `TargetResolver`. |
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
| `AudioEnvelope.swift` | Loudness over time, as 20 ms frames. What bleed detection, speech detection and speaker attribution all read. |
| `SpeakerBleed.swift` | Spots the call re-entering through the microphone, and stops the merge amplifying it. |
| `Shell.swift` | Child processes, via temp files rather than pipes. |
| `OutputPlan.swift` | The recording folder and the three track paths. |
| `Transcription/Transcript.swift` | `Utterance`, turn folding, Markdown and SRT rendering. The tested part. |
| `Transcription/TranscriptionService.swift` | Builds the mix, finds the speech, picks the engine, labels the result. |
| `Transcription/AudioMix.swift` | Sums the two tracks into the single file the engines transcribe. |
| `Transcription/SpeechRegions.swift` | Where the talking is, so no engine is handed room tone to invent over. |
| `Transcription/SpeakerAttribution.swift` | Who said each line, from which track was louder while it was said. |
| `Transcription/AppleTranscriber.swift` | macOS 26 `SpeechAnalyzer`, `@available`-gated, plus `AppleSpeech` for callers that cannot be. |
| `Transcription/WhisperTranscriber.swift` | `whisper-cli`, model discovery, JSON parsing. |
| `Transcription/OpenAITranscriber.swift` | The hosted API, behind the user's own key. Multipart upload, `diarized_json`/`verbose_json` parsing. |
| `Transcription/AudioChunks.swift` | Cuts the speech regions out to mp3, under the API's 25 MB limit, keeping each part's offset. |
| `Transcription/Summarizer.swift` | The `claude -p` pass over the finished text. |
| `Transcription/WhisperSetup.swift` | What is missing before whisper can run, and how to fetch it. |
| `Transcription/AssetDownload.swift` | Downloading a model, with progress and a checksum. |
| `Transcription/OpenAIKey.swift` | Where the user's key is read from and written to. |
| `anyrec/TUI/` | `Terminal` (raw mode, keys), `Picker`, `Page`, `SecretPrompt`, `SetupScreen`, `EngineSetup`, `RecordingScreen`, `TUISession`, plus `ConfigurationRows` and `CapturePicker` — the terminal's wording and layout for Kit types. |
| `anyrec/Report.swift`, `anyrec/TranscriptReport.swift` | Summaries, merge outcomes and transcript outcomes, as terminal text. |
| `AnyRecBar/RecordingController.swift` | The menu bar's whole state: settings, the live session, and what the last one left behind. |
| `AnyRecBar/SystemPicker.swift` | macOS's on-screen content picker, and the configuration that holds it to windows and displays. |
| `AnyRecBar/Wording.swift` | The Kit's facts in the panel's words. The tested part of the app. |
| `AnyRecBar/Preferences.swift` | The few settings that survive a relaunch, mapped onto `UserDefaults`. The Kit has no opinion about persistence. |
| `AnyRecBar/Views/` | `MenuPanel` and the three it switches between (`SetupPanel`, `RecordingPanel`, `OutcomePanel`), plus `SettingsWindow`, `LevelMeter`, `Notice` and `PermissionPanel`. |
| `scripts/bundle-app.sh` | Wraps the binary in `AnyRec.app`: `LSUIElement`, bundle id, mic usage string, signature. Universal for release, native for debug. |
| `scripts/signing.sh` | The identity both build scripts sign with, and the ad-hoc fallback when it is absent. |
| `Formula/anyrec.rb`, `Casks/anyrec-app.rb` | Reference copies of what the tap serves. The live ones are in `homebrew-tap`. |

Invariants worth preserving:

- There is one recording flow, and it is `RecordingSession`. `record`, the TUI and
  the menu bar all drive it; none may grow its own start/stop/merge/transcribe.
  When two of them had one they silently diverged three ways — `record` never
  transcribed at all, the two handled a missing ffmpeg differently, and only the
  TUI pinned the default microphone as an explicit device.
- Nothing in `AnyRecKit` prints, reads a key, or words a way out of anything. It
  answers in facts — `Advisory`, `EngineReadiness`, `TranscriptionError.Remedy`,
  `PermissionHost` — and each interface words them. "⏎ on Transcript" is true of a
  terminal and of nothing else; the app says "Settings › Transcription" for the same
  `Advisory`, because it has no ⏎ and no row to press it on.
- Anything both front ends offer lives in the Kit, including the lists they offer
  it from: `stopChoices` and `transcribeChoices` are on `RecordingConfiguration`
  so a menu and a cycling row cannot drift apart. How they are *chosen* — arrow
  keys against a popup button — stays with each interface.
- `Readiness` caches the Apple language list and nothing else. Everything else it
  reports is a live check, because whisper and ffmpeg can be installed from the
  setup screen mid-session and a cached "missing" would outlive the fix.
- All stream outputs use one serial queue, which is why `Recorder`'s writer
  table and session clock need no locking. Don't add a second queue.
- All three writers start their session at the *same* timestamp — the first
  buffer seen on any output. Per-writer session starts would silently destroy
  A/V sync.
- Non-`.complete` screen frames are discarded. Writing idle frames pads the
  video and drifts it against the audio.
- `scalesToFit` is on. Left off, ScreenCaptureKit only ever scales a window's
  output *down*: resize the window mid-call and the frame keeps its configured
  size with the picture in one corner and black around it. Measured on a resize to
  half: 26% of the frame with it off, 95% with it on, the remainder being the
  letterbox `preservesAspectRatio` leaves. A 78-minute call was recorded at a
  quarter frame before this was set.
- A stream that stops because its window is gone has *ended* the recording, not
  failed it. `noCaptureSource` and `userStopped` are reported in the summary and
  everything finalises as usual; every other stop still throws. Throwing these hid
  a complete 78-minute recording behind an error message and skipped the summary,
  the merge and the offer to transcribe.
- A capture target is a window or a display, never an application. Application
  filters record the whole display with everything else masked out, which is a
  display recording wearing a disguise. The cost is that a huddle and its
  screen-share are separate windows: record the display to get both.
- Only windows in layer 0 and at least 120px on a side are offered. macOS shares
  wallpaper backstops, the menu bar, the Dock, every Control Center status item
  and the recording indicator, and none of them is a recording target.
- Audio tracks are never encoded below 44.1 kHz. AAC here refuses the job rather
  than resampling, and fails in whichever place is least helpful: `startWriting`
  when a source format hint is set, `append` when it is not. Bluetooth is what
  hits it — as an input, AirPods run HFP at 16 kHz — and the whole recording used
  to die on it. Anything lower is lifted to 48 kHz.
- Errors that carry a message conform to `LocalizedError`, not just
  `CustomStringConvertible`. Anything reported through `localizedDescription`
  otherwise prints "the operation couldn't be completed" and a case number, which
  is how a microphone that could not be encoded reached the user as
  `WriterError error 1`.
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
- The menu bar app owns Quit the same way: `applicationShouldTerminate` returns
  `.terminateLater` while a recording is running and replies only once the
  writers have finalised. Terminating outright is the same `ftyp`+`mdat` with no
  `moov`, reached by ⌘Q instead of Ctrl-C.
- `RecordingController` is owned by the app delegate, never by a view. A
  `.window`-style `MenuBarExtra` tears its content down the moment you click away,
  and a recording has to outlive that.
- The menu bar extra shows a panel, not a menu, which the HIG allows only for
  functionality a menu cannot carry — live meters are that.
- The menu bar picks with `SCContentSharingPicker`, not a list of titles. Two
  windows called "Meet — Meeting" are one word apart in a menu and a screen apart
  in front of you. `PickedContent` reads the selection back to a `CaptureTarget`
  and throws the filter away, so `TargetResolver` stays the only place a recording's
  filter is built. The terminal keeps `CaptureCatalogue` because it has no screen to
  point at — the Kit says what is recordable, each interface says how it is chosen.
- `allowedPickerModes` is `[.singleWindow, .singleDisplay]`. The picker offers
  applications otherwise, and an application filter is the display recording this
  refuses to disguise.
- Picking is the first half of Start, not a row above it. The panel has no capture
  row: pressing the button opens the picker and a selection starts the recording, so
  what is recorded is always what was pointed at a second ago. A pick that sits in
  the panel goes stale — the window closes while the menu is shut — and the check
  for that was code paid for by a step nobody wanted. Closing the picker without
  choosing records nothing, which is what closing it means.
- `TargetResolver.resolve` looks windows up with `onScreenWindowsOnly: false`. What
  is worth *offering* is on-screen only, but the picker hands back windows from other
  Spaces and `desktopIndependentWindow` follows one there, so refusing to resolve an
  id would be the one place that did not. It is also what lets `--window <id>` record
  a window on another desktop.
- The panel offers a microphone, a transcript and a stop time; system audio and the
  merge live in Settings, on and rarely touched. They are what the tool is for, and a
  toggle for each in a panel you opened to press one button asks a question whose
  answer is always yes. `anyrec record` keeps the flags.
- Setting an engine up must be possible without a terminal. The app installs on its
  own through a cask, so "run anyrec in a terminal" was a way out that a whole class
  of user could not take — `Settings › Transcription` is `EngineSetup`'s counterpart,
  a sibling renderer over `WhisperSetup`, `AssetDownload` and `OpenAIKey`, never a
  shared view with it.
- The setup task is owned by `RecordingController`, not by the settings window. A
  `brew install` and a model download outlive the window being closed, exactly as a
  recording outlives the panel.
- `Readiness` is re-probed after a setup run. It is a stored property filled once at
  launch, so an engine installed from Settings would otherwise still read as missing
  in the panel's Transcript row and in its advisory.
- What a download costs is on the button, before it is pressed — `Wording.install`
  carries `downloadSize`, as the terminal's page does. Nothing is fetched otherwise.
- The settings window is reached by `openSettings()` after `NSApplication.activate`.
  `LSUIElement` means no Dock icon and nothing to bring forward, so the window opens
  behind every other app without it.
- Persistence belongs to `AnyRecBar`, not to the Kit. A recording is configured from
  nothing every time; an app that sits in a menu bar for days is what needs to
  remember. `Preferences` maps a handful of fields onto `UserDefaults`, and the
  microphone is stored as a device id and re-resolved, because the device it names
  may be in a drawer by the next launch.
- The meters poll at 10 Hz; the menu bar clock is held as text and only assigned
  when the second changes, so the status item redraws once a second rather than
  ten times. Don't drive the label off the tick directly.
- macOS grants TCC to the *bundle*, so the menu bar app is `AnyRec.app` with a
  stable `CFBundleIdentifier` and its own grants — which is what
  `PermissionHost.application` words. TCC keys off the signature too, which is why
  both build scripts sign with a Developer ID from `scripts/signing.sh` rather than
  ad-hoc: an ad-hoc signature changes every build, so every rebuild asked again.
  Machines without that identity fall back to ad-hoc and get the old behaviour.
- The cask's token is `anyrec-app`, not `anyrec`. A cask and a formula sharing one
  token in a tap conflict: with the cask installed, a formula install completes but
  links nothing, and `anyrec` quietly leaves `PATH`.
- The app has to be notarised, and a cask does not get you out of it. Casks apply
  the quarantine flag — `--no-quarantine` is the opt-out — so an unnotarised
  bundle installs and then refuses to open: `spctl` says `rejected: Unnotarized
  Developer ID`, and clearing the attribute by hand is the only way in. Formulae
  are the ones that install unquarantined, which is why the CLI never needed any
  of this, and why reading across from `Formula/anyrec.rb` gets it wrong.
- The app zip is made with `ditto -c -k --keepParent`, never `zip`. `zip` drops the
  symlinks and extended attributes a bundle's signature is checked against, and the
  app arrives with a signature that no longer verifies.
- `NSMicrophoneUsageDescription` must be in the bundle's `Info.plist`. Without it
  the mic prompt terminates the app rather than failing softly.
- The app must *ask* for Screen Recording, not just preflight it.
  `CGPreflightScreenCaptureAccess` reads the answer; `CGRequestScreenCaptureAccess`
  is what registers the app with TCC. An app that has only ever preflighted does not
  appear in Privacy & Security at all, so the panel's "enable it here" pointed at a
  list with no AnyRec row in it and the only way through was the `+` button. The ask
  runs when `PermissionPanel` appears, before the button is offered, and once a
  launch — macOS replies by offering Settings rather than granting, so a second ask
  buys nothing.
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
  It must never be able to fail a recording: `TranscriptPass` returns a
  `TranscriptOutcome` rather than throwing, and the interface points at
  `anyrec transcribe`. It is also why `RecordingSession.stop` and
  `.transcript()` are two calls and not one — the TUI hands raw mode back in
  between, so the engines report into a normal terminal.
- One engine run, over the mix of both tracks — never one run per track. Two
  independent runs produce two timelines that only appear comparable: an engine
  handed a quiet track invents sentences to fill it and stamps them with
  plausible times, and interleaving those against real ones scrambles the call.
  Ordering has to come from audio the engine heard whole.
- The tracks are still what says *who*. `SpeakerAttribution` compares the two
  envelopes over each line's span, so attribution stays exact without the engine
  knowing anything about the participants. It is also why bleed no longer
  misattributes: an echo is quieter than what caused it, so an echoed line still
  scores for the caller.
- Only the far end can be diarised, and only by an engine that does it. Slack
  pre-mixes every remote participant into system audio, so energy can answer
  "me or the call" and nothing finer. `--diarize` (openai only) is what turns
  "Call" into "Speaker A", "Speaker B"; energy then reclaims your own lines from
  whatever letters they arrived under.
- Attribution is per line, never per voice. A diarising model fuses two people
  into one letter when they take turns quickly, and a voice weighed as a whole
  then averages out below the margin — so nothing is claimed and nobody is "Me",
  which is exactly how a three-way call came back with one speaker holding both
  sides of it. Each line is measured on its own. The letters left over are
  renumbered from the top afterwards, so a transcript never opens on "Speaker B".
- A segment holding two people is cut at its sentence ends. One letter covers a
  whole span when a reply lands inside it — "Uite, stau pe aici, aştept. Sunt
  bine." was two speakers in one cue — and no diarising engine returns word times
  to place the seam. Sharing the span out by sentence length put the cut 33 ms
  from the real handover on that recording, which is close enough that each part
  lands on its own side of it. The cut is kept only when the parts disagree about
  who was talking, so ordinary punctuation never fragments a line.
- Every engine is handed the speech regions, and none of them may be handed the
  gaps. whisper is the one that needs it most — without VAD its first segment
  spans the leading silence and starts at 0 — but the hosted models hallucinate
  over room tone too. Engines running their own detection ignore the argument.
- Nothing leaves the machine unless it was asked for by name. `--engine openai`
  and `--summarize` are the only two that do, and both say so wherever they are
  offered. `auto` must stay local-only: falling back to an upload because a model
  was missing would ship a call off the machine by accident.
- `openai` may only use a model that returns timestamps: `gpt-4o-transcribe-diarize`
  or `whisper-1`. Everything else answers in prose, which cannot be placed on a
  timeline or attributed. The diarising model goes up in one request — its speaker
  letters are consistent within a request and meaningless across two — and needs
  `chunking_strategy` for anything over 30s. It takes no `language`.
- The OpenAI key is read from `OPENAI_API_KEY` or the key file, never stored, and
  never put in an error: only the response body reaches `engineFailed`. The setup
  screen takes one by paste and never draws it back — a tool that records screens
  must assume its own screen is being recorded. The key is checked against the API
  before it is written, so a bad paste is caught now rather than after the call it
  was meant to transcribe; a key OpenAI rejects is never saved, but one that could
  not be checked at all is, because being offline is not a reason to ask again.
- Nothing is installed or downloaded unless it was asked for: the setup CTA is
  behind ⏎ on the Transcript row and a page saying what it will fetch and how big
  it is, and behind a button in `Settings › Transcription` that says the same on
  its face. `pending()` includes ffmpeg because whisper is fed through it — a model
  downloaded onto a machine without ffmpeg is dead weight.
- A downloaded model only appears at its final path once its sha256 matches. A
  half-written model is worse than none, because `defaultModel()` picks the largest
  `.bin` it finds and would pick the wreckage.
- What `apple` covers is said before the recording, not after. It is the one engine
  that can be present, selected, and still have no model for the call — and it fails
  rather than degrades — so the row carries the count, the warning line says whisper
  covers the rest, and ⏎ lists the languages. The list is fetched before raw mode,
  alongside the microphones, for the same reason they are.
- Language detection is skipped for remote engines. Running whisper locally to
  label an upload defeats the point of not having whisper installed, so the
  engine reports what it heard and `Transcript` takes the answer from there — and
  drops the header segment entirely when it gets none, which is what the diarising
  model always does.

## Permissions

Screen Recording and Microphone are granted by macOS to the *parent terminal
application*, not to this binary. After granting, the terminal must be
relaunched. `anyrec doctor` reports the current state.

## Conventions

- No secrets in the repo and no `.env`. The one key the tool reads is the user's
  own, from `OPENAI_API_KEY` or `~/Library/Application Support/anyrec/openai-key`.
- Never commit captures; `*.mov`, `*.mp4`, `*.m4a` are gitignored.
