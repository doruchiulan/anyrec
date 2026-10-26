import AppKit
import SwiftUI
import UserNotifications

struct WelcomeSheet: View {
    static let windowID = "welcome"
    @Bindable var controller: RecordingController
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step = Step.permissions
    @State private var access = WelcomeAccess()

    typealias Step = WelcomeStep

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader(step: $step, permissionsReady: permissionsReady)
            ScrollView {
                content
                    .padding(.horizontal, 34)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 780, height: 740)
        .background(.background)
        .background(WelcomeWindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .tint(.teal)
        .task {
            while !Task.isCancelled {
                await access.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step == .permissions {
                Text(permissionsReady ? "All permissions are ready." : "Grant all permissions and restart if prompted.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let previous { Button("Back") { step = previous } }
            Button(next == nil ? "Start Using AnyRec" : "Continue") {
                if let next { step = next } else { finish() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!permissionsReady)
        }
        .controlSize(.large)
        .padding(.horizontal, 34)
        .padding(.vertical, 22)
        .background(.bar)
    }

    private func finish() {
        guard permissionsReady else { step = .permissions; return }
        controller.completeSetup()
        openWindow(id: LibraryWindow.id)
        dismissWindow(id: Self.windowID)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .permissions: WelcomePermissions(controller: controller, access: access)
        case .transcription: WelcomeTranscription(controller: controller)
        }
    }

    private var previous: Step? {
        Step.allCases.firstIndex(of: step).flatMap { $0 > 0 ? Step.allCases[$0 - 1] : nil }
    }

    private var permissionsReady: Bool { access.allGranted && controller.screenGrantedAtLaunch }

    private var next: Step? {
        Step.allCases.firstIndex(of: step).flatMap {
            $0 + 1 < Step.allCases.count ? Step.allCases[$0 + 1] : nil
        }
    }
}

/// UNUserNotificationCenter aborts outside an app bundle.
enum NotificationPermission {
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    static func granted() async -> Bool? {
        guard let center else { return nil }
        return await center.notificationSettings().authorizationStatus == .authorized
    }

    static func request() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }
}

/// The app again, as a new process: what a grant that only takes effect at launch needs.
enum Relaunch {
    @MainActor static func now() {
        let bundle = Bundle.main.bundlePath
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/bin/sh")
        open.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \"$2\"",
            "anyrec-relaunch", String(ProcessInfo.processInfo.processIdentifier), bundle,
        ]
        try? open.run()
        NSApplication.shared.terminate(nil)
    }
}
