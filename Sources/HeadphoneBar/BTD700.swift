import Foundation
import IOKit.hid

// BTD 700 vendor HID protocol: usage page FFA2, report 34, commands 01/02.
enum BTDMode: UInt8, CaseIterable {
    case standard = 0, gaming = 1, broadcast = 2
    var title: String {
        switch self { case .standard: return "Standard"; case .gaming: return "Gaming"; case .broadcast: return "Broadcast" }
    }
}
struct BTDModeState {
    let mode: BTDMode
    let transport: UInt8
}

enum BTD700 {
    private static let queue = DispatchQueue(label: "HeadphoneBar.BTD700")
    static func mode() async throws -> BTDModeState { try await run { try $0.readMode() } }
    static func setMode(_ mode: BTDMode) async throws -> BTDModeState {
        try await run { session in
            let before = try session.readMode()
            if before.mode == mode { return before }
            // Broadcast requires LE Audio; ordinary modes retain the current transport.
            let transport: UInt8 = mode == .broadcast ? 2 : before.mode == .broadcast ? 1 : before.transport
            guard (1...3).contains(transport) else { throw ControlError.message("Connect headphones to the BTD 700 before changing its mode.") }
            _ = try session.request(2, arguments: [mode.rawValue, transport])
            for _ in 0..<8 {
                _ = CFRunLoopRunInMode(.defaultMode, 0.25, false)
                let state = try session.readMode()
                if state.mode == mode { return state }
            }
            throw ControlError.message("BTD 700 did not confirm the requested mode.")
        }
    }
    private static func run(_ operation: @escaping (BTDHIDSession) throws -> BTDModeState) async throws -> BTDModeState {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let session = try BTDHIDSession()
                    defer { session.close() }
                    continuation.resume(returning: try operation(session))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class BTDHIDSession {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var reports: [[UInt8]] = []
    init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x3542, kIOHIDProductIDKey: 0x3001, kIOHIDDeviceUsagePageKey: 0xffa2, kIOHIDDeviceUsageKey: 1] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, devices.count == 1, let found = devices.first else {
            buffer.deallocate()
            throw ControlError.message("Could not find one BTD 700 control interface. Connect only one dongle.")
        }
        device = found
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            buffer.deallocate()
            throw ControlError.message("Cannot open BTD 700 controls (\(result)). Close Sennheiser Dongle Control and retry.")
        }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, { context, result, _, _, _, report, count in
            guard result == kIOReturnSuccess, let context else { return }
            let session = Unmanaged<BTDHIDSession>.fromOpaque(context).takeUnretainedValue()
            if session.reports.count < 64 { session.reports.append(Array(UnsafeBufferPointer(start: report, count: count))) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 512, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }
    func readMode() throws -> BTDModeState {
        let payload = try request(1)
        guard payload.count >= 2, let mode = BTDMode(rawValue: payload[0]), payload[1] <= 3 else {
            throw ControlError.message("BTD 700 returned an unrecognised sound mode.")
        }
        return BTDModeState(mode: mode, transport: payload[1])
    }
    private func send(_ type: UInt8, command: UInt8, arguments: [UInt8]) throws {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<(4 + arguments.count), with: [0x34, type, command, UInt8(arguments.count)] + arguments)
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x34, &bytes, bytes.count)
        guard result == kIOReturnSuccess else { throw ControlError.message("BTD 700 USB command failed (\(result)).") }
    }
    func request(_ command: UInt8, arguments: [UInt8] = []) throws -> [UInt8] {
        reports.removeAll()
        try send(0xfe, command: command, arguments: arguments)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.02, false)
            while !reports.isEmpty {
                let packet = reports.removeFirst()
                guard packet.count >= 4, packet[0] == 0x34, Int(packet[3]) + 4 <= packet.count else { continue }
                if packet[1] == 0xfc { try send(0xfd, command: packet[2], arguments: []); continue }
                if packet[1] == 0xff && packet[2] == command { return Array(packet[4..<(4 + Int(packet[3]))]) }
            }
        }
        throw ControlError.message("BTD 700 did not answer. Close Sennheiser Dongle Control and retry.")
    }
}
