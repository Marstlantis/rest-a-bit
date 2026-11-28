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
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("restabit-icon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: scratch) }

func compressedPNG(_ data: Data, for tag: String) throws -> Data {
    let input = scratch.appendingPathComponent("\(tag).png")
    let output = scratch.appendingPathComponent("\(tag)-compressed.png")
    try data.write(to: input)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["pngcrush", "-q", input.path, output.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() }
    catch { return data }
    process.waitUntilExit()
    guard process.terminationStatus == 0, let compressed = try? Data(contentsOf: output),
          compressed.count < data.count else { return data }
    return compressed
}

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
    let payload = try compressedPNG(encoded as Data, for: tag)
    contents.append(Data(tag.utf8))
    contents.append(bigEndianLength(payload.count + 8))
    contents.append(payload)
}

var file = Data("icns".utf8)
file.append(bigEndianLength(contents.count + 8))
file.append(contents)
try file.write(to: destination, options: .atomic)
