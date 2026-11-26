import AppKit
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
        card.contentView = cardView
        if let frame = landing?.stage ?? water?.frame, let art {
            let stage = NudgePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
            configure(stage, level: Self.level)
            stage.hasShadow = false
            stage.ignoresMouseEvents = true
            let player = FoxPlayer(frame: CGRect(origin: .zero, size: frame.size), art: art)
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

    func showCard(animated: Bool) {
        let pointer = NSEvent.mouseLocation
        if let anchor, let preferredArrow, card.frame.insetBy(dx: -16, dy: -16).contains(pointer),
           let alternate = Landing.callout(near: anchor, in: screen.visibleFrame,
                                           pointer: pointer, preferred: preferredArrow, compact: batch.main == .water) {
            card.setFrame(alternate.frame, display: false)
            cardView.rootView.edge = alternate.arrow
        }
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
    }

    func close() {
        card.orderOut(nil)
        stage?.orderOut(nil)
    }

    #if DEBUG
    var stageFrame: CGRect? { stage?.frame }

    var waterSceneIsCentered: Bool {
        guard batch.main == .water, let stage, stage.ignoresMouseEvents else { return false }
        let viewport = screen.visibleFrame
        return abs(stage.frame.midX - viewport.midX) <= 1 &&
            abs(stage.frame.midY - viewport.midY) <= 1 && clip?.poses.last?.frame == .drinkSip
    }
    var cardFrame: CGRect { card.frame }

    var arrivesAtCenter: Bool {
        guard let stage, stage.ignoresMouseEvents, let clip, let final = clip.points.last else { return false }
        let x = clip.mirrored ? stage.frame.width - final.position.x : final.position.x
        let actual = CGPoint(x: stage.frame.minX + x, y: stage.frame.minY + final.position.y)
        let visible = screen.visibleFrame
        return abs(actual.x - visible.midX) <= 1 && abs(actual.y - visible.midY) <= 1
            && !card.frame.contains(actual)
    }

    var keepsForwardHeading: Bool {
        guard let landing, let stage, let clip else { return false }
        let dx = landing.stop.x - landing.entry.x
        let dy = landing.stop.y - landing.entry.y
        func forward(_ point: FoxClip.Point) -> CGFloat {
            let x = clip.mirrored ? stage.frame.width - point.position.x : point.position.x
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
        stage?.contentView.map { ProbeCapture.stage($0, to: file) } ?? false
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
        art?.prepare(motion ? [.step, .run, .gather] : [.stand])
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
                                                               fox: art, illustration: illustration, motion: motion,
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
            window.orderOut(nil)
            finished()
            return
        }
        // Give up the keyboard at the scheduled end, even during the fade.
        window.ignoresMouseEvents = true
        window.resignKey()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            window.orderOut(nil)
            finished()
        })
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
