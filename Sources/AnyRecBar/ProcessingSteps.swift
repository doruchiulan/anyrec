import AnyRecKit
import Foundation

/// What happens to a recording after it is saved, as a checklist: saved, prepared (the mix
/// decided and the tracks merged), transcribed (and summarised, when asked). Each step
/// waits, runs, finishes or fails, read from the job's stage and result. A lone "Saved"
/// with a green check read as "all done" while the transcript had barely started.
struct ProcessingSteps: Equatable {
    enum State: Equatable { case waiting, running, done, failed }

    struct Step: Equatable, Identifiable {
        let title: String
        let state: State
        var id: String { title }
    }

    let steps: [Step]

    /// Whether anything is still to come, for the "continues in the background" line.
    var working: Bool { steps.contains { $0.state == .waiting || $0.state == .running } }

    init(steps: [Step]) { self.steps = steps }

    /// `stage` is the job's (nil before it is queued); `result` its outcome once finished.
    init(merges: Bool, transcribes: Bool, summarises: Bool,
         stage: RecordingJobs.Stage?, result: RecordingJobs.Result?) {
        var steps = [Step(title: "Recording saved", state: .done)]
        let finished = stage == .finished
        if merges {
            let failed: Bool = switch result?.recording?.merge {
            case .failed, .ffmpegMissing: true
            default: false
            }
            let state: State = finished ? (failed ? .failed : .done)
                : stage == .merging ? .running
                : stage == .transcribing ? .done
                : .waiting
            steps.append(Step(title: "Prepare the recording", state: state))
        }
        if transcribes {
            let failed: Bool = if case .failed = result?.transcript { true } else { false }
            let state: State = finished ? (failed ? .failed : .done)
                : stage == .transcribing ? .running
                : .waiting
            steps.append(Step(title: summarises ? "Transcribe and summarise" : "Transcribe", state: state))
        }
        self.init(steps: steps)
    }
}
