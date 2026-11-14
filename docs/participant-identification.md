# Participant names from call windows

AnyRec can use Slack and Teams Accessibility labels as evidence for speaker names.
The parser supports English interface labels. It reads Slack profile buttons and
speaking overlays, and Teams participant tiles in the shared-content view, including
muted participants. The Teams speaking border's `vdi-frame-occlusion` class names
the containing tile's speaker; announcements ending in `is speaking` remain
supported. An unmuted microphone alone is not speaking evidence. Nothing queries
calendars, meeting services or account credentials.

## What is read

During capture a background monitor polls once per second. Window recordings stay
bound to the selected process and window. Display recordings consider supported
apps doing audio and accept a snapshot only when exactly one call window is found.
Minimized windows, missing Accessibility access, unsupported labels and incomplete
or slow scans provide no evidence. The reader does not open participant panels.

Observations use the media timeline and are stored in `call-participants.json`
beside the tracks: the window source, the participant names, the names marked as
speaking and, where Teams labels it ("Myself video, …"), the recording person's own
tile. Chat text and screenshots are not stored.

Label shapes seen in real calls are cleaned to one name per person:

- Teams appends states after the name, comma-separated: "Name, Has control of
  production tools", "…, Unmuted", "…, muted". Whole trailing state segments are
  removed, so "Smith, Alex" keeps its comma. "External unfamiliar" and "(External)"
  badges are removed; "Guest", "Unverified" and "External" only when the tile carries
  that badge.
- Slack can put two profile buttons in one label ("View A's profile View B's
  profile"). That is two people, never one called "A's profile View B".

Names stored by an older parser are cleaned the same way when the file is read, so
existing recordings benefit without being rewritten.

## Scoring evidence for a voice

After diarization and voiceprint matching, each voice's clean lines are compared with
the speaking indicator: lines of at least a second that nobody else overlaps, with
0.35 s margins for the tile catching up. A span between two polls counts when the
same people were marked speaking in both, no more than 1.5 s apart.

Evidence is scored by how consistently it points at one person *where it exists*,
not by how much of the voice's speech it covers: a Slack window readable only for the
first 13 seconds still says who spoke in those 13 seconds. One person is named when
they have at least 3 seconds and two turns of single-speaker evidence, the voice has
at least 4 seconds of indicated time, and 85% of that time agrees with them. A poll
marking several people counts as agreement for any of them and against anyone else,
but cannot supply a name on its own. These thresholds are heuristics, not measured
confidence scores; the wrong name is the worse mistake.

## Agreement and conflict

The voice library holds one record per person: the name the owner gave, aliases
(display names seen in call windows), voiceprints, and whether this is the owner.

- The call name corroborates the voiceprint match when it is the person's saved name
  or an alias, or belongs to nobody in the library. That is agreement: the saved name
  stays and the display name is filed as the person's alias — names only, never a
  print.
- It is a conflict only when the display name already belongs to a different person,
  or two display names compete with no winner. Both clues are kept for review.
- A voice named only by the call window takes that display name (or the saved name it
  is an alias of) in this recording, and stays out of the library until the owner
  names it. Naming it then files the print and the display name as an alias.
- When two voices would get the same name from the call window alone, neither does.

When indicators consistently show two different people inside one voice, the voice
records them as `fusedNames` — the diarizer has probably joined them. The interface
says so; nothing is split automatically.

## Lines and the person recording

A "Call" line — one no diarized voice covered — takes the person the window showed
when exactly one was shown for most of it and that person is a voice of this
recording.

The owner must not appear as two speakers. A diarized voice is the person recording
when at least half of what the diarizer heard from it lies inside lines the
microphone measured as theirs (and at least 5 seconds), when it matches the library's
owner, or when the call window names it with the owner's own display name — their
tile, the library owner's aliases, or whoever the window showed during "Me" lines.
Its lines go to "Me" only where the microphone was live and carrying speech, and
never where the window showed someone else for that line; those go to the person
shown or to the call. The voice itself is removed and letters close up. The library's
owner is set from People ("This Is Me") or `anyrec speakers --me NAME`.

## Review

When review is enabled, conflicts are resolved by the selected LLM, choosing from the
candidate names using the saved match, call indicators, source-quoted introductions
and sampled transcript passages. It receives names and text, not audio or voiceprint
vectors. This runs as its own step after the wording review, so it still runs when no
wording section could be used. The chosen name, provider and explanation are saved
with the recording's voices, and never written to the shared library. Unknown
candidates, duplicate identity assignments and malformed replies change nothing.

## Showing it

The recording's page lists who the call window showed, how long each was shown as the
only one speaking, how much of the call the window could be read for, and any voice
facts (owner voice given back, possible fused voice, Call lines named). MCP returns
the observed names and readable seconds beside the transcript speakers.

## Replay on real recordings

The rules were replayed against copies of four real recordings (two Slack 1:1s, a
4-person Slack call readable for its first 106 s, a 6-person Teams call). Far-end
voices the indicators clearly pointed at got names — one in the latest 1:1, two in the
4-person call, three in the Teams call — and no far-end voice lost a name it had.
The only names that disappeared were the owner's own nickname on voices that were the
owner, which went back to "Me".
