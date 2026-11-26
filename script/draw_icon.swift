import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: draw_icon <artwork.png> <app.icns>")
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
      image.width == image.height
else { fatalError("Expected square app icon artwork") }

func bigEndianLength(_ value: Int) -> Data {
    var length = UInt32(value).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) }
}

let sizes = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
             ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var contents = Data()
for (tag, length) in sizes {
    let context = CGContext(data: nil, width: length, height: length, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: length, height: length))

    let encoded = NSMutableData()
    let png = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(png, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(png))
    contents.append(Data(tag.utf8))
    contents.append(bigEndianLength(encoded.length + 8))
    contents.append(encoded as Data)
}

var file = Data("icns".utf8)
file.append(bigEndianLength(contents.count + 8))
file.append(contents)
try file.write(to: destination, options: .atomic)
