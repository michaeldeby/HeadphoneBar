import Foundation
import CoreAudio
func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { precondition(value(), file: file, line: line) }
func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { precondition(!value(), file: file, line: line) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) { precondition(left == right, "\(left) != \(right)") }
func XCTFail(_ message: String) { fatalError(message) }

@MainActor final class FakeController: HeadphoneController {
    var reads = 0
    var writes = 0
    var closed = false
    var mode = 0
    var level: Double = 50
    var pending: [CheckedContinuation<Controls, Error>] = []
    func read() async throws -> Controls {
        reads += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ battery: Int = 50) {
        var controls = Controls(); controls.battery = battery
        controls.mode = mode; controls.level = level; controls.levelRange = 0...100
        controls.modes = [.init(id: 0, name: "Off"), .init(id: 1, name: "Adaptive"), .init(id: 2, name: "Custom")]
        pending.removeFirst().resume(returning: controls)
    }
    func fail() { pending.removeFirst().resume(throwing: ControlError.message("Disconnected")) }
    func setMode(_ mode: Int) async throws { writes += 1; self.mode = mode }
    func setLevel(_ level: Double) async throws { writes += 1; self.level = level; mode = 2 }
    func setEQ(_ eq: [Double]) async throws { writes += 1 }
    func close() { closed = true }
}

@main final class SessionTests {
    @MainActor static func main() async {
        let tests = SessionTests()
        await tests.testFreshCacheSkipsRepeatedPanelReadsAndStaleCacheRemainsVisible()
        await tests.testReconnectSelectedHeadsetReadsAgainAndKeepsDisabledCache()
        await tests.testLateResponseFromPreviousConnectionCannotOverwriteReconnect()
        await tests.testSwitchDuringReadRejectsOldDeviceResult()
        await tests.testRetriesStopAfterThreeFailuresAndManualRefreshResumes()
        await tests.testForgetPairingEvictsCachedSettings()
        await tests.testSleepInvalidatesPendingRead()
        await tests.testDeadlineReleasesBusyStateAndRejectsLateResponse()
        await tests.testFailedRefreshRetainsCacheAndRecovers()
        try! tests.testRemoteCapabilities()
        await tests.testRemoteWaitsForConfirmation()
        await tests.testRemoteRejectsMismatchedReadback()
        await tests.testRemoteRejectsDisconnectedHeadphone()
        tests.testAudioDiscoveryAndIconState()
        print("Passed 14 app session/cache/command regression tests.")
    }
    @MainActor private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Async operation did not settle")
    }
    @MainActor private func headphone(_ id: String = "A", connected: Bool = true) -> Headphone {
        Headphone(id: id, name: "MOMENTUM 4", kind: .momentum4, connected: connected)
    }
    @MainActor func testFreshCacheSkipsRepeatedPanelReadsAndStaleCacheRemainsVisible() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()])
        await settle { fake.reads == 1 }; fake.finish()
        await settle { model.controlsVerified }
        for _ in 0..<5 { model.refresh(force: false) }
        XCTAssertEqual(fake.reads, 1)
        model.refresh(force: false, now: Date().addingTimeInterval(31))
        await settle { fake.reads == 2 }
        XCTAssertEqual(model.controls?.battery, 50)
        XCTAssertTrue(model.refreshing)
        fake.finish(60)
        await settle { !model.refreshing }
        XCTAssertEqual(model.controls?.battery, 60)
    }
    @MainActor func testReconnectSelectedHeadsetReadsAgainAndKeepsDisabledCache() async {
        let first = FakeController(); let second = FakeController()
        var controllers = [first, second]
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in controllers.removeFirst() })
        model.updateHeadphones([headphone()])
        await settle { first.reads == 1 }; first.finish()
        await settle { model.controlsVerified }
        model.updateHeadphones([headphone(connected: false)])
        XCTAssertFalse(model.canEditControls)
        XCTAssertEqual(model.controls?.battery, 50)
        XCTAssertTrue(first.closed)
        model.setMode(1); XCTAssertEqual(first.writes, 0)
        model.updateHeadphones([headphone()])
        await settle { second.reads == 1 }; second.finish(70)
        await settle { model.canEditControls }
        XCTAssertEqual(model.controls?.battery, 70)
    }
    @MainActor func testLateResponseFromPreviousConnectionCannotOverwriteReconnect() async {
        let first = FakeController(); let second = FakeController()
        var controllers = [first, second]
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in controllers.removeFirst() })
        model.updateHeadphones([headphone()]); await settle { first.reads == 1 }
        model.updateHeadphones([headphone(connected: false)])
        model.updateHeadphones([headphone()]); await settle { second.reads == 1 }
        first.finish(10)
        await Task.yield()
        XCTAssertTrue(model.refreshing)
        second.finish(80); await settle { model.controlsVerified }
        XCTAssertEqual(model.controls?.battery, 80)
    }
    @MainActor func testSwitchDuringReadRejectsOldDeviceResult() async {
        let a = FakeController(); let b = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { $0.id == "A" ? a : b })
        model.updateHeadphones([headphone(), headphone("B")])
        model.select("A"); await settle { a.reads == 1 }
        model.select("B"); await settle { b.reads == 1 }
        b.finish(90); await settle { model.controlsVerified }
        a.finish(10); await Task.yield()
        XCTAssertEqual(model.selectedID, "B")
        XCTAssertEqual(model.controls?.battery, 90)
    }
    @MainActor func testRetriesStopAfterThreeFailuresAndManualRefreshResumes() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()])
        for attempt in 1...3 {
            await settle { fake.reads == attempt }; fake.fail()
            await settle { !model.refreshing }
            model.updateHeadphones([headphone()], now: Date().addingTimeInterval(10))
        }
        await Task.yield(); XCTAssertEqual(fake.reads, 3)
        model.refresh(); await settle { fake.reads == 4 }; fake.finish()
        await settle { model.controlsVerified }
    }
    @MainActor func testForgetPairingEvictsCachedSettings() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()]); await settle { fake.reads == 1 }; fake.finish()
        await settle { model.controlsVerified }
        model.updateHeadphones([])
        XCTAssertNil(model.controls); XCTAssertNil(model.selectedID)
        model.updateHeadphones([headphone()]); await settle { fake.reads == 2 }
        XCTAssertNil(model.controls)
        fake.finish(); await settle { model.controlsVerified }
    }
    @MainActor func testSleepInvalidatesPendingRead() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()]); await settle { fake.reads == 1 }
        model.willSleep()
        XCTAssertFalse(model.working)
        fake.finish(); await Task.yield()
        XCTAssertFalse(model.controlsVerified); XCTAssertNil(model.controls)
        model.updateHeadphones([headphone()]); await settle { fake.reads == 2 }
        fake.finish(); await settle { model.controlsVerified }
    }
    @MainActor func testDeadlineReleasesBusyStateAndRejectsLateResponse() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, responseTimeout: .milliseconds(20), controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()]); await settle { fake.reads == 1 }
        await settle { !model.working }
        XCTAssertFalse(model.working); XCTAssertFalse(model.controlsVerified)
        XCTAssertTrue(model.message?.contains("timed out") == true)
        fake.finish(); await Task.yield()
        XCTAssertNil(model.controls)
    }
    @MainActor func testFailedRefreshRetainsCacheAndRecovers() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()]); await settle { fake.reads == 1 }
        fake.finish(); await settle { model.controlsVerified }
        model.refresh(); await settle { fake.reads == 2 }; fake.fail()
        await settle { !model.refreshing }
        XCTAssertEqual(model.controls?.battery, 50); XCTAssertFalse(model.canEditControls)
        XCTAssertTrue(model.message != nil)
        model.refresh(); await settle { fake.reads == 3 }; fake.finish(75)
        await settle { model.controlsVerified }
        XCTAssertNil(model.message); XCTAssertEqual(model.controls?.battery, 75)
    }

    @MainActor func testRemoteCapabilities() throws {
        var controls = Controls(); controls.mode = 0; controls.level = 50; controls.levelRange = 0...100
        controls.modes = [.init(id: 0, name: "Off"), .init(id: 1, name: "Adaptive"), .init(id: 2, name: "Custom")]
        XCTAssertEqual(try RemoteAction.ancOn.noiseSetting(kind: .momentum4, controls: controls).level, 0)
        XCTAssertEqual(try RemoteAction.transparency.noiseSetting(kind: .momentum4, controls: controls).level, 100)
        XCTAssertEqual(try RemoteAction.ancOff.noiseSetting(kind: .momentum4, controls: controls).mode, 0)
        XCTAssertEqual(try RemoteAction.transparency.noiseSetting(kind: .sony, controls: controls).mode, 2)
        controls.modes = [.init(id: 8, name: "Quiet"), .init(id: 9, name: "Aware")]
        XCTAssertEqual(try RemoteAction.ancOn.noiseSetting(kind: .bose, controls: controls).mode, 8)
        do { _ = try RemoteAction.ancOff.noiseSetting(kind: .bose, controls: controls); XCTFail("Bose off must be rejected when absent") } catch {}
        controls.mode = nil
        do { _ = try RemoteAction.ancOn.noiseSetting(kind: .sony, controls: controls); XCTFail("Cannot promise confirmation for legacy Sony") } catch {}
    }
    @MainActor func testRemoteWaitsForConfirmation() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()]); await settle { fake.reads == 1 }; fake.finish()
        await settle { model.controlsVerified }
        let request = Task { try await model.executeRemote(.transparency) }
        await settle { fake.reads == 2 }
        XCTAssertEqual(fake.writes, 1); XCTAssertTrue(model.working)
        fake.finish()
        do { let result = try await request.value; XCTAssertTrue(result.contains("Transparency on")) }
        catch { XCTFail(error.localizedDescription) }
        XCTAssertEqual(model.controls?.level, 100)
    }
    @MainActor func testRemoteRejectsMismatchedReadback() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone()]); await settle { fake.reads == 1 }; fake.finish()
        await settle { model.controlsVerified }
        let request = Task { try await model.executeRemote(.ancOn) }
        await settle { fake.reads == 2 }; fake.mode = 0; fake.finish()
        do { _ = try await request.value; XCTFail("Incorrect readback must not report success") } catch {}
    }
    @MainActor func testRemoteRejectsDisconnectedHeadphone() async {
        let fake = FakeController()
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in fake })
        model.updateHeadphones([headphone(connected: false)])
        do { _ = try await model.executeRemote(.ancOn); XCTFail("Disconnected command must fail") } catch {}
        XCTAssertEqual(fake.writes, 0)
    }

    @MainActor func testAudioDiscoveryAndIconState() {
        let address = "80-C3-BA-81-E7-90"
        XCTAssertEqual(AudioOutputs.bluetoothAddress(uid: address + ":output", transport: kAudioDeviceTransportTypeBluetooth, alive: true), address)
        XCTAssertNil(AudioOutputs.bluetoothAddress(uid: address + ":output", transport: kAudioDeviceTransportTypeUSB, alive: true))
        XCTAssertNil(AudioOutputs.bluetoothAddress(uid: address + ":output", transport: kAudioDeviceTransportTypeBluetooth, alive: false))
        XCTAssertNil(AudioOutputs.bluetoothAddress(uid: "invalid:output", transport: kAudioDeviceTransportTypeBluetooth, alive: true))
        let output = AudioOutput(id: 1, name: "MOMENTUM 4", transport: kAudioDeviceTransportTypeBluetooth, bluetoothAddress: address)
        let found = AppModel.reconcileHeadphones([], outputs: [output])
        XCTAssertEqual(found.count, 1); XCTAssertTrue(found[0].connected)
        let paired = Headphone(id: address.lowercased(), name: "MOMENTUM 4", kind: .momentum4, connected: false)
        let merged = AppModel.reconcileHeadphones([paired], outputs: [output])
        XCTAssertEqual(merged.count, 1); XCTAssertEqual(merged[0].id, paired.id); XCTAssertTrue(merged[0].connected)
        let model = AppModel(startMonitoring: false, controllerFactory: { _ in nil })
        XCTAssertFalse(model.hasConnectedHeadphones)
        model.updateHeadphones(found); XCTAssertTrue(model.hasConnectedHeadphones)
        model.bluetoothStatus = "Bluetooth off"; XCTAssertFalse(model.hasConnectedHeadphones)
        model.bluetoothStatus = nil
        model.updateHeadphones(AppModel.reconcileHeadphones([paired], outputs: []))
        XCTAssertFalse(model.hasConnectedHeadphones)
    }

}
