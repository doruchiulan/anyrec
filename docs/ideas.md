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

### What slack-rec actually shares

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
