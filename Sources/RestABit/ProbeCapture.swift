#if DEBUG
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum ProbeCapture {
    static func stage(_ view: NSView, in canvas: CGRect? = nil, to file: URL) -> Bool {
        guard let model = view.layer else { return false }
        let canvas = canvas ?? view.bounds
        let size = canvas.size
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        (model.presentation() ?? model).render(in: context)
        guard let image = context.makeImage(),
              let writer = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(writer, image, nil)
        return CGImageDestinationFinalize(writer)
    }

    static func view(_ view: NSView, to file: URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: file)) != nil
    }
}
#endif
