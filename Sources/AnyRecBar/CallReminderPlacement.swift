import CoreGraphics

struct CallReminderPlacement {
    static func frame(above window: CGRect, size: CGSize, screens: [CGRect]) -> CGRect? {
        guard window.width > 0, window.height > 0,
            let screen = screens.max(by: { area($0.intersection(window)) < area($1.intersection(window)) }),
            area(screen.intersection(window)) > 0, screen.width >= size.width, screen.height >= size.height
        else { return nil }
        let x = min(max(window.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        let above = window.maxY + 8
        let y = above + size.height <= screen.maxY ? above : window.maxY - size.height - 12
        return CGRect(x: x, y: min(max(y, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
