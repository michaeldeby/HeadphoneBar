import AppKit
import SwiftUI
import Carbon

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let remoteInbox = RemoteCommandInbox()
    private var controlsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        let event = NSAppleEventManager.shared().currentAppleEvent
        let login = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !login && event?.eventID != AEEventID(kAEGetURL) { showControls() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: raw), url.scheme == "headphonebar", url.query == nil else { return }
        if url.host == "command" {
            remoteInbox.receive(id: String(url.path.dropFirst()), model: model)
            return
        }
        guard url.path.isEmpty || url.path == "/" else { return }
        switch url.host {
        case "open": showControls()
        case "advanced": model.openBTDAdvanced()
        case "refresh": showControls(); model.refresh()
        default: return
        }
    }

    private func showControls() {
        if controlsWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "HeadphoneBar"
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: HeadphonePanel(model: model))
            host.sizingOptions = [.preferredContentSize]
            window.contentViewController = host
            window.setContentSize(host.view.fittingSize)
            window.center()
            controlsWindow = window
        }
        controlsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.panelOpened()
    }
}
