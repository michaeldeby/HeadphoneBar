import Foundation
import IOBluetooth
import HeadphoneProtocol

@MainActor final class SonyController: NSObject, HeadphoneController, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    static let v1 = "96CC203E-5068-46AD-B32D-E316F5E069BA"
    static let v2 = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"
    private let address: String
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var stream = SonyStream()
    private var inbox: [SonyFrame] = []
    private var sequence: UInt8 = 0
    private var version2 = false
    private var initialized = false
    private var failure: String?
    private var controls = Controls()
    private var voice: UInt8 = 0
    private var sdpDone = false
    init(address: String) { self.address = address }

    static func uuid(_ string: String) -> IOBluetoothSDPUUID {
        var bytes = UUID(uuidString: string)!.uuid
        return withUnsafePointer(to: &bytes) { IOBluetoothSDPUUID(bytes: $0, length: 16) }
    }
    private func connect() async throws {
        if channel?.isOpen() == true { return }
        close(); failure = nil; stream = SonyStream(); sequence = 0
        guard let device = IOBluetoothDevice(addressString: address), device.isConnected() else {
            throw ControlError.message("Connect these headphones in macOS Bluetooth settings first.")
        }
        self.device = device
        sdpDone = false
        let status = device.performSDPQuery(self)
        guard status == kIOReturnSuccess else { throw ControlError.message("Could not discover Sony controls (\(status)).") }
        let deadline = Date().addingTimeInterval(8)
        while !sdpDone && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard sdpDone else { throw ControlError.message("Sony service discovery timed out.") }
        let old = device.getServiceRecord(for: Self.uuid(Self.v1))
        let newer = device.getServiceRecord(for: Self.uuid(Self.v2))
        guard let record = old ?? newer else { throw ControlError.message("This device does not expose a supported Sony control service.") }
        version2 = old == nil
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { throw ControlError.message("Sony control channel is unavailable.") }
        let opened = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        guard opened == kIOReturnSuccess else { throw ControlError.message("Could not open Sony controls (\(opened)).") }
        let openDeadline = Date().addingTimeInterval(8)
        while channel?.isOpen() != true && failure == nil && Date() < openDeadline { try await Task.sleep(for: .milliseconds(50)) }
        guard channel?.isOpen() == true else { close(); throw ControlError.message(failure ?? "Sony connection timed out.") }
    }
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { sdpDone = true }
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error != kIOReturnSuccess { failure = "Sony connection failed (\(error))." }
    }
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        failure = "Headphones disconnected. Reconnect them and refresh."; initialized = false
    }
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard let pointer, length > 0 else { return }
        do {
            for frame in try stream.feed(Data(bytes: pointer, count: length)) {
                if frame.type == 12 {
                    try sendFrame(SonyFrame(type: 1, sequence: 1 &- frame.sequence, payload: []))
                }
                if inbox.count < 100 { inbox.append(frame) }
            }
        } catch { failure = "Invalid Sony response: \(error.localizedDescription)" }
    }
    private func sendFrame(_ frame: SonyFrame) throws {
        guard let channel, channel.isOpen() else { throw ControlError.message("Sony control connection closed.") }
        var data = frame.encoded()
        let count = data.count
        let status = data.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16(count)) }
        guard status == kIOReturnSuccess else { throw ControlError.message("Sony command could not be sent (\(status)).") }
    }
    private func request(_ payload: [UInt8], reply: [UInt8]? = nil) async throws -> [UInt8] {
        inbox = []
        let sentSequence = sequence
        try sendFrame(SonyFrame(sequence: sentSequence, payload: payload))
        sequence = 1 &- sentSequence
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try Task.checkCancellation()
            if let failure { throw ControlError.message(failure) }
            if let index = inbox.firstIndex(where: { frame in
                if let reply { return frame.type == 12 && frame.payload.starts(with: reply) }
                return frame.type == 1 && frame.sequence == (1 &- sentSequence)
            }) { return inbox.remove(at: index).payload }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw ControlError.message("Sony did not answer. Close other headphone control apps and try Refresh.")
    }
    func read() async throws -> Controls {
        try await connect()
        controls.note = nil
        controls.modes = [.init(id: 0, name: "Off"), .init(id: 1, name: "Noise cancelling"), .init(id: 2, name: "Ambient")]
        if version2 {
            if !initialized { _ = try await request([0, 0], reply: [1]); initialized = true }
            let mode = try await request([0x66, 0x17], reply: [0x67, 0x17])
            guard mode.count >= 7, mode[3] <= 1, mode[4] <= 1, mode[6] <= 20 else { throw ControlError.message("Unsupported Sony noise control response.") }
            controls.mode = mode[3] == 0 ? 0 : (mode[4] == 0 ? 1 : 2)
            controls.level = Double(mode[6]); controls.levelRange = 1...20; voice = mode[5]
            if let battery = try? await request([0x22, 0], reply: [0x23, 0]), battery.count >= 4, battery[2] <= 100 { controls.battery = Int(battery[2]) } else { controls.battery = nil }
            if let eq = try? await request([0x56, 0], reply: [0x57, 0]), eq.count >= 10, eq[3] == 6, eq[4..<10].allSatisfy({ $0 <= 20 }) {
                controls.eq = eq[4..<10].map { Double(Int($0) - 10) }
                controls.eqLabels = ["Bass", "400 Hz", "1 kHz", "2.5 kHz", "6.3 kHz", "16 kHz"]
            } else { controls.eq = []; controls.eqLabels = [] }
        } else {
            // Never send v2 battery opcode 0x22 to legacy devices: it means power off on v1.
            _ = try await request([0x66, 2], reply: [0x67, 2])
            controls.mode = nil; controls.level = nil; controls.eq = []; controls.battery = nil
            controls.note = "Legacy Sony: mode commands are acknowledged, but current mode and EQ readback are unavailable."
        }
        return controls
    }
    func setMode(_ mode: Int) async throws {
        guard (0...2).contains(mode), channel?.isOpen() == true else { throw ControlError.message("Refresh the headphone connection first.") }
        if version2 {
            _ = try await request([0x68, 0x17, 1, mode == 0 ? 0 : 1, mode == 2 ? 1 : 0, voice, UInt8(max(1, controls.level ?? 10))])
            let result = try await read()
            guard result.mode == mode else { throw ControlError.message("Headphones did not confirm the requested mode.") }
        } else {
            let level: UInt8 = mode == 2 ? 19 : 0
            _ = try await request([0x68, 2, mode == 0 ? 0 : 17, 1, mode == 1 ? 2 : 0, 1, 0, mode == 0 ? 255 : level])
        }
    }
    func setLevel(_ level: Double) async throws {
        guard version2, (1...20).contains(level) else { throw ControlError.message("Ambient adjustment is unavailable.") }
        _ = try await request([0x68, 0x17, 1, 1, 1, voice, UInt8(level)])
        let result = try await read()
        guard result.mode == 2, result.level == level else { throw ControlError.message("Headphones did not confirm the ambient level.") }
    }
    func setEQ(_ values: [Double]) async throws {
        guard version2, values.count == 6, values.allSatisfy({ (-10...10).contains($0) }) else { throw ControlError.message("Unsupported EQ values.") }
        _ = try await request([0x58, 0, 0xa0, 6] + values.map { UInt8(Int($0) + 10) })
        let result = try await read()
        guard result.eq == values else { throw ControlError.message("Headphones did not confirm the EQ adjustment.") }
    }
    func close() {
        channel?.setDelegate(nil); channel?.close(); channel = nil; initialized = false; inbox = []
    }
}
