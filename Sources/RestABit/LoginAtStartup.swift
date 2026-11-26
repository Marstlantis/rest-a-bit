import Combine
import ServiceManagement

@MainActor
final class LoginAtStartup: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var message: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    convenience init() {
        let service = SMAppService.mainApp
        self.init(readStatus: { service.status }, register: { try service.register() },
                  unregister: { try service.unregister() })
    }

    private init(readStatus: @escaping () -> SMAppService.Status,
                 register: @escaping () throws -> Void, unregister: @escaping () throws -> Void) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        let current = readStatus()
        if current != status {
            status = current
            message = nil
        }
    }

    func setRequested(_ value: Bool) {
        refresh()
        guard value != isRequested else { return }
        message = nil
        do {
            if value { try register() } else { try unregister() }
        } catch {
            message = Copy.text("无法更改登录时启动。", "Couldn’t change launch at login.")
                + " " + error.localizedDescription
        }
        refresh()
        if needsApproval { message = nil }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    #if DEBUG
    static func verifyTransitions() -> Bool {
        var state = SMAppService.Status.notRegistered
        var registrationCount = 0
        var unregistrationCount = 0
        let login = LoginAtStartup(readStatus: { state }, register: {
            registrationCount += 1
            state = .requiresApproval
        }, unregister: {
            unregistrationCount += 1
            state = .notRegistered
        })
        guard !login.isRequested else { return false }
        login.setRequested(true)
        guard login.isRequested && login.needsApproval && registrationCount == 1 else { return false }
        state = .enabled
        login.refresh()
        guard login.isRequested && !login.needsApproval else { return false }
        login.setRequested(false)
        guard !login.isRequested && unregistrationCount == 1 else { return false }
        let failed = LoginAtStartup(readStatus: { .enabled }, register: {}, unregister: {
            throw CocoaError(.fileReadNoPermission)
        })
        failed.setRequested(false)
        return failed.isRequested && failed.message != nil
    }
    #endif
}
