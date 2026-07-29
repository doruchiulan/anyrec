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

/// Who macOS thinks the grant belongs to. A command-line tool inherits the terminal's
/// grant, so the terminal is what has to be relaunched; a bundled app holds its own
/// and only has to relaunch itself.
public enum PermissionHost: Sendable {
    case terminal
    case application
}

public struct PermissionsError: Error, LocalizedError, CustomStringConvertible {
    public let missing: [Permission]
    public let host: PermissionHost

    public init(missing: [Permission], host: PermissionHost) {
        self.missing = missing
        self.host = host
    }

    public var description: String {
        let names = missing.map(\.rawValue).joined(separator: " and ")
        let links = missing.map { "  \($0.settingsURL.absoluteString)" }.joined(separator: "\n")
        return """
        Missing permission: \(names).

        \(relaunch)

        \(links)
        """
    }

    private var relaunch: String {
        switch host {
        case .terminal:
            """
            macOS grants these to the *terminal application* running anyrec, not to \
            anyrec itself. Enable it here, then quit and reopen your terminal — the \
            grant only takes effect for newly launched processes:
            """
        case .application:
            """
            Enable it here, then quit and reopen anyrec — the grant only takes effect \
            for newly launched processes:
            """
        }
    }

    public var errorDescription: String? { description }
}

public enum Permissions {
    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func microphoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Prompts for anything not yet granted, then throws listing what is still missing.
    public static func preflight(needsMicrophone: Bool, host: PermissionHost) async throws {
        var missing: [Permission] = []

        if !screenRecordingGranted(), !CGRequestScreenCaptureAccess() {
            missing.append(.screenRecording)
        }
        if needsMicrophone, !microphoneGranted() {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { missing.append(.microphone) }
        }

        guard missing.isEmpty else { throw PermissionsError(missing: missing, host: host) }
    }

    @discardableResult
    public static func requestMicrophone() async -> Bool {
        if microphoneGranted() { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// SCShareableContent throws an opaque error without this permission; fail readably instead.
    public static func requireScreenRecording(host: PermissionHost) throws {
        guard screenRecordingGranted() else {
            throw PermissionsError(missing: [.screenRecording], host: host)
        }
    }

    public static func status(needsMicrophone: Bool) -> [(Permission, Bool)] {
        var rows = [(Permission.screenRecording, screenRecordingGranted())]
        if needsMicrophone { rows.append((.microphone, microphoneGranted())) }
        return rows
    }
}
