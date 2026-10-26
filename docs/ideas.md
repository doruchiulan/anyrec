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

## Custom summary instructions

Let users provide their own additional summary instructions, such as preferred
focus, tone, detail or terminology. Keep this separate from the required output
structure.

The summary must still extract decisions and action items, including owners and
timestamps when supported by the transcript. Custom instructions cannot remove
those requirements or replace the structured result with free-form text. Validate
the output structure; allow empty lists when no decisions or actions were agreed.

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

Expose AnyRec's inference pipeline through an MCP server so agents can reuse its
installed models and configured providers.

- Transcribe supplied audio or existing recordings, separate speakers and match
  known voices, and generate summaries with decisions and action items.
- Return structured results with timestamps and speaker identities, plus job
  progress and cancellation for longer runs.
- Reuse the app's engine selection and processing pipeline so agent requests
  produce consistent results without a separate inference implementation.
- Make access opt-in and identify when a request will use a cloud provider.

Transport, access controls and the initial tool set remain design choices.

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
