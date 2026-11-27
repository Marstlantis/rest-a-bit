import Foundation
import ImageIO

enum ArtworkBitmap {
    static func load(_ url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary) else { return nil }
            if let maxPixelSize {
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
            return CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
    }
}
