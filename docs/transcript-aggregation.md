# Transcript aggregation

Aggregator runs its enabled, selected and available transcription engines in
parallel. The engine selected before switching to Aggregator has no influence.
Its fixed fallback order is Parakeet, Apple, Whisper, then OpenAI. Failed and
empty results are skipped when choosing a usable transcript.

With transcript review disabled, the first usable result in that order becomes
the final transcript. Other engine results remain available in View Sources.
This order is a predictable fallback, not a measured quality ranking.

With review enabled, every successful engine is included in the LLM's `sources`
array. For each passage, the reviewer compares the sources as peers and can
combine complementary corrections from different engines. The reference engine
has no wording priority. Recognition evidence and context matter; a more formal
or fluent sentence is not a reason to rewrite what someone said. Slang,
contractions, repetitions and mixed languages must remain intact.

The first usable result still supplies the timestamp and speaker timeline.
Review can combine wording within those passages, but it cannot add or remove
timeline segments, move timestamps, or silently change speaking turns. This is
wording reconciliation, not a second diarization pass. Unresolved wording falls
back to the reference text. Speaking-turn changes remain suggestions requiring user
confirmation. Conflicting speaker names are resolved automatically by a separate
LLM pass using call indicators, saved voice matches and transcript context. Its
choices affect only this recording, never the shared voice library. Originals
are retained if review fails.

Summarization is separate. It consumes the finished transcript and does not
control whether Aggregator reconciles its source transcripts. Transcript review
remains opt-in, including when Aggregator is selected.

`ANYREC_LIVE_REVIEW_TEST=1 swift test --filter TranscriptReviewWordingTests`
checks spoken wording and complementary-source reconciliation with the configured
Claude CLI. The regular test suite checks source inclusion, fixed selection order,
preserved timing and speakers, and fallback when review fails without calling an LLM.
