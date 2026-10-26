import Testing

@testable import AnyRecKit

@Suite("CallWatch")
struct CallWatchTests {
    private func process(_ bundleID: String, input: Bool, output: Bool = true) -> AudioProcess {
        AudioProcess(bundleID: bundleID, pid: 1, runningInput: input, runningOutput: output)
    }

    @Test("a call app holding the microphone is a call, through a helper too")
    func detects() {
        let teams = CallWatch.app(
            holding: [process("com.microsoft.teams2.modulehost", input: true)],
            among: CallApps.known)
        let chrome = CallWatch.app(
            holding: [process("com.google.Chrome.helper", input: true)], among: CallApps.known)

        #expect(teams?.name == "Microsoft Teams")
        #expect(chrome?.name == "Chrome")
    }

    @Test("playing audio is not a call, and neither is an app nobody knows")
    func ignores() {
        let playing = CallWatch.app(
            holding: [process("com.google.Chrome.helper", input: false)], among: CallApps.known)
        let unknown = CallWatch.app(
            holding: [process("com.example.dictation", input: true)], among: CallApps.known)
        let speech = CallWatch.app(
            holding: [process("com.apple.CoreSpeech", input: true, output: false)],
            among: CallApps.known)

        #expect(playing == nil)
        #expect(unknown == nil)
        #expect(speech == nil)
    }
}
