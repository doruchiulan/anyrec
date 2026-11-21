#if ANYREC_WEBSITE_DEMO
import SwiftUI

@main
struct WebsiteDemoApp: App {
    enum Scene { case reminder, callOnly, recording, review }

    @State private var scene = Scene.reminder
    @State private var started = Date()
    @State private var video = true
    private let status = DemoStatusItem()
    let fixture: Result<DemoTranscript, Error>

    init() {
        fixture = Result {
            guard Bundle.main.bundleIdentifier == "com.doruchiulan.anyrec.website-demo" else {
                throw CocoaError(.fileReadUnknown)
            }
            return try DemoTranscript()
        }
    }

    var body: some SwiftUI.Scene {
        Window("AnyRec Website Demo", id: "demo") {
            Group {
                switch fixture {
                case .success(let fixture): content(fixture)
                case .failure(let error): Text(error.localizedDescription).padding()
                }
            }
            .onChange(of: scene, initial: true) { _, scene in
                status.show(started: scene == .recording ? started : nil)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                if case .success(let fixture) = fixture { try? FileManager.default.removeItem(at: fixture.root) }
            }
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commands {
            CommandMenu("Scenes") {
                Button("Call Reminder") { scene = .reminder }.keyboardShortcut("1")
                Button("Recording Panel") { record(true) }.keyboardShortcut("2")
                Button("Transcript") { scene = .review }.keyboardShortcut("3")
            }
        }
    }

    @ViewBuilder private func content(_ fixture: DemoTranscript) -> some View {
        switch scene {
        case .reminder, .callOnly:
            VStack(spacing: 6) {
                if scene == .reminder {
                    CallReminderView(appName: "Slack", record: record, dismiss: { scene = .callOnly })
                }
                DemoCall()
            }
            .padding(20).frame(width: 538)
        case .recording:
            DemoRecording(started: started, video: video) { scene = .review }.padding(20)
        case .review:
            DemoReview(fixture: fixture).frame(width: 520, height: 300)
        }
    }

    private func record(_ video: Bool) {
        self.video = video
        started = Date()
        scene = .recording
    }
}

@MainActor
private final class DemoStatusItem: NSObject {
    private lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    func show(started: Date?) {
        timer?.invalidate()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(open)
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.image = NSImage(systemSymbolName: started == nil ? "waveform" : "waveform.badge.microphone",
                               accessibilityDescription: "AnyRec Website Demo")
        button.title = started == nil ? "" : Wording.clock(0)
        guard let started else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak button] _ in
            MainActor.assumeIsolated { button?.title = Wording.clock(Date().timeIntervalSince(started)) }
        }
    }

    @objc private func open() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "AnyRec Website Demo" })?.makeKeyAndOrderFront(nil)
    }
}
#endif
