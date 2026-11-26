import AppKit
import SwiftUI
import RestABitCore

struct ExcludedApp: Codable, Equatable, Identifiable {
    let id: String
    let name: String
}

final class Preferences: ObservableObject {
    @Published var rules: [Reminder: ReminderRule] { didSet { save(); changed?() } }
    @Published var excluded: [ExcludedApp] { didSet { save(); changed?() } }
    @Published var autoStart: Bool { didSet { save(); changed?() } }
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
        var edgeMotion: EdgeMotion? = nil
        var blinkMotion: BlinkMotion? = nil
        var restScene: RestScene? = nil
        var language: AppLanguage? = nil
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
        rules = ReminderSchedule(rules: stored?.rules ?? [:]).rules
        excluded = stored?.excluded ?? []
        autoStart = stored?.autoStart ?? false
        edgeMotion = stored?.edgeMotion ?? .rotate
        blinkMotion = stored?.blinkMotion ?? .rotate
        restScene = stored?.restScene ?? .rotate
        language = stored?.language ?? .system
        if current == nil, stored != nil { save() }
    }

    private func save() {
        let stored = Stored(rules: rules, excluded: excluded, autoStart: autoStart,
                            edgeMotion: edgeMotion, blinkMotion: blinkMotion, restScene: restScene, language: language)
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
              migrated.excluded == excluded, migrated.autoStart,
              fresh.data(forKey: key) != nil,
              legacy.data(forKey: previousKey) == encoded else { return false }

        guard migrated.edgeMotion == .rotate, migrated.blinkMotion == .rotate, migrated.restScene == .rotate, migrated.language == .system else { return false }
        migrated.autoStart = false
        migrated.edgeMotion = .peek
        migrated.blinkMotion = .sway
        migrated.restScene = .shore
        migrated.language = .english
        let reopened = Preferences(defaults: fresh, previousDomain: previous)
        return !reopened.autoStart && reopened.rules[.look] == rule && reopened.excluded == excluded
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
                    Button(Copy.text("打开系统登录项…", "Open System Login Items…")) {
                        loginAtStartup.openLoginItems()
                    }
                    .padding(.leading, 30)
                }
            } footer: {
                if let message = loginAtStartup.message {
                    Text(message)
                }
            }

            Section {
                ForEach(Reminder.allCases, id: \.self) { reminder in
                    let rule = preferences.rules[reminder] ?? ReminderRule(minutes: reminder.defaultMinutes)
                    HStack(spacing: 8) {
                        ReminderGlyph(reminder: reminder)
                            .foregroundStyle(.secondary)
                        Text(reminder.name)
                        Spacer(minLength: 12)
                        Text(Copy.text("\(rule.minutes) 分钟", "\(rule.minutes) min"))
                            .monospacedDigit()
                            .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
                            .frame(width: 76, alignment: .trailing)
                        Stepper(value: binding(for: reminder, \.minutes), in: 1...240) {
                            Text(Copy.text("\(reminder.name)提醒间隔", "\(reminder.name) interval"))
                        }
                        .labelsHidden()
                        .frame(width: 24, alignment: .trailing)
                        .disabled(!rule.enabled)
                        .accessibilityValue(Copy.text("\(rule.minutes) 分钟", "\(rule.minutes) minutes"))
                        Toggle(reminder.name, isOn: binding(for: reminder, \.enabled))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(minHeight: 24)
                }

                row(Copy.text("自动开始休息", "Start breaks automatically"), icon: "timer") {
                    Toggle(Copy.text("自动开始休息", "Start breaks automatically"), isOn: $preferences.autoStart)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } header: {
                Text(Copy.text("提醒间隔", "Reminders"))
            } footer: {
                Text(Copy.text("开启后，提醒结束时会自动进入全屏休息。", "When on, full-screen breaks begin after the reminder."))
            }

            Section {
                row(Copy.text("入场动作", "Entrance motion"), icon: "arrow.turn.down.right") {
                    Picker(Copy.text("入场动作", "Entrance motion"), selection: $preferences.edgeMotion) {
                        ForEach(EdgeMotion.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                row(Copy.text("眨眼动作", "Blink motion"), icon: "eye") {
                    Picker(Copy.text("眨眼动作", "Blink motion"), selection: $preferences.blinkMotion) {
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
                Text(Copy.text("动画和插画", "Motion and illustrations"))
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preferences.excluded) { app in
                        row(app.name, icon: "app") {
                            Button {
                                preferences.excluded = preferences.excluded.filter { $0.id != app.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Copy.text("移除 \(app.name)", "Remove \(app.name)"))
                        }
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
                Text(Copy.text("这些应用在前台时暂停提醒，离开后等至少 30 秒。", "Reminders pause in these apps and wait at least 30 seconds after you leave."))
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginAtStartup.refresh()
        }
        .frame(minWidth: 480, idealWidth: 510, minHeight: 425, idealHeight: 654)
    }

    private func row<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: 24)
    }

    private func binding<Value>(for reminder: Reminder, _ keyPath: WritableKeyPath<ReminderRule, Value>) -> Binding<Value> {
        Binding {
            (preferences.rules[reminder] ?? ReminderRule(minutes: reminder.defaultMinutes))[keyPath: keyPath]
        } set: { value in
            preferences.rules[reminder, default: ReminderRule(minutes: reminder.defaultMinutes)][keyPath: keyPath] = value
        }
    }
}
