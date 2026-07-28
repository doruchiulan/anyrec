import AVFoundation
import CoreGraphics
import Foundation

public enum Permission: String, Sendable, CaseIterable {
    case screenRecording = "Screen Recording"
    case microphone = "Microphone"

    var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        }
    }

    public var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")!
    }
}

public struct PermissionsError: Error, CustomStringConvertible {
    public let missing: [Permission]

    public var description: String {
        let names = missing.map(\.rawValue).joined(separator: " and ")
        let links = missing.map { "  \($0.settingsURL.absoluteString)" }.joined(separator: "\n")
        return """
        Missing permission: \(names).

        macOS grants these to the *terminal application* running anyrec, not to \
        anyrec itself. Enable it here, then quit and reopen your terminal — the \
        grant only takes effect for newly launched processes:

        \(links)
        """
    }
}

public enum Permissions {
    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Prompts for anything not yet granted, then throws listing what is still missing.
    public static func preflight(needsMicrophone: Bool) async throws {
        var missing: [Permission] = []

        if !screenRecordingGranted(), !CGRequestScreenCaptureAccess() {
            missing.append(.screenRecording)
        }
        if needsMicrophone, !microphoneGranted() {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { missing.append(.microphone) }
        }

        guard missing.isEmpty else { throw PermissionsError(missing: missing) }
    }

    @discardableResult
    public static func requestMicrophone() async -> Bool {
        if microphoneGranted() { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// SCShareableContent throws an opaque error without this permission; fail readably instead.
    public static func requireScreenRecording() throws {
        guard screenRecordingGranted() else {
            throw PermissionsError(missing: [.screenRecording])
        }
    }

    public static func status(needsMicrophone: Bool) -> [(Permission, Bool)] {
        var rows = [(Permission.screenRecording, screenRecordingGranted())]
        if needsMicrophone { rows.append((.microphone, microphoneGranted())) }
        return rows
    }
}
