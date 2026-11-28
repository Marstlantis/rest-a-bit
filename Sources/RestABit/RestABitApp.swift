import AppKit
import SwiftUI
import OSLog
import RestABitCore

@main
enum RestABitApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private enum Block: Hashable { case sleep, displaySleep, lock, inactiveSession }

    private let log = Logger(subsystem: "local.restabit.app", category: "reminder")
    private let preferences: Preferences
    private let loginAtStartup = LoginAtStartup()
    private let foregroundProtection = ForegroundProtection()
    private var schedule: ReminderSchedule
    private var art: FoxArt?
    private var item: NSStatusItem?
    private var statusMenuIsOpen = false
    private var statusFillStep: Int?
    private let menu = NSMenu()
    private var settings: NSWindow?
    private var settingsFrame: CGRect?
    private var timer: Timer?
    private var blocks: Set<Block> = []
    private var nextPresentation: Double = 0
    private var previousEdge: EntranceOrigin?
    private var previousEdgeMotion: EdgeMotion?
    private var previousBlinkMotion: BlinkMotion?
    private var previousPelvicMotion: PelvicPracticeMotion?
    private var previousRestScene: RestScene?
    private var random = SeededRandom(seed: UInt64.random(in: .min ... .max))
    private var nudge: NudgePresentation?
    private var blink: BlinkPresentation?
    private var pelvicPractice: PelvicPracticePresentation?
    private var retreat: NudgePresentation?
    private var rest: RestPresentation?
    private var fadingRest: RestPresentation?
    private var deadline: DispatchWorkItem?
    private var pendingCommit: ReminderBatch?
    private var testing = false

    override init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        testing = arguments.contains("--ui-probe") || arguments.contains("--memory-probe")
        #endif
        preferences = Preferences(defaults: testing ? nil : .standard)
        schedule = ReminderSchedule(rules: preferences.rules)
        super.init()
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var workspace: NSWorkspace { .shared }
    private var reducedMotion: Bool { workspace.accessibilityDisplayShouldReduceMotion }
    private var presentationAvailable: Bool {
        nudge == nil && blink == nil && pelvicPractice == nil && rest == nil && retreat == nil && fadingRest == nil && blocks.isEmpty
    }
    private var isExcluded: Bool {
        foregroundProtection.isExcluded(workspace.frontmostApplication, exclusions: preferences.excluded)
    }

    private func pauseReason(for application: NSRunningApplication? = nil,
                             refresh: Bool = false) -> ForegroundProtection.Reason? {
        foregroundProtection.reason(for: application ?? workspace.frontmostApplication,
                                    exclusions: preferences.excluded,
                                    pauseForFullScreen: preferences.pauseForFullScreen, now: now, refresh: refresh)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Copy.language = preferences.language
        art = FoxArt()
        if art == nil { log.error("Required fox artwork could not load") }
        preferences.changed = { [weak self] in self?.applyPreferences() }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        menu.delegate = self
        self.item = item
        updateStatusLabel()
        menuNeedsUpdate(menu)
        registerSystemEvents()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.18
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()

        #if DEBUG
        if let probe = MemoryProbe.configuration {
            runMemoryProbe(probe.output, cycles: probe.cycles)
        } else if testing {
            runProbe()
        }
        #endif
    }

    private func tick(activatedApplication: NSRunningApplication? = nil) {
        guard blocks.isEmpty else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                          eventType: CGEventType(rawValue: UInt32.max)!)
        let time = now
        let reason = pauseReason(for: activatedApplication)
        let practicing = pelvicPractice?.isRunning == true
        schedule.advance(to: time, idle: idle, excluded: reason != nil, resting: rest != nil || practicing)
        let scheduledNudge = nudge.map { !$0.preview && !$0.demo } ?? false
        if (reason != nil || idle >= ReminderSchedule.idlePauseAfter),
           scheduledNudge || blink?.preview == false || pelvicPractice?.preview == false {
            cancelPresentation(cooldown: 0)
        }
        let clockSuspended = reason != nil || schedule.pausedUntil != nil ||
            idle >= ReminderSchedule.idlePauseAfter || (rest != nil && pendingCommit == nil) || practicing
        updateStatusIcon(at: time, suspended: clockSuspended)
        updateStatusHover(at: time, suspended: clockSuspended)
        guard reason == nil, presentationAvailable,
              time >= nextPresentation,
              let batch = schedule.due(now: time) else { return }
        show(batch: batch)
    }

    private func updateStatusLabel() {
        item?.button?.setAccessibilityLabel(Copy.name)
        updateStatusIcon(at: now, suspended: true, force: true)
    }

    private func updateStatusHover(at time: TimeInterval, suspended: Bool) {
        guard !statusMenuIsOpen, blocks.isEmpty, let button = item?.button else { return }
        let title = statusHoverTitle(at: time, suspended: suspended)
        // Keep AppKit's tooltip registration intact while the text is the same.
        if button.toolTip != title { button.toolTip = title }
    }

    private func statusHoverTitle(at time: TimeInterval, suspended: Bool) -> String {
        if rest != nil || pelvicPractice?.isRunning == true { return Copy.text("休息中", "On a break") }
        if suspended {
            return Copy.text("提醒已暂停", "Reminders paused")
        }
        guard let (reminder, seconds) = schedule.nextScreenBreak(now: time) else {
            return Copy.text("休息提醒已关闭", "Break reminders off")
        }
        let action = reminder == .stand ? "站起来" : "远眺"
        let actionEnglish = reminder == .stand ? "Stand up" : "Look away"
        if seconds == 0 { return Copy.text("该\(action)啦", "\(actionEnglish) now") }
        if seconds < 60 { return Copy.text("不到 1 分钟后\(action)", "\(actionEnglish) in under 1 min") }
        let minutes = Int(ceil(seconds / 60))
        return Copy.text("\(minutes) 分钟后\(action)", "\(actionEnglish) in \(minutes) min")
    }

    private func updateStatusIcon(at time: TimeInterval, suspended: Bool, force: Bool = false) {
        guard let button = item?.button else { return }
        let step: Int?
        if preferences.showMenuBarProgress, let progress = schedule.nextScreenBreakProgress(now: time) {
            let showingNudge = nudge.map { !$0.preview && !$0.demo && $0.batch.main.usesEdgeEntrance } ?? false
            let showingRest = rest != nil && pendingCommit != nil
            let fill = showingNudge || showingRest ? 1 : progress
            let current = Int((fill * Double(StatusIcon.fillSteps)).rounded(.down))
            step = suspended ? statusFillStep ?? current : current
        } else {
            step = nil
        }
        guard force || statusFillStep != step || button.image == nil else { return }
        statusFillStep = step
        let fill = step.map { CGFloat($0) / CGFloat(StatusIcon.fillSteps) }
        button.image = StatusIcon.image(accessibilityLabel: Copy.name, fill: fill)
    }

    private func applyPreferences() {
        if Copy.language != preferences.language {
            Copy.language = preferences.language
            updateStatusLabel()
            settings?.title = Copy.settingsTitle
            nudge?.refreshCopy()
            blink?.refreshCopy()
            pelvicPractice?.refreshCopy()
            menuNeedsUpdate(menu)
        }
        let affectedNudge = nudge.flatMap { presentation in
            presentation.preview || presentation.demo ? nil : presentation.batch.included
        }?.contains { schedule.rules[$0] != preferences.rules[$0] } ?? false
        let affectedBlink = blink?.preview == false && schedule.rules[.blink] != preferences.rules[.blink]
        let affectedPractice = pelvicPractice?.preview == false &&
            schedule.rules[.pelvicFloor] != preferences.rules[.pelvicFloor]
        for (kind, rule) in preferences.rules { schedule.update(rule, for: kind) }
        if affectedNudge || affectedBlink || affectedPractice {
            cancelPresentation()
        }
        tick()
    }

    @discardableResult
    private func show(batch: ReminderBatch, preview: Bool = false, forcedEdge: EntranceOrigin? = nil,
                      demo: Bool = false, dismissOnly: Bool = false,
                      preferredScreen: NSScreen? = nil, samplePointer: CGPoint? = nil) -> Bool {
        guard presentationAvailable, preview || demo || pauseReason(refresh: true) == nil else { return false }
        let pointer = samplePointer ?? NSEvent.mouseLocation
        guard let screen = preferredScreen ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return false }
        if batch.main == .pelvicFloor { return showPelvicPractice(on: screen, preview: preview || demo) }
        if batch.main == .blink {
            let style = nextVariant(preference: preferences.blinkMotion, rotating: .rotate,
                                    choices: BlinkMotion.variants, previous: previousBlinkMotion)
            previousBlinkMotion = style
            let presentation = BlinkPresentation(screen: screen, art: art, motion: !reducedMotion,
                                                 style: style, preview: preview || demo)
            blink = presentation
            presentation.show()
            if !preview && !demo { schedule.finish(batch) }
            after(Reminder.blink.presentationSeconds) { [weak self] in self?.dismissBlink() }
            return true
        }

        let safe = screen.visibleFrame
        let motion = !reducedMotion && !dismissOnly && batch.main.usesEdgeEntrance && art != nil
        let landing = motion ? Landing.choose(in: safe, pointer: pointer, previous: previousEdge,
                                              force: forcedEdge, using: &random) : nil
        let water = batch.main == .water && art != nil
            ? WaterScene(in: safe, pointer: pointer, backingScale: screen.backingScaleFactor) : nil
        let centerCard = (batch.main.usesEdgeEntrance || batch.main == .water)
            ? Landing.callout(near: CGPoint(x: safe.midX, y: safe.midY), in: safe,
                              pointer: pointer, preferred: .left, compact: batch.main == .water)?.frame
            : nil
        guard let frame = landing?.card ?? water?.callout.frame ?? centerCard ?? Landing.fallback(in: safe, pointer: pointer, compact: batch.main == .water) else {
            nextPresentation = now + 30
            return false
        }
        let style = nextVariant(preference: preferences.edgeMotion, rotating: .rotate,
                                choices: EdgeMotion.variants, previous: previousEdgeMotion)
        if let landing {
            previousEdge = landing.origin
            previousEdgeMotion = style
        }
        let presentation = NudgePresentation(batch: batch, screen: screen, cardFrame: frame, landing: landing, water: water,
                                             art: art, preview: preview, demo: demo, dismissOnly: dismissOnly, style: style,
                                             motion: !reducedMotion,
                                             confirm: { [weak self] in self?.confirmNudge() },
                                             postpone: { [weak self] in self?.snoozeNudge() })
        nudge = presentation
        if !preview && !demo && !dismissOnly {
            schedule.notePresentation(batch.main, now: now)
        }
        presentation.showEntrance()
        log.info("Heads-up shown, edge: \(landing?.origin.rawValue ?? "card", privacy: .public)")
        if presentation.entranceDuration > 0 {
            after(presentation.entranceDuration) { [weak self, weak presentation] in
                guard let self, let presentation, nudge === presentation else { return }
                reveal(presentation)
            }
        } else {
            reveal(presentation)
        }
        return true
    }

    private func nextVariant<T: Equatable>(preference: T, rotating: T, choices: [T], previous: T?) -> T {
        guard preference == rotating else { return preference }
        if let previous, let index = choices.firstIndex(of: previous) {
            return choices[(index + 1) % choices.count]
        }
        return choices.randomElement(using: &random) ?? preference
    }

    private func reveal(_ presentation: NudgePresentation) {
        if !presentation.preview, !presentation.demo, pauseReason(refresh: true) != nil {
            cancelPresentation(cooldown: 0)
            return
        }
        presentation.showCard(animated: !reducedMotion && presentation.entranceDuration > 0)
        let seconds: Double = presentation.preview ? 6 : (presentation.batch.main == .water ? 12 : 10)
        after(seconds) { [weak self, weak presentation] in
            guard let self, let presentation, nudge === presentation else { return }
            if !presentation.preview, !presentation.demo, pauseReason(refresh: true) != nil {
                cancelPresentation(cooldown: 0)
                return
            }
            if !presentation.preview, !presentation.dismissOnly, presentation.batch.main != .water,
               preferences.autoStart || presentation.demo,
               !isExcluded, presentation.frontmostPID == workspace.frontmostApplication?.processIdentifier {
                confirmNudge()
            } else {
                if !presentation.preview && !presentation.demo { schedule.finish(presentation.batch) }
                dismissNudge(animated: true)
            }
        }
    }

    @objc private func confirmNudge() {
        guard let nudge else { return }
        if !nudge.preview, !nudge.demo, pauseReason(refresh: true) != nil {
            cancelPresentation(cooldown: 0)
            return
        }
        let batch = nudge.batch
        if nudge.preview || nudge.dismissOnly || batch.main == .water {
            if !nudge.preview && !nudge.demo { schedule.finish(batch) }
            dismissNudge(animated: true)
        } else {
            let screen = nudge.screen
            dismissNudge(animated: false)
            beginRest(batch: batch, screen: screen, recordReminder: !nudge.demo)
        }
    }

    @objc private func snoozeNudge() {
        guard let nudge, !nudge.preview, !nudge.dismissOnly, nudge.batch.main != .water else { return }
        if !nudge.demo { schedule.snooze(nudge.batch, now: now) }
        dismissNudge(animated: true)
        updateStatusIcon(at: now, suspended: false)
    }

    private func dismissNudge(animated: Bool) {
        deadline?.cancel()
        deadline = nil
        guard let presented = nudge else { return }
        nudge = nil
        if !presented.preview && !presented.demo { leaveReminderGap(after: now) }
        if animated && !reducedMotion {
            retreat = presented
            presented.retreat { [weak self, weak presented] in
                guard let self, retreat === presented else { return }
                retreat = nil
            }
        } else {
            presented.close()
        }
    }

    private func dismissBlink() {
        guard let blink else { return }
        self.blink = nil
        deadline?.cancel()
        deadline = nil
        blink.close()
        if !blink.preview { leaveReminderGap(after: now) }
    }

    private func showPelvicPractice(on screen: NSScreen, preview: Bool) -> Bool {
        let styles = PelvicPracticeMotion.allCases.filter { $0 != previousPelvicMotion }
        let style = styles.randomElement(using: &random) ?? .curl
        guard let practice = PelvicPracticePresentation(screen: screen, art: art, style: style, motion: !reducedMotion,
                                                        preview: preview, start: { [weak self] in self?.startPelvicPractice() },
                                                        dismiss: { [weak self] in self?.dismissPelvicPractice() })
        else { return false }
        previousPelvicMotion = style
        pelvicPractice = practice
        practice.show()
        if !preview {
            schedule.notePresentation(.pelvicFloor, now: now)
            schedule.finish(ReminderBatch(main: .pelvicFloor))
            after(Reminder.pelvicFloor.presentationSeconds) { [weak self] in self?.dismissPelvicPractice() }
        }
        return true
    }

    private func startPelvicPractice() {
        guard let practice = pelvicPractice, !practice.isRunning else { return }
        guard practice.preview || pauseReason(refresh: true) == nil else {
            dismissPelvicPractice()
            return
        }
        let time = now
        schedule.advance(to: time, idle: 0, excluded: false, resting: true)
        practice.start(at: time)
        after(PelvicPracticeTiming.duration + 2.5) { [weak self] in self?.dismissPelvicPractice() }
    }

    private func dismissPelvicPractice() {
        guard let practice = pelvicPractice else { return }
        pelvicPractice = nil
        deadline?.cancel()
        deadline = nil
        let time = now
        if practice.isRunning { schedule.advance(to: time, idle: 0, excluded: pauseReason() != nil, resting: true) }
        if !practice.preview || practice.isRunning { leaveReminderGap(after: time) }
        practice.close()
    }

    @objc private func takeBreak() {
        if let nudge, !nudge.preview, !nudge.dismissOnly, nudge.batch.main != .water {
            confirmNudge()
            return
        }
        if let nudge, !nudge.preview && !nudge.demo { schedule.finish(nudge.batch) }
        dismissPelvicPractice()
        dismissBlink()
        dismissNudge(animated: false)
        retreat?.close()
        retreat = nil
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        beginRest(batch: ReminderBatch(main: .look), screen: screen)
    }

    private func beginRest(batch: ReminderBatch, screen: NSScreen, duration override: Double? = nil,
                           recordReminder: Bool = true) {
        guard rest == nil, fadingRest == nil, blocks.isEmpty, !isExcluded else { return }
        let duration = override ?? batch.main.presentationSeconds
        let scene = nextVariant(preference: preferences.restScene, rotating: .rotate,
                                choices: RestScene.variants, previous: previousRestScene)
        previousRestScene = scene
        let presentation = RestPresentation(batch: batch, screen: screen, art: art, duration: duration,
                                            scene: scene, motion: !reducedMotion, ended: { [weak self] in self?.endRest(animated: false) })
        rest = presentation
        pendingCommit = recordReminder ? batch : nil
        updateStatusIcon(at: now, suspended: !recordReminder)
        presentation.show()
        let endsAt = presentation.timing.endsAt
        after(0.10) { [weak self, weak presentation] in
            guard let self, let presentation, rest === presentation else { return }
            guard presentation.hasKeyboard else {
                log.error("Break window did not receive keyboard focus")
                endRest(animated: false, countBreak: false)
                nextPresentation = now + 30
                show(batch: batch, demo: !recordReminder, dismissOnly: true, preferredScreen: screen)
                return
            }
            log.info("Break window became key")
            after(max(0, endsAt - now)) { [weak self] in self?.endRest(animated: true) }
        }
    }

    @objc private func closeRest() { endRest(animated: false) }

    private func endRest(animated: Bool, countBreak: Bool = true) {
        guard let presented = rest else { return }
        rest = nil
        deadline?.cancel()
        deadline = nil
        if countBreak, let pendingCommit {
            schedule.finish(pendingCommit)
            schedule.noteRestEnded(now: now)
            leaveReminderGap(after: now)
        }
        pendingCommit = nil
        updateStatusIcon(at: now, suspended: !countBreak || schedule.pausedUntil != nil)
        schedule.advance(to: now, idle: 0, excluded: isExcluded, resting: true)
        if animated {
            fadingRest = presented
            presented.close(animated: true) { [weak self, weak presented] in
                guard let self, fadingRest === presented else { return }
                fadingRest = nil
            }
        } else {
            presented.close(animated: false)
        }
        log.info("Break window dismissed")
    }

    private func after(_ seconds: Double, perform: @escaping () -> Void) {
        deadline?.cancel()
        let work = DispatchWorkItem(block: perform)
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func leaveReminderGap(after time: TimeInterval) {
        nextPresentation = max(nextPresentation, time + 6)
    }

    private func cancelPresentation(cooldown: Double = 30) {
        if nudge != nil { dismissNudge(animated: false) }
        dismissBlink()
        dismissPelvicPractice()
        retreat?.close()
        retreat = nil
        endRest(animated: false, countBreak: false)
        fadingRest?.close(animated: false)
        fadingRest = nil
        nextPresentation = now + cooldown
    }

    @objc private func pause() {
        schedule.setPause(until: now + 30 * 60)
        cancelPresentation(cooldown: 0)
    }

    @objc private func resume() {
        schedule.setPause(until: nil)
        nextPresentation = now
        tick()
    }

    @objc private func preview() { show(batch: ReminderBatch(main: .look), preview: true) }

    @objc private func previewBlink() { show(batch: ReminderBatch(main: .blink), preview: true) }

    @objc private func previewWater() { show(batch: ReminderBatch(main: .water), preview: true) }

    @objc private func previewPelvicPractice() {
        show(batch: ReminderBatch(main: .pelvicFloor), preview: true)
    }

    @objc private func previewRest() {
        guard presentationAvailable,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }
        beginRest(batch: ReminderBatch(main: .look), screen: screen, recordReminder: false)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        loginAtStartup.refresh()
        if settings == nil {
            let screenHeight = NSScreen.main?.visibleFrame.height ?? 820
            let height = max(425, min(790, screenHeight - 42))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = Copy.settingsTitle
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, loginAtStartup: loginAtStartup,
                                                                       addApp: { [weak self] in self?.addExcludedApp() }))
            if let settingsFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(settingsFrame) }) {
                window.setFrame(settingsFrame, display: false)
            } else {
                window.center()
            }
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settings else { return }
        settingsFrame = window.frame
        settings = nil
    }

    private func addExcludedApp() {
        guard let settings, settings.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = Copy.text("添加", "Add")
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        panel.beginSheetModal(for: settings) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.addExcludedAppAfterSheet(url)
        }
    }

    private func addExcludedAppAfterSheet(_ url: URL) {
        // Deliver the change after AppKit finishes updating the sheet and its parent.
        DispatchQueue.main.async { [weak self] in self?.applyExcludedApp(url) }
    }

    private func applyExcludedApp(_ url: URL) {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard let bundle = Bundle(url: canonical), let id = bundle.bundleIdentifier else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? canonical.deletingPathExtension().lastPathComponent
        let app = ExcludedApp(id: id, name: name, bundlePath: canonical.path)
        if let index = preferences.excluded.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            if preferences.excluded[index] != app {
                preferences.excluded[index] = app
            }
        } else {
            preferences.excluded = preferences.excluded + [app]
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let protection = pauseReason()
        let status: String
        if let paused = schedule.pausedUntil {
            let minutes = max(1, Int(ceil((paused - now) / 60)))
            status = Copy.text("已暂停 · \(minutes) 分钟", "Paused · \(minutes) min")
        } else if protection == .excluded {
            status = Copy.text("已为当前应用暂停", "Paused in this app")
        } else if protection == .fullScreen {
            status = Copy.text("全屏中，提醒已暂停", "Paused in full screen")
        } else if let (reminder, time) = schedule.next(now: now) {
            let minutes = max(0, Int(ceil(time / 60)))
            status = Copy.text("下次提醒 · \(reminder.name) · \(minutes) 分钟", "Next · \(reminder.name) · \(minutes) min")
        } else {
            status = Copy.text("提醒已关闭", "Reminders off")
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if schedule.pausedUntil == nil, protection == nil,
           let next = schedule.next(now: now), !next.0.usesEdgeEntrance,
           let (reminder, time) = schedule.nextScreenBreak(now: now) {
            let minutes = max(0, Int(ceil(time / 60)))
            menu.addItem(withTitle: Copy.text("下次休息 · \(reminder.name) · \(minutes) 分钟",
                                            "Next break · \(reminder.name) · \(minutes) min"),
                         action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        if rest != nil {
            add(Copy.text("结束休息", "End Break"), #selector(closeRest))
        } else {
            add(Copy.text("现在休息", "Take a Break"), #selector(takeBreak))
            if let nudge, !nudge.preview, !nudge.dismissOnly, nudge.batch.main != .water {
                add(Copy.text("稍后 5 分钟", "Snooze for 5 Min"), #selector(snoozeNudge))
            }
        }
        add(Copy.text("预览狐狸", "Preview Fox"), #selector(preview))
        add(Copy.text("预览眨眼提醒", "Preview Blink"), #selector(previewBlink))
        add(Copy.text("预览喝水提醒", "Preview Water"), #selector(previewWater))
        add(Copy.text("预览休息插画", "Preview Break"), #selector(previewRest))
        add(Copy.text("提肛练习…", "Kegel Exercises…"), #selector(previewPelvicPractice))
        if schedule.pausedUntil != nil {
            add(Copy.text("继续提醒", "Resume Reminders"), #selector(resume))
        } else {
            add(Copy.text("暂停 30 分钟", "Pause for 30 Min"), #selector(pause))
        }
        menu.addItem(.separator())
        add(Copy.text("设置…", "Settings…"), #selector(openSettings), key: ",")
        #if DEBUG
        let debugItem = NSMenuItem(title: Copy.text("开发预览", "Developer Preview"), action: nil, keyEquivalent: "")
        let debug = NSMenu()
        for edge in EntranceOrigin.allCases {
            let item = NSMenuItem(title: edge.previewTitle,
                                  action: #selector(previewEdge(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = edge.rawValue
            debug.addItem(item)
        }
        let seeded = NSMenuItem(title: Copy.text("重置随机种子 42", "Reset Seed to 42"), action: #selector(reseed), keyEquivalent: "")
        seeded.target = self
        debug.addItem(seeded)
        let quick = NSMenuItem(title: Copy.text("5 秒后预览完整流程", "Preview Full Flow in 5 Seconds"),
                               action: #selector(quickPreview), keyEquivalent: "")
        quick.target = self
        debug.addItem(quick)
        debugItem.submenu = debug
        menu.addItem(debugItem)
        #endif
        add(Copy.quitTitle, #selector(quit), key: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        statusMenuIsOpen = true
        item?.button?.toolTip = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { statusMenuIsOpen = false }
    }

    private func add(_ title: String, _ action: Selector, key: String = "") {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }

    #if DEBUG
    @objc private func reseed() {
        random = SeededRandom(seed: 42)
        previousEdge = nil
        previousEdgeMotion = nil
        previousBlinkMotion = nil
        previousPelvicMotion = nil
        previousRestScene = nil
    }

    @objc private func previewEdge(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let edge = EntranceOrigin(rawValue: name) else { return }
        dismissNudge(animated: false)
        show(batch: ReminderBatch(main: .look), preview: true, forcedEdge: edge)
    }

    @objc private func quickPreview() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, presentationAvailable, !isExcluded else { return }
            show(batch: ReminderBatch(main: .look), demo: true)
        }
    }
    #endif

    private func registerSystemEvents() {
        let events: [Notification.Name] = [
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ]
        for event in events {
            workspace.notificationCenter.addObserver(self, selector: #selector(systemChanged(_:)), name: event, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(systemChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(systemChanged(_:)),
                                                               name: Notification.Name(name), object: nil)
        }
    }

    @objc private func systemChanged(_ note: Notification) {
        item?.button?.toolTip = nil
        switch note.name {
        case NSWorkspace.willSleepNotification: blocks.insert(.sleep)
        case NSWorkspace.didWakeNotification: blocks.remove(.sleep)
        case NSWorkspace.screensDidSleepNotification: blocks.insert(.displaySleep)
        case NSWorkspace.screensDidWakeNotification: blocks.remove(.displaySleep)
        case NSWorkspace.sessionDidResignActiveNotification: blocks.insert(.inactiveSession)
        case NSWorkspace.sessionDidBecomeActiveNotification: blocks.remove(.inactiveSession)
        case Notification.Name("com.apple.screenIsLocked"): blocks.insert(.lock)
        case Notification.Name("com.apple.screenIsUnlocked"): blocks.remove(.lock)
        case NSWorkspace.didActivateApplicationNotification:
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let foreground = activated ?? workspace.frontmostApplication
            foregroundProtection.invalidateFullScreen()
            if rest != nil && rest?.frontmostPID != foreground?.processIdentifier {
                cancelPresentation()
            }
            tick(activatedApplication: foreground)
            return
        case NSWorkspace.activeSpaceDidChangeNotification, NSApplication.didChangeScreenParametersNotification:
            foregroundProtection.invalidateFullScreen()
            cancelPresentation()
            tick()
            return
        default:
            cancelPresentation()
            return
        }
        cancelPresentation(cooldown: 0)
        schedule.reset()
    }

    #if DEBUG
    private func runMemoryProbe(_ output: URL, cycles: Int) {
        guard let screen = NSScreen.main else { return }
        Task { @MainActor in
            var probe = MemoryProbe()
            let pointer = CGPoint(x: screen.visibleFrame.minX + 16, y: screen.visibleFrame.minY + 16)
            let edges = EntranceOrigin.allCases
            reseed()
            try? await Task.sleep(for: .seconds(2))
            probe.sample("idle")

            // Exercise every entrance once, then revisit all views to detect retained memory.
            for cycle in 0..<cycles {
                for kind in [Reminder.blink, .look, .water] {
                    let label = "\(cycle)-\(kind.rawValue)"
                    let shown = show(batch: ReminderBatch(main: kind), preview: true,
                                     forcedEdge: edges[cycle % edges.count], preferredScreen: screen, samplePointer: pointer)
                    guard shown else {
                        probe.sample("failed-\(label)")
                        continue
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                    probe.sample(label + "-moving")
                    if cycle < edges.count && kind == .look {
                        let remainder = max(0, (nudge?.entranceDuration ?? 0) - 0.10)
                        try? await Task.sleep(for: .seconds(remainder))
                        probe.sample(label + "-card")
                    }
                    dismissBlink()
                    dismissNudge(animated: false)
                }

                openSettings()
                try? await Task.sleep(for: .milliseconds(300))
                probe.sample("\(cycle)-settings")
                settings?.close()
                beginRest(batch: ReminderBatch(main: .look), screen: screen, duration: 5, recordReminder: false)
                try? await Task.sleep(for: .milliseconds(650))
                probe.sample("\(cycle)-rest")
                if rest?.hasKeyboard != true { probe.sample("failed-\(cycle)-rest") }
                endRest(animated: true)
                try? await Task.sleep(for: .milliseconds(600))
                probe.sample("\(cycle)-closed")
            }

            try? await Task.sleep(for: .seconds(5))
            probe.sample("settled")
            probe.write(to: output, screen: screen)
            NSApp.terminate(nil)
        }
    }

    private func verifyEdgePriority(screen: NSScreen, pointer: CGPoint) -> Bool {
        let original = schedule
        let originalEdge = previousEdge
        let originalMotion = previousEdgeMotion
        let originalRandom = random
        defer {
            dismissNudge(animated: false)
            schedule = original
            previousEdge = originalEdge
            previousEdgeMotion = originalMotion
            random = originalRandom
        }

        let rule = ReminderRule(minutes: 1)
        schedule = ReminderSchedule(rules: [.look: rule, .blink: rule])
        let time = now
        schedule.advance(to: time - 300, idle: 0, excluded: false, resting: false)
        schedule.advance(to: time - 241, idle: 0, excluded: false, resting: false)
        schedule.advance(to: time - 5, idle: 235, excluded: false, resting: false)
        schedule.advance(to: time - 1, idle: 0, excluded: false, resting: false)
        schedule.advance(to: time, idle: 0, excluded: false, resting: false)
        guard let batch = schedule.due(now: time),
              show(batch: batch, forcedEdge: .left, preferredScreen: screen, samplePointer: pointer)
        else { return false }
        return nudge?.batch == ReminderBatch(main: .look) && blink == nil
            && schedule.timeLeft(for: .blink, now: now) == 60
    }

    private func verifyNativeFullScreen(fixturePID: pid_t, output: URL) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: fixturePID),
              pauseReason(for: app, refresh: true) == nil else { return false }
        let command = output.appendingPathComponent("fullscreen-command.txt")
        let state = output.appendingPathComponent("fullscreen-state.txt")
        func wait(for expected: String) async -> Bool {
            for _ in 0..<40 {
                if (try? String(contentsOf: state, encoding: .utf8)) == expected { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }

        try? "enter".write(to: command, atomically: true, encoding: .utf8)
        let didEnter = await wait(for: "fullscreen")
        let detected = didEnter && pauseReason(for: app, refresh: true) == .fullScreen
        let held = detected && !show(batch: ReminderBatch(main: .look))
        preferences.pauseForFullScreen = false
        let canDisable = pauseReason(for: app, refresh: true) == nil
        preferences.pauseForFullScreen = true
        try? "exit".write(to: command, atomically: true, encoding: .utf8)
        let didExit = await wait(for: "windowed")
        try? await Task.sleep(for: .milliseconds(150))
        return held && canDisable && didExit && pauseReason(for: app, refresh: true) == nil
    }

    private func verifyMenuBarProgress() -> Bool {
        guard !preferences.showMenuBarProgress, statusFillStep == nil, let button = item?.button else { return false }
        let originalSchedule = schedule
        defer {
            schedule = originalSchedule
            preferences.showMenuBarProgress = false
        }

        preferences.showMenuBarProgress = true
        let time = now
        schedule = ReminderSchedule(rules: [
            .look: ReminderRule(minutes: 1),
            .stand: ReminderRule(enabled: false, minutes: 60)
        ])
        schedule.advance(to: time - 30, idle: 0, excluded: false, resting: false)
        schedule.advance(to: time, idle: 0, excluded: false, resting: false)
        updateStatusIcon(at: time, suspended: false)
        guard statusFillStep == StatusIcon.fillSteps / 2, button.image?.isTemplate == true else { return false }
        let halfImage = button.image
        updateStatusIcon(at: time, suspended: false)
        guard halfImage === button.image else { return false }

        schedule.advance(to: time + 30, idle: 0, excluded: false, resting: false)
        updateStatusIcon(at: time + 30, suspended: true)
        guard halfImage === button.image && statusFillStep == StatusIcon.fillSteps / 2 else { return false }
        updateStatusIcon(at: time + 30, suspended: false)
        guard statusFillStep == StatusIcon.fillSteps else { return false }

        schedule.snooze(ReminderBatch(main: .look), now: time + 30)
        updateStatusIcon(at: time + 30, suspended: false)
        guard statusFillStep == 0 else { return false }
        schedule.update(ReminderRule(enabled: false, minutes: 1), for: .look)
        updateStatusIcon(at: time + 30, suspended: false)
        return statusFillStep == nil && button.toolTip != Copy.name && button.image?.isTemplate == true
    }

    private func verifyStatusHover() -> Bool {
        guard let button = item?.button, !preferences.showMenuBarProgress else { return false }
        let originalSchedule = schedule
        let originalLanguage = Copy.language
        let time = now
        defer {
            schedule = originalSchedule
            Copy.language = originalLanguage
            tick()
        }

        Copy.language = .english
        schedule = ReminderSchedule(rules: [.look: ReminderRule(minutes: 8)])
        updateStatusHover(at: time, suspended: false)
        guard button.toolTip == "Look away in 8 min" else { return false }
        updateStatusHover(at: time, suspended: true)
        guard button.toolTip == "Reminders paused" else { return false }

        Copy.language = .chinese
        schedule = ReminderSchedule(rules: [.stand: ReminderRule(minutes: 3)])
        updateStatusHover(at: time, suspended: false)
        guard button.toolTip == "3 分钟后站起来" else { return false }

        var closedForMenu = false
        let dismissMenu = Timer(timeInterval: 0.16, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateStatusHover(at: time, suspended: false)
                closedForMenu = self.statusMenuIsOpen && button.toolTip == nil
                self.menu.cancelTracking()
            }
        }
        RunLoop.main.add(dismissMenu, forMode: .eventTracking)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)

        updateStatusHover(at: time, suspended: false)
        return closedForMenu && !statusMenuIsOpen && button.toolTip == "3 分钟后站起来"
    }

    private func verifyPelvicPractice(on screen: NSScreen, output: URL) async -> Bool {
        let originalLanguage = Copy.language
        defer {
            dismissPelvicPractice()
            Copy.language = originalLanguage
            menuNeedsUpdate(menu)
        }
        Copy.language = .english
        menuNeedsUpdate(menu)
        let englishMenu = menu.items.contains { $0.title == "Kegel Exercises…" && $0.action == #selector(previewPelvicPractice) }
        guard PelvicPracticeMotion.allCases.allSatisfy({
            $0.frames().count == 25 && $0.frames(motion: false).count == 1
        }),
              show(batch: ReminderBatch(main: .pelvicFloor), preview: true, preferredScreen: screen),
              let practice = pelvicPractice else { return false }
        try? await Task.sleep(for: .milliseconds(660))
        let englishInvitation = practice.capture(in: output, label: "ready-english")
        Copy.language = .chinese
        practice.refreshCopy()
        menuNeedsUpdate(menu)
        let chineseNames = Reminder.pelvicFloor.name == "提肛" &&
            menu.items.contains { $0.title == "提肛练习…" && $0.action == #selector(previewPelvicPractice) }
        try? await Task.sleep(for: .milliseconds(150))
        let invitation = !practice.isRunning && practice.isCompactAndClickThrough &&
            practice.capture(in: output, label: "ready")
        startPelvicPractice()
        try? await Task.sleep(for: .milliseconds(3_320))
        let transition = practice.capture(in: output, label: "transition")
        try? await Task.sleep(for: .milliseconds(910))
        let contraction = practice.isRunning && practice.capture(in: output, label: "squeeze")
        Copy.language = .english
        practice.refreshCopy()
        try? await Task.sleep(for: .milliseconds(150))
        let englishContraction = practice.capture(in: output, label: "squeeze-english")
        try? await Task.sleep(for: .milliseconds(3_030))
        let release = practice.capture(in: output, label: "release")
        dismissPelvicPractice()
        return englishMenu && chineseNames && englishInvitation && englishContraction &&
            invitation && transition && contraction && release && practice.isClosed
    }

    private func runProbe() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-probe"), arguments.count > flag + 2,
              let fixturePID = Int32(arguments[flag + 2]), let screen = NSScreen.main else {
            log.error("UI probe needs an output directory, a fixture PID, and a screen")
            return
        }
        let output = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        Task { @MainActor in
            var lines: [String] = []
            let expectedName = Copy.chinese ? "歇哈嘛" : "Rest a Bit"
            let expectedQuit = Copy.chinese ? "退出歇哈嘛" : "Quit Rest a Bit"
            let menuBrandMatches = Bundle.main.bundleIdentifier == "local.restabit.app"
                && item?.button?.toolTip != Copy.name
                && item?.button?.image?.accessibilityDescription == expectedName
                && menu.items.last?.title == expectedQuit
            lines.append("Menu and application identity match: \(menuBrandMatches) [\(expectedName)]")
            lines.append("Status icon hover does not show the app name: \(item?.button != nil && item?.button?.toolTip != Copy.name)")
            lines.append("Optional menu-bar progress, pause, snooze and static fallback verified: \(verifyMenuBarProgress())")
            lines.append("Synthetic previous settings migrate and persist: \(Preferences.verifyMigration())")
            lines.append("Login item registration states verified without changing login items: \(LoginAtStartup.verifyTransitions())")
            lines.append("Forward direction sprite sets loaded: \(art?.hasDirectionalGaits == true)")
            reseed()
            let frontmost = { self.workspace.frontmostApplication?.processIdentifier == fixturePID }
            lines.append("Synthetic editor initially frontmost: \(frontmost())")
            lines.append("Native status hover countdown, localization, pause and menu dismissal: \(verifyStatusHover())")
            let fullScreenVerified = await verifyNativeFullScreen(fixturePID: fixturePID, output: output)
            lines.append("Native full-screen pause, toggle, and exit verified: \(fullScreenVerified)")
            let practice = await verifyPelvicPractice(on: screen, output: output)
            lines.append("Centered pelvic practice waits for consent, renders both phases, and closes: \(practice)")
            let fixtureURL = output.appendingPathComponent("Fixture.app")
            applyExcludedApp(fixtureURL)
            let liveExclusion = frontmost() && pauseReason(refresh: true) == .excluded
                && !show(batch: ReminderBatch(main: .look))
            lines.append("Automatic reminder held for the excluded foreground app: \(liveExclusion)")
            preferences.excluded = []
            let safe = screen.visibleFrame
            let pointer = CGPoint(x: safe.midX, y: safe.midY)
            let edgeStyles: [EntranceOrigin: EdgeMotion] = [
                .left: .dash, .right: .hop, .bottom: .hop, .top: .peek,
                .topLeft: .hop, .topRight: .peek, .bottomLeft: .dash, .bottomRight: .hop
            ]
            for edge in EntranceOrigin.allCases {
                preferences.edgeMotion = edgeStyles[edge] ?? .dash
                guard show(batch: ReminderBatch(main: .look), forcedEdge: edge,
                           demo: true, preferredScreen: screen, samplePointer: pointer), let sample = nudge else {
                    lines.append("\(edge.rawValue): failed to show")
                    continue
                }
                var retainedFocus = frontmost()
                var count = 0
                let start = now
                let frameCount = Int(ceil((sample.entranceDuration + 0.22) * 30))
                for index in 0..<frameCount {
                    let delay = start + Double(index) / 30 - now
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    retainedFocus = retainedFocus && frontmost() && NSApp.keyWindow == nil
                    let name = String(format: "%@-%03d.png", edge.rawValue, index)
                    if sample.captureFox(to: output.appendingPathComponent(name)) { count += 1 }
                }
                let card = sample.captureCard(to: output.appendingPathComponent("card-\(edge.rawValue).png"))
                lines.append("\(edge.rawValue): captured \(count) stage frames and card=\(card), kept editor frontmost=\(retainedFocus)")
                lines.append("\(edge.rawValue): arrived at the center and kept animation click-through: \(sample.arrivesAtCenter && sample.usesCompactStage && count == frameCount)")
                lines.append("\(edge.rawValue): slows down before stopping: \(sample.slowsBeforeArrival)")
                lines.append("\(edge.rawValue): keeps forward heading: \(sample.keepsForwardHeading)")
                lines.append("\(edge.rawValue): cue fits its own content: \(card && sample.cardFrame.width < 215 && sample.cardFitsLocalizedContent)")
                if let stage = sample.stageFrame {
                    let frame = sample.cardFrame
                    let values: [CGFloat] = [
                        safe.width, safe.height, stage.minX - safe.minX, safe.maxY - stage.maxY, stage.width, stage.height,
                        frame.minX - safe.minX, safe.maxY - frame.maxY, frame.width, frame.height
                    ]
                    let metadata = values.map { String(Int($0.rounded())) }.joined(separator: " ")
                        + " " + String(format: "%.3f", sample.entranceDuration) + "\n"
                    try? metadata.write(to: output.appendingPathComponent("layout-\(edge.rawValue).txt"),
                                        atomically: true, encoding: .utf8)
                }
                dismissNudge(animated: false)
                try? await Task.sleep(for: .milliseconds(120))
            }
            preferences.edgeMotion = .rotate
            let originalLanguage = preferences.language
            preferences.language = .english
            let combined = ReminderBatch(main: .stand, included: [.stand, .look])
            if show(batch: combined, forcedEdge: .right, demo: true, preferredScreen: screen, samplePointer: pointer),
               let sample = nudge {
                try? await Task.sleep(for: .seconds(sample.entranceDuration + 0.25))
                let captured = sample.captureCard(to: output.appendingPathComponent("card-combined-english.png"))
                lines.append("Combined English cue fits beside the fox: \(captured && sample.arrivesAtCenter && sample.cardFitsLocalizedContent)")
                dismissNudge(animated: false)
            }
            preferences.language = originalLanguage
            lines.append("Scheduled edge reminder skips overlapping blink: \(verifyEdgePriority(screen: screen, pointer: pointer))")
            preferences.language = .english
            if show(batch: ReminderBatch(main: .water), preview: true, preferredScreen: screen, samplePointer: pointer),
               let scene = nudge {
                var retainedFocus = frontmost()
                let start = now
                let frames = 63
                var captured = 0
                for index in 0..<frames {
                    let delay = start + Double(index) / 30 - now
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    retainedFocus = retainedFocus && frontmost() && NSApp.keyWindow == nil
                    let name = String(format: "water-%03d.png", index)
                    if scene.captureFox(to: output.appendingPathComponent(name)) { captured += 1 }
                }
                let card = scene.captureCard(to: output.appendingPathComponent("card-water.png"))
                let verified = art?.hasWaterPoses == true && scene.waterSceneIsCentered
                    && retainedFocus && captured == frames && card
                lines.append("Water scene is centered and leaves focus on the editor: \(verified)")
                lines.append("Water cue fits its complete English text: \(card && scene.cardFitsLocalizedContent)")
                if let stage = scene.stageFrame {
                    let frame = scene.cardFrame
                    let values: [CGFloat] = [
                        safe.width, safe.height, stage.minX - safe.minX, safe.maxY - stage.maxY, stage.width, stage.height,
                        frame.minX - safe.minX, safe.maxY - frame.maxY, frame.width, frame.height
                    ]
                    let metadata = values.map { String(Int($0.rounded())) }.joined(separator: " ")
                        + " " + String(format: "%.3f", scene.entranceDuration) + "\n"
                    try? metadata.write(to: output.appendingPathComponent("layout-water.txt"), atomically: true, encoding: .utf8)
                }
                dismissNudge(animated: false)
            } else {
                lines.append("Water scene did not open")
            }
            preferences.language = originalLanguage
            preferences.blinkMotion = .hop
            if show(batch: ReminderBatch(main: .blink), preview: true, preferredScreen: screen), let sample = blink {
                let centered = abs(sample.windowFrame.midX - safe.midX) <= 1 &&
                    abs(sample.windowFrame.midY - safe.midY) <= 1
                lines.append("Blink stage is centered and click-through: \(centered && sample.passesPointerThrough)")
                var count = 0
                var retainedFocus = frontmost()
                let start = now
                for index in 0..<100 {
                    let delay = start + Double(index) / 30 - now
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    retainedFocus = retainedFocus && frontmost() && NSApp.keyWindow == nil && rest == nil
                    let name = String(format: "blink-%03d.png", index)
                    if sample.capture(to: output.appendingPathComponent(name)) { count += 1 }
                }
                lines.append("Blink captured \(count) frames and kept editor frontmost: \(retainedFocus)")
                try? await Task.sleep(for: .milliseconds(250))
                lines.append("Blink closed on its own: \(blink == nil)")
            } else {
                lines.append("Blink did not open")
            }

            let staticBlink = BlinkPresentation(screen: screen, art: art, motion: false, style: .hop, preview: true)
            staticBlink.show()
            try? await Task.sleep(for: .milliseconds(180))
            let staticCapture = staticBlink.capture(to: output.appendingPathComponent("blink-static.png"))
            staticBlink.close()
            lines.append("Reduced-motion blink rendered: \(staticCapture)")

            for style in [BlinkMotion.rise, .sway] {
                let sample = BlinkPresentation(screen: screen, art: art, motion: true, style: style, preview: true)
                sample.show()
                var captured = 0
                var retainedFocus = frontmost()
                let start = now
                for index in 0..<100 {
                    let delay = start + Double(index) / 30 - now
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    retainedFocus = retainedFocus && frontmost() && NSApp.keyWindow == nil
                    let name = String(format: "blink-%@-%03d.png", style.rawValue, index)
                    if sample.capture(to: output.appendingPathComponent(name)) { captured += 1 }
                }
                sample.close()
                lines.append("Blink style \(style.rawValue) rendered: \(captured == 100 && retainedFocus)")
            }
            preferences.blinkMotion = .rotate

            preferences.restScene = .hills
            beginRest(batch: ReminderBatch(main: .look), screen: screen, recordReminder: false)
            try? await Task.sleep(for: .milliseconds(500))
            if let rest {
                lines.append("Rest panel became key: \(rest.hasKeyboard)")
                lines.append("Rest rendered: \(rest.capture(to: output.appendingPathComponent("rest.png")))")
                lines.append("Rest covers the screen above the menu bar: \(rest.coversScreenAboveMenuBar)")
                let initial = rest.timing.secondsRemaining(at: now)
                try? await Task.sleep(for: .milliseconds(1_150))
                let subsequent = rest.timing.secondsRemaining(at: now)
                let countdownCapture = rest.capture(to: output.appendingPathComponent("rest-countdown.png"))
                lines.append("Rest countdown decreased with the running deadline: \(subsequent < initial && countdownCapture) [\(initial) -> \(subsequent)]")
                rest.postEscapeForProbe()
                try? await Task.sleep(for: .milliseconds(100))
            } else {
                lines.append("Rest panel missing")
            }
            lines.append("Rest closed on Escape: \(rest == nil && fadingRest == nil)")
            lines.append("Synthetic editor frontmost after Escape: \(frontmost())")
            if rest == nil && frontmost() {
                try? Data().write(to: output.appendingPathComponent("escaped.flag"), options: .atomic)
            }
            try? await Task.sleep(for: .milliseconds(350))
            beginRest(batch: ReminderBatch(main: .look), screen: screen, duration: 1, recordReminder: false)
            try? await Task.sleep(for: .milliseconds(1_350))
            lines.append("Rest closed on its own and returned to editor: \(rest == nil && fadingRest == nil && frontmost())")

            for scene in [RestScene.shore, .grove] {
                preferences.restScene = scene
                beginRest(batch: ReminderBatch(main: .look), screen: screen, recordReminder: false)
                try? await Task.sleep(for: .milliseconds(300))
                let captured = rest?.capture(to: output.appendingPathComponent("rest-\(scene.rawValue).png")) == true
                lines.append("Rest illustration \(scene.rawValue) rendered: \(captured && scene.illustration != nil)")
                endRest(animated: false, countBreak: false)
                try? await Task.sleep(for: .milliseconds(120))
            }
            lines.append("Rest illustration hills loaded: \(RestScene.hills.illustration != nil)")
            preferences.language = .english
            beginRest(batch: combined, screen: screen, recordReminder: false)
            try? await Task.sleep(for: .milliseconds(350))
            let standCaptured = rest?.capture(to: output.appendingPathComponent("rest-stand-english.png")) == true
            lines.append("English standing break rendered: \(standCaptured)")
            endRest(animated: false, countBreak: false)
            preferences.language = originalLanguage
            let systemAppearance = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .darkAqua)
            beginRest(batch: ReminderBatch(main: .look), screen: screen, recordReminder: false)
            try? await Task.sleep(for: .milliseconds(300))
            let darkSceneCaptured = rest?.capture(to: output.appendingPathComponent("rest-dark.png")) == true
            endRest(animated: false, countBreak: false)
            _ = show(batch: ReminderBatch(main: .look), forcedEdge: .right, demo: true,
                     preferredScreen: screen, samplePointer: pointer)
            try? await Task.sleep(for: .seconds((nudge?.entranceDuration ?? 0) + 0.22))
            let darkCardCaptured = nudge?.captureCard(to: output.appendingPathComponent("card-dark.png")) == true
            dismissNudge(animated: false)
            NSApp.appearance = systemAppearance
            lines.append("Dark illustration and callout rendered: \(darkSceneCaptured && darkCardCaptured)")
            preferences.restScene = .rotate

            openSettings()
            try? await Task.sleep(for: .milliseconds(250))
            let settingsCaptured = settings?.contentView.map {
                ProbeCapture.view($0, to: output.appendingPathComponent("settings.png"))
            } ?? false
            lines.append("Settings rendered: \(settingsCaptured)")
            let expectedTitle = Copy.chinese ? "歇哈嘛设置" : "Rest a Bit Settings"
            lines.append("Settings title matches: \(settings?.title == expectedTitle) [\(expectedTitle)]")
            if let window = settings, let host = window.contentView {
                let fixtureURL = output.appendingPathComponent("Fixture.app")
                let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 180, height: 80),
                                     styleMask: [.titled], backing: .buffered, defer: false)
                window.beginSheet(sheet, completionHandler: nil)
                try? await Task.sleep(for: .milliseconds(100))
                window.endSheet(sheet)
                addExcludedAppAfterSheet(fixtureURL)
                addExcludedAppAfterSheet(fixtureURL)
                try? await Task.sleep(for: .milliseconds(350))
                let expectedID = Bundle(url: fixtureURL)?.bundleIdentifier
                let updated = expectedID != nil && preferences.excluded.count == 1 &&
                    preferences.excluded.first?.id == expectedID && window.attachedSheet == nil
                var captured = false
                if let scroll = ProbeCapture.scrollView(in: host), let document = scroll.documentView {
                    let origin = scroll.contentView.bounds.origin
                    let bottom = document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0
                    scroll.contentView.scroll(to: CGPoint(x: origin.x, y: bottom))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try? await Task.sleep(for: .milliseconds(150))
                    captured = ProbeCapture.view(host, to: output.appendingPathComponent("settings-excluded.png"))
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                lines.append("Excluded app appears after sheet closes without reopening settings: \(updated && captured)")
                let syntheticHelper = fixtureURL.appendingPathComponent("Contents/Frameworks/Fixture Helper.app", isDirectory: true)
                let identity = ForegroundIdentity(bundleIdentifier: "example.invalid.helper", locations: [syntheticHelper])
                let unrelated = ForegroundIdentity(bundleIdentifier: "example.invalid.helper", locations: [])
                let iconAndMatching = preferences.excluded.first.map { exclusion in
                    let olderExclusion = ExcludedApp(id: exclusion.id, name: exclusion.name)
                    return exclusion.applicationIcon != nil && identity.matches(exclusion)
                        && identity.matches(olderExclusion) && !unrelated.matches(exclusion)
                } ?? false
                lines.append("Excluded icon and nested helper matching verified: \(iconAndMatching)")
            }
            settings?.setContentSize(NSSize(width: 480, height: settings?.contentView?.frame.height ?? 660))
            preferences.excluded.append(ExcludedApp(
                id: "local.restabit.demo-long-name",
                name: "Sample Application with an Unusually Long Name for Checking English Settings Layout at the Minimum Window Width"
            ))
            for language in [AppLanguage.english, .chinese] {
                preferences.language = language
                try? await Task.sleep(for: .milliseconds(150))
                let title = language == .chinese ? "歇哈嘛设置" : "Rest a Bit Settings"
                let quit = language == .chinese ? "退出歇哈嘛" : "Quit Rest a Bit"
                let logo = language == .chinese ? "歇哈嘛" : "Rest a Bit"
                let verified = settings?.title == title && menu.items.last?.title == quit
                    && item?.button?.image?.accessibilityDescription == logo && item?.button?.toolTip != Copy.name
                let captured = settings?.contentView.map {
                    ProbeCapture.view($0, to: output.appendingPathComponent("settings-\(language.rawValue).png"))
                } ?? false
                lines.append("Live language \(language.rawValue) updated: \(verified && captured)")
            }
            preferences.language = .system
            let originalAppearance = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .darkAqua)
            preferences.showMenuBarProgress = true
            try? await Task.sleep(for: .milliseconds(150))
            let darkProgressSettings = settings?.contentView.map {
                ProbeCapture.view($0, to: output.appendingPathComponent("settings-progress-dark.png"))
            } ?? false
            lines.append("Enabled menu-bar progress settings rendered in dark mode: \(darkProgressSettings)")
            preferences.showMenuBarProgress = false
            NSApp.appearance = originalAppearance
            let settingsFrame = settings?.frame
            settings?.close()
            let released = settings == nil
            openSettings()
            lines.append("Closed settings rebuilds at the same position: \(released && settings?.frame == settingsFrame)")
            settings?.close()
            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
    #endif
}
