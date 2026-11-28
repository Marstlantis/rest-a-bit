import AppKit
import SwiftUI
import RestABitCore

struct ExcludedApp: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let bundlePath: String?

    init(id: String, name: String, bundlePath: String? = nil) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
    }
}

final class Preferences: ObservableObject {
    @Published var rules: [Reminder: ReminderRule] { didSet { save(); changed?() } }
    @Published var excluded: [ExcludedApp] { didSet { save(); changed?() } }
    @Published var autoStart: Bool { didSet { save(); changed?() } }
    @Published var pauseForFullScreen: Bool { didSet { save(); changed?() } }
    @Published var showMenuBarProgress: Bool { didSet { save(); changed?() } }
    @Published var edgeMotion: EdgeMotion { didSet { save(); changed?() } }
    @Published var blinkMotion: BlinkMotion { didSet { save(); changed?() } }
    @Published var restScene: RestScene { didSet { save(); changed?() } }
    @Published var language: AppLanguage { didSet { save(); changed?() } }
    var changed: (() -> Void)?

    private let defaults: UserDefaults?
    private static let key = "RestABitPreferences.v1"
    private static let previousDomain = "local.foxpause.app"
    private static let previousKey = "FoxPausePreferences.v1"

    private struct Stored: Codable {
        var rules: [Reminder: ReminderRule]
        var excluded: [ExcludedApp]
        var autoStart: Bool
        var pauseForFullScreen: Bool? = nil
        var showMenuBarProgress: Bool? = nil
        var edgeMotion: EdgeMotion? = nil
        var blinkMotion: BlinkMotion? = nil
        var restScene: RestScene? = nil
        var language: AppLanguage? = nil
        var pelvicRule: ReminderRule? = nil
    }

    init(defaults: UserDefaults? = .standard, previousDomain: String = Preferences.previousDomain) {
        self.defaults = defaults
        let current = defaults?.data(forKey: Self.key)
        let data: Data?
        if current == nil, defaults != nil {
            data = UserDefaults(suiteName: previousDomain)?.data(forKey: Self.previousKey)
        } else {
            data = current
        }
        let stored = data.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        var savedRules = stored?.rules ?? [:]
        if let pelvicRule = stored?.pelvicRule { savedRules[.pelvicFloor] = pelvicRule }
        rules = ReminderSchedule(rules: savedRules).rules
        excluded = stored?.excluded ?? []
        autoStart = stored?.autoStart ?? false
        pauseForFullScreen = stored?.pauseForFullScreen ?? true
        showMenuBarProgress = stored?.showMenuBarProgress ?? false
        edgeMotion = stored?.edgeMotion ?? .rotate
        blinkMotion = stored?.blinkMotion ?? .rotate
        restScene = stored?.restScene ?? .rotate
        language = stored?.language ?? .system
        if current == nil, stored != nil { save() }
    }

    private func save() {
        // Older builds still decode the original reminder keys when users roll back.
        let stored = Stored(rules: rules.filter { $0.key != .pelvicFloor }, excluded: excluded, autoStart: autoStart,
                            pauseForFullScreen: pauseForFullScreen, showMenuBarProgress: showMenuBarProgress,
                            edgeMotion: edgeMotion, blinkMotion: blinkMotion, restScene: restScene, language: language,
                            pelvicRule: rules[.pelvicFloor])
        if let data = try? JSONEncoder().encode(stored) { defaults?.set(data, forKey: Self.key) }
    }
    #if DEBUG
    static func verifyMigration() -> Bool {
        let domain = "local.restabit.probe." + UUID().uuidString
        let previous = domain + ".previous"
        guard let fresh = UserDefaults(suiteName: domain),
              let legacy = UserDefaults(suiteName: previous) else { return false }
        defer {
            fresh.removePersistentDomain(forName: domain)
            legacy.removePersistentDomain(forName: previous)
        }

        let excluded = [ExcludedApp(id: "example.invalid.editor", name: "Synthetic Editor")]
        let rule = ReminderRule(enabled: false, minutes: 37)
        let old = Stored(rules: [.look: rule], excluded: excluded, autoStart: true)
        guard let encoded = try? JSONEncoder().encode(old) else { return false }
        legacy.set(encoded, forKey: previousKey)
        let migrated = Preferences(defaults: fresh, previousDomain: previous)
        guard migrated.rules[.look] == rule,
              migrated.rules[.blink] == ReminderRule(minutes: 10),
              migrated.rules[.pelvicFloor] == .init(enabled: false, minutes: 120),
              migrated.excluded == excluded, migrated.autoStart, migrated.pauseForFullScreen, !migrated.showMenuBarProgress,
              fresh.data(forKey: key) != nil,
              legacy.data(forKey: previousKey) == encoded else { return false }

        guard migrated.edgeMotion == .rotate, migrated.blinkMotion == .rotate, migrated.restScene == .rotate, migrated.language == .system else { return false }
        migrated.autoStart = false
        migrated.pauseForFullScreen = false
        migrated.showMenuBarProgress = true
        migrated.edgeMotion = .peek
        migrated.blinkMotion = .sway
        migrated.restScene = .shore
        migrated.language = .english
        let practiceRule = ReminderRule(minutes: 180)
        migrated.rules[.pelvicFloor] = practiceRule
        guard let saved = fresh.data(forKey: key),
              var oldPracticeSettings = (try? JSONSerialization.jsonObject(with: saved)) as? [String: Any]
        else { return false }
        oldPracticeSettings["practiceReminders"] = ["date": 0, "count": 2]
        guard let oldPracticeData = try? JSONSerialization.data(withJSONObject: oldPracticeSettings) else { return false }
        fresh.set(oldPracticeData, forKey: key)
        let reopened = Preferences(defaults: fresh, previousDomain: previous)
        return !reopened.autoStart && !reopened.pauseForFullScreen && reopened.showMenuBarProgress
            && reopened.rules[.pelvicFloor] == practiceRule
            && reopened.rules[.look] == rule && reopened.excluded == excluded
            && reopened.edgeMotion == .peek && reopened.blinkMotion == .sway && reopened.restScene == .shore && reopened.language == .english
    }
    #endif

}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var loginAtStartup: LoginAtStartup
    let addApp: () -> Void

    var body: some View {
        Form {
            Section {
                row(Copy.text("语言", "Language"), icon: "globe") {
                    Picker(Copy.text("语言", "Language"), selection: $preferences.language) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row(Copy.text("登录时启动", "Launch at login"), icon: "power") {
                    Toggle(Copy.text("登录时启动", "Launch at login"), isOn: Binding {
                        loginAtStartup.isRequested
                    } set: { value in
                        loginAtStartup.setRequested(value)
                    })
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                if loginAtStartup.needsApproval {
                    Button(Copy.text("打开系统登录项…", "Open Login Items…")) {
                        loginAtStartup.openLoginItems()
                    }
                    .padding(.leading, 30)
                }
                menuBarProgressRow
            } footer: {
                if let message = loginAtStartup.message {
                    Text(message)
                }
            }

            Section {
                ForEach(Reminder.allCases, id: \.self) { reminder in
                    let rule = preferences.rules[reminder] ?? reminder.defaultRule
                    HStack(spacing: 8) {
                        ReminderGlyph(reminder: reminder)
                            .foregroundStyle(.secondary)
                        Text(reminder.name)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Text(Copy.text("\(rule.minutes) 分钟", "\(rule.minutes) min"))
                            .monospacedDigit()
                            .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
                            .frame(width: 76, alignment: .trailing)
                        Stepper(value: binding(for: reminder, \.minutes), in: 1...240) {
                            Text(Copy.text("\(reminder.name)提醒间隔", "Interval for \(reminder.name)"))
                        }
                        .labelsHidden()
                        .frame(width: 24, alignment: .trailing)
                        .disabled(!rule.enabled)
                        .accessibilityValue(Copy.text("\(rule.minutes) 分钟",
                                                      rule.minutes == 1 ? "1 minute" : "\(rule.minutes) minutes"))
                        Toggle(reminder.name, isOn: binding(for: reminder, \.enabled))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(minHeight: 24)
                }

                row(Copy.text("全屏时暂停提醒", "Pause in full screen"), icon: "arrow.up.left.and.arrow.down.right") {
                    Toggle(Copy.text("全屏时暂停提醒", "Pause in full screen"), isOn: $preferences.pauseForFullScreen)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                row(Copy.text("自动开始休息", "Start breaks automatically"),
                    detail: Copy.text("远眺和站立", "Eye and standing breaks"), icon: "timer") {
                    Toggle(Copy.text("自动开始休息", "Start breaks automatically"), isOn: $preferences.autoStart)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } header: {
                Text(Copy.text("提醒间隔", "Reminders"))
            }

            Section {
                row(Copy.text("入场动作", "Entrance animation"), icon: "arrow.turn.down.right") {
                    Picker(Copy.text("入场动作", "Entrance animation"), selection: $preferences.edgeMotion) {
                        ForEach(EdgeMotion.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row(Copy.text("眨眼动作", "Blink animation"), icon: "eye") {
                    Picker(Copy.text("眨眼动作", "Blink animation"), selection: $preferences.blinkMotion) {
                        ForEach(BlinkMotion.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row(Copy.text("休息插画", "Break illustration"), icon: "photo") {
                    Picker(Copy.text("休息插画", "Break illustration"), selection: $preferences.restScene) {
                        ForEach(RestScene.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text(Copy.text("动画和插画", "Animations and illustrations"))
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preferences.excluded) { app in
                        HStack(spacing: 8) {
                            ExcludedAppIcon(app: app)
                            Text(app.name)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Button {
                                preferences.excluded = preferences.excluded.filter { $0.id != app.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Copy.text("移除 \(app.name)", "Remove \(app.name)"))
                        }
                        .frame(minHeight: 24)
                    }
                    Button(action: addApp) {
                        Label(Copy.text("添加应用…", "Add App…"), systemImage: "plus")
                    }
                    .padding(.leading, 30)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text(Copy.text("排除应用", "Excluded Apps"))
            } footer: {
                Text(Copy.text("使用时暂停，切出后至少等 30 秒。", "Pauses in these apps. Waits at least 30 sec after you leave."))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginAtStartup.refresh()
        }
        .frame(minWidth: 480, idealWidth: 510, minHeight: 425, idealHeight: 654)
    }

    private var menuBarProgressRow: some View {
        let title = Copy.text("菜单栏休息进度", "Menu bar progress")
        let detail = Copy.text("狐狸随下一次远眺或站立的倒计时填色。", "Counts down to an eye or standing break.")
        return row(title, detail: detail) {
            Image(nsImage: StatusIcon.image(accessibilityLabel: "", fill: 0.5))
                .renderingMode(.template)
                .foregroundStyle(.primary)
        } content: {
            Toggle(title, isOn: $preferences.showMenuBarProgress)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityHint(detail)
        }
    }

    private func row<Content: View>(_ title: String, detail: String? = nil, icon: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        row(title, detail: detail) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        } content: {
            content()
        }
    }

    private func row<Symbol: View, Content: View>(_ title: String, detail: String? = nil,
                                                  @ViewBuilder symbol: () -> Symbol,
                                                  @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            symbol()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: 24)
    }

    private func binding<Value>(for reminder: Reminder, _ keyPath: WritableKeyPath<ReminderRule, Value>) -> Binding<Value> {
        Binding {
            (preferences.rules[reminder] ?? reminder.defaultRule)[keyPath: keyPath]
        } set: { value in
            preferences.rules[reminder, default: reminder.defaultRule][keyPath: keyPath] = value
        }
    }
}


private struct ExcludedAppIcon: View {
    let app: ExcludedApp
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
        .task(id: app) { icon = app.applicationIcon }
    }
}
