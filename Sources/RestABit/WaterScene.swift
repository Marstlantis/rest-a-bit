import AppKit
import RestABitCore

struct WaterScene {
    static let foxStop = CGPoint(x: 172, y: 83)
    let frame: CGRect
    let cueAnchor: CGPoint
    let callout: Landing.Callout
    let illustration: CGImage

    init?(in screen: CGRect, pointer: CGPoint, backingScale: CGFloat) {
        let size = CGSize(width: 380, height: 152)
        guard screen.width >= size.width + 24, screen.height >= size.height + 24,
              let url = Bundle.module.url(forResource: "pond", withExtension: "png", subdirectory: "Assets")
        else { return nil }
        let frame = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                           width: size.width, height: size.height)
        let anchor = CGPoint(x: screen.midX, y: frame.minY + 57)
        guard let callout = Landing.callout(near: anchor, in: screen, pointer: pointer, preferred: .top, compact: true),
              let image = ArtworkBitmap.load(url, maxPixelSize: Int(ceil(size.width * backingScale)))
        else { return nil }
        self.frame = frame
        self.cueAnchor = anchor
        self.callout = callout
        illustration = image
    }

    @MainActor
    func stage(containing fox: FoxPlayer) -> NSView {
        let surface = NSView(frame: CGRect(origin: .zero, size: frame.size))
        surface.wantsLayer = true
        let water = CALayer()
        water.bounds = CGRect(x: 0, y: 0, width: frame.width, height: 62)
        water.position = CGPoint(x: surface.bounds.midX, y: 28)
        water.contents = illustration
        water.contentsGravity = .resizeAspect
        surface.layer?.addSublayer(water)
        surface.addSubview(fox)
        return surface
    }
}
