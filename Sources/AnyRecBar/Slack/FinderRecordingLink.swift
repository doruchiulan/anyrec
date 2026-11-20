import AppKit

enum FinderRecordingLink {
    static func oneDriveRoot(for file: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let storage = home.appendingPathComponent("Library/CloudStorage").standardizedFileURL.resolvingSymlinksInPath()
        let path = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = storage.pathComponents
        guard path.starts(with: parent), path.count > parent.count + 1 else { return nil }
        let name = path[parent.count]
        guard name == "OneDrive" || name.hasPrefix("OneDrive-") else { return nil }
        return storage.appendingPathComponent(name)
    }

    static func providerURL(_ text: String) -> URL? {
        guard let url = DraftRecordingLink.parse(text), let host = url.host?.lowercased() else { return nil }
        let domains = ["1drv.ms", "onedrive.live.com", "sharepoint.com", "sharepoint.us", "sharepoint-mil.us",
                       "sharepoint.cn", "sharepoint.de"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) } ? url : nil
    }

    @MainActor static func fetch(_ file: URL) async throws -> URL {
        guard oneDriveRoot(for: file) != nil, (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { throw DraftError("Choose the uploaded media file in your OneDrive folder.") }
        guard AXIsProcessTrusted() else { throw DraftError("Allow Accessibility access to use Finder’s Copy Link.") }
        NSWorkspace.shared.activateFileViewerSelecting([file])
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw DraftError("Finder couldn’t open the OneDrive file.")
        }
        let finder = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(finder, 0.35)
        guard let target = try await poll(seconds: 4, {
            app.isActive ? FinderFileMenu.selectedFile(file, in: finder) : nil
        }) else { throw DraftError("Finder couldn’t verify the selected file. You can paste its sharing link here.") }
        return try await copy(file: target, name: file.lastPathComponent, pid: app.processIdentifier)
    }

    @MainActor private static func copy(file: AXUIElement, name: String, pid: pid_t) async throws -> URL {
        let existing = Set(FinderFileMenu.menuWindows(pid: pid).keys)
        AXUIElementSetMessagingTimeout(file, 0.35)
        let shown = AXUIElementPerformAction(file, kAXShowMenuAction as CFString)
        guard [.success, .cannotComplete].contains(shown),
              let menu = try await poll(seconds: 3, { FinderFileMenu.openedMenu(pid: pid, excluding: existing) }) else {
            throw DraftError("Finder couldn’t open the file menu. You can paste the link instead.")
        }
        defer { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        guard let command = try await poll(seconds: 2, { FinderFileMenu.copyCommand(in: menu) }) else {
            throw DraftError("OneDrive’s Copy Link command isn’t available for this file.")
        }
        let before = NSPasteboard.general.changeCount
        let pressed = AXUIElementPerformAction(command, kAXPressAction as CFString)
        guard [.success, .cannotComplete].contains(pressed) else {
            throw DraftError("Finder couldn’t invoke OneDrive’s Copy Link.")
        }
        return try await receiveLink(for: name, after: before)
    }

    @MainActor static func receiveLink(for fileName: String, after before: Int) async throws -> URL {
        let board = NSPasteboard.general
        var confirmed = false
        let link: URL? = try await poll(seconds: 20) {
            if board.changeCount != before {
                for type in [NSPasteboard.PasteboardType.URL, .string] {
                    if let text = board.string(forType: type), let link = providerURL(text) { return link }
                }
            }
            if !confirmed, let button = OneDriveLinkWindow.copyButton(for: fileName) {
                confirmed = true
                _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
            return nil
        }
        guard let link else { throw DraftError("OneDrive didn’t copy a sharing link. You can paste it here.") }
        return link
    }

    @MainActor private static func poll<T>(seconds: TimeInterval, _ read: () -> T?) async throws -> T? {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            try Task.checkCancellation()
            if let result = read() { return result }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }
}
