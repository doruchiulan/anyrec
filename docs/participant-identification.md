# Participant names from call windows

AnyRec can use Slack and Teams Accessibility labels as evidence for speaker names.
The current parser supports English interface labels. It reads Slack profile buttons
and speaking indicators. For Teams it reads participant tiles in the shared-content
view, including muted participants. The speaking border's `vdi-frame-occlusion`
class identifies the containing tile's speaker; announcements ending in `is speaking`
remain supported. An unmuted microphone alone is not speaking evidence. It does not
query calendars, meeting services or account credentials.

During capture, a background monitor polls once per second. Window recordings stay
bound to the selected process and window. Display recordings consider supported
apps doing audio and accept a snapshot only when exactly one call window is found.
Minimized windows, missing Accessibility access, unsupported labels and incomplete
or slow scans provide no evidence. The reader does not open participant panels.

Observations use the media timeline and are stored in `call-participants.json`
beside the tracks. Each observation holds the window source, observed participant
names and active-speaker names. Names may be incomplete when tiles are hidden.
Chat text and screenshots are not stored. Regeneration reuses these observations;
older recordings continue to use voiceprints without this evidence.

After diarization and voiceprint matching, the identity resolver checks sustained
agreement across at least two transcript passages. It requires six seconds of
evidence, coverage of at least 70% of eligible speech, and 85% agreement for one
name. It excludes overlapping voices, brief passages and transition margins.
Observations more than 1.5 seconds apart cannot bridge a gap. These conservative
thresholds are heuristics, not measured confidence scores.

If a supported call name and saved voiceprint agree, the saved spelling remains.
If they disagree, both clues are retained for transcript review. When review is
enabled, the selected LLM automatically chooses a name from those candidates using
the saved match, sustained call indicators, source-quoted introductions and sampled
reviewed transcript passages. It sees the first passages, excerpts spread across
each conflicted voice's turns, and neighboring lines. It receives names and text,
not audio or voiceprint vectors. This runs for both single-engine and Aggregator review.

The chosen name, provider and explanation are saved with that recording's voices.
Resolved conflicts no longer appear in the naming panel. Unknown candidates,
duplicate identity assignments and malformed replies cannot overwrite identities.
When review is disabled, fails or cannot distinguish the candidates, the voice
stays lettered and both clues remain visible. No confirmation is required to use
the recording. New name suggestions and individual speaking-turn corrections
still use their existing confirmation controls.

Uncertain call evidence leaves the existing voiceprint match alone. The resolver
does not change speaking turns, timestamps or words, and never enrolls voiceprints.
Only an explicit naming action updates the shared voice library.

The same identity resolver runs for single-engine and Aggregator jobs. Disabling
speaker identification in transcription settings also disables this naming pass
for jobs using those settings. OpenAI's diarized turns remain intact.

Tests cover parsing, sustained evidence, conflicts, overlapping speech, stale
indicators, storage compatibility and automatic conflict resolution. Teams tests
replay tile labels and border-class transitions captured from a live call in
November 2026. The live reader returned both participants and detected the remote
speaker without relying on generated CSS class names. A 61-poll live monitor check
captured four speaking observations, 56 silent observations and three attributable
spans. This validates the tested English Teams layout, not every app version,
interface language or meeting layout.
