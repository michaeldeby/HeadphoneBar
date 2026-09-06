import MomentumCore
import Foundation
import HeadphoneProtocol

func expect(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    let result = try value()
    precondition(result, "Assertion failed at \(file):\(line)")
}
func expectWireError<T>(_ body: () throws -> T) {
    do { _ = try body(); fatalError("Expected malformed packet to be rejected") }
    catch is WireError {} catch { fatalError("Unexpected error: \(error)") }
}


func sonyKnownWireFrame() throws {
    let frame = SonyFrame(sequence: 0, payload: [0, 0])
    expect(Array(frame.encoded()) == [0x3e, 12, 0, 0, 0, 0, 2, 0, 0, 14, 0x3c])
}
func sonyFragmentedAndCoalescedFrames() throws {
    let first = SonyFrame(sequence: 1, payload: [0x67, 0x17, 0x3c, 0x3d, 0x3e])
    let second = SonyFrame(type: 1, sequence: 0, payload: [])
    let bytes = first.encoded() + second.encoded()
    for split in 0...bytes.count {
        var stream = SonyStream()
        let received = try stream.feed(bytes.prefix(split)) + stream.feed(bytes.dropFirst(split))
        expect(received == [first, second])
    }
}
func sonyRejectsCorruptionAndRecovers() throws {
    var stream = SonyStream()
    expectWireError { try stream.feed(Data([0x3e, 12, 0, 0, 0, 0, 0, 99, 0x3c])) }
    let valid = SonyFrame(sequence: 0, payload: [1, 2])
    try expect(try stream.feed(valid.encoded()) == [valid])
    expectWireError { try SonyFrame.decode([12, 0, 0, 0, 0, 0, 0x3d]) }
}
func boseKnownCommandAndSegmentation() throws {
    let query = BosePacket(block: 0x1f, function: 3)
    try expect(try query.segments() == [Data([0, 0x1f, 3, 1, 0])])
    let packet = BosePacket(block: 0x1f, function: 6, operation: 3, payload: Array(0...47))
    let segments = try packet.segments()
    expect(segments.map { $0.first! } == [0x20, 0x21, 0x22])
    var stream = BoseStream()
    try expect(try stream.feed(segments[0]) == nil)
    try expect(try stream.feed(segments[1]) == nil)
    try expect(try stream.feed(segments[2]) == packet)
}
func boseRejectsOutOfOrderAndBadLength() throws {
    var stream = BoseStream()
    expectWireError { try stream.feed(Data([0x11, 0, 0])) }
    expectWireError { try stream.feed(Data([0, 2, 2, 3, 4, 100])) }
    let packet = BosePacket(block: 2, function: 2, operation: 3, payload: [80, 255, 255, 0])
    try expect(try stream.feed(packet.segments()[0]) == packet)
}
func conservativeModelDetection() {
    expect(HeadphoneKind.detect("MOMENTUM 4") == .momentum4)
    expect(HeadphoneKind.detect("MOMENTUM 3") == .sennheiserAudio)
    expect(HeadphoneKind.detect("WH-1000XM5") == .sony)
    expect(HeadphoneKind.detect("Bose QC Ultra") == .bose)
    expect(HeadphoneKind.detect("Magic Mouse") == .unknown)
    expect(HeadphoneKind.detect("Michael’s headphones") == .unknown)
    for name in ["MOMENTUM 5", "HDB 630", "ACCENTUM Plus", "MOMENTUM True Wireless 4", "CX 400BT", "HD 450BT", "HD 4.50BTNC", "PXC 550-II", "SPORT True Wireless", "IE 80S BT", "Sennheiser headphones"] {
        expect(HeadphoneKind.detect(name) == .sennheiserAudio)
        expect(HeadphoneKind.detect(name).supportsBTD700Audio)
    }
    expect(HeadphoneKind.momentum4.supportsBTD700Audio)
    for name in ["WH-1000XM5", "Bose QC Ultra", "AirPods Pro", "HD 600", "Magic Mouse"] {
        expect(!HeadphoneKind.detect(name).supportsBTD700Audio)
    }
}

func dongleSwitchPreservesMac() throws {
    let mac = MomentumDevice(index: 2, priority: 0, isConnected: true, name: "Mac")
    let phone = MomentumDevice(index: 0, priority: 0, isConnected: true, name: "Phone")
    let dongle = MomentumDevice(index: 1, priority: 0, isConnected: false, name: "BTD 700")
    let plan = try SwitchPlanner.plan(devices: [phone, dongle, mac], ownIndex: 2, targetIndex: 1, maxConnections: 2)
    expect(plan.disconnectIndices == [0])
    expect(plan.connectIndex == 1)
    let connectedDongle = MomentumDevice(index: 1, priority: 0, isConnected: true, name: "BTD 700")
    let existing = try SwitchPlanner.plan(devices: [mac, connectedDongle], ownIndex: 2, targetIndex: 1, maxConnections: 2)
    expect(existing.disconnectIndices.isEmpty && existing.connectIndex == nil)
    let disconnectedMac = MomentumDevice(index: 2, priority: 0, isConnected: false, name: "Mac")
    do {
        _ = try SwitchPlanner.plan(devices: [disconnectedMac, phone, dongle], ownIndex: 2, targetIndex: 1, maxConnections: 2)
        preconditionFailure("Switch must require the Mac control connection")
    } catch SwitchPlanningError.ownDeviceNotConnected {}
}

@main enum ProtocolTestRunner {
    static func main() throws {
        try sonyKnownWireFrame()
        try sonyFragmentedAndCoalescedFrames()
        try sonyRejectsCorruptionAndRecovers()
        try boseKnownCommandAndSegmentation()
        try boseRejectsOutOfOrderAndBadLength()
        conservativeModelDetection()
        try dongleSwitchPreservesMac()
        print("Passed 7 protocol tests (including all Sony packet split positions).")
    }
}
