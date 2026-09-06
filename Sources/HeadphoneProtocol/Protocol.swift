import Foundation

public enum WireError: Error { case malformed, oversized }

public enum HeadphoneKind: String, Sendable {
    case momentum4 = "Sennheiser", sennheiserAudio = "Sennheiser audio", sony = "Sony", bose = "Bose", unknown = "Other"
    public var supportsBTD700Audio: Bool { self == .momentum4 || self == .sennheiserAudio }
    public static func detect(_ name: String) -> Self {
        let n = name.uppercased()
        if n.contains("MOMENTUM 4") { return .momentum4 }
        // These are Sennheiser Bluetooth product families. Audio support does not imply GAIA control support.
        if n.contains("SENNHEISER") || n.range(of: #"\b(MOMENTUM|ACCENTUM|HDB\s*630|PXC\s*\d+|CX(?:\s*\d+(?:BT)?)?|HD\s*\d+(?:\.\d+)?\s*(?:BT(?:NC)?|SE)|MM\s*\d+|SPORT TRUE WIRELESS|IE\s*80S\s*BT)\b"#, options: .regularExpression) != nil {
            return .sennheiserAudio
        }
        if ["WH-", "WF-", "WI-", "MDR-", "LINKBUDS"].contains(where: { n.contains($0) }) { return .sony }
        if n.contains("BOSE") || n.contains("QUIETCOMFORT") || n.contains("QC ULTRA") { return .bose }
        return .unknown
    }
}

public struct SonyFrame: Equatable, Sendable {
    public let type: UInt8
    public let sequence: UInt8
    public let payload: [UInt8]
    public init(type: UInt8 = 12, sequence: UInt8, payload: [UInt8]) {
        self.type = type; self.sequence = sequence; self.payload = payload
    }
    public func encoded() -> Data {
        let count = UInt32(payload.count)
        var bytes = [type, sequence, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)] + payload
        bytes.append(bytes.reduce(0, &+))
        return Data([0x3e] + bytes.flatMap { (0x3c...0x3e).contains($0) ? [0x3d, $0 &- 0x10] : [$0] } + [0x3c])
    }
    public static func decode(_ escaped: [UInt8]) throws -> Self {
        var bytes: [UInt8] = []; var index = 0
        while index < escaped.count {
            let b = escaped[index]; index += 1
            if b == 0x3d {
                guard index < escaped.count, (0x2c...0x2e).contains(escaped[index]) else { throw WireError.malformed }
                bytes.append(escaped[index] + 0x10); index += 1
            } else { bytes.append(b) }
        }
        guard bytes.count >= 7 else { throw WireError.malformed }
        let count = bytes[2..<6].reduce(0) { ($0 << 8) | Int($1) }
        guard count <= 8192, bytes.count == count + 7, bytes.dropLast().reduce(UInt8(0), &+) == bytes.last else { throw WireError.malformed }
        return Self(type: bytes[0], sequence: bytes[1], payload: Array(bytes[6..<(6 + count)]))
    }
}

public struct SonyStream {
    private var buffer: [UInt8]? = nil
    public init() {}
    public mutating func feed(_ data: Data) throws -> [SonyFrame] {
        var frames: [SonyFrame] = []
        for byte in data {
            if byte == 0x3e { buffer = []; continue }
            guard buffer != nil else { continue }
            if byte == 0x3c {
                let packet = buffer!; buffer = nil
                frames.append(try SonyFrame.decode(packet))
            } else {
                buffer!.append(byte)
                if buffer!.count > 16384 { buffer = nil; throw WireError.oversized }
            }
        }
        return frames
    }
}

public struct BosePacket: Equatable, Sendable {
    public let block: UInt8
    public let function: UInt8
    public let operation: UInt8
    public let payload: [UInt8]
    public init(block: UInt8, function: UInt8, operation: UInt8 = 1, payload: [UInt8] = []) {
        self.block = block; self.function = function; self.operation = operation; self.payload = payload
    }
    public func segments() throws -> [Data] {
        guard payload.count <= 255 else { throw WireError.oversized }
        let bytes = [block, function, operation, UInt8(payload.count)] + payload
        let count = (bytes.count + 18) / 19
        return (0..<count).map { index in
            let header = UInt8(((count - 1) << 4) | index)
            let end = min((index + 1) * 19, bytes.count)
            let payload = Array(bytes[(index * 19)..<end])
            return Data([header] + payload)
        }
    }
    public static func decode(_ bytes: [UInt8]) throws -> Self {
        guard bytes.count >= 4, bytes.count == Int(bytes[3]) + 4 else { throw WireError.malformed }
        return Self(block: bytes[0], function: bytes[1], operation: bytes[2] & 15, payload: Array(bytes.dropFirst(4)))
    }
}

public struct BoseStream {
    private var buffer: [UInt8] = []
    private var next = 0
    private var last = -1
    public init() {}
    public mutating func feed(_ data: Data) throws -> BosePacket? {
        guard let header = data.first, data.count > 1 else { throw WireError.malformed }
        let index = Int(header & 15), maximum = Int(header >> 4)
        if index == 0 { buffer = []; next = 0; last = maximum }
        guard index == next, maximum == last, index <= maximum else {
            buffer = []; next = 0; last = -1; throw WireError.malformed
        }
        buffer += data.dropFirst(); next += 1
        guard buffer.count <= 259 else { buffer = []; last = -1; throw WireError.oversized }
        if index == maximum {
            let packet = buffer; buffer = []; next = 0; last = -1
            return try BosePacket.decode(packet)
        }
        return nil
    }
}
