import Foundation
import HeadphoneProtocol

enum ControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct Headphone: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: HeadphoneKind
    let connected: Bool
}
struct SoundMode: Identifiable, Equatable {
    let id: Int
    let name: String
}
struct Controls {
    var battery: Int?
    var modes: [SoundMode] = []
    var mode: Int?
    var level: Double?
    var levelRange: ClosedRange<Double> = 0...20
    var levelLabel = "Ambient sound"
    var eq: [Double] = []
    var eqActive = true
    var eqLabels: [String] = []
    var eqRange: ClosedRange<Double> = -10...10
    var note: String?
}
@MainActor protocol HeadphoneController: AnyObject {
    func read() async throws -> Controls
    func setMode(_ mode: Int) async throws
    func setLevel(_ level: Double) async throws
    func setEQ(_ values: [Double]) async throws
    func close()
}
