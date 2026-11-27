import AppKit

enum StatusIcon {
    static let fillSteps = 28

    static func image(accessibilityLabel: String, fill: CGFloat? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }

            let face = CGMutablePath()
            face.move(to: CGPoint(x: 9, y: 2.2))
            face.addCurve(to: CGPoint(x: 1.3, y: 6.7),
                          control1: CGPoint(x: 6.8, y: 2.2), control2: CGPoint(x: 3, y: 5))
            face.addQuadCurve(to: CGPoint(x: 1.4, y: 7.8), control: CGPoint(x: 0.7, y: 7.3))
            face.addQuadCurve(to: CGPoint(x: 3.25, y: 9.5), control: CGPoint(x: 2.35, y: 8.45))
            face.addLine(to: CGPoint(x: 2.75, y: 15.1))
            face.addQuadCurve(to: CGPoint(x: 4.1, y: 15.8), control: CGPoint(x: 2.6, y: 16.35))
            face.addLine(to: CGPoint(x: 7.3, y: 12.95))
            face.addQuadCurve(to: CGPoint(x: 10.7, y: 12.95), control: CGPoint(x: 9, y: 13.5))
            face.addLine(to: CGPoint(x: 13.9, y: 15.8))
            face.addQuadCurve(to: CGPoint(x: 15.25, y: 15.1), control: CGPoint(x: 15.4, y: 16.35))
            face.addLine(to: CGPoint(x: 14.75, y: 9.5))
            face.addQuadCurve(to: CGPoint(x: 16.6, y: 7.8), control: CGPoint(x: 15.65, y: 8.45))
            face.addQuadCurve(to: CGPoint(x: 16.7, y: 6.7), control: CGPoint(x: 17.3, y: 7.3))
            face.addCurve(to: CGPoint(x: 9, y: 2.2),
                          control1: CGPoint(x: 15, y: 5), control2: CGPoint(x: 11.2, y: 2.2))
            face.closeSubpath()

            let progress = fill.map { min(1, max(0, $0)) } ?? 1
            context.setFillColor(NSColor.black.withAlphaComponent(progress == 1 ? 1 : 0.42).cgColor)
            context.addPath(face)
            context.fillPath()
            if progress > 0 && progress < 1 {
                let bounds = face.boundingBoxOfPath
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: 0, width: 18, height: bounds.minY + bounds.height * progress))
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(face)
                context.fillPath()
                context.restoreGState()
            }

            // The expression is cut out so wallpaper shows through the system-tinted template.
            context.setBlendMode(.clear)
            context.setLineCap(.round)
            context.setLineWidth(1.2)
            for x in [4.15, 11.05] {
                context.move(to: CGPoint(x: x, y: 8.25))
                context.addQuadCurve(to: CGPoint(x: x + 2.8, y: 8.25),
                                     control: CGPoint(x: x + 1.4, y: 6.7))
            }
            context.strokePath()
            context.fillEllipse(in: CGRect(x: 8.05, y: 4.55, width: 1.9, height: 1.25))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityLabel
        return image
    }
}
