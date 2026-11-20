# Website fact check

Initial check on 2026-10-24 against the working tree and installed AnyRec app. Speaker workflow rechecked against current source on 2026-11-20.
The website describes current behavior; it does not promise planned features.

## Implementation evidence

Paths below are relative to the repository root.

| Topic | Website claim and limit | Evidence |
| --- | --- | --- |
| Compatibility | macOS 15.2+; Apple transcription needs macOS 26 and a supported locale | `Package.swift`, `Sources/AnyRecKit/Transcription/AppleTranscriber.swift` |
| Setup | Screen Recording, Microphone, Accessibility, Notifications; processing tools and models may need downloads | `Sources/AnyRecBar/Views/WelcomePermissions.swift`, `Sources/AnyRecKit/FFmpegSetup.swift`, `Sources/AnyRecKit/Transcription/WhisperSetup.swift` |
| Call reminders | Microphone activity triggers an offer; supported Slack/Teams windows can record directly; fallback notification opens a picker | `Sources/AnyRecKit/CallWatch.swift`, `Sources/AnyRecBar/CallReminder.swift`, `Sources/AnyRecBar/CallNotifier.swift` |
| Mute tracking | Supported Slack/Teams controls inform the mix. Original mic audio remains unchanged. Missing tracking or single-track transcription does not guarantee exclusion | `Sources/AnyRecKit/MicrophoneLive.swift`, `Sources/AnyRecKit/MixPlan.swift`, `Sources/AnyRecKit/Muxer.swift`, `Sources/AnyRecKit/Transcription/AudioMix.swift` |
| Audio balance | Both tracks are measured; detected bleed can lower the mic while call audio plays, including overlapping local speech | `Sources/AnyRecKit/MixPlan.swift` |
| Stop behavior | Losing the captured window stops recording; hanging up with the window open or recording a display is different | `Sources/AnyRecKit/Recorder.swift` |
| Background work | A saved recording can continue processing while another starts | `Sources/AnyRecBar/RecordingJobs.swift`, `Sources/AnyRecBar/Views/OutcomePanel.swift` |
| Languages | Parakeet lists 25 languages; the installed Whisper engine lists 100, including Cantonese | `Sources/AnyRecKit/Transcription/TranscriptionLanguages.swift`, installed app engine-info popover |
| Automatic engine | Uses an available enabled local engine; does not test Parakeet language support first | `Sources/AnyRecKit/Transcription/TranscriptionService.swift` |
| Parallel and review | Parallel transcription and LLM review are separate, default-off options | `Sources/AnyRecKit/Transcription/TranscriptionOptions.swift` |
| Speaker recognition | Downloaded local models separate voices and match saved voiceprints. People in this call lists who spoke and shows one question at a time when a name needs checking. Unresolved speech can remain under “Not sure who”. | `Sources/AnyRecKit/Transcription/SpeakerSetup.swift`, `Sources/AnyRecKit/Transcription/SpeakerRecognition.swift`, `Sources/AnyRecKit/Transcription/PeopleQuestions.swift`, `Sources/AnyRecBar/Views/PeoplePanel.swift` |
| Summaries | Overview, decisions, and action items; timestamped items seek playback, checkboxes track completion | `Sources/AnyRecBar/Views/RecordingDetail.swift` |
| Summary default | Automatic summaries default on and can use an available provider; review is separately opt-in | `Sources/AnyRecBar/Preferences.swift`, `Sources/AnyRecBar/RecordingController.swift` |
| Privacy | Local engines process audio locally; OpenAI receives audio; summary/review providers receive transcript text | `Sources/AnyRecKit/Transcription/TranscriptionService.swift`, `Sources/AnyRecKit/Transcription/LLMClient.swift`, `Sources/AnyRecKit/Transcription/Summary.swift` |
| Files | Originals retained; combined video; Markdown, JSON, SRT transcripts; regeneration in app | `Sources/AnyRecKit/Muxer.swift`, `Sources/AnyRecKit/Transcription/TranscriptStore.swift`, `Sources/AnyRecBar/Views/RecordingDetail.swift` |

Mute tracking also watches other recognized apps using the microphone. Their
activity can keep it live. It is not a privacy guarantee that all muted speech
will be excluded. The previous illustrated “muted, left out” transcript row was
removed because the app does not render that row.

The installed settings UI says OpenAI uploads both tracks, while the current
source prepares mixed audio. Website copy says “sends audio” without promising
that older detail. Installed-app captures do not prove source/build parity.

## Screenshot provenance

All product screenshots are native captures. No compositing, cropping,
retouching, or replacement UI was applied. The JPEGs came from the installed
app during the original 2026-10-24 capture session.

| Asset | Captured content |
| --- | --- |
| `assets/general-settings.jpg` | Actual General settings, 1080 × 652 |
| `assets/transcription-settings.jpg` | Actual engine and review settings, 1080 × 1416 |
| `assets/recording-library.jpg` | Earlier library with a staged sample, 2808 × 1758. Superseded by the PNG. |
| `assets/recording-library.png` | Current library with staged “Welcome screen review” recording, 2808 × 2200 |

The library fixture contains synthesized sample speech and manually authored
transcript, speaker labels, and summary data. Its summary provider is labeled
“Sample content”. It tests native rendering, not speech recognition, speaker
identification, or LLM quality. The caption discloses this on the page.

The temporary sample was moved out of the user's library after capture. Existing
recordings, model downloads, permissions, and provider settings were preserved.

Installed executable SHA-256:
`42dac55a10ff8cabc7a27de6b272d150a9f35b6d9b1f46ab89ef0c1d46e398f7`.

The PNG was captured on 2026-11-20 with `screencapture -x -o -l <windowID>`
from a fresh AnyRec 0.9.0 debug build of the working tree. The ad-hoc signed
bundle used a separate bundle identifier, scratch home, and explicit scratch
recordings folder. The fixture contains macOS synthesized speech, fictional
names, and a hand-authored transcript and summary labeled “Sample content”.
The displayed summary came from fixture JSON. The installed app and real
library were left untouched during this capture.

Isolated executable SHA-256:
`e049e22606d46b5aa0f0e2db8b7cef6db876c6a052a33335621c9f220e5c426b`.

## Brand assets

The Dual track, Record ring, and Call note marks and their wordmarks are hand-drawn
SVGs. The favicon PNGs and the 1200 × 630 social card are raster exports of SVG
artwork. The share card contains typography and the brand mark. The existing
app icon comes from `Resources/AppIcon.icns`.

## Publishing

The download URL remains the existing GitHub releases fallback. No App Store
availability, price, purchase flow, or free license is asserted. Configure the
final sales link before announcing the paid release.
