import AppKit
import QuartzCore
import SwiftUI
import RestABitCore

@MainActor
final class BlinkPresentation {
    private let panel: NudgePanel
    private let scene: NSView
    private let player: FoxPlayer?
    private let badge: NSHostingView<BlinkBadge>
    private let clip: FoxClip?
    let preview: Bool

    init(screen: NSScreen, art: FoxArt?, motion: Bool, style: BlinkMotion, preview: Bool) {
        self.preview = preview
        let safe = screen.visibleFrame
        let size = CGSize(width: 226, height: 207)
        let frame = CGRect(x: safe.midX - size.width / 2, y: safe.midY - size.height / 2,
                           width: size.width, height: size.height)
        panel = NudgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        configure(panel, level: NudgePresentation.level)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.title = Reminder.blink.name

        scene = NSView(frame: CGRect(origin: .zero, size: size))
        scene.wantsLayer = true
        if let art {
            let player = FoxPlayer(frame: CGRect(x: 0, y: 39, width: size.width, height: size.height - 39),
                                   art: art, backingScale: screen.backingScaleFactor)
            scene.addSubview(player)
            self.player = player
            clip = motion && art.hasBlinkSequence ? FoxClip.blink(in: size.width, motion: style) : nil
        } else {
            player = nil
            clip = nil
        }
        badge = NSHostingView(rootView: BlinkBadge())
        badge.frame = CGRect(x: 0, y: 0, width: size.width, height: player == nil ? size.height : 51)
        scene.addSubview(badge)
        panel.contentView = scene
    }

    func show() {
        if let clip, let player {
            player.prepare(clip)
            scene.layer?.opacity = 0
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, panel.isVisible else { return }
                player.play(clip)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0, 0]
                fade.keyTimes = [0, 0.13, 0.80, 0.94, 1]
                fade.duration = clip.duration
                scene.layer?.add(fade, forKey: "blink.appearance")
            }
        } else {
            player?.place(.blinkOpen, at: CGPoint(x: scene.bounds.midX, y: 70))
            panel.orderFrontRegardless()
        }
        NSAccessibility.post(element: scene, notification: .announcementRequested,
                             userInfo: [.announcement: Reminder.blink.nudge,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func refreshCopy() {
        panel.title = Reminder.blink.name
        badge.rootView = BlinkBadge()
    }

    func close() {
        panel.close()
        scene.layer?.removeAllAnimations()
        player?.clear()
        panel.contentView = nil
    }

    #if DEBUG
    var passesPointerThrough: Bool { panel.ignoresMouseEvents }
    var windowFrame: CGRect { panel.frame }

    func capture(to file: URL) -> Bool {
        ProbeCapture.stage(scene, to: file)
    }
    #endif
}

private struct BlinkBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette(dark: colorScheme == .dark)
        Label {
            Text(Reminder.blink.nudge)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.ink)
        } icon: {
            ReminderGlyph(reminder: .blink, size: 13)
                .foregroundStyle(palette.accent)
        }
        .padding(.horizontal, 15)
        .frame(height: 34)
        .background {
            let bubble = RoundedRectangle(cornerRadius: 17, style: .circular)
            bubble.fill(palette.paper)
                .overlay { bubble.strokeBorder(palette.hairline, lineWidth: 1) }
                .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
