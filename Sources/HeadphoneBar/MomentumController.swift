import Foundation
import MomentumCore
import MomentumBluetooth
import OSLog

@MainActor final class MomentumController: HeadphoneController {
    private let client: MomentumHeadsetClient
    private let customLevelKey: String
    private var last: MomentumControlsSnapshot? {
        didSet {
            guard let last, last.ancEnabled, !last.ancModes.adaptiveEnabled,
                  last.transparencyLevel <= 100 else { return }
            UserDefaults.standard.set(Int(last.transparencyLevel), forKey: customLevelKey)
        }
    }
    private var rememberedCustomLevel: Int {
        guard let value = UserDefaults.standard.object(forKey: customLevelKey) as? Int,
              (0...100).contains(value) else { return 50 }
        return value
    }
    init(address: String) {
        customLevelKey = "momentum.customLevel." + address.lowercased().filter(\.isHexDigit)
        client = MomentumHeadsetClient(headsetAddress: address)
    }
    func read() async throws -> Controls {
        let state = try await client.controlsSnapshot(); last = state
        var controls = Controls()
        if let snapshot = try? await client.snapshot() { controls.battery = snapshot.batteryPercentage.map(Int.init) }
        controls.modes = [.init(id: 0, name: "Off"), .init(id: 1, name: "Adaptive"), .init(id: 2, name: "Custom")]
        controls.mode = !state.ancEnabled ? 0 : state.ancModes.adaptiveEnabled ? 1 : 2
        controls.level = Double(state.transparencyLevel); controls.levelRange = 0...100
        controls.levelLabel = "ANC → Transparency"
        controls.eq = state.eqBands.map(\.gainDB)
        controls.eqActive = state.soundMode == .equalizer
        Logger(subsystem: "local.headphonebar.app", category: "Equalizer").notice("Headphone EQ readback: mode=\(state.soundMode.displayName, privacy: .public), gains=\(String(describing: controls.eq), privacy: .public)")
        controls.eqLabels = MomentumControlPresentation.eqBandLabels(count: state.eqBands.count)
        controls.eqRange = state.eqConfig.minimumGainDB...state.eqConfig.maximumGainDB
        if state.eqConfig.bandCount == 3 { controls.note = "Your headphones currently report 3 EQ bands. Check firmware updates in Sennheiser Smart Control Plus for 5-band EQ support." }
        return controls
    }
    func setMode(_ mode: Int) async throws {
        switch mode {
        case 0: last = try await client.setAncEnabled(false)
        case 1: last = try await client.setAdaptiveEnabled(true)
        case 2: last = try await client.setCustomMode(restoringLevel: rememberedCustomLevel)
        default: throw ControlError.message("Unknown mode.")
        }
    }
    func setLevel(_ level: Double) async throws { last = try await client.setCustomMode(restoringLevel: Int(level)) }
    func setEQ(_ values: [Double]) async throws {
        last = try await client.setEqBands(values)
        let confirmed = try await client.setAudioMode(.equalizer)
        last = confirmed
        let actual = confirmed.eqBands.map(\.gainDB)
        guard confirmed.soundMode == .equalizer, actual.count == values.count,
              zip(actual, values).allSatisfy({ abs($0 - $1) < 0.051 }) else {
            throw ControlError.message("The headphones did not confirm the requested EQ settings. Refresh and try again.")
        }
        Logger(subsystem: "local.headphonebar.app", category: "Equalizer").notice("EQ applied and verified: \(String(describing: actual), privacy: .public)")
    }
    func connectDongle() async throws {
        let snapshot = try await client.snapshot()
        let dongles = snapshot.devices.filter {
            $0.index != snapshot.ownIndex && $0.name.uppercased().replacingOccurrences(of: " ", with: "").contains("BTD700")
        }
        guard dongles.count == 1, let dongle = dongles.first else {
            throw ControlError.message(dongles.isEmpty
                ? "Pair the BTD 700 with your headphones first. Keep this Mac connected for ANC and EQ."
                : "Multiple paired BTD 700 dongles were found. Cannot choose one safely.")
        }
        let result = try await client.switchPeer(to: dongle.index, expectedName: dongle.name)
        guard result.devices.contains(where: { $0.index == result.ownIndex && $0.isConnected }),
              result.devices.contains(where: { $0.index == dongle.index && $0.name == dongle.name && $0.isConnected }) else {
            throw ControlError.message("Could not confirm both the Mac and BTD 700 connections. Audio output was not changed.")
        }
    }
    func close() {} // The upstream client closes its RFCOMM channel after each operation.
}
