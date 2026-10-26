# anyrec

## Overview

macOS tool that records a call as three separate tracks: one window or display,
system audio output, and microphone input. Built on ScreenCaptureKit, so no
virtual audio driver is required. Windows belonging to Slack, Teams, Zoom, Meet,
Discord and browsers are listed first; everything else follows.

It ships as two front ends over one library. `anyrec` with no arguments opens a
TUI (setup screen, interactive capture and microphone pickers, live meters);
`anyrec record` is the same thing driven by flags, and is what a non-tty falls
back to. `AnyRec.app` is a regular Mac app over the same Kit — a library window of every
recording, with Settings — and a menu bar helper that starts and watches a recording,
offering the settings worth a panel and leaving the rest at their defaults.

An optional pass turns the two audio tracks into a speaker-labelled transcript:
on-device with NVIDIA's Parakeet (through FluidAudio, in 25 languages, a download
away), with macOS 26's `SpeechAnalyzer`, with whisper.cpp, or — for people who would
rather bring a key than a model — with OpenAI's API.

## Tech Stack

- Swift 6 (language mode 5), SwiftPM
- ScreenCaptureKit — capture; AVFoundation — encoding
- swift-argument-parser — CLI
- SwiftUI `MenuBarExtra` — the menu bar app
- swift-testing — tests
- ffmpeg (runtime) — merges the tracks into `call.mp4` and makes the mix the engines
  hear; on by default, degrades to a warning plus the separate tracks when absent.
  Found on `PATH`, or fetched as a static build into
  `~/Library/Application Support/anyrec/bin` by `FFmpegSetup`, so Homebrew is not needed
- Speech (macOS 26) — `SpeechAnalyzer`/`SpeechTranscriber`, optional
- whisper.cpp (SwiftPM binary target, the xcframework its own CI builds) — linked
  into the Kit, so whisper runs in-process; its ggml model goes in
  `~/Library/Application Support/anyrec/models`. The framework is embedded in the app
  bundle and the CLI tarball by `scripts/embed-whisper.sh`
- FluidAudio (SwiftPM, pinned) — Parakeet TDT 0.6B v3 on CoreML, the default on-device
  engine (~480 MB, under `parakeet-tdt-0.6b-v3-coreml/` in the models folder), and
  pyannote community-1 diarization for telling the far end's voices apart (~22 MB,
  under `speaker-diarization/`). Attribution is in `NOTICE.md`.

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
scripts/bundle-app.sh       # dist/AnyRec.app — the Mac app and its menu bar helper
./.build/debug/anyrec doctor
./.build/debug/anyrec speakers --download   # the 22 MB speaker models, no terminal UI needed
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
| `Session/RecordingLibrary.swift` | Every finished recording under the output folder, newest first, and which artefacts each has left. What the app's library window lists. |
| `Session/RecordingInfo.swift` | `recording.json`, written when a recording starts: the window's title, its app, the picture's size. What the library titles a recording by. |
| `Session/Thumbnail.swift` | A still from a tenth of the way into the video, kept as `thumbnail.jpg`, for the library's list rows. |
| `Session/Waveform.swift` | A recording's loudness cut into columns for drawing, read with AVFoundation so it needs no ffmpeg. |
| `Transcription/Summary.swift` | A summary as data (overview, decisions, actions with the second they were said), `SummaryProvider` (Claude Code, Codex, OpenAI API, Gemini CLI) and `Summarizer.summary`. |
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
| `MixPlan.swift` | How the two audio tracks go together — matched by loudness, or the mic held under the call when it bleeds, and silenced wherever the call was not listening. Both mixes are built from it. |
| `MicrophoneLive.swift` | When the call could hear the microphone: the monitor that watches the call app's mic for the length of a recording, and the file it leaves. |
| `AudioProcesses.swift` | Who is doing audio right now, read from Core Audio's process objects. The list behind the orange dot. |
| `MuteButton.swift` | The call app's own mute control, found in its accessibility tree and re-read four times a second. What Teams's mute is read from. |
| `CallWatch.swift` | A call starting, read as a known call app taking the microphone. What the menu bar's offer to record comes from. |
| `AnyRecBar/CallReminder.swift` | A persistent Record/Dismiss banner above the focused Slack or Teams call window, with native notifications as fallback. |
| `AnyRecBar/CallNotifier.swift` | The native notification fallback; Record opens the capture picker. |
| `AudioEnvelope.swift` | Loudness over time, as 20 ms frames. What bleed detection, speech detection and speaker attribution all read. |
| `SpeakerBleed.swift` | Spots the call re-entering through the microphone, and words the warning for it. |
| `Shell.swift` | Child processes, via temp files rather than pipes. |
| `OutputPlan.swift` | The recording folder and the three track paths. |
| `Transcription/Transcript.swift` | `Utterance`, turn folding, Markdown and SRT rendering. The tested part. |
| `Transcription/TranscriptStore.swift` | Publishes transcript generations and selects their own voices and summary atomically. |
| `Transcription/TranscriptionService.swift` | Builds the mix, finds the speech, picks the engine, labels the result. |
| `Transcription/AudioMix.swift` | Sums the two tracks into the single file the engines transcribe. |
| `Transcription/SpeechRegions.swift` | Where the talking is, so no engine is handed room tone to invent over. |
| `Transcription/SpeakerAttribution.swift` | Who said each line, from which track was louder while it was said. |
| `Transcription/AppleTranscriber.swift` | macOS 26 `SpeechAnalyzer`, `@available`-gated, plus `AppleSpeech` for callers that cannot be. |
| `Transcription/ParakeetTranscriber.swift` | Parakeet on CoreML via FluidAudio: the words with their times, cut into lines; and `ParakeetSetup`, the one place its model is fetched. |
| `FFmpegSetup.swift` | A static ffmpeg fetched into the tools folder when there is none on `PATH`, made executable and let out of quarantine. |
| `Transcription/WhisperTranscriber.swift` | whisper.cpp through its C API, in-process: model discovery, language detection, segments. |
| `Transcription/AudioSamples.swift` | A file's audio as 16 kHz mono float, read a second at a time with AVFoundation. What whisper is handed. |
| `Transcription/OpenAITranscriber.swift` | The hosted API, behind the user's own key. Multipart upload, `diarized_json`/`verbose_json` parsing. |
| `Transcription/AudioChunks.swift` | Cuts the speech regions out to mp3, under the API's 25 MB limit, keeping each part's offset. |
| `Transcription/Summarizer.swift` | The `claude -p` pass over the finished text. |
| `Transcription/WhisperSetup.swift` | What is missing before whisper can run, and how to fetch it. |
| `Transcription/AssetDownload.swift` | Downloading a model, with progress and a checksum. |
| `Transcription/OpenAIKey.swift` | Where the user's key is read from and written to. |
| `Transcription/VoiceSeparation.swift` | The far end told apart on-device, whatever engine wrote the words: FluidAudio's segments and per-voice prints, lettered and laid over the lines. |
| `Transcription/VoiceLibrary.swift` | The people anyrec has been told the names of, as voiceprints on disk, and the cosine match against them. |
| `Transcription/SpeakerNames.swift` | Per-generation speaker letters and `VoiceNaming`, which names the active generation from any interface. |
| `Transcription/SpeakerSetup.swift` | Whether the speaker models are here, and the one place FluidAudio is let on the network to fetch them. |
| `anyrec/TUI/` | `Terminal` (raw mode, keys), `Picker`, `Page`, `SecretPrompt`, `SetupScreen`, `EngineSetup`, `RecordingScreen`, `TUISession`, plus `ConfigurationRows` and `CapturePicker` — the terminal's wording and layout for Kit types. |
| `anyrec/Report.swift`, `anyrec/TranscriptReport.swift` | Summaries, merge outcomes and transcript outcomes, as terminal text. |
| `anyrec/SpeakersCommand.swift`, `anyrec/SpeakerPrompt.swift` | `anyrec speakers`, and the plain-terminal questions that put names to letters after any transcript. |
| `AnyRecBar/RecordingController.swift` | The menu bar's whole state: settings, the live session, and what the last one left behind. |
| `AnyRecBar/RecordingJobs.swift` | Serial background merging and transcription, keyed by recording directory, independent of capture and the saved panel. |
| `Session/CapturedRecording.swift` | Finalized tracks and microphone timing, ready for merging after capture has been released. |
| `AnyRecBar/SystemPicker.swift` | macOS's on-screen content picker, and the configuration that holds it to windows and displays. |
| `AnyRecBar/Wording.swift` | The Kit's facts in the panel's words. The tested part of the app. |
| `AnyRecBar/Preferences.swift` | The few settings that survive a relaunch, mapped onto `UserDefaults`. The Kit has no opinion about persistence. |
| `AnyRecBar/Commands.swift` | The menu bar's File, View, Playback and Recording commands. The open player reaches them as a focused value. |
| `AnyRecBar/Playback.swift`, `HotKey.swift` | One recording's player (call.mp4, or the three masters with a track silenced), and the ⌘⇧R shortcut. |
| `AnyRecBar/Views/LibraryWindow.swift`, `RecordingDetail.swift` | The library window: filters, day-grouped list, and one recording's video, summary and voice naming, with its transcript, tracks and files in the inspector. Reads files the Kit left; writes only voice names (via `VoiceNaming`) and ticks on action items. Summaries are written by `RecordingController`, which outlives the window. |
| `AnyRecBar/Views/WelcomeSheet.swift` | Two-step first launch: recording access, then on-device transcription downloads. Opens the library on completion; Help can reopen it. |
| `AnyRecBar/Views/` | `MenuPanel` and the three it switches between (`SetupPanel`, `RecordingPanel`, `OutcomePanel`), plus `SettingsWindow`, `LevelMeter`, `Notice` and `PermissionPanel`. System components throughout, except the recording page's cards and transport, which live privately in `RecordingDetail.swift`. |
| `scripts/bundle-app.sh` | Wraps the binary in `AnyRec.app`: bundle id, icon, mic usage string, signature. Universal for release, native for debug. |
| `scripts/embed-whisper.sh` | Copies whisper.framework beside a binary and repoints its rpath from `.build` to `@executable_path/../Frameworks`; both build scripts source it. |
| `scripts/signing.sh` | The identity both build scripts sign with, and the ad-hoc fallback when it is absent. |
| `Formula/anyrec.rb`, `Casks/anyrec-app.rb` | Reference copies of what the tap serves. The live ones are in `homebrew-tap`. |

Invariants worth preserving:

- Saving capture releases the recorder before merging or transcription. Done clears
  only the saved panel; starting another recording never cancels pending processing.
  Job progress and failures belong to recording directories, and stale callbacks cannot
  update completed or retried jobs. Quit waits for capture and background work.
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
- The idle panel offers Record Window and recent recordings. Microphone, transcript,
  stop time and system audio live in Settings. The app always merges the tracks into
  `call.mp4`; merging is not a user option. `anyrec record` keeps the flags.
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
  in Settings and in the panel's advisory.
- What a download costs is on the button, before it is pressed — `Wording.install`
  carries `downloadSize`, as the terminal's page does. Nothing is fetched otherwise.
- A window opened from the menu bar helper is reached after `NSApplication.activate`:
  the helper is clicked while another app is in front, and the window would open behind
  it otherwise.
- The app is a regular app (Dock icon, library window at launch), not an `LSUIElement`
  agent, and closing the last window must not quit it: `applicationShouldTerminateAfterLastWindowClosed`
  is false, because a recording and the menu bar helper outlive the window.
- The library window does no work in a view's `init` or in a body that redraws often.
  `RecordingDetail` makes its `Playback` in `.task(id:)`: made in `init`, it was a new
  `AVPlayer`, a new time observer and a fresh decode of the call's audio on every redraw
  of the list, none of them ever stopped, and a search keystroke started another. The
  playhead moves ten times a second, so only the views that show it read it — the clock,
  the waveform, and the transcript's highlight through `Playback.currentLine`, which
  changes once a line. What has to be found on disk (summary providers, free space) is
  read into `RecordingController` and held, like `readiness`, and `library` is only
  assigned when what is on disk changed.
- The library's list is laid out the way Notes lays out its own: large bold headings
  for Today, Yesterday, Previous 7 Days, Previous 30 Days, then months, then years;
  rows of a bold title, the time or date beside a line of what was said (the summary's
  first sentence, else the transcript's first words), and the app and length where Notes
  puts the folder; a status badge in the leading margin and a still on the right.
- A recording's waveform is decoded once and kept as `waveform.json` beside the tracks;
  its list thumbnail likewise as `thumbnail.jpg`.
  Decoding is the cost — about 4 s of CPU for a 100-minute call, however the samples are
  summed — and like `call.mp4` it is derived: delete it and it is made again.
- The app is built from the system's components and follows the macOS HIG, not a
  mockup. Text uses text styles (`.headline`, `.subheadline`, `.callout`), never point
  sizes; colours are system colours; containers are `GroupBox`, grouped `Form`s and
  `List`s. The exception is the recording's own page, which keeps its cards and its own
  transport under the video, because it was tried the system's way and read worse. Its
  Transcript/Tracks/Files tabs live in the inspector beside it, open by default, so the
  transcript stays in view while the video plays. Settings is a toolbar of panes, reopened on
  the last one. Every command is in the menu bar — toolbar items, context-menu items
  and the helper's actions are copies of menu commands, never the only way in.
- The app bundle is linked as built against the SDK it really was. SwiftPM records the
  deployment target (15.2) as the SDK in `LC_BUILD_VERSION`, and macOS 26 gives its
  current design — Liquid Glass toolbars, floating toolbar items, the floating sidebar —
  only to apps built against SDK 26 or later; everything else gets a compatibility mode
  with a flat band across the top. `bundle-app.sh` passes `-platform_version` to the
  linker with `xcrun --show-sdk-version`, which leaves the deployment target alone.
  A hand-made glass overlay never matched Notes until this was fixed: in compatibility
  mode `glassEffect` is not the real thing. The recording's Finder, Share and ⓘ buttons
  are toolbar items at the start of the recording's toolbar row, so they stay while the
  page scrolls. They are not pushed to the trailing end: the window's toolbar is one
  strip across the recording and the inspector, so the trailing end is over the
  inspector, and an overlay in that row is drawn under the toolbar. So everything is
  pushed to the trailing end and walked back by two invisible toolbar items whose widths
  are measured (`ToolbarStrip`): one holds the buttons at the recording's edge, one
  centres the inspector's Transcript/Tracks/Files tabs over the inspector, which has no
  row of its own above the transcript. The measurements are applied on the next turn of
  the run loop — a width changed inside the layout pass that measured it is an AppKit
  exception, and crashed the app — and each is worked out from its frame plus the widths
  that frame was laid out under, never nudged by an offset, because the three callbacks
  of one pass all run `place()` and three nudges from one stale frame ran a width to its
  clamp. The widths live in `LibraryView`, not the recording's page, and the page is not
  re-identified per recording: widths that started from zero for each one opened sent
  the buttons on a visible walk from the trailing edge at every change of selection.
  The widths are computed from the inspector's and the tabs' *widths*, which hold still
  during a window resize, with a constant per width taken from positions — and the
  positions have to be real ones. The toolbar moves its items itself after SwiftUI has
  laid them out, so SwiftUI's geometry for a toolbar item is wherever it was last laid
  out: the tabs reported one x through three changes of the pad. `ToolbarProbe` reads
  each item's view from AppKit instead, 300 ms after anything changed, and an offset is
  acted on only when two looks agree, so a frame caught mid-move changes nothing. The
  inspector's frame does come from SwiftUI (it lays the content out), applied a turn of
  the run loop later — changed inside the pass that measured it, it was an AppKit
  exception that crashed the app. Nothing is measured while the inspector is hidden: the
  strip then has no gap or tabs in it. The probes pass clicks through (`hitTest` nil):
  as plain views over the ⓘ and the tabs they swallowed every click on them. The
  constants and last widths are remembered in `Preferences`, so the first layout of a
  launch is right rather than walking into place over a second, and a first calibration
  is taken from the first look — only a correction to an existing one waits for two.
- The menu bar extra can be switched off (Settings › General), because whether an
  extra is in the menu bar is the person's call, and the system hides extras when the
  menu bar is full. The Dock menu carries New Recording and Stop Recording for that
  reason.
- Persistence belongs to `AnyRecBar`, not to the Kit. A recording is configured from
  nothing every time; an app that sits in a menu bar for days is what needs to
  remember. `Preferences` maps a handful of fields onto `UserDefaults`, and the
  microphone is stored as a device id and re-resolved, because the device it names
  may be in a drawer by the next launch.
- The microphone is saved when it is *chosen*, never when it is resolved, which is why
  the panel binds `controller.microphone` rather than `configuration.microphone`. Both
  launch and reopening the panel resolve the stored id against what is plugged in, and
  a resolution that found nothing writing itself back would forget a headset for good
  the first time it was unplugged. An empty stored id is Off — a choice — as against
  no id at all, which is why `pinDefaultMicrophone` is skipped for the first and not
  the second.
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
- Speaker bleed is checked before the mic is boosted, and a bleeding mic is held
  under the call rather than summed with it. On speakers the far end is already in
  the mic track: boosting it doubles the echo, and summing it as-is hands the engine
  every word twice — a 5-minute call came back as 503 lines over six "speakers",
  each sentence shared out word by word between the wire's copy and the room's. The
  duck is a sidechain compressor keyed on the system track, so it needs no estimate
  of how loud or how late the echo is; measured at −39 dB under the far end and
  0 dB where the call is silent. What it costs is anything said over the other
  side. Both mixes decide this once, through `MixPlan` — `mix.wav` used to skip the
  bleed check and boost the echo by the loudness difference. Bleed is detected as
  the microphone running *louder* while the call speaks — turn-taking makes that
  figure negative, so the sign alone separates the cases.
- Mute is read from the app, never from the audio. Two ways, both polled four times
  a second by `MicrophoneLive.Monitor`, which leaves `microphone-live.json` beside
  the tracks; both mixes silence the microphone outside the live spans, and
  attribution never claims a line there. First, Core Audio: an app that releases the
  microphone on mute shows as running no input on its process object
  (`kAudioProcessPropertyIsRunningInput`), with no permission and no integration.
  Teams does *not* release it — its log shows `InputMuteStateChangeNotification`,
  macOS 14's per-process input mute, which keeps the IO running and feeds it
  silence, and that flag is the process's own: `pmin` on another process object
  answers `who?`. So, second, the app's own mute button, read through accessibility:
  `MuteButton` carries the labels per app (Teams: "Unmute mic" / "Mute mic"; Slack:
  "Unmute microphone" / "Mute microphone", in the description with an empty title;
  all watched flipping live), the tree is walked once to find it and the one element
  re-read after that. Slack keeps the microphone open while muted too.
  `AXEnhancedUserInterface` has to be set on the app first or Chromium stops the
  tree at the close button; Electron's own switch is `AXManualAccessibility`, and
  both are set. Needs the Accessibility grant, which every front end *asks* for
  the way the app asks for Screen Recording — only asking lists the app in Privacy
  & Security — the menu bar once a launch when the panel opens, the TUI before raw
  mode, `record` in its preflight, `doctor` outright. It is never required:
  `Advisory.accessibilityMissing` says what is missing, and without it Teams reads
  as live throughout and nothing is gated, which is the safe failure. The Teams log and
  its third-party API were looked at and dropped: the log only mentions mute when
  AirPods are in, and the API needs a token and a Teams build that still has it.
  Energy could not do this: a word to someone in the room while muted *is* speech
  on the microphone, and a muted speakerphone call came back with "Me" on clicks
  the engine had turned into words. When no watched app does any audio for the
  whole recording, nothing is written and the microphone is left alone — a call
  nobody saw is not a call that was muted. The window's own app is watched along
  with the known ones, and a watched id covers the helpers under it, because a
  browser's audio runs in `com.google.Chrome.helper`.
- A call is detected the way mute is, and offered rather than acted on. `CallWatch`
  reads Core Audio's process list every two seconds; a known call app running
  microphone input is a call beginning (Teams holds it from the join, muted or not),
  and its release is the call ending. Slack and Teams get a persistent banner above
  the focused call window, found through its mute control. It follows the window
  and hides when another window is focused. If there is no room above, it sits just
  inside the top edge. Other apps or an unidentified call window use a notification.
  The banner's Record button starts its call window directly, matched by process,
  bounds and title, with ownership checked again before capture. Missing or ambiguous
  windows are rejected. Notification fallbacks still open the picker; Dismiss
  suppresses the offer for that call.
  Starting a recording or ending the call removes the reminder. An
  app testing its microphone looks like a call, which is why nothing records until
  the button is pressed. One offer per call, withdrawn when it ends, only while
  idle, off in Settings › General. Notifications are asked for the first time
  there is one to show, so the dialog arrives with its reason in view.
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
- For local transcription, the tracks say *who*. `SpeakerAttribution` compares the two
  envelopes over each line's span, so attribution stays exact without the engine
  knowing anything about the participants. It is also why bleed no longer
  misattributes: an echo is quieter than what caused it, so an echoed line still
  scores for the caller. Two more checks, both from a muted speakerphone call that
  came back with six lines of "Me": the mic has to clear `SpeechRegions`' own
  threshold, because against a digitally silent call any room noise wins the
  ratio; and in a bleeding recording the mic is read with the duck replayed on its
  envelope, as the engine heard it, because a cue that lands inside the far end's
  sentence ran 1.9× the wire copy in the raw mic and was nothing but the room.
- For local transcription, only the far end needs diarising. Slack
  pre-mixes every remote participant into system audio, so energy can answer "me
  or the call" and nothing finer; `VoiceSeparation` runs FluidAudio over the mix
  after a local engine has written the words, letters the voices by first appearance
  and lays them over the lines by overlap, cutting a paragraph at sentence ends
  when its halves disagree. Energy keeps the last word on "Me".
- OpenAI diarization keeps its speaker labels and segment times through attribution
  and speaker processing, including on merged-only recordings. `SpeakerRecognition`
  samples clean passages for each supplied label; `SpeakerEmbedding` uses the pinned
  local model's FBANK and embedding stages without segmentation or clustering.
  Voiceprints match against the existing library without changing speaking turns.
  Short, overlapping or inconsistent samples remain unnamed. Missing models or
  extraction failures retain nameable labels with no reusable print.
- A voice named once is found on the next call. The diarizer's centroid per voice
  is its print, the generation's voices file keeps each letter's print and longest line beside the
  tracks, and naming a letter — `anyrec speakers`, the prompt after a transcript,
  the outcome panel — files the print under the name in
  `~/Library/Application Support/anyrec/voices/`. The next recording matches every
  voice against the library by cosine similarity and names what it recognises.
  Nothing caps the library: OpenAI's known-speaker references stop at four, which
  is why they are not used — a meeting here can be twenty people. The 0.5 match
  threshold is provisional, set from FluidAudio's own table, and only ever moves
  up until it has been measured on real calls: the wrong name is the worse mistake.
- Each generation is kept as `transcript-<engine>-<UUID>.json` plus Markdown and
  SRT. `TranscriptStore` writes all files before atomically selecting the generation
  in `.transcription.json`, which also binds its voices and summary. Legacy files
  remain readable. Regeneration uses the background queue without capturing or
  merging again, preserves the previous version on failure, and never changes the
  default engine. Naming renders only the active generation.
- The speaker models are the documented exception to the checksum rule: they are
  several files each, fetched by FluidAudio from a pinned revision over HTTPS with
  a size check, and only from `SpeakerSetup.fetch` — the setup screen's Speakers
  row, Settings, or `anyrec speakers --download`. Transcription runs with
  `ModelHub.offlineMode` on and can never download.
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
- The on-device engine is Parakeet, and `auto` reaches for it first: Parakeet when its
  model is here, Apple's engine where that can run, whisper after that. It needs
  nothing installed — choosing it *is* the request for its model, so picking Parakeet
  in the panel or Settings starts the download, with the size on the choice, and ffmpeg
  comes with it when there is none, because the mix the engine is handed is made with
  ffmpeg. Parakeet tells the language itself, so none is detected for it beforehand,
  and the transcript carries none unless one was given. It is handed the whole file —
  a TDT model does not invent over silence as whisper does — and a line placed where
  nobody was speaking is dropped. Its words come with times and no lines; a line ends
  at a sentence end after a moment, at a pause of most of a second, or at twenty
  seconds, so attribution is never averaging two speakers. Whisper stays for its 99
  languages, and nothing about it is installed either: whisper.cpp is linked in as the
  xcframework its CI publishes on its nightly `b####` builds (the tagged releases carry
  none), pinned by build number and checksum in `Package.swift`, and only its model is
  downloaded. The framework is dynamic, so every binary that links the Kit ships with
  `whisper.framework` beside it — `Contents/Frameworks` in the app, `Frameworks` next
  to `bin` in the CLI tarball, which the formula installs into the prefix — with the
  rpath repointed from `.build` and the framework signed with the same identity, or the
  hardened runtime refuses to load it. Homebrew is needed for nothing.
- ffmpeg is fetched, not installed: a static GPL build from ffmpeg-static's releases,
  pinned by version and checksum per architecture, into the app's own tools folder,
  which `Muxer.ffmpegPath` tries after the package managers' paths. It has to be made
  executable and have the quarantine attribute removed, or Gatekeeper refuses to run
  what a download brought.
- A new install opens on the welcome window, once (`Preferences.welcomed`), and Help
  brings it back. Two steps cover all four permissions and on-device engine
  downloads. Screen Recording, Microphone, Accessibility and Notifications must
  be granted before setup can finish. Recording entry points also require completed
  setup. Other preferences stay in Settings and use their defaults.
  Screen Recording granted during a run takes effect for a newly
  launched process, so the window says so and offers a relaunch. Welcome is a
  separate window so it cannot block quitting. Finishing setup opens
  the library; later launches open the library directly.
- Voices travel as one file, `.anyrecvoices`: the library's people and prints as JSON,
  no audio. Importing adds the people a library does not have and the prints it does
  not have under names it does, so a team names each person once. File › Import and
  Export Voices, the People list and the welcome window all go through the same two
  panels on `RecordingController`.
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
