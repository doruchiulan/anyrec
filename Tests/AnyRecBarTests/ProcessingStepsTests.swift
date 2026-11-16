import Testing

@testable import AnyRecBar
@testable import AnyRecKit

@Suite("The checklist after a recording")
struct ProcessingStepsTests {
    private func states(_ steps: ProcessingSteps) -> [ProcessingSteps.State] { steps.steps.map(\.state) }

    @Test("saved first, then each step waits, runs and finishes in order")
    func order() {
        let queued = ProcessingSteps(merges: true, transcribes: true, summarises: false, stage: .queued, result: nil)
        #expect(queued.steps.map(\.title) == ["Recording saved", "Prepare the recording", "Transcribe"])
        #expect(states(queued) == [.done, .waiting, .waiting] && queued.working)
        #expect(states(ProcessingSteps(merges: true, transcribes: true, summarises: false, stage: .merging, result: nil))
                == [.done, .running, .waiting])
        #expect(states(ProcessingSteps(merges: true, transcribes: true, summarises: false, stage: .transcribing, result: nil))
                == [.done, .done, .running])
        let finished = ProcessingSteps(merges: true, transcribes: true, summarises: true, stage: .finished,
                                       result: .init(transcript: nil))
        #expect(states(finished) == [.done, .done, .done] && !finished.working)
        #expect(finished.steps.last?.title == "Transcribe and summarise")
    }

    @Test("a failed transcript marks its own step, not the others")
    func failure() {
        let failed = ProcessingSteps(merges: true, transcribes: true, summarises: false, stage: .finished,
                                     result: .init(transcript: .failed(reason: "no model", remedy: nil)))
        #expect(states(failed) == [.done, .done, .failed])
    }

    @Test("steps that were not asked for are not listed")
    func onlyAsked() {
        let plain = ProcessingSteps(merges: false, transcribes: false, summarises: false, stage: .finished, result: nil)
        #expect(plain.steps.map(\.title) == ["Recording saved"] && !plain.working)
    }
}
