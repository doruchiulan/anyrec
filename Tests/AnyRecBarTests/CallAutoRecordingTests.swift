import Foundation
import Testing

@testable import AnyRecBar
@testable import AnyRecKit

@Suite("Automatic call recording")
struct CallAutoRecordingTests {
    let slack = CallApps.known.first { $0.name == "Slack" }!
    let teams = CallApps.known.first { $0.name == "Microsoft Teams" }!
    let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom")
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func context(enabled: Bool = true, mode: AutomaticRecordingMode = .window, canStart: Bool = true)
        -> CallAutoRecording.Context
    {
        .init(enabled: enabled, mode: mode, canStart: canStart)
    }

    /// A Slack call, its window found, recording: the state most tests start from.
    func recordingSlack() -> CallAutoRecording {
        var policy = CallAutoRecording()
        _ = policy.callStarted(slack, context: context())
        _ = policy.windowFound(context: context())
        return policy
    }

    @Test("watches a Slack or Teams call and starts once the window is found")
    func startsWhenIdentified() {
        for app in [slack, teams] {
            var policy = CallAutoRecording()
            let r1 = policy.callStarted(app, context: context())
            #expect(r1 == .watch(app))
            let r2 = policy.windowFound(context: context())
            #expect(r2 == true)
            #expect(policy.recording == app)
            #expect(policy.watching == nil)
        }
    }

    @Test("keeps watching until the window is found, however long that takes")
    func waitsForTheWindow() {
        var policy = CallAutoRecording()
        let r3 = policy.callStarted(slack, context: context())
        #expect(r3 == .watch(slack))
        #expect(policy.watching == slack)
        #expect(policy.recording == nil)
        let r4 = policy.deadlinePassed(at: start.addingTimeInterval(3_600))
        #expect(!r4)
        #expect(policy.watching == slack)
    }

    @Test("stops watching when the call ends without a window, and starts nothing")
    func callEndsWithoutAWindow() {
        var policy = CallAutoRecording()
        _ = policy.callStarted(slack, context: context())
        let r5 = policy.callEnded(at: start)
        #expect(r5 == .stopWatching)
        #expect(policy.watching == nil)
        let r6 = policy.windowFound(context: context())
        #expect(r6 == nil)
        #expect(policy.recording == nil)
    }

    @Test("turned off while watching, the call is handed back to the offer")
    func turnedOffWhileWatching() {
        var policy = CallAutoRecording()
        _ = policy.callStarted(teams, context: context())
        let r7 = policy.disabled()
        #expect(r7 == teams)
        let r8 = policy.windowFound(context: context())
        #expect(r8 == nil)
        let r9 = policy.disabled()
        #expect(r9 == nil)
    }

    @Test("a window found after the switch went off, or after a recording began, starts nothing")
    func windowFoundTooLate() {
        var off = CallAutoRecording()
        _ = off.callStarted(slack, context: context())
        let r10 = off.windowFound(context: context(enabled: false))
        #expect(r10 == nil)
        #expect(off.recording == nil)

        var busy = CallAutoRecording()
        _ = busy.callStarted(slack, context: context())
        let r11 = busy.windowFound(context: context(canStart: false))
        #expect(r11 == nil)
        #expect(busy.recording == nil)
    }

    @Test("other apps, and the setting off, keep the offer")
    func offers() {
        var policy = CallAutoRecording()
        let r12 = policy.callStarted(zoom, context: context())
        #expect(r12 == .offer(zoom))
        let classic = CallApps.known.first { $0.bundleID == "com.microsoft.teams" }!
        let r13 = policy.callStarted(classic, context: context())
        #expect(r13 == .offer(classic))
        let r14 = policy.callStarted(slack, context: context(enabled: false))
        #expect(r14 == .offer(slack))
        #expect(policy.watching == nil)
    }

    @Test("does nothing while recording, saving, or before setup is complete")
    func ignoresWhenItCannotStart() {
        var policy = CallAutoRecording()
        let r15 = policy.callStarted(slack, context: context(canStart: false))
        #expect(r15 == .ignore)
        #expect(policy.watching == nil)
        let r16 = policy.windowFound(context: context())
        #expect(r16 == nil)
    }

    @Test("records the picture or only the sound, as chosen")
    func usesTheMode() {
        var audio = CallAutoRecording()
        _ = audio.callStarted(slack, context: context(mode: .audioOnly))
        let r17 = audio.windowFound(context: context(mode: .audioOnly))
        #expect(r17 == false)

        var window = CallAutoRecording()
        _ = window.callStarted(slack, context: context(mode: .window))
        let r18 = window.windowFound(context: context(mode: .window))
        #expect(r18 == true)
    }

    @Test("stops an automatic recording once the call has been over for the grace period")
    func stopsAfterTheGrace() {
        var policy = recordingSlack()
        let deadline = start.addingTimeInterval(CallAutoRecording.endGrace)
        let r19 = policy.callEnded(at: start)
        #expect(r19 == .stopAt(deadline))
        let r20 = policy.deadlinePassed(at: start.addingTimeInterval(CallAutoRecording.endGrace - 1))
        #expect(!r20)
        let r21 = policy.deadlinePassed(at: deadline)
        #expect(r21)
        let r22 = policy.deadlinePassed(at: deadline.addingTimeInterval(1))
        #expect(!r22, "stops once")
    }

    @Test("a brief release of the microphone does not cut the call in two")
    func briefReleaseKeepsRecording() {
        var policy = recordingSlack()
        _ = policy.callEnded(at: start)
        let r23 = policy.callStarted(slack, context: context(canStart: false))
        #expect(r23 == .resume)
        let r24 = policy.deadlinePassed(at: start.addingTimeInterval(CallAutoRecording.endGrace * 2))
        #expect(!r24)
        #expect(policy.recording == slack)

        /// The real end, later, still stops it.
        let end = start.addingTimeInterval(600)
        let r25 = policy.callEnded(at: end)
        #expect(r25 == .stopAt(end.addingTimeInterval(CallAutoRecording.endGrace)))
        let r26 = policy.deadlinePassed(at: end.addingTimeInterval(CallAutoRecording.endGrace))
        #expect(r26)
    }

    @Test("another app's call during the grace does not keep the recording going")
    func otherAppDoesNotResume() {
        var policy = recordingSlack()
        _ = policy.callEnded(at: start)
        let r27 = policy.callStarted(teams, context: context(canStart: false))
        #expect(r27 == .ignore)
        let r28 = policy.deadlinePassed(at: start.addingTimeInterval(CallAutoRecording.endGrace))
        #expect(r28)
    }

    @Test("never stops a manual recording")
    func leavesManualRecordings() {
        var policy = CallAutoRecording()
        /// Recording by hand when the call starts: the call is ignored, so it never
        /// becomes automatic.
        let r29 = policy.callStarted(slack, context: context(canStart: false))
        #expect(r29 == .ignore)
        let r30 = policy.callEnded(at: start)
        #expect(r30 == .nothing)
        let r31 = policy.deadlinePassed(at: start.addingTimeInterval(CallAutoRecording.endGrace * 10))
        #expect(!r31)
    }

    @Test("a recording that ended or never started is forgotten, and its call end stops nothing")
    func endedRecordingIsForgotten() {
        var policy = recordingSlack()
        policy.recordingEnded()
        #expect(policy.recording == nil)
        let r32 = policy.callEnded(at: start)
        #expect(r32 == .nothing)

        var pending = recordingSlack()
        _ = pending.callEnded(at: start)
        pending.recordingEnded()
        let r33 = pending.deadlinePassed(at: start.addingTimeInterval(CallAutoRecording.endGrace))
        #expect(!r33)
    }

    @Test("a second end during the grace keeps the first deadline")
    func repeatedEndKeepsDeadline() {
        var policy = recordingSlack()
        _ = policy.callEnded(at: start)
        let r34 = policy.callEnded(at: start.addingTimeInterval(4))
        #expect(r34 == .stopAt(start.addingTimeInterval(CallAutoRecording.endGrace)))
    }
}
