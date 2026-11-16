import CoreGraphics

/// Which of the library window's side columns give way as the window narrows: the sidebar
/// first, then the inspector, so the recording keeps a usable width. Each threshold sits
/// above the narrowest window the visible columns allow, so the window can only reach the
/// next threshold once the column has gone.
///
/// Acts only when the width crosses a threshold. In between, the toggles are the person's
/// own, so a sidebar shown again by hand in a narrow window is not taken away on the next
/// pixel. A column comes back on its own only if it was hidden here, and only after the
/// window grows past a higher threshold. The gap between the two thresholds keeps it from
/// flickering at one width.
/// A class held in `@State`, so remembering the last width on every frame of a resize does not
/// redraw the window; only a threshold crossing changes what is shown.
final class CompactColumns {
    struct Threshold: Equatable {
        let hide: CGFloat
        let show: CGFloat
    }

    /// The narrowest window with every column is about 1240 pt.
    static let sidebar = Threshold(hide: 1290, show: 1350)
    /// The narrowest window with the inspector and without the sidebar is about 1060 pt.
    static let inspector = Threshold(hide: 1100, show: 1160)

    /// The list's minimum width. With the sidebar hidden, its toolbar row also holds the
    /// window buttons and the sidebar toggle, beside the title ("Unnamed Voices" is the
    /// longest). Narrower, the title ran past the column and the toolbar's separator no
    /// longer lined up with the list's edge.
    static let list: CGFloat = 300

    struct Change: Equatable {
        var sidebar: Bool?
        var inspector: Bool?
    }

    private var width: CGFloat?
    private(set) var hidSidebar = false
    private(set) var hidInspector = false

    /// What to show or hide now the window is `width` wide. Nil fields stay as they are.
    func resized(to width: CGFloat, sidebarVisible: Bool, inspectorVisible: Bool) -> Change {
        let previous = self.width
        self.width = width
        var change = Change()
        if let show = adjust(Self.sidebar, from: previous, to: width, visible: sidebarVisible, hid: &hidSidebar) {
            change.sidebar = show
        }
        if let show = adjust(Self.inspector, from: previous, to: width, visible: inspectorVisible, hid: &hidInspector) {
            change.inspector = show
        }
        return change
    }

    /// A window grown to `width` so a column shown by hand has room. Opened in a window too
    /// narrow for it, the inspector took its width from the list, squeezed it under its
    /// minimum, and ran the list's title under the recording's toolbar. The window keeps its
    /// leading edge where the screen allows, moves left where it does not, and never grows
    /// past the screen.
    static func grown(_ frame: CGRect, to width: CGFloat, within screen: CGRect) -> CGRect? {
        guard frame.width < width else { return nil }
        let wide = min(width, screen.width)
        guard wide > frame.width else { return nil }
        let x = max(screen.minX, min(frame.minX, screen.maxX - wide))
        return CGRect(x: x, y: frame.minY, width: wide, height: frame.height)
    }

    /// Shown by hand: it is the person's again, not ours to hide or bring back.
    func sidebarShown() { hidSidebar = false }
    func inspectorShown() { hidInspector = false }

    private func adjust(
        _ threshold: Threshold, from previous: CGFloat?, to width: CGFloat, visible: Bool, hid: inout Bool
    ) -> Bool? {
        if visible, width < threshold.hide, (previous ?? .infinity) >= threshold.hide {
            hid = true
            return false
        }
        if !visible, hid, width >= threshold.show, (previous ?? 0) < threshold.show {
            hid = false
            return true
        }
        return nil
    }
}
