# Review with a second engine

The engine chosen in Settings (or Automatic's pick) always writes the transcript and
its timeline. Comparing engines is part of transcript review: with review on and
"Review with a second engine" checked, the other checked, enabled and available
engines run too, and the reviewer sees every version. With review off, only the
chosen engine runs — other engines are worth their minutes only to a reviewer.

Aggregator, the old transcription mode that ran engines together and kept the first
usable result in a fixed order, was migrated: a stored Aggregator setting becomes
Automatic plus "Review with a second engine" with the same engine selection. With
review on that is the same behaviour; with review off it is the same transcript
without the retained alternatives.

## Wording review

Each engine's transcript is a peer in the reviewer's `sources`. For each passage the
reviewer compares the sources and can combine complementary corrections from
different engines; the reference engine has no wording priority. Recognition evidence
and context matter; a more formal or fluent sentence is not a reason to rewrite what
someone said. Slang, contractions, repetitions and mixed languages stay intact.

The chosen engine supplies the timeline. Review can change the wording of a line, but
it cannot add or remove lines, move timestamps, or silently change speaking turns.
Speaking-turn changes remain suggestions requiring confirmation.

The transcript is reviewed in sections of up to 30 lines, three at a time. Each
reply is a patch: only the lines the model changed, by ID, with their new text. A line
it leaves out is unchanged; an ID outside the section, a repeated ID, an empty line or
one grown past four times its length is ignored. A section whose reply cannot be read
at all, or whose call failed, keeps its lines as transcribed and is recorded by line
range. The review counts if any section was used, and says how many were kept.

Conflicting speaker names are resolved by a separate LLM pass using call indicators,
saved voice matches and transcript context. It runs after the wording pass whether or
not any wording section succeeded, and a failure of either leaves the other's result
in place. Its choices affect only this recording, never the shared voice library.

## Summary

The summary is the last step of the same pass, for every interface. It refers to
speakers nobody has named by their label ("Speaker B"); the name is filled in when it
is shown, so naming someone later updates the summary without another model call. If
the transcript's words or who said them change, or a name it was written with
changes, the summary is marked stale and the app offers to refresh it.

`ANYREC_LIVE_REVIEW_TEST=1 swift test --filter TranscriptReviewWordingTests`
checks spoken wording and complementary-source reconciliation with the configured
Claude CLI. The regular test suite checks the patch format, partial failure, bounded
concurrency, engine selection and migration without calling an LLM.
