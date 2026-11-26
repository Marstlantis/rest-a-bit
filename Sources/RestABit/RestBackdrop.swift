import ImageIO
import SwiftUI

extension RestScene {
    var illustration: CGImage? {
        guard Self.variants.contains(self),
              let url = Bundle.module.url(forResource: rawValue, withExtension: "jpg", subdirectory: "Assets/Scenes"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

struct RestBackdrop: View {
    let image: CGImage
    let size: CGSize
    let palette: Palette

    var body: some View {
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height, alignment: .bottom)
                .clipped()
                .opacity(palette.dark ? 0.29 : 0.95)

            RadialGradient(colors: [palette.paper.opacity(palette.dark ? 0.58 : 0.82), .clear],
                           center: UnitPoint(x: 0.5, y: 0.46), startRadius: 30,
                           endRadius: min(size.width, size.height) * 0.55)

            LinearGradient(stops: [
                .init(color: .clear, location: 0.76),
                .init(color: palette.paper.opacity(palette.dark ? 0.65 : 0.56), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}
