#if ANYREC_WEBSITE_DEMO
import AnyRecKit
import SwiftUI

@MainActor
struct DemoTranscript {
    let root: URL
    let desk: SpeakerDesk
    let playback: Playback

    init() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("AnyRec-Website-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        self.root = root
        do {
            let voices = root.appendingPathComponent("Voices")
            setenv("ANYREC_VOICE_LIBRARY", voices.path, 1)
            guard VoiceLibrary.directory.standardizedFileURL.path == voices.standardizedFileURL.path else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try VoiceLibrary(people: [.init(name: "Robin Vale", prints: [])]).save(to: voices)
            let recordings = root.appendingPathComponent("Recordings")
            UserDefaults.standard.set(recordings.path, forKey: "recordingsFolder")
            let directory = recordings.appendingPathComponent("Sketch review")
            try OutputPlan(directory: directory).layout.prepare()
            guard let sound = Bundle.main.url(forResource: "Sketches", withExtension: "m4a") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            try files.copyItem(at: sound, to: directory.appendingPathComponent("Sketches.m4a"))
            let info = RecordingInfo(title: "Sketch review", bundleID: nil, width: 0, height: 0, fps: 0,
                                     audioOnly: true, mergedFile: "Sketches.m4a", startedAt: Date())
            try info.write(to: directory)
            let entry = RecordingLibrary.entry(at: directory)
            let line = Utterance(start: 0, end: entry.duration, text: "I will send the updated sketches after lunch.")
            let transcript = Transcript(utterances: [line], language: "en", engine: "demo")
            try TranscriptStore.publish(transcript, voices: nil, in: directory)
            desk = SpeakerDesk(directory: directory, controller: RecordingController(completedSetup: true))
            playback = Playback(entry)
            playback.follow(transcript)
        } catch {
            try? files.removeItem(at: root)
            throw error
        }
    }
}

struct DemoReview: View {
    let fixture: DemoTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcript").font(.headline).padding()
            Divider()
            if let speakers = fixture.desk.speakers {
                TranscriptList(lines: speakers.lines, meName: nil, playback: fixture.playback,
                               desk: fixture.desk, filter: .constant(nil))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await fixture.desk.load() }
    }
}
#endif
