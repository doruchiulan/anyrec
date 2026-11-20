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
(display names seen in call windows), voiceprints, whether this is the owner, and the
display name a call window showed for them most recently.

- The call name corroborates the voiceprint match when it is the person's saved name
  or an alias, or belongs to nobody in the library. That is agreement: the display
  name is filed as the person's alias and remembered as their display name — names
  only, never a print. The transcript shows the display name.
- It is a conflict only when the display name already belongs to a different person,
  or two display names compete with no winner. Both clues are kept for review.
- A voice named only by the call window takes that display name (or the saved name it
  is an alias of) in this recording, and stays out of the library until the owner
  names it. Naming it then files the print and the display name as an alias.
- When two voices would get the same name from the call window alone, neither does.

Which name a transcript shows for someone the library knows, in order:

1. A name typed for that voice in this recording.
2. The display name the call window showed for that voice in this recording.
3. The display name learned for that person on an earlier call.
4. The name saved in the library.

The saved name stays the key the library is filed and matched under. Names are
settled when a transcript is written, so older transcripts keep the names they had.

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
A line of that voice goes to the person the window showed when it showed only someone
else. Otherwise it goes to "Me" when the microphone was live (the call could hear it
over at least four fifths of the line, from `microphone-live.json`) and either the
microphone carried speech or the window showed the owner speaking (one of the owner's
names alone for at least half a second and twice as long as anyone else); everything
else goes to the call. The window's clause is for speakerphone: a bleeding microphone
is held under the call, so where the owner talks over or straight after the far end
the duck holds the microphone down and "carrying speech", judged on what the mix heard,
fails exactly on the owner's lines. On a real Slack 1:1 on speakerphone, the five lines
the diarizer heard as the owner all went to the call under the old rule; under this one
four go to "Me" and the fifth, with no indicator and a silent microphone, still goes
to the call. A line is never put in the owner's mouth while the window showed someone
else, or while the call could not hear the microphone. The voice itself is removed and
letters close up. A display name the window showed for the owner is never filed as the
alias of a non-owner whose saved print a voice matched: unflagged, the owner can look
like anyone. The library's owner is set from People ("This Is Me"), `anyrec speakers
--me NAME`, or the "Remember … is me" tick in the Speakers panel.

## Review

When review is enabled, conflicts are resolved by the selected LLM, choosing from the
candidate names using the saved match, call indicators, source-quoted introductions
and sampled transcript passages. It receives names and text, not audio or voiceprint
vectors. This runs as its own step after the wording review, so it still runs when no
wording section could be used. The chosen name, provider and explanation are saved
with the recording's voices, and never written to the shared library. Unknown
candidates, duplicate identity assignments and malformed replies change nothing.

## Showing it

The recording's page has one Speakers panel (`RecordingSpeakers` in the Kit). Every
speaker with lines is a row, Me included; rows needing a look come first — unnamed,
conflicting candidates, possibly two people (`fusedNames`), or with line corrections
pending, or probably you — and the heading says how many ("Speakers · 2 to check").
Each row shows the
name or letter, how it was decided (call window and voice agree, voice match, call
window, chosen by review, named by you, uncertain), talk time, up to three clips,
candidate names to click, "Someone else…" to type one, and under it that speaker's
lines the review thinks are someone else's, each with a clip and Move to / Keep.
Settled rows are compact with "Change…". Below them are the unclaimed Call lines
and the participants seen in the call window, with their observed speaking times.
Clicking a speaker label on a transcript line
opens the same choices for that line only or for every line of the voice.

A row is probably you (`YourVoiceEvidence`), worked out when the speakers are read so
it holds for transcripts written before the owner merge, when its name or its saved
person is the library's owner (`savedAsYou`); when its saved person answers to a name
the call window showed for the owner — their tile, or whoever it showed during "Me"
lines (`yourCallName`); or when the window showed one of the owner's names for most of
the time the speaker's lines were indicated, at least 3 s over two lines or more
(`shownSpeaking`). Its line under the name says "Probably you: …", it counts as one to
check, its first candidate is Me (`.yourVoice`), and it is offered nobody it only
sounds like. Me gives every line to Me in the speakers layer
(`SpeakerEditing.giveToMe`). When the evidence is the call window's, the row's saved
person is not the owner and the library has no owner yet, a "Remember <name> is me"
tick sits beside Me, on by default: with it ticked, Me also marks that person as the
library's owner and files the window's name for the owner as their alias. Nothing sets
the owner without the tick. It is not offered when the owner named the voice
themselves (a name they picked is the likelier mistake to remember), when the window's
name belongs to someone else, or in the terminal, which gives the lines to Me and
never remembers.

Clips: a line of that speaker at least 2 s long, overlapped by no other speaker's
line, with no pending correction; at most 8 s, centred; one from each third of the
call where possible. A clip plays its span and stops. The old sample — the voice's
longest line — ran on into the next speaker and was the line most likely to hold two.

Candidate names, best first, one per person (`VoiceLibrary.normalized` and the
library's aliases), never a name another speaker carries, never the owner's names
for a far-end voice, never the speaker's own name:

1. The call window's names for this voice (`callName`, `callNames`).
2. The library match, as its shown name, and the review's resolution.
3. A name the voice introduced itself by (the review's suggestions), with the quote.
4. Only one left: the roster minus names given to other voices and minus the owner's
   names (their tile, the library owner's name, aliases and display name, and whoever
   the window showed during "Me" lines). When exactly one remains it is offered first,
   or right after the call window's names when the window named someone for this voice.
5. The rest of the roster.
6. Slack only: the window title's first segment split on ", " ("First Last, Other
   Person - Workspace - 2 new items - Slack").
7. Sounds like: up to two saved voices with similarity in [0.3, 0.5), as a question.
   When the call window could be read for at least half the recording, only people its
   roster listed: anyone else was not in the call. None on a row that is probably you.
   Typing still completes from everyone.

Nothing is applied without a click. Naming a whole voice goes through `VoiceNaming`,
files its print, and records `namedByOwner` so it reads "named by you" (older voices
read as before). The call window's name for that voice is filed as an alias only when
the name was typed or is the call window's own; picking another candidate means the
window was wrong. Giving one line to Me, Call or another speaker changes only the
speakers layer, and the summary says it is stale. Every row of the Speakers panel
except Me, like the transcript label's popover with "Every line of …" chosen, offers
"Or give every line of … to" Me, Call and every other speaker (`GiveToChoices`,
`SpeakerEditing.give`); Me is left out of that list where the names above it already
offer Me. The terminal (`anyrec speakers`, and the prompt after a transcript) prints the
same clips and numbered candidates and takes a number or a name.

### When a print is filed, and when it is taken back

A print enters the library only when the owner names a whole voice (`VoiceNaming.apply`)
or gives one to Me. The voice records what that filed (`Voice.filed`: the saved name it
went under, whether the record was made by that naming, and the call window's name the
naming added as that person's alias), so a wrong pick can be undone exactly:

- Renaming a voice the owner named, or giving all its lines to Me, Call or another
  speaker, first takes back what the earlier naming filed: that exact print (compared
  value for value) and that alias. Prints from other recordings are never touched. A
  voice given away also stops carrying its name.
- A voice named before `filed` was kept (`namedByOwner` without it) is looked up by its
  name, saved or answered to, and only its exact print is removed.
- A person left with no print, alias, display name or owner flag is removed only when
  that naming made the record (a typo, a wrong new name). A person who was there before
  is kept, even empty: they may have been typed on purpose.
- Given to Me, the print joins the library owner's record so the owner's voice is
  recognised next time; with no owner it is filed nowhere. With the "Remember … is me"
  tick, the owner is set first and the print then joins them.
- Naming a voice as a person who already has its print does not add it twice.

Each print filed from now on carries where it came from (`PrintOrigin`: the recording
folder, and when it was filed; nil folder for one imported from `.anyrecvoices`).
Older files read without it and show "earlier"; exports leave it behind. Settings ›
Transcription › Remembered voices lists each person's prints with that origin (the
recording's title and start when the library still has it) and a Remove button, as does
Remove Voiceprint in a People row's context menu; `anyrec speakers --people` lists them
numbered and `--remove-print NAME=N` removes one. Removing a print keeps the person.

When a call gives no names at all, every voice is a letter and the owner types. The
"Someone else…" field (in the panel and in the transcript label's popover) completes
from everyone already in the library, through `RecordingSpeakers.completions(for:typing:)`:

- Every name a person answers to is matched — shown name, saved name, aliases, display
  name — ignoring case, diacritics ("ș", "ş" and "s" alike, "ă" and "a") and spacing.
  A whole name first, then the start of any word ("lun" finds "Andrei Lungu"), then
  anywhere; within a tier the person whose voice is nearest this one first.
- The owner, people another speaker in this recording carries, and the speaker's own
  person are left out, unless the text is exactly one of their names.
- With nothing typed, the saved voices nearest this voice, with no threshold, top six.
- Each completion shows the name the transcript will show and, when another of their
  names matched, that one: "Andrei Lungu — also Andi".
- Return or a click fills the field with the shown name; Return or Save then names the
  voice. A name that is exactly one person's (`person(for:typed:)`) files the print under
  that person's saved name (`SpeakerEditing.name(…, person:)`, `VoiceNaming.apply(…,
  people:)`), spelled as the library spells it, and never starts a second record — also
  when two people are shown under one name, where the field files under the first of
  them it listed. Anything else is a new person, as typed. The call window's name for
  the voice, when there was one, is filed as an alias under the saved name the print
  went to.
- The terminal prompt uses the same list: typed text exactly one person answers to is
  used directly; text matching people already named lists them first ("1) Andrei
  Lungu (also Andi)"), and ⏎ keeps what was typed.

Nothing here calls a model or leaves the machine.

MCP returns the observed names and readable seconds beside the transcript speakers.

## Replay on real recordings

The rules were replayed against copies of four real recordings (two Slack 1:1s, a
4-person Slack call readable for its first 106 s, a 6-person Teams call). Far-end
voices the indicators clearly pointed at got names — one in the latest 1:1, two in the
4-person call, three in the Teams call — and no far-end voice lost a name it had.
The only names that disappeared were the owner's own nickname on voices that were the
owner, which went back to "Me".
