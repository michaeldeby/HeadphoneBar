import CoreBluetooth
import OSLog
import MomentumCore

@MainActor final class MomentumBLEDiagnostic: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let log = Logger(subsystem: "local.headphonebar.app", category: "MomentumBLE")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "FCFE")])
        log.notice("Already-connected Sennheiser BLE devices: \(connected.count)")
        if let match = connected.first(where: { $0.name?.uppercased().contains("MOMENTUM 4") == true }) {
            attach(match)
            return
        }
        central.scanForPeripherals(withServices: nil)
        log.notice("Scanning for MOMENTUM BLE control service")
        Task {
            try? await Task.sleep(for: .seconds(60))
            central.stopScan()
            if peripheral == nil { log.notice("No MOMENTUM BLE advertisement found") }
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.uppercased().contains("MOMENTUM 4"), self.peripheral == nil else { return }
        log.notice("Found MOMENTUM BLE; advertised services: \(String(describing: advertisementData[CBAdvertisementDataServiceUUIDsKey]), privacy: .public)")
        attach(peripheral)
    }
    private func attach(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        central.stopScan(); peripheral.delegate = self; central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { log.notice("MOMENTUM BLE connected"); peripheral.discoverServices(nil) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { log.error("MOMENTUM BLE connect failed: \(String(describing: error), privacy: .public)") }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            log.notice("BLE service: \(service.uuid.uuidString, privacy: .public)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            log.notice("BLE characteristic: \(characteristic.uuid.uuidString, privacy: .public) properties: \(characteristic.properties.rawValue)")
            if characteristic.uuid == CBUUID(string: "2A19") { peripheral.readValue(for: characteristic) }
            if characteristic.uuid == CBUUID(string: "6333133B-23C1-11E5-B696-FEFF819CDC9F") { command = characteristic }
            if characteristic.uuid == CBUUID(string: "6333133C-23C1-11E5-B696-FEFF819CDC9F") { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying, let command else {
            log.error("BLE notification setup failed: \(String(describing: error), privacy: .public)")
            return
        }
        log.notice("Sending read-only GAIA battery query over Sennheiser BLE")
        peripheral.writeValue(GaiaPacket(vendorID: MomentumCommands.vendorID, commandID: MomentumCommands.battery).data, for: command, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        log.notice("BLE query write result: \(String(describing: error), privacy: .public)")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let hex = (characteristic.value ?? Data()).map { String(format: "%02X", $0) }.joined(separator: " ")
        log.notice("BLE query response \(characteristic.uuid.uuidString, privacy: .public): \(hex, privacy: .public); error: \(String(describing: error), privacy: .public)")
    }
}
