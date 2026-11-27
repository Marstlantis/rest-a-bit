import AppKit
import QuartzCore
import SwiftUI
import RestABitCore

@MainActor
final class NudgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RestPanel: NSPanel {
    var escape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            escape?()
        } else {
            super.sendEvent(event)
        }
    }

    override func cancelOperation(_ sender: Any?) { escape?() }
}

@MainActor
func configure(_ panel: NSPanel, level: NSWindow.Level) {
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = level
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .none
}

@MainActor
final class NudgePresentation {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    let batch: ReminderBatch
    let screen: NSScreen
    let preview: Bool
    let demo: Bool
    let dismissOnly: Bool
    let frontmostPID: pid_t?
    private let card: NudgePanel
    private let cardView: NSHostingView<NudgeCard>
    private let initialCardFrame: CGRect
    private let stage: NudgePanel?
    private let player: FoxPlayer?
    private let clip: FoxClip?
    private let landing: Landing?
    private let anchor: CGPoint?
    private let preferredArrow: ScreenEdge?

    init(batch: ReminderBatch, screen: NSScreen, cardFrame: CGRect, landing: Landing?, water: WaterScene?, art: FoxArt?,
         preview: Bool, demo: Bool, dismissOnly: Bool, style: EdgeMotion, motion: Bool, confirm: @escaping () -> Void, postpone: @escaping () -> Void) {
        self.batch = batch
        self.screen = screen
        self.preview = preview
        self.demo = demo
        self.dismissOnly = dismissOnly
        initialCardFrame = cardFrame
        self.landing = landing
        anchor = landing?.stop ?? water?.cueAnchor
        preferredArrow = landing?.origin.calloutSide ?? (water == nil ? nil : .top)
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        card = NudgePanel(contentRect: cardFrame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        configure(card, level: Self.level)
        card.hasShadow = false
        card.title = batch.main.name
        cardView = NSHostingView(rootView: NudgeCard(batch: batch, edge: landing?.callout.arrow ?? water?.callout.arrow, preview: preview,
                                                      dismissOnly: dismissOnly, confirm: confirm, deferBreak: postpone))
        cardView.sizingOptions = .intrinsicContentSize
        card.contentView = cardView
        if let frame = landing?.stage ?? water?.frame, let art {
            let stage = NudgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            configure(stage, level: Self.level)
            stage.hasShadow = false
            stage.ignoresMouseEvents = true
            let player = FoxPlayer(frame: CGRect(origin: .zero, size: frame.size), art: art,
                                   backingScale: screen.backingScaleFactor)
            stage.contentView = water?.stage(containing: player) ?? player
            self.stage = stage
            self.player = player
            if let landing {
                clip = FoxClip.entrance(to: landing, kind: batch.main, motion: style)
            } else {
                clip = motion ? .water() : nil
                if !motion {
                    player.place(.drinkSip, at: WaterScene.foxStop)
                }
            }
        } else {
            stage = nil
            player = nil
            clip = nil
        }
    }

    var entranceDuration: Double { clip?.duration ?? 0 }

    func showEntrance() {
        guard let stage else { return }
        if let clip { player?.prepare(clip) }
        stage.orderFrontRegardless()
        if let clip {
            DispatchQueue.main.async { [weak self, weak stage] in
                guard stage?.isVisible == true else { return }
                self?.player?.play(clip)
            }
        }
    }

    private var fittedCardBody: CGSize? {
        let size = cardView.fittingSize
        let insets = cardView.rootView.arrowInsets
        let body = CGSize(width: ceil(size.width - insets.width), height: ceil(size.height - insets.height))
        return body.width.isFinite && body.height.isFinite && body.width > 0 && body.height > 0 ? body : nil
    }

    private func placeCard() {
        let pointer = NSEvent.mouseLocation
        let compact = batch.main == .water
        let body = fittedCardBody
        if let anchor, let preferredArrow,
           let placement = Landing.callout(near: anchor, in: screen.visibleFrame,
                                           pointer: pointer, preferred: preferredArrow, compact: compact,
                                           fittedBody: body) {
            if cardView.rootView.edge != placement.arrow {
                cardView.rootView.edge = placement.arrow
            }
            card.setFrame(placement.frame, display: false)
        } else if let body {
            // Retain the safe original placement for a cue shown without an animated anchor.
            cardView.rootView.edge = nil
            let width = min(initialCardFrame.width, body.width)
            let height = min(initialCardFrame.height, body.height)
            card.setFrame(CGRect(x: initialCardFrame.midX - width / 2, y: initialCardFrame.midY - height / 2,
                                 width: width, height: height), display: false)
        }
    }

    func showCard(animated: Bool) {
        if let landing, let stage {
            // Once the fox has arrived, the rest of the transparent window is empty.
            let stationary = CGRect(x: landing.stop.x - 92, y: landing.stop.y - 92, width: 184, height: 184)
                .intersection(screen.visibleFrame)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stage.setFrame(stationary, display: false)
            player?.settle(at: CGPoint(x: landing.stop.x - stationary.minX, y: landing.stop.y - stationary.minY))
            CATransaction.commit()
        }
        placeCard()
        let origin = card.frame.origin
        let entranceOffset: CGPoint
        switch cardView.rootView.edge {
        case .left: entranceOffset = CGPoint(x: -4, y: 0)
        case .right: entranceOffset = CGPoint(x: 4, y: 0)
        case .top: entranceOffset = CGPoint(x: 0, y: 4)
        case .bottom: entranceOffset = CGPoint(x: 0, y: -4)
        case nil: entranceOffset = .zero
        }
        if animated {
            card.setFrameOrigin(CGPoint(x: origin.x + entranceOffset.x, y: origin.y + entranceOffset.y))
        }
        card.alphaValue = animated ? 0 : 1
        card.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                card.animator().setFrameOrigin(origin)
                card.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(element: card.contentView ?? card, notification: .announcementRequested,
                             userInfo: [.announcement: batch.main.nudge,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func refreshCopy() {
        card.title = batch.main.name
        let currentView = cardView.rootView
        cardView.rootView = currentView
        if card.isVisible { placeCard() }
    }

    func close() {
        card.close()
        stage?.close()
        player?.clear()
        card.contentView = nil
        stage?.contentView = nil
    }

    #if DEBUG
    var stageFrame: CGRect? { landing?.stage ?? stage?.frame }
    var usesCompactStage: Bool {
        guard let stage else { return false }
        return stage.frame.width <= 184 && stage.frame.height <= 184
    }

    var waterSceneIsCentered: Bool {
        guard batch.main == .water, let stage, stage.ignoresMouseEvents else { return false }
        let viewport = screen.visibleFrame
        return abs(stage.frame.midX - viewport.midX) <= 1 &&
            abs(stage.frame.midY - viewport.midY) <= 1 && clip?.poses.last?.frame == .drinkSip
    }
    var cardFrame: CGRect { card.frame }

    var cardFitsLocalizedContent: Bool {
        let size = cardView.fittingSize
        return size.width > 0 && size.height > 0 &&
            card.frame.width + 1 >= size.width && card.frame.height + 1 >= size.height
    }

    var arrivesAtCenter: Bool {
        guard let stage, stage.ignoresMouseEvents, let point = player?.settledPosition else { return false }
        let actual = CGPoint(x: stage.frame.minX + point.x, y: stage.frame.minY + point.y)
        let visible = screen.visibleFrame
        return abs(actual.x - visible.midX) <= 1 && abs(actual.y - visible.midY) <= 1
            && !card.frame.contains(actual)
    }

    var keepsForwardHeading: Bool {
        guard let landing, let clip else { return false }
        let dx = landing.stop.x - landing.entry.x
        let dy = landing.stop.y - landing.entry.y
        func forward(_ point: FoxClip.Point) -> CGFloat {
            let x = clip.mirrored ? landing.stage.width - point.position.x : point.position.x
            return x * dx + point.position.y * dy
        }
        let positions = clip.points.map(forward)
        let neverReverses = zip(positions, positions.dropFirst()).allSatisfy { $1 >= $0 - 0.001 }
        switch landing.origin {
        case .top: return neverReverses && clip.poses.last?.frame == .frontStand
        case .bottom:
            return neverReverses && clip.poses.contains { $0.frame == .rearStand }
                && clip.poses.last?.frame == .rearLook
        default: return neverReverses
        }
    }

    var slowsBeforeArrival: Bool {
        guard let clip, let arrival = clip.arrivalTime else { return false }
        guard let before = clip.points.last(where: { $0.time <= arrival - 0.24 })?.position,
              let nearer = clip.points.last(where: { $0.time <= arrival - 0.12 })?.position,
              let final = clip.points.last?.position else { return false }
        return hypot(final.x - nearer.x, final.y - nearer.y)
            < hypot(nearer.x - before.x, nearer.y - before.y)
    }

    func captureFox(to file: URL) -> Bool {
        guard let stage, let view = stage.contentView else { return false }
        let canvas = landing?.stage.offsetBy(dx: -stage.frame.minX, dy: -stage.frame.minY)
        return ProbeCapture.stage(view, in: canvas, to: file)
    }

    func captureCard(to file: URL) -> Bool {
        card.isVisible && ProbeCapture.view(cardView, to: file)
    }
    #endif

    func retreat(finished: @escaping () -> Void) {
        card.orderOut(nil)
        guard let stage else { close(); finished(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            stage.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.close()
                finished()
            }
        })
    }

}

@MainActor
final class RestPresentation: NSObject, NSWindowDelegate {
    private let window: RestPanel
    private let motion: Bool
    private let screenFrame: CGRect
    let timing: RestTiming
    private var ended: (() -> Void)?
    let frontmostPID: pid_t?

    init(batch: ReminderBatch, screen: NSScreen, art: FoxArt?, duration: Double,
         scene: RestScene, motion: Bool, ended: @escaping () -> Void) {
        self.ended = ended
        self.motion = motion
        screenFrame = screen.frame
        let illustration = scene.illustration
        let frames = art?.frames(for: motion ? [.step, .run, .gather] : [.stand],
                                 maxPixelSize: Int(ceil(42 * screen.backingScaleFactor))) ?? [:]
        timing = RestTiming(startedAt: ProcessInfo.processInfo.systemUptime, duration: duration)
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window = RestPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        configure(window, level: .screenSaver)
        window.title = batch.main.name
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.delegate = self
        window.escape = { [weak self] in self?.ended?() }
        window.contentView = NSHostingView(rootView: RestScreen(batch: batch, timing: timing,
                                                               fox: frames, illustration: illustration, motion: motion,
                                                               close: { [weak self] in self?.ended?() }))
    }

    var hasKeyboard: Bool { window.isKeyWindow }

    func show() {
        window.setFrame(screenFrame, display: false)
        window.alphaValue = motion ? 0.04 : 1
        window.makeKeyAndOrderFront(nil)
        if motion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.23
                window.animator().alphaValue = 1
            }
        }
    }

    func close(animated: Bool, finished: @escaping () -> Void = {}) {
        window.delegate = nil
        window.escape = nil
        ended = nil
        guard animated && motion else {
            releaseWindow()
            finished()
            return
        }
        // Give up the keyboard at the scheduled end, even during the fade.
        window.ignoresMouseEvents = true
        window.resignKey()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.releaseWindow()
                finished()
            }
        })
    }

    private func releaseWindow() {
        window.close()
        window.contentView = nil
    }

    #if DEBUG
    var coversScreenAboveMenuBar: Bool {
        let number = CGWindowID(window.windowNumber)
        let descriptions = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]]
        let entry = descriptions?.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number }
        let actualLayer = (entry?[kCGWindowLayer as String] as? NSNumber)?.intValue
        let menuBarLayer = max(Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow)))
        return window.frame == screenFrame && (actualLayer ?? window.level.rawValue) > menuBarLayer
    }

    func postEscapeForProbe() {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53) else { return }
        NSApp.postEvent(event, atStart: true)
    }

    func capture(to file: URL) -> Bool {
        window.contentView.map { ProbeCapture.view($0, to: file) } ?? false
    }
    #endif

    func windowDidResignKey(_ notification: Notification) {
        ended?()
    }
}
