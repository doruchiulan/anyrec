# Ideas

Parked. Nothing here is committed to, and none of it is on the roadmap.

## Making a Playwright run recordable

Three parts to producing a product demo: scripting it, recording it, editing it.
Scripting is solved by writing the demo as a Playwright script. Editing is solved
by Recordly or Screen Studio. **Recording is the part with no answer**, and it is
the only part worth building.

The output should stay editable in those tools. Do not generate a finished video
— zoom easing, hold duration and when *not* to zoom are taste, and taste is what
the existing editors are already good at.

### Why a recorded Playwright run looks dead

Playwright clicks go through CDP — `Input.dispatchMouseEvent`, straight into the
browser. They never reach the OS input layer. So a screen recording of a passing
script shows a cursor sitting motionless in a corner while forms fill themselves
instantly and menus open by magic. It reads as a bug reel, not a demo.

It also means every auto-zoom recorder is blind to it. Screen Studio zooms on
clicks *it observes*; there are no clicks to observe.

### The fix: drive a real cursor

Post real macOS events instead. `CGEvent` mouse moves and clicks go through the
window server, so the cursor visibly travels, the browser responds normally, and
an event tap — Screen Studio's included — sees genuine input.

Which means the existing workflow survives intact: record with Screen Studio,
edit in Recordly, and its auto-zoom lands on the right elements *by itself*. No
metadata handoff, no proprietary project format to reverse-engineer, no editor
integration to maintain.

What makes it look human is motion, not accuracy: easing rather than teleporting,
a little overshoot on long travels, a beat of dwell before the click lands, and
typing at a cadence instead of `fill()`'s instant paste.

### The one hard part

Targeting. To move a real cursor onto a button you need the element's position in
screen pixels, and the page only knows viewport CSS pixels. Bridging them needs
`window.screenX`/`screenY`, the inner/outer size delta for the browser chrome,
and `devicePixelRatio`. Iframes each carry their own offset.

Geometry comes from the page itself, via `exposeBinding` + `addInitScript` —
`getBoundingClientRect()` on the resolved locator, reported out. Not by parsing
the script: static analysis gives intent without timing, and breaks on the first
page object or loop.

Posting events also needs the Accessibility grant, which is a third permission
on top of Screen Recording and Microphone.

### What anyrec actually shares

Less than the auto-edit version would have. Window-targeted capture, the release
script and the tap carry over; a metadata sidecar on the session clock becomes
optional garnish rather than the point. This is a separate tool that borrows
plumbing, not a `--pro` flag.

### The spike

An hour, not an evening. Open a page, read one button's rect, map it to screen
coordinates, ease the real cursor over and click it. If the page responds and the
cursor lands where it should, the idea works and everything after it is polish.
If the mapping is off by a chrome height, that is the whole risk surfacing
immediately.

Worth checking in the same hour: that Screen Studio's auto-zoom does fire on a
`CGEvent`-posted click. It should — synthetic events reach event taps — but the
entire workflow rests on it.

## Optional LLM transcript review and speaker-name suggestions

Implemented in Settings › Transcription. Review and parallel transcription are
both off by default. Users enable individual engines, choose one engine or run the
available enabled engines concurrently, and select a review provider.

The reviewer compares source transcripts to correct recognition errors and propose
speaker names or line reassignments with evidence. Original transcripts remain
available. Speaker changes require confirmation; confirming a reassignment clears
the previous summary. Audio-based separation still supplies the initial identities.

See [the pipeline](pipeline.md) for ordering and failure handling.

## Speaker changes as events, not once-a-second scans

`ParticipantMonitor` polls the call window once a second and walks its whole
accessibility tree each time, up to 1,500 elements. A turn shorter than a second can
fall between two polls, and a poll that runs past its 0.4 s deadline is recorded as a
gap. In the Slack calls recorded so far the window was readable for 13 s and 106 s
and then produced nothing but gaps for the rest of the call.

Subscribe instead. Find the speaker tiles and the roster once, register an
`AXObserver` on them for value, title and child changes, and append a timestamped
event whenever the active speaker or the roster changes. Keep a slow full rescan,
every few seconds, to pick up tiles that appear and to recover when a notification is
missed or the tree is rebuilt.

Fathom's meeting helper appears to work this way: its binary carries `AXObserver`,
`AXObserverManager` and `ActiveSpeakerChangedEvent`, and each audio chunk it uploads
carries the speaker and roster changes seen since the last one. That is read from
strings in the installed app, not confirmed by running it.

Questions to settle first:

- Which Slack and Teams elements actually post notifications when the speaker
  changes. Chromium does not post them for every DOM change; the speaking state may be
  a class change that never produces one, which would leave polling as the only way.
- Whether `call-participants.json` keeps its format, with events turned into
  observations, or becomes a list of events. `CallParticipants.spans` and the replay
  tests read the current shape.
- What to measure before and after: share of the call with usable evidence, and how
  many turns under a second are caught, on the same recorded calls.

## Custom summary instructions

Let users provide their own additional summary instructions, such as preferred
focus, tone, detail or terminology. Keep this separate from the required output
structure.

The summary must still extract decisions and action items, including owners and
timestamps when supported by the transcript. Custom instructions cannot remove
those requirements or replace the structured result with free-form text. Validate
the output structure; allow empty lists when no decisions or actions were agreed.

## Live meeting summary

Show a running summary during recording so users can catch up on the discussion
without waiting for the call to end.

- Use one fast transcription engine to process incoming audio incrementally.
- Periodically send new transcript passages and earlier meeting context to the
  selected LLM to update key points, decisions and action items.
- Mark live notes as provisional and revise them when participants change a
  decision or later speech clarifies an earlier point.
- After the call, run the existing transcription, optional Aggregator and review,
  and final summary pipeline over the complete recording.
- Make live summarization opt-in and explain when text goes to a cloud provider.

Update frequency, context retention, provider cost and recording performance
need evaluation. Parked for later; no implementation started.

## Speaker export and a shared speaker database

The local voice library already matches named voices across recordings and supports
import/export through the File menu and People view. Extend it into one place to
manage speaker identities across all recordings.

- Keep speaker export/import available, including names and reusable voice profiles.
- Maintain stable speaker identities across recordings, with rename, merge and
  correction tools that keep recording references consistent.
- Treat voice profiles as sensitive data; make their inclusion in exports explicit.

Whether the database should also be shared across devices or users remains an
open design choice.

## MCP server for agents

Implemented as a read-only library server, started explicitly with `anyrec mcp`.
Agents can list meetings, search saved content, and read transcripts, participants,
summaries, decisions and action items. Results use the selected transcript
generation and include timestamps and name provenance where available.

The server cannot record, transcribe, regenerate, edit, delete or invoke inference.
It uses local stdio and reads only the configured recordings folder. No audio,
video, voiceprints or provider credentials are exposed.

See [MCP setup and tools](mcp.md).

## iPad app

Explore an iPad version sharing the Mac app's transcription, speaker recognition,
transcript review and recording library logic. Keep Claude Code, Codex and Gemini
CLI integrations Mac-only; an iPad app could use local transcription without an
LLM, with API providers optional for review and summaries.

The pinned FluidAudio dependency supports iOS, and the bundled Whisper framework
includes an iOS build. iPadOS 27 adds ScreenCaptureKit support, including audio and
microphone capture, but Mac window-selection APIs do not carry over. Verify actual
Teams and Slack call capture on a device before committing to recording parity.

The port would need an iPad interface and capture flow, native replacements for
ffmpeg subprocesses, and device testing for model memory use and background work.
Imported recordings could provide a smaller first version.

Parked for later; no iPad implementation started.

## Offline echo cancellation with WebRTC AEC3

Speakerphone calls are handled by holding the microphone down while the call talks (the
duck), which loses anything said over the other side. Cancelling the echo instead would
keep it. Tried so far, on the 2026-11-16 08:39 call (MacBook speakers), scored with
`anyrec echo` (echo left while the far end talks, median; lower is better):

| | echo left | audible |
|---|---|---|
| raw microphone | +5.7 dB | 100% |
| the duck, tracks lined up | −24.7 dB | 39% |
| ffmpeg NLMS (`anlms`), call track as reference | +1.3 dB | 100% |
| SpeexDSP echo canceller | +3.7 dB | 100% |
| NLMS, then the duck | −29.7 dB | 36% |

The echo is only 0.43 correlated with the call track at its lag (572 ms, measured at
sample level): the call track is the app's audio before the MacBook's speaker processing,
which is not linear, so a linear canceller removes little. macOS voice processing at
capture was removed (0.7.2) because it turns the microphone down for every app,
the call included.

WebRTC's AEC3 adds a non-linear residual-echo suppressor built for laptop speakers and is
the one candidate left. It is a large C++ dependency to build and ship. Worth a prototype
only if speakerphone echo becomes a bigger problem than the duck's cost.
