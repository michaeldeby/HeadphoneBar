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
    @Published var refreshing = false
    @Published var controlsVerified = false
    private var generation = 0
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var retryCount = 0
    private var retryAt: Date?
    private var cache: [String: (Controls, Date)] = [:]
    private let responseTimeout: Duration
    private let makeController: (Headphone) -> HeadphoneController?
    var working: Bool { busy || refreshing }
    var canEditControls: Bool { selected?.connected == true && controlsVerified && !working }
    var controlStatus: String {
        if selected?.connected != true { return "Mac Bluetooth disconnected · cached settings" }
        if refreshing { return controls == nil ? "Connecting controls…" : "Updating settings…" }
        return controlsVerified ? "Controls available" : "Controls unavailable · cached settings"
    }
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
    private var outputErrorWaitingForHeadphoneID: String?
    private var advancedPanel: NSPanel?
    private var controller: HeadphoneController?
    private var bleDiagnostic: MomentumBLEDiagnostic?
    private var timer: Timer?
    private var bluetooth: CBCentralManager!
    var selected: Headphone? { headphones.first { $0.id == selectedID } }
    init(startMonitoring: Bool = true, responseTimeout: Duration = .seconds(30), controllerFactory: ((Headphone) -> HeadphoneController?)? = nil) {
        self.responseTimeout = responseTimeout
        makeController = controllerFactory ?? { headphone in
            switch headphone.kind {
            case .momentum4: return MomentumController(address: headphone.id)
            case .sony: return SonyController(address: headphone.id)
            case .bose: return BoseController(name: headphone.name)
            default: return nil
            }
        }
        super.init()
        guard startMonitoring else { return }
        if ProcessInfo.processInfo.arguments.contains("--diagnose-momentum") { bleDiagnostic = MomentumBLEDiagnostic() }
        bluetooth = CBCentralManager(delegate: self, queue: .main)
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothStatus = nil; scan()
        case .poweredOff: bluetoothStatus = "Bluetooth is off. Turn it on in System Settings."; clearConnection()
        case .unauthorized: bluetoothStatus = "Allow HeadphoneBar in System Settings → Privacy & Security → Bluetooth."; clearConnection()
        case .unsupported: bluetoothStatus = "Bluetooth is unavailable on this Mac."; clearConnection()
        default: bluetoothStatus = "Waiting for Bluetooth…"; clearConnection()
        }
    }
    @objc func willSleep() { clearConnection() }
    @objc private func didWake() { clearConnection(); scan() }
    private func clearConnection() {
        generation += 1
        operationTask?.cancel(); operationTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        controller?.close(); controller = nil
        busy = false; refreshing = false; readingDongleMode = false
        controlsVerified = false
        retryCount = 0; retryAt = nil
    }
    func scan() {
        let oldDongles = Set(dongleOutputs.map(\.id))
        audioOutputs = AudioOutputs.list()
        audioOutputID = AudioOutputs.currentID()
        if oldDongles != Set(dongleOutputs.map(\.id)) {
            clearConnection()
            dongleMode = nil; dongleFormats = []; dongleFormatID = ""
            dongleModeError = nil; dongleFormatError = nil; audioOutputError = nil
        }
        guard bluetooth?.state == .poweredOn else { return }
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        updateHeadphones(paired.compactMap { device in
            guard let id = device.addressString, let name = device.name else { return nil }
            let kind = HeadphoneKind.detect(name)
            guard kind != .unknown || device.deviceClassMajor == 4 else { return nil }
            return Headphone(id: id, name: name, kind: kind, connected: device.isConnected())
        })
    }
    func updateHeadphones(_ devices: [Headphone], now: Date = Date()) {
        let wasConnected = selected?.connected == true
        headphones = devices.sorted { $0.connected != $1.connected ? $0.connected : $0.name < $1.name }
        let pairedIDs = Set(devices.map(\.id))
        cache = cache.filter { pairedIDs.contains($0.key) }
        if selectedID != nil && selected == nil {
            clearConnection(); selectedID = nil; controls = nil; updatedAt = nil; message = nil
            audioOutputError = nil; outputErrorWaitingForHeadphoneID = nil
        }
        if let waitingID = outputErrorWaitingForHeadphoneID,
           waitingID != selectedID || selected?.connected == true {
            audioOutputError = nil; outputErrorWaitingForHeadphoneID = nil
        }
        if wasConnected != (selected?.connected == true) { clearConnection(); message = nil }
        if selectedID == nil {
            let connected = headphones.filter { $0.connected && $0.kind != .unknown }
            if connected.count == 1 { select(connected[0].id) }
        } else if selected?.connected == true && !controlsVerified && !working && retryCount < 3,
                  retryAt == nil || now >= retryAt! {
            refresh(force: false, now: now)
        }
    }
    func select(_ id: String) {
        guard !busy else { return }
        clearConnection()
        selectedID = id
        controls = cache[id]?.0; updatedAt = cache[id]?.1
        message = nil; audioOutputError = nil; outputErrorWaitingForHeadphoneID = nil
        refresh(force: false)
    }
    func panelOpened() { scan(); refresh(force: false) }
    func refresh(force: Bool = true, now: Date = Date()) {
        guard !working, bluetoothStatus == nil, selected?.connected == true else { return }
        if !force {
            if controlsVerified, let updatedAt, now.timeIntervalSince(updatedAt) < 30 { return }
            if retryCount >= 3 || retryAt.map({ now < $0 }) == true { return }
        } else { retryCount = 0; retryAt = nil }
        guard let selected else { return }
        if controller == nil { controller = makeController(selected) }
        guard controller != nil else { return }
        perform(writing: false) { _ in }
    }
    private func perform(writing: Bool = true, _ operation: @escaping (HeadphoneController) async throws -> Void) {
        guard !working, bluetoothStatus == nil, selected?.connected == true, let controller,
              let id = selectedID, !writing || controlsVerified else { return }
        let token = generation
        busy = writing; refreshing = !writing; message = nil
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: self?.responseTimeout ?? .seconds(30)) } catch { return }
            guard let self, self.generation == token else { return }
            self.operationTask?.cancel()
            self.generation += 1
            self.readFailed("Headphone controls timed out. Refresh to retry.")
        }
        operationTask = Task {
            do {
                try Task.checkCancellation()
                try await operation(controller)
                try Task.checkCancellation()
                guard generation == token else { return }
                let result = try await controller.read()
                guard generation == token, !Task.isCancelled else { return }
                controls = result; updatedAt = Date(); controlsVerified = true
                cache[id] = (result, updatedAt!)
                retryCount = 0; retryAt = nil; message = nil
                busy = false; refreshing = false
                deadlineTask?.cancel(); deadlineTask = nil; operationTask = nil
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                readFailed(error.localizedDescription)
            }
        }
    }
    private func readFailed(_ error: String) {
        deadlineTask?.cancel(); deadlineTask = nil; operationTask = nil
        busy = false; refreshing = false; controlsVerified = false
        message = error
        controller?.close(); controller = nil
        retryCount += 1
        retryAt = Date().addingTimeInterval(retryCount == 1 ? 2 : 5)
    }
    func setMode(_ mode: Int) { perform { try await $0.setMode(mode) } }
    func setLevel(_ level: Double) { perform { try await $0.setLevel(level) } }
    func setEQ(_ eq: [Double]) { perform { try await $0.setEQ(eq) } }
    func refreshDongleMode(clearErrors: Bool = true) async {
        guard showsDongleControls, !readingDongleMode, !working else { return }
        do {
            dongleFormats = try BTDAudioFormats.available()
            dongleFormatID = try BTDAudioFormats.current().id
            if clearErrors { dongleFormatError = nil }
        } catch { dongleFormats = []; dongleFormatID = ""; dongleFormatError = error.localizedDescription }
        let token = generation
        readingDongleMode = true
        defer { if generation == token { readingDongleMode = false } }
        do {
            let state = try await BTD700.mode().mode
            guard generation == token else { return }
            dongleMode = state
            if clearErrors { dongleModeError = nil }
        } catch { guard generation == token else { return }; dongleMode = nil; dongleModeError = error.localizedDescription }
    }
    func setDongleFormat(_ id: String) {
        guard !working, !readingDongleMode, let format = dongleFormats.first(where: { $0.id == id }) else { return }
        busy = true
        dongleFormatError = nil
        let token = generation
        operationTask = Task {
            guard generation == token, !Task.isCancelled else { return }
            defer { if generation == token { busy = false } }
            do { let result = try await BTDAudioFormats.select(format).id; guard generation == token else { return }; dongleFormatID = result }
            catch {
                guard generation == token else { return }
                dongleFormatID = (try? BTDAudioFormats.current().id) ?? ""
                dongleFormatError = error.localizedDescription
            }
        }
    }
    func setDongleMode(_ mode: BTDMode) {
        guard !working, !readingDongleMode else { return }
        busy = true
        dongleModeError = nil
        let token = generation
        operationTask = Task {
            guard generation == token, !Task.isCancelled else { return }
            defer { if generation == token { busy = false } }
            do { let result = try await BTD700.setMode(mode).mode; guard generation == token else { return }; dongleMode = result }
            catch { guard generation == token else { return }; dongleMode = nil; dongleModeError = error.localizedDescription }
        }
    }
    func selectAudioOutput(_ output: AudioOutput) {
        guard !working else { return }
        busy = true
        audioOutputError = nil
        outputErrorWaitingForHeadphoneID = nil
        let token = generation
        let selected = self.selected
        operationTask = Task {
            guard generation == token, !Task.isCancelled else { return }
            defer { if generation == token { busy = false; scan() } }
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
                            outputErrorWaitingForHeadphoneID = selected.id
                            throw ControlError.message("Connect MOMENTUM 4 directly to this Mac first so its control connection can be preserved.")
                        }
                        let momentum = controller as? MomentumController ?? MomentumController(address: selected.id)
                        try await momentum.connectDongle()
                    }
                }
                guard generation == token else { return }
                try AudioOutputs.select(output.id)
            } catch { guard generation == token else { return }; audioOutputError = error.localizedDescription }
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

#if !SESSION_TEST
@main struct HeadphoneBarApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra("HeadphoneBar", systemImage: "headphones") {
            HeadphonePanel(model: model)
        }.menuBarExtraStyle(.window)
    }
}

#endif

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
        }.buttonStyle(.plain).disabled(model.working)
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
                if model.working { ProgressView().controlSize(.small) }
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
                        Text(selected.kind.rawValue + " · Mac " + (selected.connected ? "connected" : "disconnected"))
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
                Text(model.controlStatus).font(.caption).foregroundStyle(.secondary)
                ControlPanel(controls: controls, model: model).id(model.selectedID).disabled(!model.canEditControls)
            } else if model.working {
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
        .onAppear { model.panelOpened() }
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
                Text("Last read at \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .onChange(of: controls.eq) { old, new in
            if eq == old || eq.count != new.count { eq = new }
        }
        .onChange(of: controls.level) { old, new in
            if level == old, let new { level = new }
        }
    }
}
