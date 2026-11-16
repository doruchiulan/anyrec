# anyrec

## Overview

macOS tool that records a call as three separate tracks: one window or display,
system audio output, and microphone input — or, audio only, the two audio tracks
with the window still picked but no picture kept. Beside the raw microphone it records
the same microphone through macOS voice processing (`microphone-clean.m4a`), echo
cancelled, which the mixes use when it carries sound. Built on ScreenCaptureKit, so no
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
- AppKit `NSStatusItem` with a SwiftUI panel — the menu bar helper
- swift-testing — tests
- ffmpeg (runtime) — merges the tracks into one file named after the call, which
  replaces `screen.mov` once verified, and makes the mix the engines
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
| `Session/TranscriptPass.swift`, `TranscriptPass+Review.swift` | The optional pass over closed files and the one sequence every interface runs: engines, voices and names, publish, review, name conflicts, summary. Returns an outcome; never throws. |
| `Session/SummaryPass.swift` | The summary step: written by label for unnamed speakers, with the basis it was written from, selected beside the transcript. |
| `Readiness/Readiness.swift` | What is installed and available here, and the single `Advisory` worth showing for a configuration. |
| `Capture/CaptureCatalogue.swift` | Every recordable window and display, in the order worth offering them. What the terminal picks from. |
| `Capture/PickedContent.swift` | What macOS's content picker handed back, read as a `CaptureTarget`. The inverse of `TargetResolver`. |
| `Session/RecordingLibrary.swift` | Every finished recording under the output folder, newest first, and which artefacts each has left. What the app's library window lists. `media` is what plays (`RecordingMedia.playable`); `video` is the same but nil for an audio-only recording. |
| `Session/RecordingMedia.swift` | Which file plays, which holds the picture, and what the merged file is called. `playable`: the name `recording.json` keeps if that file exists, else `call.mp4` (older folders), else `screen.mov`. `video`: `screen.mov` while it exists, else the merged file. `fileName`: "Design review – Slack – 2026-11-03 10.08.mp4" (`.m4a` audio only), title stripped of unread counters, a browser's "(3)" and a trailing app segment, characters Finder/zip/Windows mangle, capped. Every reader of a recording's media goes through it. |
| `Session/RecordingInfo.swift` | `recording.json`, written when a recording starts: the window's title, its app, the picture's size, and whether it is audio only (absent in older files, which read as video); after a verified merge, `mergedFile`, the merged file's name (absent before, and in older files); when capture stops, `timing` (`CaptureTiming`, absent in older files and ignored when unreadable). What the library titles a recording by. |
| `Session/Thumbnail.swift` | A still from a tenth of the way into the video, kept as `thumbnail.jpg`, for the library's list rows. None for an audio-only recording, decided from `recording.json` without trying. |
| `Session/Waveform.swift` | A recording's loudness cut into columns for drawing, read with AVFoundation so it needs no ffmpeg. |
| `Transcription/Summary.swift` | A summary as data (overview, decisions, actions with the second they were said), its `Basis` and `Staleness`, labels filled from names at display (`named`), `SummaryProvider` (Claude Code, Codex, OpenAI API, Gemini CLI) and `Summarizer.summary`. |
| `Recorder.swift` | Owns the `SCStream`, fans its three output types into three `TrackWriter`s — two for audio only, whose screen frames arrive at 2×2 and 1 fps and are dropped before the clock. Also runs `CleanMicrophone` and writes its buffers on the same queue, and notes each output's buffer stamps, formats and the devices into `CaptureTiming`. Follows device changes on its `devices` queue: moves the microphone (`updateConfiguration`), restarts the clean microphone, and restarts a stream a change stopped. |
| `MicrophoneRoute.swift` | Which device each microphone records from as devices come and go: the default followed, a picked one kept while connected, a vanished one replaced. Pure; says what has to move. |
| `DeviceWatch.swift` | Core Audio listeners on the default input, default output and device list. |
| `AudioBuffers.swift` | `CMSampleBuffer` ↔ `AVAudioPCMBuffer`, silence, and `AudioConformer`, which converts a buffer to a track's first format. |
| `CleanMicrophone.swift` | The microphone through `AVAudioEngine` voice processing (other-audio ducking at its minimum), stamped with the tap's host time, written as `microphone-clean.m4a`; reports its engine stopping on a configuration change; `usable` decides whether a recorded clean track can stand in for the raw one. |
| `CaptureTiming.swift` | Each output's first eight buffers (presentation time, host-clock arrival, length), its last and its count; the default output and input devices (name, transport, latency, safety offset, stream latency, buffer size) via `AudioDeviceFacts`; `stampingGap`; each `DeviceChange` (session-clock time, reason, devices before and after, streams affected, problem), and per stream the gaps written as silence and the formats it arrived in. Kept in `recording.json`; all of it optional. |
| `TrackAlignment.swift` | `TrackOffset` and its measurement, per stretch between device changes (`sections`): the change in log loudness, correlated over up to eight 50 s windows a stretch at lags within ±2 s, refined between frames, accepted only when strong windows agree, a straight line when they drift. `TrackShift`, the lag over the call. `AudioEnvelope.advanced(by:)`. |
| `EchoCheck.swift` | `EchoReport`: the offsets, echo left in the raw microphone, under the duck before and after alignment, in the clean track, the owner's level raw and clean, and the verdict. What `anyrec echo` prints. |
| `TimingCheck.swift` | The test signal and the offset read from a check's tracks, for `anyrec timing`. |
| `TrackWriter.swift` | One `AVAssetWriter` + input. Audio inputs are built from the first buffer's format description; later buffers are converted to it, and a gap in the stamps is written as silence. |
| `TargetResolver.swift` | `CaptureTarget` → `SCContentFilter` plus pixel dimensions. |
| `CallApps.swift` | The bundle-id registry that orders windows and puts the `*` marks in `sources`. |
| `ContentInventory.swift` | Read-only listing of windows and displays, filtered to what apps actually draw. |
| `AudioLevel.swift`, `LevelMonitor.swift` | Peak/RMS off the raw buffers; lock-guarded hand-off to the UI. |
| `MeterScale.swift` | Pure dBFS → bar/zone/verdict math. The tested part of the meters. |
| `Permissions.swift` | TCC preflight and status. |
| `Muxer.swift` | Builds and runs the optional ffmpeg merge. `job(for:)` takes the picture from `screen.mov`, or from the merged file once that has replaced it; with no picture it makes an audio-only `.m4a` from the same `MixPlan`. Writes a hidden temporary file, verifies it, moves it into place, records the name, then deletes `screen.mov` and any older merged file. |
| `MergeVerification.swift` | `MediaFacts` (video codec, size, frame count from a sample cursor, audio lengths, read with AVFoundation) and the check a merge's result must pass before it replaces anything. |
| `LoudnessMatch.swift` | Measures both audio tracks (ffmpeg `ebur128=peak=true`) and balances them for the merge. |
| `MixDecision.swift` | The mix decided once per recording and kept as `mix.json` beside the tracks, keyed to the tracks', the clean microphone's and `microphone-live.json`'s size and modification time: the system track's offset and the clean track's offset (each per stretch, version 3), which microphone is used, bleed, loudness. Also the mix's envelope worked out from the two (aligned) track envelopes. |
| `MixPlan.swift` | How the two audio tracks go together — each moved onto the raw microphone's timeline (`Alignment`), the raw or clean microphone (`MicrophoneTrack`), matched by loudness or the mic held under the call when it bleeds, and silenced wherever the call was not listening. Both mixes are built from it; `aligned` lines up the envelopes everything else compares. |
| `MicrophoneLive.swift` | When the call could hear the microphone: the monitor that watches the call app's mic for the length of a recording, and the file it leaves. |
| `AudioProcesses.swift` | Who is doing audio right now, read from Core Audio's process objects. The list behind the orange dot. |
| `MuteButton.swift` | The call app's own mute control, found in its accessibility tree and re-read four times a second. What Teams's mute is read from. |
| `CallWatch.swift` | A call starting, read as a known call app taking the microphone. What the menu bar's offer to record, and automatic recording, come from. |
| `AnyRecBar/CallReminder.swift` | A persistent Record/Audio Only/Dismiss banner above the focused Slack or Teams call window, with native notifications as fallback; `watch` is the same window search for automatic recording, handing the window over instead of showing the banner. |
| `AnyRecBar/CallAutoRecording.swift` | Whether a call is recorded without asking (Slack or Teams, switched on, window found, nothing recording) and when that recording stops (the call over for `endGrace`). Pure state; `AutomaticRecordingMode` is Window or Audio only. |
| `AnyRecBar/CallNotifier.swift` | The native notification fallback; Record and Record Audio Only open the capture picker. Also the automatic recording's started notification, whose Stop Recording stops it. |
| `AudioEnvelope.swift` | Loudness over time, as 20 ms frames. What bleed detection, speech detection and speaker attribution all read; the last few decoded are remembered by path, size and modification time. |
| `Transcription/DiarizationCache.swift` | Diarization segments and prints kept as `diarization.json`, keyed by a SHA-256 of the exact mix the diarizer heard. |
| `SpeakerBleed.swift` | Spots the call re-entering through the microphone, and words the warning for it. |
| `Shell.swift` | Child processes, via temp files rather than pipes. |
| `OutputPlan.swift` | The recording folder and the track paths, `microphone-clean.m4a` included. |
| `Transcription/Transcript.swift` | `Utterance`, turn folding, Markdown and SRT rendering. The tested part. |
| `Transcription/TranscriptStore.swift` | Publishes sources and layers, selects them, migrates older generations when changed, and renders Markdown and SRT. |
| `Transcription/TranscriptLayers.swift` | `SpeakerLayer`, `WordingLayer` and `RecordingTranscript`, the transcript as it reads now — what every interface shows. |
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
| `Transcription/Summarizer.swift` | Where the summary programs are found, and the timed transcript text they are handed. |
| `Transcription/TranscriptionOptions.swift` | Enabled engines, speakers on/off, review, and "review with a second engine" (the comparison engines), with the migration from Aggregator. |
| `Transcription/ParticipantAttribution.swift` | Call-window evidence over the voices: consistency scoring, agreement vs conflict, aliases, fused-voice facts, Call lines named, and the owner's voice given back to Me. |
| `CallParticipants.swift`, `ParticipantLabels.swift`, `TeamsParticipantLabels.swift`, `ParticipantMonitor.swift` | What the call window showed, polled once a second into `call-participants.json`; label shapes cleaned on parse and on read; the roster and readable time. |
| `Transcription/TranscriptReview.swift`, `ReviewPrompt.swift` | The optional LLM wording review: 30-line sections, three in flight, each reply a patch of the lines it changed. |
| `Transcription/SpeakerIdentityReview.swift` | Picks between competing candidate names for a voice, as its own step after wording review. |
| `Transcription/WhisperSetup.swift` | What is missing before whisper can run, and how to fetch it. |
| `Transcription/AssetDownload.swift` | Downloading a model, with progress and a checksum. |
| `Transcription/OpenAIKey.swift` | Where the user's key is read from and written to. |
| `Transcription/VoiceSeparation.swift` | The far end told apart on-device, whatever engine wrote the words: FluidAudio's segments and per-voice prints, lettered and laid over the lines. |
| `Transcription/VoiceLibrary.swift` | The people anyrec has been told the names of: one record each with aliases, voiceprints (each with its `PrintOrigin`, where known), the owner flag and the last display name a call window showed, and the cosine match against them; `retract` and `removePrint` take a print back out. |
| `Transcription/SpeakerNames.swift` | Speaker letters and `VoiceNaming`, which names voices in the speakers layer from any interface, records that the owner named them (`namedByOwner`) and what it filed (`Voice.filed`), files prints and aliases in the library, and takes back an earlier naming's (`takeBack`). |
| `Transcription/PersonCompletion.swift` | `PersonSuggestion` and the match of typed text against the library's people; `RecordingSpeakers.completions(for:typing:)` and `person(for:typed:)`, which the Speakers panel's name field and the terminal prompt complete from. |
| `Transcription/RecordingSpeakers.swift` | Every speaker in the current transcript, as the Speakers panel and the terminal show them: how each was named (`SpeakerBasis`), talk time, up to three `SpeakerClip`s, ordered `SpeakerCandidate`s with reasons, whether it is probably you (`YourVoiceEvidence`, `OwnerToRemember`), pending line corrections, Call lines nobody claims. `SpeakerEditing` names a whole voice, gives lines to another speaker, or gives a whole voice to Me, Call or another speaker (`give`, `giveToMe`), taking back what naming it filed and filing a voice given to Me under the owner; only the ticked remember-me writes the library's owner. |
| `Transcription/SpeakerSetup.swift` | Whether the speaker models are here, and the one place FluidAudio is let on the network to fetch them. |
| `anyrec/TUI/` | `Terminal` (raw mode, keys), `Picker`, `Page`, `SecretPrompt`, `SetupScreen`, `EngineSetup`, `RecordingScreen`, `TUISession`, plus `ConfigurationRows` and `CapturePicker` — the terminal's wording and layout for Kit types. |
| `anyrec/Report.swift`, `anyrec/TranscriptReport.swift` | Summaries, merge outcomes and transcript outcomes, as terminal text. |
| `anyrec/EchoCommand.swift`, `anyrec/TimingCommand.swift` | `anyrec echo` (the echo check for one recording, as text) and `anyrec timing` (a test signal through the speakers while recording, then the offset and the devices). |
| `anyrec/SpeakersCommand.swift`, `anyrec/SpeakerPrompt.swift` | `anyrec speakers` (with `--people` and `--remove-print` for the library's prints), and the plain-terminal questions that put names to letters after any transcript: clips, numbered candidates from `RecordingSpeakers`, or a typed name. |
| `AnyRecBar/StatusItem.swift` | The menu bar helper: the status item, its button drawn from the controller through Observation, and the panel hung under it with `MenuPanel` (`Anchor` is where it goes). |
| `AnyRecBar/RecordingController.swift` | The menu bar's whole state: settings, the live session, and what the last one left behind. |
| `AnyRecBar/RecordingJobs.swift` | Serial background processing, keyed by recording directory, independent of capture and the saved panel. Within one job the mix is decided first, then the merge and the transcript run side by side. |
| `Session/CapturedRecording.swift` | Finalized tracks and microphone timing, ready for merging after capture has been released. |
| `AnyRecBar/SystemPicker.swift` | macOS's on-screen content picker, and the configuration that holds it to windows and displays. |
| `AnyRecBar/Wording.swift` | The Kit's facts in the panel's words. The tested part of the app. |
| `AnyRecBar/Preferences.swift` | The few settings that survive a relaunch, mapped onto `UserDefaults`. The Kit has no opinion about persistence. |
| `AnyRecBar/Commands.swift` | The menu bar's File, View, Playback and Recording commands (Recording › Show Speakers scrolls the open recording to its Speakers panel). The open player reaches them as a focused value. |
| `AnyRecBar/Playback.swift`, `HotKey.swift` | One recording's player (the merged file, or the masters with a track silenced — the picture from `screen.mov` or, once that is gone, the merged file's video stream), which also plays a speaker clip's span and stops (`play(_:)`, `playingClip`), and the ⌘⇧R shortcut. |
| `AnyRecBar/Views/LibraryWindow.swift`, `RecordingDetail.swift` | The library window: filters, day-grouped list, and one recording's video (or, audio only, the app's icon and title above the waveform), summary and Speakers panel, with its transcript, tracks and files in the inspector; a transcript line's speaker label opens the same chooser as the panel. Reads files the Kit left; writes only who spoke (voice names and line speakers, via `SpeakerEditing`) and ticks on action items. Summaries are written by the Kit's `SummaryPass`, started by the pass or by `RecordingController`, which outlives the window. |
| `AnyRecBar/Views/SpeakersPanel.swift` | The recording page's Speakers panel (`SpeakerDesk` loads `RecordingSpeakers` off the main thread and makes the changes), the candidate chooser, `GiveToChoices` (Me, Call and the other speakers, for a row and for the popover), clip buttons, and `LineSpeakerChooser`, what a transcript label's popover shows. |
| `AnyRecBar/Views/ObservedParticipants.swift` | The recording's roster from the call window, with how long it was readable and the voice facts: the Speakers panel's last section, or a box of its own before there is a transcript. |
| `AnyRecBar/Views/AggregatorSettings.swift` | `ComparisonSettings`: "Review with a second engine" and which engines it runs. |
| `AnyRecBar/Views/WelcomeSheet.swift` | Two-step first launch: recording access, then on-device transcription downloads. Opens the library on completion; Help can reopen it. |
| `AnyRecBar/Views/` | `MenuPanel` and the three it switches between (`SetupPanel`, `RecordingPanel`, `OutcomePanel`), plus `SettingsWindow`, `LevelMeter`, `Notice` and `PermissionPanel`. System components throughout, except the recording page's cards and transport, which live privately in `RecordingDetail.swift`. |
| `scripts/bundle-app.sh` | Wraps the binary in `AnyRec.app`: bundle id, icon, mic usage string, signature. Universal for release, native for debug. |
| `scripts/embed-whisper.sh` | Copies whisper.framework beside a binary and repoints its rpath from `.build` to `@executable_path/../Frameworks`; both build scripts source it. |
| `scripts/signing.sh` | The identity both build scripts sign with, and the ad-hoc fallback when it is absent. |
| `Formula/anyrec.rb`, `Casks/anyrec-app.rb` | Reference copies of what the tap serves. The live ones are in `homebrew-tap`. |

Invariants worth preserving:

- What is derived from the audio is kept beside it and keyed to what it came from:
  `mix.json` to the tracks and the mute record, `diarization.json` to a hash of the mix,
  `waveform.json` and `thumbnail.jpg` to the recording. (The merged file is not one of
  these once it has replaced `screen.mov`: it then holds the only copy of the picture.) Each is deleted and made again
  freely, and none is ever used for audio it was not computed from. A pass decodes each
  track's envelope once and reads it for bleed, speech regions and attribution; speech
  regions come from the mix's envelope worked out from the tracks, not from decoding the
  mix. On the 76-minute call preparation went from 230 s to 30 s, and a regeneration with
  the diarization kept costs 10 s of preparation plus the engine.
- The merge and the transcript run side by side once the mix is decided; neither needs
  the other's output.
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
  table and session clock need no locking. Don't add a second queue for anything the
  writers own. The clean microphone's tap runs on the audio engine's thread and only
  copies each buffer and hands it to that queue; it is written there. Device changes are
  followed on `Recorder`'s `devices` queue, which owns the stream, the route and the clean
  microphone and never touches a writer, the clock or the timing facts except by handing
  work to the capture queue: starting a voice-processing engine can take most of a
  second, and the capture queue must not wait on it.
- All writers start their session at the *same* timestamp — the first
  buffer written on any ScreenCaptureKit output. Per-writer session starts would silently
  destroy A/V sync. The clean microphone never starts the clock: its buffers wait for it,
  so the clock, the timeline anchor and the participant times are what they were without it.
- The two audio tracks are lined up wherever they are combined or compared, and nowhere
  are the masters rewritten. ScreenCaptureKit stamps `.audio` and `.microphone` buffers
  differently: on a speakerphone Slack call the far end's echo in `microphone.m4a` sat
  505 ms *ahead* of the same words in `system-audio.m4a`, constant for ten minutes (it
  drifts by about 30 ms an hour); on a Teams call, 61 ms. An echo cannot precede its
  source, so this is stamping, not acoustics. Unaligned, the duck keyed on the system
  track opened half a second after each far-end phrase began: 29% of far-end moments
  carried echo less than 20 dB under the far end, and 24% of each phrase's first
  half-second less than 12 dB under it; aligned, 3–4% and 0–1%. `TrackAlignment` measures the lag from the
  echo: the frame-to-frame change in log loudness of each 20 ms envelope frame,
  correlated over up to eight 50 s windows at lags within ±2 s, the peak refined between
  frames. Changes rather than levels because turn-taking (mic loud while the call is
  quiet) drags a level correlation to zero. Echo windows correlate at 0.53–0.80, headphone calls at about
  0.05 and never above 0.27, so a lag is accepted only from windows above 0.35 when at
  least two and a third of all windows agree (within 40 ms) and they are most of the strong
  ones; otherwise "not measurable" and nothing moves. The lag is measured per stretch:
  the call is cut at the device changes in `recording.json` (`CaptureTiming.changeTimes`),
  since a change can move it, and each stretch gets its own windows (kept 2 s clear of its
  edges) and the rules above. Within a stretch it is a straight line when at least four
  windows agree around one and it moves more than 10 ms across the stretch (and less than
  0.5 s an hour); otherwise held. The measured drift is 12–34 ms an hour, so only calls
  past about twenty minutes follow it; on the ten-minute Cipri call forcing it on changed
  nothing in `anyrec echo` (−34.6 dB, 4%, 1% either way). A stretch with no echo
  (switched to AirPods) takes the lag its nearest measured neighbour has at their shared
  edge, so one measured stretch is one constant for the call, the simple case. Kept in
  `mix.json` as `TrackOffset.sections` (version 3; older versions are decided again, which
  is how existing recordings are lined up; an offset without sections reads as one lag).
  The *system* track moves (advanced by the lag, a `TrackShift`; a constant one trimmed or
  delayed in ffmpeg, a changing one restamped with `asetpts` and followed by
  `aresample=async=100:min_hard_comp=0.02:first_pts=0`, which cuts or pads a step over
  20 ms and resamples anything smaller; shifted on the envelope),
  because the microphone, the video and the call window's times share the clock, and the
  far end is then placed where it was heard in the room, which is where its lips are in a
  WebRTC call's video. The microphone stays fixed. Applied in both mixes' filter graphs, the bleed
  check, the mix envelope speech regions are found on, `SpeakerAttribution`, the owner
  merge, the echo check, and the masters player's call track (cut into held stretches no
  more than 5 ms off the line); the merge is verified against each track's
  length once moved. The echo check's mic-only ducked graph has no branch ending in a sink:
  with a drifting shift ffmpeg 7.1 asserted on one (`best_input >= 0`). The cause is not established. Each output's first buffer stamps
  against the host clock, and the default devices' reported latencies, go into
  `recording.json` (`CaptureTiming`). On the machine they were checked on, ScreenCaptureKit
  stamps on the host clock (screen frames arrive within a few ms of their stamp, audio
  about 36 ms after). The built-in microphone reports 61.7 ms of total latency, which is
  the Teams call's offset, but nothing confirms that call used it. Until a speaker
  call's timing facts tie the offset to a device figure, it is measured from echo only.
  Headphone recordings have no echo to measure from, so they are not moved.
- The microphone is recorded twice when echo cancellation is on (the default; Settings ›
  Recording, kept in `Preferences`; `anyrec record --no-echo-cancellation`): raw by
  ScreenCaptureKit, which stays the master, and through `AVAudioEngine` with voice
  processing on, as `microphone-clean.m4a`. This is the same approach as a browser's
  `echoCancellation`, with the system audio still captured untouched. Other-audio ducking is set to its
  minimum, advanced ducking off, so the call is not turned down. The clean track is on the
  same device as the raw one (`kAudioOutputUnitProperty_CurrentDevice`, or no clean track),
  folded to mono through a silent mixer. The main mixer connects to the output explicitly
  at the microphone rate: mismatched client rates make VoiceProcessingIO fail with -10875.
  The live regression is `ANYREC_LIVE_AUDIO_TEST=1 swift test --no-parallel --filter VoiceProcessingFormatTests`.
  Clean buffers are stamped with the tap's `AVAudioTime.hostTime`
  (the mach clock ScreenCaptureKit's stamps are on), and lined up against the raw track
  afterwards from the owner's voice, which both carry (`cleanMicrophoneOffset`, per stretch
  like the system track's, because a restart on another device brings another latency),
  because voice processing's own latency may not be in the stamp. Failing to start costs the
  recording nothing: the reason goes into `CaptureTiming.cleanMicrophoneProblem`.
  `AVAudioEngine` stops itself on any device configuration change (the default input or
  output moving, the device going) and never restarts; `CleanMicrophone` reports it and the
  recorder starts a new engine on the raw microphone's current device, writing on into the
  same file on the same clock (see the device-change invariant). When
  the clean track carries sound (`CleanMicrophone.usable`: loud enough, 90% of the raw
  track's length, not 30 dB quieter), both mixes and attribution use it instead of the raw
  track, and the duck applies only if the bleed check still finds echo in it. Otherwise
  the raw track is used as before. `anyrec echo` reports the echo left each way and the
  owner's level change, for the owner's rule: if cancelling at capture beats the aligned
  duck, nothing more is built after the fact (no offline canceller, no reworked duck).
- A device change during a recording never restarts the session, starts a new writer or
  ends the recording. What follows: the raw microphone follows the system default input
  when nobody picked one (`RecordingConfiguration.followsDefaultMicrophone`, set by
  `pinDefaultMicrophone`, cleared by `selectMicrophone`, the app's microphone setting, the
  TUI's picker and `--mic`); a picked device is kept while it is connected. A microphone that
  disappears moves to the default input, else the device it is on, else the first input
  left, and a picked one moves back when it returns (`MicrophoneRoute`). The clean
  microphone always goes where the raw one goes. The output is never followed: ScreenCaptureKit takes
  app audio before any output device; checked live by switching the default output twice
  during an audio-only recording, the system track's stamps ran on with no gap and the
  file was as long as they span (the playing app, afplay, went silent for a moment at each
  switch, which is what it rendered). An output change is still recorded and still a
  stretch boundary, because the echo's path changes.
  How: `DeviceWatch` listens on the default input, default output and device list; the
  recorder reads the devices 0.3 s after the last notification and asks the route. The raw
  microphone is moved with `SCStream.updateConfiguration` on the running stream (the SDK
  header limits no property; if refused, microphone capture is switched off and on with the
  new device). 2.5 s later the buffers are checked: a microphone that delivered before and
  has delivered nothing since, or one still at the old device's rate when the new device
  runs at another (ScreenCaptureKit delivers a microphone in its device's own format),
  did not move, and the stream is started again. A stream that stops with an error while
  its microphone has gone, within 10 s of a change, or with
  `failedToStartMicrophoneCapture` is started again too: a new `SCStream` with the same
  filter and outputs on the same capture queue, on the device the route names now, without
  the microphone if that will not start, at most five times a recording. If it cannot be
  started at all, the recording *ends* there (`RecorderError.deviceChangeEnded`, reported
  like a closed window), never fails. The clean microphone restarts at most twenty times.
  Gap as silence: AVAssetWriter packs audio back to back whatever the stamps say (measured:
  5 s, a 2 s gap in the stamps, 5 s, and the file ran 10 s with no silence), so without
  help a microphone that paused to switch would pull everything after it early. Every audio
  `TrackWriter` writes a gap of more than 50 ms between one buffer's end and the next
  one's stamp as that much silence, skips a buffer stamped wholly inside what is already
  written, and converts each buffer to the track's first format (`AudioConformer`):
  measured, 24 kHz buffers appended to a 48 kHz track were encoded at double speed, and
  mono to stereo failed the writer and left a file with no `moov`. Bluetooth inputs change
  both. Small jitter is left alone, so a track's timeline is what it was before.
  Facts: each change goes into `recording.json` as `CaptureTiming.DeviceChange` (seconds on
  the session clock, reason — `default-changed`, `device-gone`, `device-back`,
  `output-changed`, `clean-interrupted`, `stream-restarted` — input and output before and
  after with name, transport and reported latencies, the streams affected, and any
  problem), with each stream's `gaps` and `formats`; `anyrec echo` prints them. All optional;
  older files read without them. The alignment measures each stretch between these times on
  its own (see the alignment invariant). Mute and call watching are untouched by it:
  `MicrophoneLive` and `CallWatch` read the call app's process, not a device; a call app
  that lets go of the microphone while it switches reads, for that moment, as not
  listening (true: the call heard nothing) and as `.ended` then `.started` for the same app,
  which an automatic recording rides out within `endGrace` (10 s); released for longer, it
  stops, as for any call that ended. Not verified live: whether `updateConfiguration`
  really moves ScreenCaptureKit's microphone, and what ScreenCaptureKit does when the
  microphone vanishes. The terminal this was built in had no microphone grant.
- Audio only still picks a window (or a display), and still captures it. The window's
  filter is what carries the call's sound; its title and app go into `recording.json`;
  its accessibility tree is where the participant monitor reads names and where
  `MuteButton` reads mute. Recording "just audio" from no window would lose all four.
  `RecordingConfiguration.video` is off for the recording and never persisted;
  `recording.json` carries `audioOnly` so the library and player know without probing.
  ScreenCaptureKit needs a screen output even then — leave it out and every frame is
  logged as "stream output NOT found. Dropping frame" — so the screen output is added
  at 2×2 pixels and one frame a second, and `Recorder.accepts` refuses those frames
  before the session clock or the timeline anchor is touched, and before any screen
  `TrackWriter` could be made. The clock therefore starts at the first audio buffer
  written, and the audio tracks and the participant times share it exactly as they
  share it with video. The merge makes a named `.m4a` from the mixed audio alone, found
  through `RecordingMedia` like any merged file; no thumbnail is made or retried. Video off with
  both audio tracks off is refused (`SessionError.noTracks`), because it would record
  nothing.
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
- `RecordingController` is owned by the app delegate, never by a view, and so is
  `StatusItem`. The panel's `MenuPanel` is made afresh each time it opens and torn down
  when it closes, and a recording has to outlive that.
- The menu bar helper shows a panel, not a menu, which the HIG allows only for
  functionality a menu cannot carry — live meters are that. It is an AppKit
  `NSStatusItem` and a borderless non-activating `NSPanel` hosting `MenuPanel`, not
  SwiftUI's `MenuBarExtra`: a `MenuBarExtra` cannot be opened from code (its button has
  no action or target, and synthetic clicks either did nothing or hung the main thread
  in its tracking loop), so a launch by hand had nothing to show. The panel hangs from
  the bottom of the menu bar under the icon, its leading edge at the icon's and kept on
  the screen; on another display it opens under the pointer in that display's menu bar,
  because the system draws a copy of the item there while the button's own window is on
  one screen. The icon's window starts somewhere arbitrary and is moved into the menu bar
  after launch, so nothing hangs from it until it reaches the top of its screen and holds
  still. The panel grows downwards with its content (`NSHostingController`'s preferred
  size, applied a turn of the run loop later), closes when it loses key status, on a
  click in another app (a global monitor), on Escape and on a Space change, and never
  activates the app: the app in front keeps its menu bar. Pressing Record closes it
  before macOS's picker comes up (`willPresentPicker`). Nothing in the panel may use
  SwiftUI's scene environment: it is outside every scene, where `openWindow` and
  `openSettings` do nothing, so it goes through the `openLibrary` and `openSettings`
  closures `AnyRecCommands` leaves on `RecordingController`.
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
- The idle panel offers Record Window, Record Audio Only and recent recordings. The two
  Record commands are the whole choice — there is no video switch or sheet before the
  picker — and both are also in File (New Recording… ⌘N, New Audio-Only Recording…
  ⌥⌘N), the Dock menu and the call banner; ⌘⇧R is Record Window. Both go through the
  one `RecordingController.pickAndStart(video:)` / `start(video:)` path. Microphone,
  transcript, stop time and system audio live in Settings. The app always merges the tracks,
  so `screen.mov` is always replaced by the named merged file once it is verified;
  merging is not a user option. `anyrec record` keeps the flags (`--no-mux` keeps
  `screen.mov` and makes no merged file).
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
- The app is a regular app (Dock icon), not an `LSUIElement` agent, and closing the last
  window must not quit it: `applicationShouldTerminateAfterLastWindowClosed` is false,
  because a recording and the menu bar helper outlive the window. The library window is
  not opened at launch (`.defaultLaunchBehavior(.suppressed)`, and `.restorationBehavior(.disabled)`,
  or macOS reopens it when it was open at quit): people work from the menu bar, and a
  window at every launch was one more thing to close. A launch by hand, once setup is
  complete, drops the menu bar panel open instead, so starting the app is not invisible;
  with the menu bar item switched off (or nowhere on screen) it opens the library. A
  launch at login opens nothing — told apart by the launch event's `keyAEPropData` being
  `keyAELaunchedAsLogInItem`. Before setup the welcome window is the whole launch. The
  library opens from the Dock icon, the helper's Open AnyRec and the Window menu. A
  `Window` scene suppressed at launch is not reopened by a Dock click on its own, so
  `applicationShouldHandleReopen` opens it when nothing but the panel is on screen
  (closing the panel), through the `openWindow` the menu bar's commands leave on
  `RecordingController` (`openLibrary`) — commands are built at launch, the window's
  views are not.
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
  summed — and like `mix.json` it is derived: delete it and it is made again.
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
- The menu bar item can be switched off (Settings › General), because whether an
  item is in the menu bar is the person's call, and the system hides items when the
  menu bar is full. The switch sets the status item's `isVisible` live, and ⌘-dragging
  the item out of the menu bar (`.removalAllowed`) turns the switch off. The Dock menu
  carries New Recording and Stop Recording for that reason.
- Persistence belongs to `AnyRecBar`, not to the Kit. A recording is configured from
  nothing every time; an app that sits in a menu bar for days is what needs to
  remember. `Preferences` maps a handful of fields onto `UserDefaults`, and the
  microphone is stored as a device id and re-resolved, because the device it names
  may be in a drawer by the next launch.
- The microphone is saved when it is *chosen*, never when it is resolved, which is why
  the panel binds `controller.microphoneChoice` rather than `configuration.microphone`. Both
  launch and reopening the panel resolve the stored id against what is plugged in, and
  a resolution that found nothing writing itself back would forget a headset for good
  the first time it was unplugged. An empty stored id is Off — a choice — as against
  no id at all, which is why `pinDefaultMicrophone` is skipped for the first and not
  the second. A microphone nobody picked is pinned again from the current default each
  time the panel reopens, because it stands for "the default", which may have moved since
  launch; one picked is only re-resolved. Choosing "System default" in Settings clears
  the saved device and restores following the default input. Off remains a separate choice.
- The meters poll at 10 Hz; the menu bar clock is held as text and only assigned
  when the second changes, so the status item redraws once a second rather than
  ten times. `StatusItem` reads the controller's `clock`, never `tick`, inside
  `withObservationTracking` (re-armed after each change) and sets the button's image and
  title only when they differ from what it shows. Don't drive the label off the tick.
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
- The audio tracks are masters and are never rewritten: `microphone.m4a`,
  `system-audio.m4a` and `microphone-clean.m4a`. The alignment, the choice of microphone,
  the loudness match and the mix exist only in the merged file and the transcript's mix. The video is stored once. `screen.mov` is the
  picture's master only until a merge is verified: the merge stream-copies its video
  (never re-encodes it) beside the mix into a hidden temporary file, and checks with
  AVFoundation that the result has exactly one video stream with `screen.mov`'s codec,
  size and frame count (or its duration within a frame) and one audio stream as long as
  the longest track (±0.5 s). Only then is the file moved into place under its name,
  the name written to `recording.json`, and `screen.mov` deleted — in that order, so
  an interruption leaves at worst a stray `.merge-*` file and a playable folder. From
  then the merged file is the video master. A re-merge (a retried job, a new mix
  decision, a changed `microphone-live.json`) copies the video from it, verifies against
  it, and replaces it atomically: there is always one verified file holding the picture.
  A failed merge, missing ffmpeg or `--no-mux` leaves `screen.mov` as it was. Older
  folders with `call.mp4` beside `screen.mov` are read unchanged and never migrated; one
  merged again follows the new rule, and both are replaced by the named file. Verification
  uses AVFoundation, not ffprobe, because the static ffmpeg anyrec fetches comes without
  ffprobe; a sample cursor counts frames from the sample table without decoding.
  Copied HEVC is tagged `hvc1`, because AVFoundation will not play `hev1`.
- The merged file is named from `recording.json` — the title without unread counters
  or a trailing app segment, the app, and the start from the folder name, as
  "Design review – Slack – 2026-11-03 10.08.mp4" — and the name is kept in
  `recording.json`, which every reader resolves through `RecordingMedia`, never by
  naming a file. A later merge keeps the stored name. A folder without `recording.json`
  has nowhere to keep one, so its merge is `call.mp4`. Recording folders keep their
  `rec-YYYY-MM-DD-HHMMSS` names. Slack's workspace segment stays in the name: nothing in
  the title marks which segment it is.
- Loudness is measured with `ebur128=peak=true`, not `loudnorm`'s analysis pass: the same
  integrated loudness and true peak in about a seventh of the time.
- Balance by loudness, never by peak: speech peaks as high as continuous call
  audio and averages ~13 dB below it, so peak-matching leaves the mic buried.
- Speaker bleed is checked before the mic is boosted, on the aligned envelopes of the
  microphone the mix uses (the clean one when it is used), and a bleeding mic is held
  under the call rather than summed with it. On speakers the far end is already in
  the mic track: boosting it doubles the echo, and summing it as-is hands the engine
  every word twice — a 5-minute call came back as 503 lines over six "speakers",
  each sentence shared out word by word between the wire's copy and the room's. The
  duck is a sidechain compressor keyed on the system track, so it needs no estimate
  of how loud or how late the echo is; measured at −39 dB under the far end and
  0 dB where the call is silent. What it costs is anything said over the other
  side. Both mixes decide this once, through `MixPlan.decided(for:)`, which keeps the
  answer as `mix.json` beside the tracks — `mix.wav` used to skip the bleed check and
  boost the echo by the loudness difference, and later the two each measured the tracks
  with `loudnorm`, 186 s apiece on a 76-minute call. Bleed is detected as
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
- A call is detected the way mute is, and offered rather than acted on — unless the
  owner switched on automatic recording, which only Slack and Teams with a found window
  get. `CallWatch` reads Core Audio's process list every two seconds; a known call app
  running microphone input is a call beginning (Teams holds it from the join, muted or
  not), and its release is the call ending. Slack and Teams get a persistent banner above
  the focused call window, found through its mute control. It follows the window
  and hides when another window is focused. If there is no room above, it sits just
  inside the top edge. Other apps or an unidentified call window use a notification.
  The banner's Record and Audio Only buttons start its call window directly, matched by
  process, bounds and title, with ownership checked again before capture. Missing or
  ambiguous windows are rejected. Notification fallbacks (Record, Record Audio Only)
  still open the picker; Dismiss suppresses the offer for that call.
  Starting a recording or ending the call removes the reminder. An
  app testing its microphone looks like a call, which is why nothing records until
  the button is pressed. One offer per call, withdrawn when it ends, only while
  idle, off in Settings › General. Notifications are asked for the first time
  there is one to show, so the dialog arrives with its reason in view.
  "Record Slack and Teams calls automatically" (Settings › General, off by default,
  with Window or Audio only beside it, both in `Preferences`) skips the banner: while
  idle with setup complete, a Slack or Teams call's window is looked for by the banner's
  own search (`CallReminder.watch`) for as long as the call lasts, and the moment it is
  found and captured-checked it starts through `RecordingController.start(video:)`, with
  a notification that says so and carries Stop Recording. The notification offer still
  appears after three seconds without a window (when offers are on) and is withdrawn if
  the window turns up. Other apps keep the offer because there is no window to be sure
  of: an app's display recorded unasked, or a guessed window, is not something to start
  on a microphone grab. Only a recording started this way is stopped by the call ending,
  and only after the microphone has stayed released for `CallAutoRecording.endGrace`
  (10 s): a headset reconnecting or the app restarting its audio drops the microphone for
  a moment, and a call cut in two is worse than ten seconds of silence at its end. The
  call taking the microphone back within that cancels the stop. A window closing ends it
  as `noCaptureSource` like any recording. A manual recording, or one already running or
  saving, is never started over or stopped. The decisions are `CallAutoRecording`, pure
  state the controller feeds, and are tested without a call. Turning the switch on
  mid-call applies from the next call; off while looking hands the call to the offer.
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
  envelopes, aligned and of the microphone the mix used, over each line's span, so attribution stays exact without the engine
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
  is its print, the speakers layer keeps each letter's print beside the
  tracks, and naming a letter — `anyrec speakers`, the prompt after a transcript,
  the Speakers panel — files the print under the name in
  `~/Library/Application Support/anyrec/voices/`. The next recording matches every
  voice against the library by cosine similarity and names what it recognises.
  Nothing caps the library: OpenAI's known-speaker references stop at four, which
  is why they are not used — a meeting here can be twenty people. The 0.5 match
  threshold is provisional, set from FluidAudio's own table, and only ever moves
  up until it has been measured on real calls: the wrong name is the worse mistake.
- A print is filed only by the owner: naming a whole voice, or giving one to Me. And
  what a naming filed can be taken back, because a wrong pick otherwise goes on matching
  that voice to that person on every later call — the owner once picked a "sounds like"
  name for their own voice, and the other person's record then held the owner's print.
  The voice records what its naming filed (`Voice.filed`: saved name, whether the record
  was made by it, the alias it added). Renaming an owner-named voice, or giving all its
  lines to Me, Call or another speaker (`SpeakerEditing.give`), first removes that exact
  print and that alias (`VoiceNaming.takeBack`); prints from other recordings are never
  touched; a voice named before `filed` existed is looked up by name and only its exact
  print removed. A record left empty is removed only when that naming made it; a person
  who existed before is kept, empty or not. Given to Me, the print joins the library
  owner's record, and with no owner it is filed nowhere. A print a person already has is
  not filed twice. Each print filed carries a `PrintOrigin` (recording folder, when;
  nil folder for an import), older files read without it ("earlier") and exports leave
  it out; People in Settings, a People row's context menu and `anyrec speakers --people`
  / `--remove-print` list a person's prints and remove one.
- Speakers are checked and changed in one place: the recording page's Speakers panel,
  and the same chooser behind every speaker label in the transcript. It lists every
  speaker with lines, Me included, those needing a look first (unnamed, conflicting,
  possibly two people, with pending line corrections, or probably you), each with how it was named,
  its talk time, up to three clips, candidate names and the review's corrections of its
  lines; then the Call lines no voice claims and the call window's roster. Every row
  but Me, once expanded, also offers "Or give every line of … to" Me, Call and every
  other speaker — `GiveToChoices`, the same component as the label popover's "Or give it
  to" — through `SpeakerEditing.give`; Me is left out of it where the names above
  already offer Me, so a probably-you row keeps its one Me button and remember tick. It
  replaced the naming card, the corrections card and the roster card. Nothing in it
  sends anything anywhere or calls a model.
- A clip is a line of that speaker at least 2 s long that no other speaker's line
  overlaps and that has no pending correction, at most 8 s, centred in the line; up to
  three, one from each third of the call where one qualifies. Playing one plays exactly
  its span and stops (a boundary observer, removed by any seek, toggle or other clip),
  and its line lights up through `currentLine`. A voice's longest line is no longer its
  sample: it played on into the next speaker and was the line most likely to hold two.
- Candidate names come from `RecordingSpeakers`, the same list for the app and the
  terminal, best first: the call window's names for the voice (with "only one left" —
  the one roster name not yet given to a voice or the owner — ahead of them when the
  call window named nobody for this voice, and right after when it did), the library
  match (shown name) and the review's resolution, names the voice introduced itself
  by, the rest of the roster, the Slack title's first segment (Slack only), and up to
  two saved voices with similarity in [0.3, 0.5) worded as a question — only people in
  the roster when the call window was readable for at least half the recording, since
  anyone else was not in the call. A name another
  speaker carries (by any of a person's names), the owner's names and the speaker's
  own name are never offered, and one person is offered once.
- A speaker is probably you (`YourVoiceEvidence`, read at display time so it holds for
  transcripts from before the owner merge) when its name or saved person is the library
  owner, its saved person answers to the owner's name in the call window (their tile, or
  whoever it showed during Me lines), or the window showed the owner for most of its
  indicated time. Its first candidate is Me (`.yourVoice`), which gives every line to Me
  (`SpeakerEditing.giveToMe`); it counts as one to check and is offered no sounds-like
  names. On call-window evidence, with no library owner yet and a name the owner did
  not type, a "Remember <name> is me" tick beside Me (on by default) also sets that
  person as owner and files the window's name as their alias. The owner flag is never
  set without that tick; the terminal never sets it. A real Slack 1:1 showed the owner's
  own voice as a third speaker offered two strangers from other calls and no Me. Picking a whole-voice
  name goes through `VoiceNaming` and marks it `namedByOwner` ("named by you"); the
  call window's name is learned as an alias only for a typed name or the call window's
  own. Giving one line to Me, Call or another speaker changes the speakers layer only;
  giving every line of a voice also takes back what naming it filed (and files it under
  the owner when given to Me); either way the summary then says it is stale. Naming keeps the
  voice's identity evidence (conflict cleared) so its candidates survive for "Change…".
- A typed name completes from everyone already named (`RecordingSpeakers.completions`,
  matching in `PersonCompletion`), the same list for the "Someone else…" field — the
  panel's and the transcript label's, a native `textInputSuggestions` list — and the
  terminal prompt. Every name a person answers to is matched (shown, saved, aliases,
  display name) ignoring case, diacritics ("ș", "ş" and "s" alike) and spacing: a
  whole name first, then the start of any word, then anywhere, each tier nearest voice
  first. The owner, people another speaker carries and the speaker's own person are left
  out unless the text is exactly one of their names; with nothing typed, the saved voices
  nearest this one, with no threshold. A name that is exactly one person's
  (`person(for:typed:)`) — what a picked completion fills in — is filed under that
  person's saved name through `SpeakerEditing.name(…, person:)` and `VoiceNaming`'s
  `people`, never as a new record, even when two people are shown under one name; the
  terminal lists matches as numbered choices first and uses a unique exact match
  directly. A name nobody answers to is a new person. The call window's alias is filed
  under the saved name the print went to. Nothing in it calls a model.
- A person is one library record: saved name, aliases, prints, owner flag, and the
  display name a call window showed most recently. A call window's display name that
  corroborates a voiceprint match is agreement, filed as an alias and as that display
  name (names only — call evidence never enrols a print); it is a conflict only when
  the display name belongs to someone else or two compete. The saved name stays the key
  the library is filed and matched under, but transcripts call a person what the call
  window showed in this recording, else the display name learned on an earlier call,
  else the saved name — so a nickname typed once ("Andi") reads as the call's name
  ("Andrei Lungu") from then on, even in calls whose window was unreadable. A name
  typed for a voice in a recording beats all three. Names are settled when a
  transcript is written; older transcripts keep theirs. Old library files and
  `.anyrecvoices` read without aliases, owner or display name; exports carry the
  display name but never the owner flag, and an import never replaces a display name
  already learned.
  Call evidence is scored by consistency where it exists, not by coverage: the Slack
  windows in real calls were readable for 13 s and 106 s, and a coverage rule threw
  away evidence that pointed at exactly one person per voice. Polls marking several
  people agree with a name but never supply one.
- The owner is never two speakers. A diarized voice that is the microphone's speaker
  (mostly inside measured "Me" lines, the library owner's print, or the owner's display
  name in the call window) gives its lines back: to the person the window showed when
  it showed only someone else; to "Me" when the microphone was live (`microphone-live.json`,
  four fifths of the line) and either carried speech or the window showed the owner
  speaking; otherwise to the call. The window's clause is for speakerphone: a bleeding
  microphone is held under the call, so the duck holds it down exactly where the owner
  talks over or straight after the far end, and "carrying speech" (judged on what the
  mix heard) failed on every line the diarizer heard as the owner — a Slack 1:1 sent all
  five to Call; now four go to "Me". Never "Me" while the window showed someone else or
  the call could not hear the microphone. A real 1:1 had 16 lines as "Me" and 11 under
  the owner's own nickname. A display name the window showed for the owner is never
  filed as the alias of a non-owner whose print a voice matched.
- A transcript is layers, each a file recording what it was built from: sources
  (`transcript-<engine>-<UUID>.json`, one per engine run, never rewritten), speakers
  (`speakers-<UUID>.json`: per-line speakers when they differ from the source, voices,
  decided suggestions), wording (`wording-<UUID>.json`: review changes to specific
  lines, what was compared, suggestions, failures) and the summary (with its basis).
  `.transcription.json` selects one of each; files are complete before they are
  selected and nothing selected is deleted, so older versions stay viewable ("View
  Sources" lists every source). Naming a voice, accepting one speaker correction or
  re-running review changes one layer — the summary is no longer dropped by a
  correction. Markdown, SRT, the app and MCP render from `RecordingTranscript`.
  Generations from before layers and recordings without a selection read unchanged and
  are migrated (their transcript becomes the source, their summary stays selected) only
  when the owner changes something. Regeneration uses the background queue without
  capturing or merging again, leaves the previous selection on failure, and never
  changes the default engine. A review used to embed every engine's transcript in each
  review file and republish a whole generation per correction.
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
  the library; later launches open no window.
- Voices travel as one file, `.anyrecvoices`: the library's people and prints as JSON,
  no audio. Importing adds the people a library does not have and the prints it does
  not have under names it does, so a team names each person once. File › Import and
  Export Voices, the People list and the welcome window all go through the same two
  panels on `RecordingController`.
- Review cannot fail structurally. A reply is a patch (`changes`: id and text of the lines
  the model changed); a missing line is unchanged and an id outside the section is
  ignored. A section with no usable reply keeps its lines and is recorded by range; the
  review fails only when no section could be used. Name-conflict resolution is a
  separate step that runs whether or not wording succeeded. Both long real calls lost
  their whole review to one section that did not restate all thirty lines exactly.
- Nothing leaves the machine unless it was asked for by name. `--engine openai`,
  review and `--summarize` are the only ones that do, and each says where the text or
  audio goes wherever it is offered. A comparison engine is OpenAI only when it is both
  enabled and checked.
- There is one pass. The app, `anyrec transcribe`, `anyrec record` and the TUI all run
  `TranscriptPass`: engines, voices, publish, review, name conflicts, then the summary
  through `SummaryPass`. Before this, `transcribe` bypassed the pass and used a
  Markdown prompt that forbade naming speakers, and the app summarised from the
  controller once, before anyone was named, so owners read "Speaker A" for good.
- A summary refers to unnamed speakers by label and is shown with the current names
  filled in; it records the transcript digest and the names it was written with, and is
  stale — said, with an offer to refresh — when either changes. A summary without that
  basis is shown as it is and never called stale.
- Other engines run only for a review that compares them ("Review with a second
  engine"). The chosen engine always writes the transcript; Aggregator, which picked a
  primary by fixed order before anything was compared, is migrated to this. `auto` must stay local-only: falling back to an upload because a model
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
- `ANYREC_VOICE_LIBRARY` points the voice library at another folder. It exists so a replay
  against copies of real recordings can run without writing aliases into the owner's
  library; tests pass a library folder explicitly instead.
