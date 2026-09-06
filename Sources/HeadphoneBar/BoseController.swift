import Foundation
import CoreBluetooth
import HeadphoneProtocol

@MainActor final class BoseController: NSObject, HeadphoneController, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let service = CBUUID(string: "FEBE")
    static let secure = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")
    static let plain = CBUUID(string: "D417C028-9818-4354-99D1-2AC09D074591")
    private let name: String
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var candidates: [UUID: CBPeripheral] = [:]
    private var failure: String?
    private var stream = BoseStream()
    private var inbox: [BosePacket] = []
    private var controls = Controls()
    init(name: String) { self.name = name; super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: break
        case .unauthorized: failure = "Allow HeadphoneBar in System Settings → Privacy & Security → Bluetooth."
        case .poweredOff: failure = "Turn Bluetooth on in System Settings."
        case .unsupported: failure = "Bluetooth Low Energy is unavailable on this Mac."
        default: break
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // BLE identifiers cannot be matched to Classic MAC addresses. Require the selected device's exact name.
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if peripheral.name == name || advertised == name { candidates[peripheral.identifier] = peripheral }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self; peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { failure = error?.localizedDescription ?? "Bose connection failed." }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { characteristic = nil; failure = "Bose disconnected. Reconnect and refresh." }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { failure = "Bose control service unavailable."; return }
        peripheral.discoverCharacteristics([Self.secure, Self.plain], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let available = service.characteristics ?? []
        let usable = available.filter {
            $0.properties.contains(.notify) && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse))
        }
        guard error == nil, let selected = usable.first(where: { $0.uuid == Self.secure }) ?? usable.first(where: { $0.uuid == Self.plain }) else { failure = "Bose control characteristic unavailable."; return }
        characteristic = selected; peripheral.setNotifyValue(true, for: selected)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error.localizedDescription }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error.localizedDescription }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error.localizedDescription; return }
        guard let data = characteristic.value else { return }
        do { if let packet = try stream.feed(data), inbox.count < 100 { inbox.append(packet) } }
        catch { failure = "Malformed Bose control response." }
    }
    private func connect() async throws {
        if peripheral?.state == .connected, characteristic?.isNotifying == true { return }
        failure = nil
        let stateDeadline = Date().addingTimeInterval(4)
        while central.state == .unknown || central.state == .resetting {
            guard Date() < stateDeadline else { throw ControlError.message("Bluetooth initialization timed out.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard central.state == .poweredOn else { centralManagerDidUpdateState(central); throw ControlError.message(failure ?? "Bluetooth unavailable.") }
        candidates = [:]
        for candidate in central.retrieveConnectedPeripherals(withServices: [Self.service]) where candidate.name == name { candidates[candidate.identifier] = candidate }
        central.scanForPeripherals(withServices: [Self.service])
        do { try await Task.sleep(for: .seconds(3)) } catch { central.stopScan(); throw error }
        central.stopScan()
        guard candidates.count == 1, let candidate = candidates.values.first else {
            throw ControlError.message(candidates.count > 1 ? "Multiple Bose headphones have the same name. Rename one in the Bose app before connecting." : "Bose BLE controls not found. Close the Bose phone app, keep headphones nearby, and refresh. Renamed devices must advertise the same name as macOS.")
        }
        peripheral = candidate; characteristic = nil; stream = BoseStream(); candidate.delegate = self
        central.connect(candidate)
        let deadline = Date().addingTimeInterval(10)
        while characteristic?.isNotifying != true && failure == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard characteristic?.isNotifying == true, failure == nil else { central.cancelPeripheralConnection(candidate); throw ControlError.message(failure ?? "Bose connection timed out.") }
    }
    private func request(_ packet: BosePacket) async throws -> [UInt8] {
        guard let peripheral, let characteristic, peripheral.state == .connected else { throw ControlError.message("Bose control connection is closed.") }
        inbox = []
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        for data in try packet.segments() {
            let deadline = Date().addingTimeInterval(3)
            while type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                guard Date() < deadline else { throw ControlError.message("Bose Bluetooth write queue timed out.") }
                try await Task.sleep(for: .milliseconds(30))
            }
            peripheral.writeValue(data, for: characteristic, type: type)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try Task.checkCancellation()
            if let failure { throw ControlError.message(failure) }
            if let index = inbox.firstIndex(where: { $0.block == packet.block && $0.function == packet.function && [3, 4, 6].contains($0.operation) }) {
                let response = inbox.remove(at: index)
                guard response.operation != 4 else { throw ControlError.message("Bose rejected this control (code \(response.payload.first.map(String.init) ?? "unknown")).") }
                return response.payload
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw ControlError.message("Bose did not answer the control request.")
    }
    func read() async throws -> Controls {
        try await connect()
        let capabilities = try await request(.init(block: 0x1f, function: 2))
        guard capabilities.count >= 6, Int(capabilities[0]) + Int(capabilities[1]) <= 16 else { throw ControlError.message("Unsupported Bose audio mode capabilities.") }
        var modes: [SoundMode] = []
        for index in 0..<(Int(capabilities[0]) + Int(capabilities[1])) {
            if let config = try? await request(.init(block: 0x1f, function: 6, payload: [UInt8(index)])), config.count >= 38, config[0] == index {
                let customName = String(bytes: config[6..<38].prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
                let labels: [UInt8: String] = [1: "Quiet", 2: "Aware", 34: "Immersion", 35: "Stereo"]
                modes.append(.init(id: index, name: customName.isEmpty ? labels[config[2]] ?? "Mode \(index + 1)" : customName))
            }
        }
        let current = try await request(.init(block: 0x1f, function: 3))
        guard let mode = current.first, modes.contains(where: { $0.id == Int(mode) }) else { throw ControlError.message("Could not read Bose audio modes.") }
        controls.modes = modes; controls.mode = Int(mode)
        if let battery = try? await request(.init(block: 2, function: 2)), battery.count >= 4, battery[0] <= 100 { controls.battery = Int(battery[0]) } else { controls.battery = nil }
        controls.note = "Bose audio modes are read from your headphones, including custom modes."
        return controls
    }
    func setMode(_ mode: Int) async throws {
        guard controls.modes.contains(where: { $0.id == mode }) else { throw ControlError.message("Unknown Bose mode.") }
        _ = try await request(.init(block: 0x1f, function: 3, operation: 5, payload: [UInt8(mode), 0]))
        let result = try await request(.init(block: 0x1f, function: 3))
        guard result.first == UInt8(mode) else { throw ControlError.message("Bose did not confirm the requested mode.") }
    }
    func setLevel(_ level: Double) async throws { throw ControlError.message("Use a Bose audio mode to adjust noise cancellation.") }
    func setEQ(_ values: [Double]) async throws { throw ControlError.message("Bose EQ is not implemented in this version.") }
    func close() {
        central.stopScan()
        if let peripheral { peripheral.delegate = nil; central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; characteristic = nil
    }
}
