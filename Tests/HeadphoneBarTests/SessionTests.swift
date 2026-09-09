import Foundation
func XCTAssertTrue(_ value: @autoclosure () -> Bool) { precondition(value()) }
func XCTAssertFalse(_ value: @autoclosure () -> Bool) { precondition(!value()) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) { precondition(left == right, "\(left) != \(right)") }
func XCTFail(_ message: String) { fatalError(message) }

@MainActor final class FakeController: HeadphoneController {
    var reads = 0
    var writes = 0
    var closed = false
    var pending: [CheckedContinuation<Controls, Error>] = []
    func read() async throws -> Controls {
        reads += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ battery: Int = 50) {
        var controls = Controls(); controls.battery = battery
        pending.removeFirst().resume(returning: controls)
    }
    func fail() { pending.removeFirst().resume(throwing: ControlError.message("Disconnected")) }
    func setMode(_ mode: Int) async throws { writes += 1 }
    func setLevel(_ level: Double) async throws { writes += 1 }
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
        print("Passed 9 app session/cache regression tests.")
    }
    @MainActor private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
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
        try? await Task.sleep(for: .milliseconds(50))
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

}
