import Foundation
import SlackRecKit

/// The transcription pass that follows a recording, for both the TUI and `record`.
/// It never throws: the recording is already safe on disk, and a missing model is
/// not a reason to end the run badly.
enum TranscriptRun {
    static func follow(_ plan: OutputPlan, engine: TranscriptionEngine) async {
        print("")
        do {
            let job = TranscriptionService.Job(
                tracks: TranscriptionService.tracks(in: plan), engine: engine
            )
            let transcript = try await TranscriptionService.run(job) { print("  \($0)") }
            guard !transcript.isEmpty else {
                print("  Nothing was heard, so there is no transcript.")
                return
            }
            let written = try TranscriptionService.write(
                transcript, into: plan.directory, named: "transcript-\(transcript.engine)"
            )
            written.forEach { print("  Wrote \($0.path)") }
            transcript.notes.forEach { print("\n  \($0)") }
        } catch {
            print("  No transcript: \(error)")
            print("  The recording is untouched — retry with `slack-rec transcribe`.")
        }
    }
}
