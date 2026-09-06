import SwiftUI
import AppKit
import IOBluetooth
import CoreBluetooth
import HeadphoneProtocol
import CoreAudio

@MainActor final class AppModel: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published var headphones: [Headphone] = []
    @Published var selectedID: String?
    @Published var controls: Controls?
    @Published var busy = false
    @Published var message: String?
    @Published var bluetoothStatus: String?
    @Published var updatedAt: Date?
    @Published var audioOutputs: [AudioOutput] = []
    @Published var audioOutputID: AudioDeviceID?
    @Published var audioOutputError: String?
    @Published var dongleFormats: [BTDAudioFormat] = []
    @Published var dongleFormatID = ""
    @Published var dongleFormatError: String?
    @Published var dongleMode: BTDMode?
    @Published var dongleModeError: String?
    @Published var readingDongleMode = false
    var dongleOutputs: [AudioOutput] { audioOutputs.filter(\.isBTD700) }
    var showsDongleControls: Bool {
        selected?.kind.supportsBTD700Audio == true && !dongleOutputs.isEmpty
    }
    var directOutput: AudioOutput? {
        guard let selected else { return nil }
        let matches = audioOutputs.filter { $0.name == selected.name && $0.transport == kAudioDeviceTransportTypeBluetooth }
        return matches.count == 1 ? matches[0] : nil
    }
    var currentOutputName: String { audioOutputs.first { $0.id == audioOutputID }?.name ?? "Unavailable" }
    private var advancedPanel: NSPanel?
    private var controller: HeadphoneController?
    private var bleDiagnostic: MomentumBLEDiagnostic?
    private var timer: Timer?
    private var bluetooth: CBCentralManager!
    var selected: Headphone? { headphones.first { $0.id == selectedID } }
    override init() {
        super.init()
        if ProcessInfo.processInfo.arguments.contains("--diagnose-momentum") { bleDiagnostic = MomentumBLEDiagnostic() }
        bluetooth = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothStatus = nil; scan()
        case .poweredOff: bluetoothStatus = "Bluetooth is off. Turn it on in System Settings."; clearConnection()
        case .unauthorized: bluetoothStatus = "Allow HeadphoneBar in System Settings → Privacy & Security → Bluetooth."; clearConnection()
        case .unsupported: bluetoothStatus = "Bluetooth is unavailable on this Mac."; clearConnection()
        default: bluetoothStatus = "Waiting for Bluetooth…"
        }
    }
    private func clearConnection() {
        controls = nil
        if !busy { controller?.close(); controller = nil }
    }
    func scan() {
        audioOutputs = AudioOutputs.list()
        audioOutputID = AudioOutputs.currentID()
        guard !busy, bluetooth.state == .poweredOn else { return }
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        headphones = paired.compactMap { device in
            guard let id = device.addressString, let name = device.name else { return nil }
            let kind = HeadphoneKind.detect(name)
            guard kind != .unknown || device.deviceClassMajor == 4 else { return nil }
            return Headphone(id: id, name: name, kind: kind, connected: device.isConnected())
        }.sorted { lhs, rhs in lhs.connected != rhs.connected ? lhs.connected : lhs.name < rhs.name }
        if let selected, !selected.connected { clearConnection() }
        if selectedID != nil && selected == nil { clearConnection(); selectedID = nil }
        if selectedID == nil {
            let connected = headphones.filter { $0.connected && $0.kind != .unknown }
            if connected.count == 1 { select(connected[0].id) }
        }
    }
    func select(_ id: String) {
        guard !busy else { return }
        controller?.close(); controller = nil; controls = nil; message = nil; updatedAt = nil
        selectedID = id
        refresh()
    }
    func refresh() {
        guard !busy else { return }
        guard let selected, selected.connected else { message = "Connect the headphones in macOS Bluetooth settings, then refresh."; return }
        if controller == nil {
            switch selected.kind {
            case .momentum4: controller = MomentumController(address: selected.id)
            case .sony: controller = SonyController(address: selected.id)
            case .bose: controller = BoseController(name: selected.name)
            case .sennheiserAudio: message = "BTD 700 audio is supported. ANC/EQ controls for this model are not implemented yet."; return
            case .unknown: message = "Detected as an audio device. This model does not have a control adapter yet."; return
            }
        }
        perform { _ in }
    }
    private func perform(_ operation: @escaping (HeadphoneController) async throws -> Void) {
        guard !busy, let controller else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await operation(controller)
                controls = try await controller.read()
                updatedAt = Date()
            } catch {
                controls = nil; updatedAt = nil
                message = error.localizedDescription
                controller.close(); self.controller = nil
            }
        }
    }
    func setMode(_ mode: Int) { perform { try await $0.setMode(mode) } }
    func setLevel(_ level: Double) { perform { try await $0.setLevel(level) } }
    func setEQ(_ eq: [Double]) { perform { try await $0.setEQ(eq) } }
    func refreshDongleMode(clearErrors: Bool = true) async {
        guard showsDongleControls, !readingDongleMode, !busy else { return }
        do {
            dongleFormats = try BTDAudioFormats.available()
            dongleFormatID = try BTDAudioFormats.current().id
            if clearErrors { dongleFormatError = nil }
        } catch { dongleFormats = []; dongleFormatID = ""; dongleFormatError = error.localizedDescription }
        readingDongleMode = true
        defer { readingDongleMode = false }
        do {
            dongleMode = try await BTD700.mode().mode
            if clearErrors { dongleModeError = nil }
        } catch { dongleMode = nil; dongleModeError = error.localizedDescription }
    }
    func setDongleFormat(_ id: String) {
        guard !busy, !readingDongleMode, let format = dongleFormats.first(where: { $0.id == id }) else { return }
        busy = true
        dongleFormatError = nil
        Task {
            defer { busy = false }
            do { dongleFormatID = try await BTDAudioFormats.select(format).id }
            catch {
                dongleFormatID = (try? BTDAudioFormats.current().id) ?? ""
                dongleFormatError = error.localizedDescription
            }
        }
    }
    func setDongleMode(_ mode: BTDMode) {
        guard !busy, !readingDongleMode else { return }
        busy = true
        dongleModeError = nil
        Task {
            defer { busy = false }
            do { dongleMode = try await BTD700.setMode(mode).mode }
            catch { dongleMode = nil; dongleModeError = error.localizedDescription }
        }
    }
    func selectAudioOutput(_ output: AudioOutput) {
        guard !busy else { return }
        busy = true
        audioOutputError = nil
        Task {
            defer { busy = false; scan() }
            do {
                if output.isBTD700 {
                    guard dongleOutputs.count == 1 else {
                        throw ControlError.message("Connect only one BTD 700 dongle to choose the matching headphone connection.")
                    }
                    guard let selected, selected.kind.supportsBTD700Audio else {
                        throw ControlError.message("Select a supported Sennheiser Bluetooth headphone first.")
                    }
                    if selected.kind == .momentum4 {
                        guard selected.connected else {
                            throw ControlError.message("Connect MOMENTUM 4 directly to this Mac first so its control connection can be preserved.")
                        }
                        let momentum = controller as? MomentumController ?? MomentumController(address: selected.id)
                        try await momentum.connectDongle()
                    }
                }
                try AudioOutputs.select(output.id)
            } catch { audioOutputError = error.localizedDescription }
        }
    }
    func openBTDAdvanced() {
        if advancedPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "BTD 700 — Advanced"
            panel.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: BTDAdvancedPanel(model: self))
            panel.contentViewController = host
            panel.setContentSize(host.view.fittingSize)
            panel.center()
            advancedPanel = panel
        }
        advancedPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await refreshDongleMode() }
    }
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
}

@main struct HeadphoneBarApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra("HeadphoneBar", systemImage: "headphones") {
            HeadphonePanel(model: model)
        }.menuBarExtraStyle(.window)
    }
}

struct HeadphonePanel: View {
    @ObservedObject var model: AppModel
    private func outputButton(_ title: String, output: AudioOutput) -> some View {
        let selected = model.audioOutputID == output.id
        return Button { model.selectAudioOutput(output) } label: {
            Text(title).font(.callout.weight(.medium))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        }.buttonStyle(.plain).disabled(model.busy)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "headphones").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HeadphoneBar").font(.headline)
                    Text("Headphone controls").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                else { Button { model.scan(); model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh headphone settings") }
            }
            Divider()
            if let status = model.bluetoothStatus {
                Label(status, systemImage: "antenna.radiowaves.left.and.right.slash").font(.callout)
            } else if model.headphones.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No headphones found").font(.headline)
                    Text("Pair your headphones in Bluetooth settings. Connected Sennheiser, Sony, and Bose models appear here automatically.").foregroundStyle(.secondary)
                }
            } else {
                Picker("Headphones", selection: Binding(get: { model.selectedID ?? "" }, set: { model.select($0) })) {
                    Text("Choose headphones…").tag("")
                    ForEach(model.headphones) { headphone in
                        Text(headphone.name + (headphone.connected ? "" : " · Disconnected")).tag(headphone.id)
                    }
                }.disabled(model.busy)
                if let selected = model.selected {
                    HStack {
                        Circle().fill(selected.connected ? Color.green : Color.gray).frame(width: 6, height: 6)
                        Text(selected.kind.rawValue + " · " + (selected.connected ? "Connected" : "Disconnected"))
                        Spacer()
                        if let battery = model.controls?.battery {
                            Label("\(battery)%", systemImage: battery > 20 ? "battery.75percent" : "battery.25percent")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.showsDongleControls {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AUDIO OUTPUT").font(.caption.weight(.semibold))
                        Spacer()
                        Text(model.currentOutputName).font(.caption).lineLimit(1)
                    }.foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(model.dongleOutputs) { dongle in
                            outputButton("BTD 700", output: dongle)
                        }
                        if let direct = model.directOutput {
                            outputButton("Bluetooth", output: direct)
                        }
                    }
                    Text(model.selected?.kind == .momentum4
                        ? "BTD 700 uses the second connection, replacing your phone when needed. This Mac stays connected for ANC and EQ."
                        : "Connect these headphones to the BTD 700 first. This button selects Mac audio output; automatic headphone connection switching is not yet supported for this model.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = model.audioOutputError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let error = model.message {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let controls = model.controls {
                ControlPanel(controls: controls, model: model).id(model.updatedAt).disabled(model.busy)
            } else if model.busy {
                Text("Reading headphone settings…").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Bluetooth settings…") { model.openSettings() }.buttonStyle(.borderless)
                if model.showsDongleControls {
                    Button("BTD 700 Advanced…") { model.openBTDAdvanced() }.buttonStyle(.borderless)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless).disabled(model.busy)
            }.font(.caption)
        }
        .padding(20).frame(width: 380).fixedSize(horizontal: false, vertical: true)
        .onAppear { model.scan(); if model.selectedID != nil && !model.busy { model.refresh() } }
    }
}

struct BTDAdvancedPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BTD 700").font(.title2.weight(.semibold))
            Text("Advanced audio settings").foregroundStyle(.secondary)
            Divider()
            if model.showsDongleControls {
                HStack {
                    Text("Sound mode").font(.headline)
                    Spacer()
                    if model.readingDongleMode { ProgressView().controlSize(.small) }
                    else { Button("Refresh") { Task { await model.refreshDongleMode() } }.disabled(model.busy) }
                }
                Picker("Sound mode", selection: Binding(get: { model.dongleMode?.rawValue ?? 255 }, set: { value in
                    if let mode = BTDMode(rawValue: value) { model.setDongleMode(mode) }
                })) {
                    if model.dongleMode == nil { Text("Unknown").tag(UInt8(255)) }
                    ForEach(BTDMode.allCases, id: \.rawValue) { mode in Text(mode.title).tag(mode.rawValue) }
                }.pickerStyle(.segmented).labelsHidden().disabled(model.busy || model.readingDongleMode)
                Text("Standard prioritises audio quality. Gaming reduces latency. Broadcast uses your saved Auracast public/private settings and requires a compatible receiver.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.dongleModeError { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Divider()
                Text("Audio format").font(.headline)
                Picker("Audio format", selection: Binding(get: { model.dongleFormatID }, set: { model.setDongleFormat($0) })) {
                    if !model.dongleFormats.contains(where: { $0.id == model.dongleFormatID }) { Text("Unavailable").tag(model.dongleFormatID) }
                    ForEach(model.dongleFormats) { format in Text(format.title).tag(format.id) }
                }.labelsHidden().disabled(model.busy || model.readingDongleMode || model.dongleFormats.isEmpty)
                Text("Sets the Mac’s USB audio format, as in Audio MIDI Setup. Bluetooth transmission quality also depends on the codec and headphones.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.dongleFormatError { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            } else {
                Text("Connect a BTD 700 and select your Sennheiser headphones to access these settings.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(20).frame(width: 420).fixedSize(horizontal: false, vertical: true)
            .task(id: model.busy) { await model.refreshDongleMode(clearErrors: false) }
    }
}

struct ControlPanel: View {
    let controls: Controls
    @ObservedObject var model: AppModel
    @State private var level: Double
    @State private var eq: [Double]
    init(controls: Controls, model: AppModel) {
        self.controls = controls; self.model = model
        _level = State(initialValue: controls.level ?? 0)
        _eq = State(initialValue: controls.eq)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NOISE CONTROL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(controls.modes) { mode in
                    Button { model.setMode(mode.id) } label: {
                        Text(mode.name).font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(controls.mode == mode.id ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(controls.mode == mode.id ? Color.white : Color.primary)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(controls.mode == mode.id ? [.isSelected] : [])
                }
            }
            if controls.level != nil {
                HStack { Text(controls.levelLabel); Spacer(); Text("\(Int(level))").monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
                VStack(spacing: 3) {
                    Slider(value: Binding(get: { level }, set: { level = $0.rounded() }), in: controls.levelRange) { editing in
                        if !editing && level != controls.level { model.setLevel(level) }
                    }.accessibilityLabel(controls.levelLabel)
                    HStack {
                        Spacer()
                        Rectangle().fill(Color.primary.opacity(0.65)).frame(width: 2, height: 8)
                        Spacer()
                    }.allowsHitTesting(false).accessibilityHidden(true)
                    if model.selected?.kind == .momentum4 {
                        Text("Neutral").frame(maxWidth: .infinity)
                            .overlay(alignment: .leading) { Text("ANC") }
                            .overlay(alignment: .trailing) { Text("Transparency") }
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !eq.isEmpty {
                Divider()
                HStack {
                    Text("EQUALIZER").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(eq.count) bands · dB").font(.caption)
                }.foregroundStyle(.secondary)
                if !controls.eqActive {
                    Text("EQ is inactive. Apply EQ enables it and replaces the current sound mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(eq.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Text(controls.eqLabels[index]).font(.caption).frame(width: 48, alignment: .leading)
                        Slider(value: Binding(get: { eq[index] }, set: { eq[index] = ($0 * 10).rounded() / 10 }), in: controls.eqRange).accessibilityLabel(controls.eqLabels[index])
                        Text(String(format: "%+.1f", eq[index])).font(.caption.monospacedDigit()).frame(width: 36)
                    }
                }
                HStack {
                    Button("Reset to flat") { eq = Array(repeating: 0, count: eq.count) }
                    Spacer()
                    Button("Apply EQ") { model.setEQ(eq) }.buttonStyle(.borderedProminent).disabled(eq == controls.eq && controls.eqActive)
                }.controlSize(.small)
            }
            if let note = controls.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let date = model.updatedAt {
                Text("Read from headphones at \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
