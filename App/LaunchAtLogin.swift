import Observation
import ServiceManagement

/// macOS owns this preference; never register or repair it automatically at launch.
@MainActor @Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?
    @ObservationIgnored private let readStatus: () -> SMAppService.Status
    @ObservationIgnored private let register: () throws -> Void
    @ObservationIgnored private let unregister: () throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = readStatus() }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isOn else { return }
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            // Do not expose raw system errors or claim a preference was saved on failure.
            errorMessage = String(localized: "Couldn’t change launch at login. Check Login Items in System Settings and try again.")
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
