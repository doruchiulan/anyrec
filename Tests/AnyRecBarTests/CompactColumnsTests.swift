import CoreGraphics
import Testing

@testable import AnyRecBar

@Suite("Library columns in a narrow window")
struct CompactColumnsTests {
    private let sidebar = CompactColumns.sidebar
    private let inspector = CompactColumns.inspector

    @Test("the sidebar goes first, then the inspector, and both come back in reverse")
    func narrowing() {
        var columns = CompactColumns()
        var sidebarShown = true, inspectorShown = true
        func resize(_ width: CGFloat) {
            let change = columns.resized(to: width, sidebarVisible: sidebarShown, inspectorVisible: inspectorShown)
            sidebarShown = change.sidebar ?? sidebarShown
            inspectorShown = change.inspector ?? inspectorShown
        }
        resize(sidebar.show + 100)
        #expect(sidebarShown && inspectorShown)
        resize(sidebar.hide - 10)
        #expect(!sidebarShown && inspectorShown)
        resize(inspector.hide - 10)
        #expect(!sidebarShown && !inspectorShown)
        resize(inspector.show - 10)
        #expect(!inspectorShown, "not back until past the higher threshold")
        resize(inspector.show + 10)
        #expect(!sidebarShown && inspectorShown)
        resize(sidebar.show + 10)
        #expect(sidebarShown && inspectorShown)
    }

    @Test("what the person toggles is left alone")
    func manual() {
        var columns = CompactColumns()
        _ = columns.resized(to: sidebar.show + 100, sidebarVisible: false, inspectorVisible: true)
        #expect(columns.resized(to: sidebar.hide - 10, sidebarVisible: false, inspectorVisible: true) == .init(),
                "hidden by hand, so never brought back")
        #expect(columns.resized(to: sidebar.show + 100, sidebarVisible: false, inspectorVisible: true) == .init())

        _ = columns.resized(to: sidebar.hide - 10, sidebarVisible: true, inspectorVisible: true)
        columns.sidebarShown()
        #expect(columns.resized(to: sidebar.hide - 20, sidebarVisible: true, inspectorVisible: true) == .init(),
                "shown again by hand in a narrow window, it stays")
    }

    @Test("a window opened narrow starts compact")
    func launch() {
        var columns = CompactColumns()
        #expect(columns.resized(to: inspector.hide - 10, sidebarVisible: true, inspectorVisible: true)
                == .init(sidebar: false, inspector: false))
    }

    @Test("the thresholds keep their order and sit above what the columns need")
    func thresholds() {
        #expect(inspector.hide < inspector.show && inspector.show < sidebar.hide && sidebar.hide < sidebar.show)
    }

    @Test("showing a column in a narrow window grows the window, within the screen")
    func grown() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(CompactColumns.grown(CGRect(x: 100, y: 50, width: 900, height: 700), to: 1190, within: screen)
                == CGRect(x: 100, y: 50, width: 1190, height: 700))
        #expect(CompactColumns.grown(CGRect(x: 500, y: 50, width: 900, height: 700), to: 1190, within: screen)
                == CGRect(x: 250, y: 50, width: 1190, height: 700), "moved left to stay on the screen")
        #expect(CompactColumns.grown(CGRect(x: 0, y: 0, width: 900, height: 700), to: 1300,
                                     within: CGRect(x: 0, y: 0, width: 1100, height: 700))?.width == 1100)
        #expect(CompactColumns.grown(CGRect(x: 0, y: 0, width: 1400, height: 700), to: 1190, within: screen) == nil)
    }
}
