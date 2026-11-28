import AppKit
import ImageIO
import QuartzCore
import SwiftUI
import RestABitCore

enum PelvicPracticeMotion: String, CaseIterable {
    case curl, low, sway

    func frames(motion: Bool = true) -> [CGImage] {
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "webp",
                                          subdirectory: "Assets/PelvicPractice"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let color = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let count = CGImageSourceGetCount(source)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let rgba = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var result: [CGImage] = []
        for index in 0..<(motion ? count : min(count, 1)) {
            let frame: CGImage? = autoreleasepool {
                // WebP frames can use different byte layouts. Give the still and animated
                // contents the same explicit format before handing them to Core Animation.
                guard let image = CGImageSourceCreateImageAtIndex(source, index, options),
                      let bitmap = CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: color, bitmapInfo: rgba) else { return nil }
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return bitmap.makeImage()
            }
            guard let frame else {
                return Array(result.prefix(1))
            }
            result.append(frame)
        }
        return result
    }
}

@MainActor
private final class PracticePanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { dismiss?() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 { dismiss?() }
        else { super.sendEvent(event) }
    }
}

@MainActor
private final class PracticeClock: ObservableObject {
    @Published var startedAt: TimeInterval?
}

@MainActor
final class PelvicPracticePresentation {
    let preview: Bool
    private let card: PracticePanel
    private let stage: NudgePanel
    private let cardView: NSHostingView<PracticeCard>
    private let clock = PracticeClock()

    init?(screen: NSScreen, art: FoxArt?, style: PelvicPracticeMotion, motion: Bool, preview: Bool,
          start: @escaping () -> Void, dismiss: @escaping () -> Void) {
        let safe = screen.visibleFrame
        guard safe.width >= 308, safe.height >= 280 else { return nil }
        let width = min(392, safe.width - 24)
        let height = min(148, safe.height * 0.35)
        let stageSize = CGSize(width: width, height: height)
        self.preview = preview
        cardView = NSHostingView(rootView: PracticeCard(clock: clock, width: width, start: start, dismiss: dismiss))
        let cardSize = CGSize(width: width, height: ceil(cardView.fittingSize.height))
        let groupHeight = stageSize.height + cardSize.height + 3
        let cardFrame = CGRect(x: safe.midX - width / 2, y: safe.midY - groupHeight / 2,
                               width: width, height: cardSize.height)
        let stageFrame = CGRect(x: cardFrame.minX, y: cardFrame.maxY + 3, width: width, height: stageSize.height)
        card = PracticePanel(contentRect: cardFrame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        stage = NudgePanel(contentRect: stageFrame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        configure(card, level: NudgePresentation.level)
        configure(stage, level: NudgePresentation.level)
        card.title = Reminder.pelvicFloor.name
        card.dismiss = dismiss
        card.becomesKeyOnlyIfNeeded = false
        card.hasShadow = false
        stage.hasShadow = false
        stage.ignoresMouseEvents = true
        let pixelScale = screen.backingScaleFactor
        let forest = Bundle.module.url(forResource: "pelvicForest", withExtension: "png", subdirectory: "Assets")
            .flatMap { ArtworkBitmap.load($0, maxPixelSize: Int(ceil(width * pixelScale))) }
        let foxPixels = Int(ceil(height * pixelScale))
        let frames = style.frames(motion: motion)
        let sprites = frames.isEmpty ? [art?.frame(for: .rearLook, maxPixelSize: foxPixels)].compactMap { $0 } : frames
        stage.contentView = NSHostingView(rootView: PracticeForest(clock: clock, size: stageSize,
                                                                   forest: forest, sprites: sprites, motion: motion))
        card.contentView = cardView
    }

    var isRunning: Bool { clock.startedAt != nil }

    func show() {
        stage.orderFrontRegardless()
        card.orderFrontRegardless()
    }

    func refreshCopy() {
        card.title = Reminder.pelvicFloor.name
        let updated = cardView.rootView
        cardView.rootView = updated
    }

    func start(at uptime: TimeInterval) {
        clock.startedAt = uptime
    }

    func close() {
        card.close()
        stage.close()
        card.dismiss = nil
        card.contentView = nil
        stage.contentView = nil
    }

    #if DEBUG
    var isCompactAndClickThrough: Bool {
        guard let screen = card.screen else { return false }
        let group = card.frame.union(stage.frame)
        let safe = screen.visibleFrame
        return stage.ignoresMouseEvents && !card.isKeyWindow &&
            abs(group.midX - safe.midX) < 2 && abs(group.midY - safe.midY) < 2 && group.width <= 392
    }

    var isClosed: Bool { !card.isVisible && !stage.isVisible }

    func capture(in folder: URL, label: String) -> Bool {
        guard let forestView = stage.contentView, card.isVisible else { return false }
        return ProbeCapture.stage(forestView, flipped: true, to: folder.appendingPathComponent("practice-forest-\(label).png")) &&
            ProbeCapture.view(cardView, to: folder.appendingPathComponent("practice-card-\(label).png"))
    }
    #endif
}

private struct PracticeForest: View {
    @ObservedObject var clock: PracticeClock
    @Environment(\.colorScheme) private var colorScheme
    @State private var arrived = false
    let size: CGSize
    let forest: CGImage?
    let sprites: [CGImage]
    let motion: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            if let forest {
                Image(decorative: forest, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width - 8, height: size.height, alignment: .bottom)
                    .brightness(colorScheme == .dark ? -0.10 : 0)
            }

            PracticeFox(frames: sprites, startedAt: clock.startedAt)
                .frame(width: size.height, height: size.height - 16)
                .offset(x: arrived || !motion ? -8 : -46, y: -12)
                .opacity(arrived || !motion ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 0.70)) { arrived = true } }
    }
}

private struct PracticeFox: NSViewRepresentable {
    let frames: [CGImage]
    let startedAt: TimeInterval?

    func makeNSView(context: Context) -> PracticeFoxView {
        PracticeFoxView(frames: frames)
    }

    func updateNSView(_ view: PracticeFoxView, context: Context) {
        if let startedAt { view.play(startedAt: startedAt) }
    }
}

@MainActor
private final class PracticeFoxView: NSView {
    private let frames: [CGImage]
    private var animationStart: TimeInterval?

    init(frames: [CGImage]) {
        self.frames = frames
        super.init(frame: .zero)
        let artwork = CALayer()
        artwork.contents = frames.first
        artwork.contentsGravity = .resizeAspect
        layer = artwork
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    func play(startedAt: TimeInterval) {
        guard frames.count > 1, animationStart != startedAt, let layer else { return }
        animationStart = startedAt
        let timeline = PelvicPracticeTiming.foxKeyframes(frameCount: frames.count)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = timeline.map { frames[$0.frame] }
        animation.keyTimes = timeline.map { NSNumber(value: $0.time / PelvicPracticeTiming.duration) } + [1]
        animation.calculationMode = .discrete
        animation.duration = PelvicPracticeTiming.duration
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        animation.beginTime = layer.convertTime(CACurrentMediaTime() - elapsed, from: nil)
        layer.add(animation, forKey: "practice.poses")
    }
}

private struct PracticeCard: View {
    @ObservedObject var clock: PracticeClock
    @Environment(\.colorScheme) private var colorScheme
    let width: CGFloat
    let start: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let palette = Palette(dark: colorScheme == .dark)
        VStack(alignment: .leading, spacing: 0) {
            if let startedAt = clock.startedAt {
                TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                    let cue = PelvicPracticeTiming.cue(elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
                    practice(cue, palette: palette)
                }
            } else {
                invitation(palette)
            }
        }
        .padding(.horizontal, 18)
        .frame(width: width - 14, height: 156, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 19)
                .fill(palette.paper)
                .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(palette.hairline) }
                .shadow(color: .black.opacity(0.13), radius: 4, x: 0, y: 2)
        }
        .padding(7)
    }

    private func invitation(_ palette: Palette) -> some View {
        let duration = Int(PelvicPracticeTiming.exerciseSeconds)
        return VStack(alignment: .leading, spacing: 8) {
            Text(Reminder.pelvicFloor.nudge)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(Copy.text("坐稳，像忍住排气一样轻提盆底。",
                           "Sit comfortably. Gently squeeze and lift your pelvic floor."))
                .font(.system(size: 12))
                .foregroundStyle(palette.quiet)
                .fixedSize(horizontal: false, vertical: true)
            Text(Copy.text("约 \(duration) 秒 · 自然呼吸，臀腿放松。",
                           "About \(duration) sec · Breathe normally. Relax your legs and glutes."))
                .font(.system(size: 11))
                .foregroundStyle(palette.quiet)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(Copy.text("下次再练", "Not now"), action: dismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.quiet)
                    .padding(5)
                Button(action: start) {
                    Text(Copy.text("开始跟练", "Start"))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(palette.shade, in: Capsule())
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func practice(_ cue: PelvicPracticeTiming.Cue, palette: Palette) -> some View {
        let title: String = switch cue.phase {
        case .prepare: Copy.text("坐舒服，准备哈", "Sit comfortably")
        case .squeeze: Copy.text("轻收盆底", "Squeeze and lift")
        case .release: Copy.text("完全放松", "Relax fully")
        case .finished: Copy.text("练完啦，歇哈嘛", "All done")
        }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if cue.secondsLeft > 0 {
                    Text(Copy.text("\(cue.secondsLeft) 秒", "\(cue.secondsLeft) sec"))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                }
            }
            if cue.phase != .finished {
                Text(Copy.text("自然呼吸，臀腿放松。疼痛就停。",
                               "Breathe normally. Relax your legs and glutes. Stop if it hurts."))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: cue.progress)
                .tint(palette.accent)
                .accessibilityLabel(Copy.text("练习进度", "Kegel exercise progress"))
            HStack {
                if cue.round > 0 {
                    Text(Copy.text("第 \(cue.round) / \(PelvicPracticeTiming.rounds) 轮",
                                   "Rep \(cue.round) of \(PelvicPracticeTiming.rounds)"))
                        .foregroundStyle(palette.quiet)
                }
                Spacer()
                Button(cue.phase == .finished ? Copy.text("关闭", "Close") : Copy.text("结束练习", "End session"),
                       action: dismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
            }
            .font(.system(size: 12))
        }
    }
}
