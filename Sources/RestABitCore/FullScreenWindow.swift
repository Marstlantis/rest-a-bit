import CoreGraphics

public enum FullScreenWindow {
    public static func matchesDisplay(_ window: CGRect, display: CGRect) -> Bool {
        guard !window.isEmpty, !display.isEmpty else { return false }
        let tolerance: CGFloat = 2
        return abs(window.minX - display.minX) <= tolerance &&
            abs(window.minY - display.minY) <= tolerance &&
            abs(window.maxX - display.maxX) <= tolerance &&
            abs(window.maxY - display.maxY) <= tolerance
    }
}
