import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

private let side = 264
private let frameCount = 25
private let space = CGColorSpace(name: CGColorSpace.sRGB)!
private typealias Point = SIMD2<Float>
private typealias Pixel = SIMD4<Float>

enum BakeError: Error { case arguments, image(URL), output(URL) }

private struct TailRig {
    let root: Point
    let turn: Float
    let tipMotion: Point
    let footLine: Float

    func velocity(at point: Point) -> Point {
        let alongTail = smoothStep((root.x - point.x) / 0.29)
        let aboveFeet = 1 - smoothStep((point.y - footLine) / 0.14)
        let radius = point - root
        let rotation = Point(-radius.y, radius.x) * turn
        return (rotation + tipMotion) * alongTail * aboveFeet
    }
}

private let rigs: [String: TailRig] = [
    "curl": TailRig(root: Point(0.48, 0.55), turn: 0.27, tipMotion: Point(0.046, 0.012), footLine: 0.68),
    "low": TailRig(root: Point(0.49, 0.56), turn: -0.24, tipMotion: Point(0.050, 0.033), footLine: 0.69),
    "sway": TailRig(root: Point(0.50, 0.55), turn: 0.19, tipMotion: Point(-0.032, -0.038), footLine: 0.68),
]

private func smoothStep(_ value: Float) -> Float {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
}

private func context(data: UnsafeMutableRawPointer? = nil) -> CGContext {
    CGContext(data: data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

private func load(_ url: URL) throws -> [Pixel] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BakeError.image(url) }
    let canvas = context()
    let size = CGFloat(side)
    let scale = size / CGFloat(max(image.width, image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    canvas.interpolationQuality = .high
    canvas.draw(image, in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
    let buffer = canvas.data!.assumingMemoryBound(to: SIMD4<UInt8>.self)
    let drawing = (0..<(side * side)).map { Pixel(buffer[$0]) }
    var minimum = Point(repeating: Float(side))
    var maximum = Point.zero
    for (offset, pixel) in drawing.enumerated() where pixel.w >= 128 {
        let point = Point(Float(offset % side), Float(offset / side))
        minimum = simd_min(minimum, point)
        maximum = simd_max(maximum, point)
    }
    let extent = maximum - minimum
    guard extent.x > 0, extent.y > 0 else { throw BakeError.image(url) }
    let fit = min(222 / extent.x, 224 / extent.y)
    let center = (minimum.x + maximum.x) / 2
    let offset = Point(Float(side - 1) / 2 - center * fit, 244 - maximum.y * fit)
    return (0..<drawing.count).map { index in
        let point = Point(Float(index % side), Float(index / side))
        return sample(drawing, at: ((point - offset) / fit) / Float(side - 1))
    }
}

private func sample(_ image: [Pixel], at position: Point) -> Pixel {
    let p = position * Float(side - 1)
    guard p.x >= 0, p.y >= 0, p.x <= Float(side - 1), p.y <= Float(side - 1) else { return .zero }
    let x = Int(p.x), y = Int(p.y)
    let x1 = min(x + 1, side - 1), y1 = min(y + 1, side - 1)
    let fx = p.x - Float(x), fy = p.y - Float(y)
    let top = image[y * side + x] * (1 - fx) + image[y * side + x1] * fx
    let bottom = image[y1 * side + x] * (1 - fx) + image[y1 * side + x1] * fx
    return top * (1 - fy) + bottom * fy
}

private func save(_ pixels: [Pixel], to url: URL) throws {
    var bytes = pixels.map { SIMD4<UInt8>(simd_clamp($0.rounded(.toNearestOrAwayFromZero), .zero, Pixel(repeating: 255))) }
    try bytes.withUnsafeMutableBytes { buffer in
        guard let image = context(data: buffer.baseAddress).makeImage(),
              let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw BakeError.output(url) }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw BakeError.output(url) }
    }
}

private func bake(_ drawing: [Pixel], rig: TailRig, to folder: URL) throws {
    let unit = Float(side - 1)
    for index in 0..<frameCount {
        let amount = smoothStep(Float(index) / Float(frameCount - 1))
        let frame = (0..<drawing.count).map { offset -> Pixel in
            let point = Point(Float(offset % side), Float(offset / side)) / unit
            guard amount > 0, point.x < rig.root.x, point.y < rig.footLine + 0.14 else { return drawing[offset] }
            // Backtrace through small steps of one smooth field. The same fur texture spans
            // the tail and hip, with zero displacement where the tail joins the body.
            var source = point
            for _ in 0..<8 {
                source -= rig.velocity(at: source) * (amount / 8)
            }
            return sample(drawing, at: source)
        }
        try save(frame, to: folder.appendingPathComponent(String(format: "frame-%03d.png", index)))
    }
}

let args = CommandLine.arguments
guard args.count == 4, let rig = rigs[args[1]] else {
    FileHandle.standardError.write(Data("Usage: animate_practice curl|low|sway DRAWING.png OUTPUT_DIRECTORY\n".utf8))
    throw BakeError.arguments
}
try bake(load(URL(fileURLWithPath: args[2])), rig: rig, to: URL(fileURLWithPath: args[3]))
