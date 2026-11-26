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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Block: Hashable { case sleep, displaySleep, lock, inactiveSession }

    private let log = Logger(subsystem: "local.restabit.app", category: "reminder")
    private let preferences: Preferences
    private let loginAtStartup = LoginAtStartup()
    private var schedule: ReminderSchedule
    private var art: FoxArt?
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var settings: NSWindow?
    private var timer: Timer?
    private var blocks: Set<Block> = []
    private var nextPresentation: Double = 0
    private var previousEdge: EntranceOrigin?
    private var previousEdgeMotion: EdgeMotion?
    private var previousBlinkMotion: BlinkMotion?
    private var previousRestScene: RestScene?
    private var random = SeededRandom(seed: UInt64.random(in: .min ... .max))
    private var nudge: NudgePresentation?
    private var blink: BlinkPresentation?
    private var retreat: NudgePresentation?
    private var rest: RestPresentation?
    private var fadingRest: RestPresentation?
    private var deadline: DispatchWorkItem?
    private var pendingCommit: ReminderBatch?
    private var testing = false

    override init() {
        #if DEBUG
        testing = ProcessInfo.processInfo.arguments.contains("--ui-probe")
        #endif
        preferences = Preferences(defaults: testing ? nil : .standard)
        schedule = ReminderSchedule(rules: preferences.rules)
        super.init()
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var workspace: NSWorkspace { .shared }
    private var reducedMotion: Bool { workspace.accessibilityDisplayShouldReduceMotion }
    private var presentationAvailable: Bool {
        nudge == nil && blink == nil && rest == nil && retreat == nil && fadingRest == nil && blocks.isEmpty
    }
    private var isExcluded: Bool {
        guard let id = workspace.frontmostApplication?.bundleIdentifier else { return false }
        return preferences.excluded.contains { $0.id == id }
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
        if testing { runProbe() }
        #endif
    }

    private func tick() {
        guard blocks.isEmpty else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                          eventType: CGEventType(rawValue: UInt32.max)!)
        let time = now
        schedule.advance(to: time, idle: idle, excluded: isExcluded, resting: rest != nil)
        let scheduledNudge = nudge.map { !$0.preview && !$0.demo } ?? false
        if idle >= ReminderSchedule.idlePauseAfter && (scheduledNudge || blink?.preview == false) {
            cancelPresentation(cooldown: 0)
        }
        guard presentationAvailable,
              time >= nextPresentation,
              let batch = schedule.due(now: time) else { return }
        show(batch: batch)
    }

    private func updateStatusLabel() {
        item?.button?.image = StatusIcon.image(accessibilityLabel: Copy.name)
        item?.button?.toolTip = Copy.name
        item?.button?.setAccessibilityLabel(Copy.name)
    }

    private func applyPreferences() {
        if Copy.language != preferences.language {
            Copy.language = preferences.language
            updateStatusLabel()
            settings?.title = Copy.settingsTitle
            nudge?.refreshCopy()
            blink?.refreshCopy()
            menuNeedsUpdate(menu)
        }
        let affectedNudge = nudge.flatMap { presentation in
            presentation.preview || presentation.demo ? nil : presentation.batch.included
        }?.contains { schedule.rules[$0] != preferences.rules[$0] } ?? false
        let affectedBlink = blink?.preview == false && schedule.rules[.blink] != preferences.rules[.blink]
        for (kind, rule) in preferences.rules { schedule.update(rule, for: kind) }
        if affectedNudge || affectedBlink || ((nudge != nil || blink != nil) && isExcluded) {
            cancelPresentation()
        }
        tick()
    }

    @discardableResult
    private func show(batch: ReminderBatch, preview: Bool = false, forcedEdge: EntranceOrigin? = nil,
                      demo: Bool = false, dismissOnly: Bool = false,
                      preferredScreen: NSScreen? = nil, samplePointer: CGPoint? = nil) -> Bool {
        guard presentationAvailable else { return false }
        let pointer = samplePointer ?? NSEvent.mouseLocation
        guard let screen = preferredScreen ?? NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return false }
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
        let water = batch.main == .water && art != nil ? WaterScene(in: safe, pointer: pointer) : nil
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
        presentation.showCard(animated: !reducedMotion && presentation.entranceDuration > 0)
        let seconds: Double = presentation.preview ? 6 : (presentation.batch.main == .water ? 12 : 10)
        after(seconds) { [weak self, weak presentation] in
            guard let self, let presentation, nudge === presentation else { return }
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
    }

    private func dismissNudge(animated: Bool) {
        deadline?.cancel()
        deadline = nil
        guard let presented = nudge else { return }
        nudge = nil
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
    }

    @objc private func takeBreak() {
        if let nudge, !nudge.preview, !nudge.dismissOnly, nudge.batch.main != .water {
            confirmNudge()
            return
        }
        if let nudge, !nudge.preview && !nudge.demo { schedule.finish(nudge.batch) }
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
        }
        pendingCommit = nil
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

    private func cancelPresentation(cooldown: Double = 30) {
        if nudge != nil { dismissNudge(animated: false) }
        dismissBlink()
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 722),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = Copy.settingsTitle
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, loginAtStartup: loginAtStartup,
                                                                       addApp: { [weak self] in self?.addExcludedApp() }))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
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
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              !preferences.excluded.contains(where: { $0.id == id }) else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        preferences.excluded = preferences.excluded + [ExcludedApp(id: id, name: name)]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        let status: String
        if let paused = schedule.pausedUntil {
            let minutes = max(1, Int(ceil((paused - now) / 60)))
            status = Copy.text("已暂停 · \(minutes) 分钟", "Paused · \(minutes) min")
        } else if isExcluded {
            status = Copy.text("当前应用已排除", "Current app is excluded")
        } else if let (reminder, time) = schedule.next(now: now) {
            let minutes = max(0, Int(ceil(time / 60)))
            status = Copy.text("下次提醒 · \(reminder.name) · \(minutes) 分钟", "Next · \(reminder.name) · \(minutes) min")
        } else {
            status = Copy.text("提醒已关闭", "Reminders off")
        }
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if schedule.pausedUntil == nil, !isExcluded, let next = schedule.next(now: now), !next.0.usesEdgeEntrance,
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
            add(Copy.text("现在休息", "Take a Break Now"), #selector(takeBreak))
            if let nudge, !nudge.preview, !nudge.dismissOnly, nudge.batch.main != .water {
                add(Copy.text("稍后 5 分钟", "Remind in 5 Min"), #selector(snoozeNudge))
            }
        }
        add(Copy.text("预览狐狸", "Preview Fox"), #selector(preview))
        add(Copy.text("预览眨眼提醒", "Preview Blink Reminder"), #selector(previewBlink))
        add(Copy.text("预览喝水提醒", "Preview Water Reminder"), #selector(previewWater))
        add(Copy.text("预览休息插画", "Preview Break Illustration"), #selector(previewRest))
        if schedule.pausedUntil != nil {
            add(Copy.text("继续提醒", "Resume Reminders"), #selector(resume))
        } else {
            add(Copy.text("暂停 30 分钟", "Pause for 30 Min"), #selector(pause))
        }
        menu.addItem(.separator())
        add(Copy.text("设置…", "Settings…"), #selector(openSettings), key: ",")
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
        add(Copy.quitTitle, #selector(quit), key: "q")
    }

    private func add(_ title: String, _ action: Selector, key: String = "") {
        menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
    }

    @objc private func reseed() {
        random = SeededRandom(seed: 42)
        previousEdge = nil
        previousEdgeMotion = nil
        previousBlinkMotion = nil
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
            if isExcluded || (rest != nil && rest?.frontmostPID != workspace.frontmostApplication?.processIdentifier) {
                cancelPresentation()
            }
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
                && item?.button?.toolTip == expectedName
                && item?.button?.image?.accessibilityDescription == expectedName
                && menu.items.last?.title == expectedQuit
            lines.append("Menu and application identity match: \(menuBrandMatches) [\(expectedName)]")
            lines.append("Synthetic previous settings migrate and persist: \(Preferences.verifyMigration())")
            lines.append("Login item registration states verified without changing login items: \(LoginAtStartup.verifyTransitions())")
            lines.append("Forward direction sprite sets loaded: \(art?.hasDirectionalGaits == true)")
            reseed()
            let frontmost = { self.workspace.frontmostApplication?.processIdentifier == fixturePID }
            lines.append("Synthetic editor initially frontmost: \(frontmost())")
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
                lines.append("\(edge.rawValue): arrived at the center and kept animation click-through: \(sample.arrivesAtCenter && count == frameCount)")
                lines.append("\(edge.rawValue): slows down before stopping: \(sample.slowsBeforeArrival)")
                lines.append("\(edge.rawValue): keeps forward heading: \(sample.keepsForwardHeading)")
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
            lines.append("Scheduled edge reminder skips overlapping blink: \(verifyEdgePriority(screen: screen, pointer: pointer))")
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
                let captured = ProbeCapture.view(host, to: output.appendingPathComponent("settings-excluded.png"))
                lines.append("Excluded app appears after sheet closes without reopening settings: \(updated && captured)")
            }
            for language in [AppLanguage.english, .chinese] {
                preferences.language = language
                try? await Task.sleep(for: .milliseconds(150))
                let title = language == .chinese ? "歇哈嘛设置" : "Rest a Bit Settings"
                let quit = language == .chinese ? "退出歇哈嘛" : "Quit Rest a Bit"
                let logo = language == .chinese ? "歇哈嘛" : "Rest a Bit"
                let verified = settings?.title == title && menu.items.last?.title == quit && item?.button?.toolTip == logo
                let captured = settings?.contentView.map {
                    ProbeCapture.view($0, to: output.appendingPathComponent("settings-\(language.rawValue).png"))
                } ?? false
                lines.append("Live language \(language.rawValue) updated: \(verified && captured)")
            }
            preferences.language = .system
            settings?.orderOut(nil)
            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
    #endif
}
