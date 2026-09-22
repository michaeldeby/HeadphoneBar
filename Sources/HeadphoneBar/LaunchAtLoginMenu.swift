import SwiftUI
import ServiceManagement
import AppKit

struct LaunchAtLoginMenu: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: setEnabled
            )).toggleStyle(.switch).controlSize(.small)
            if status == .requiresApproval {
                Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
        .alert("Could not change launch at login", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { errorMessage = error.localizedDescription }
        status = SMAppService.mainApp.status
        if enabled && status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
