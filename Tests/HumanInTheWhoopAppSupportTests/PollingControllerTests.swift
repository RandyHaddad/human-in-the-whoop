import Foundation
@testable import HumanInTheWhoopAppSupport
@testable import HumanInTheWhoopCore

actor ControlledSleeper: Sleeper {
    private struct Waiter {
        let id: UUID
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, seconds: seconds, continuation: continuation))
                resumeCountWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitForSleepCount(_ count: Int) async {
        guard waiters.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func waitUntilIdle() async {
        guard !waiters.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func durations() -> [TimeInterval] { waiters.map(\.seconds) }

    func releaseFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
        resumeIdleWaiters()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        resumeIdleWaiters()
    }

    private func resumeCountWaiters() {
        let ready = countWaiters.filter { waiters.count >= $0.0 }
        countWaiters.removeAll { waiters.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    private func resumeIdleWaiters() {
        guard waiters.isEmpty else { return }
        let ready = idleWaiters
        idleWaiters.removeAll()
        for continuation in ready { continuation.resume() }
    }
}

private actor CallProbe {
    private var calls = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func call() {
        calls += 1
        let ready = waiters.filter { calls >= $0.0 }
        waiters.removeAll { calls >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    func waitForCalls(_ count: Int) async {
        guard calls < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func count() -> Int { calls }
}

private actor SuspendingCallProbe {
    private var calls = 0
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    func call() async {
        calls += 1
        let ready = callWaiters.filter { calls >= $0.0 }
        callWaiters.removeAll { calls >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        guard calls == 1 else { return }
        await withCheckedContinuation { firstRelease = $0 }
    }

    func waitForCalls(_ count: Int) async {
        guard calls < count else { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func count() -> Int { calls }
}

private enum PollingControllerTestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    @MainActor
    static func launchIntervalWakeAndDisableBoundaries() async throws {
        let sleeper = ControlledSleeper()
        let probe = CallProbe()
        let center = NotificationCenter()
        let wakeName = Notification.Name("test.didWake")
        let controller = PollingController(
            sleeper: sleeper,
            notificationCenter: center,
            wakeNotificationName: wakeName
        ) {
            await probe.call()
        }

        controller.start(enabled: true)
        await probe.waitForCalls(1)
        await sleeper.waitForSleepCount(1)
        let intervalDurations = await sleeper.durations()
        try expect(intervalDurations == [900], "poll interval was not exactly 900 seconds")

        await sleeper.releaseFirst()
        await probe.waitForCalls(2)
        await sleeper.waitForSleepCount(1)

        center.post(name: wakeName, object: nil)
        await probe.waitForCalls(3)

        controller.setEnabled(false)
        center.post(name: wakeName, object: nil)
        await Task.yield()
        await Task.yield()
        let disabledWakeCount = await probe.count()
        try expect(disabledWakeCount == 3, "disabled polling refreshed on wake")
        try expect(!controller.isRunning, "disabled polling task was not cancelled")
    }

    @MainActor
    static func disabledLaunchAndRepeatedStartDoNotRefresh() async throws {
        let sleeper = ControlledSleeper()
        let probe = CallProbe()
        let controller = PollingController(
            sleeper: sleeper,
            notificationCenter: NotificationCenter(),
            wakeNotificationName: Notification.Name("unused")
        ) { await probe.call() }

        controller.start(enabled: false)
        await Task.yield()
        let disabledCount = await probe.count()
        try expect(disabledCount == 0, "disabled launch refreshed")

        controller.start(enabled: true)
        controller.start(enabled: true)
        await probe.waitForCalls(1)
        await Task.yield()
        let repeatedStartCount = await probe.count()
        try expect(repeatedStartCount == 1, "repeated start created duplicate launch refreshes")
        controller.stop()
    }

    @MainActor
    static func localPollingRereadsSQLiteWithoutWHOOP() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStateStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        let engine = ChargeEngine(store: store)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try engine.setEnabled(true)
        try engine.applyRecovery(
            RecoverySnapshot(
                cycleID: 100,
                sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                recoveryScore: 72,
                createdAt: now.addingTimeInterval(-7_200),
                updatedAt: now.addingTimeInterval(-3_600),
                cycleStart: now.addingTimeInterval(-43_200),
                cycleEnd: nil,
                sleepPerformance: 82,
                cycleStrain: 8,
                recentWorkout: nil,
                secondaryDataComplete: true,
                validatedAt: now
            )
        )
        let whoop = CallProbe()
        let sleeper = ControlledSleeper()
        let model = try MenuBarViewModel(
            engine: engine,
            localStateSleeper: sleeper
        ) {
            await whoop.call()
        }

        model.startLocalStatePolling()
        await sleeper.waitForSleepCount(1)
        let localDurations = await sleeper.durations()
        try expect(localDurations == [1], "local state interval was not one second")
        try store.mutate { $0.chargeRemaining = 71 }
        await sleeper.releaseFirst()
        for _ in 0..<20 where model.state.chargeRemaining != 71 { await Task.yield() }
        try expect(model.state.chargeRemaining == 71, "local polling did not reread SQLite")
        let whoopCount = await whoop.count()
        try expect(whoopCount == 0, "local state polling called WHOOP")
        model.stopLocalStatePolling()
    }

    @MainActor
    static func suspendedLaunchOffThenEnableUsesNewDelayedGeneration() async throws {
        let sleeper = ControlledSleeper()
        let probe = SuspendingCallProbe()
        let controller = PollingController(
            sleeper: sleeper,
            notificationCenter: NotificationCenter(),
            wakeNotificationName: Notification.Name("unused.generation")
        ) { await probe.call() }

        controller.start(enabled: true)
        await probe.waitForCalls(1)
        controller.setEnabled(false)
        try expect(!controller.isRunning, "Off did not revoke suspended launch generation")

        controller.setEnabled(true)
        await sleeper.waitForSleepCount(1)
        let beforeInterval = await probe.count()
        try expect(beforeInterval == 1, "re-enable duplicated launch-immediate refresh")
        let durations = await sleeper.durations()
        try expect(durations == [900], "re-enable did not schedule the 900-second interval")

        await probe.releaseFirst()
        await sleeper.releaseFirst()
        await probe.waitForCalls(2)
        let finalCount = await probe.count()
        try expect(finalCount == 2, "new polling generation did not refresh after its interval")
        controller.stop()
    }

    @MainActor
    static func droppingControllerCancelsLoopAndRemovesWakeObserver() async throws {
        let sleeper = ControlledSleeper()
        let probe = CallProbe()
        let center = NotificationCenter()
        let wakeName = Notification.Name("deallocation.didWake")
        weak var weakController: PollingController?
        var controller: PollingController? = PollingController(
            sleeper: sleeper,
            notificationCenter: center,
            wakeNotificationName: wakeName
        ) { await probe.call() }
        weakController = controller

        controller?.start(enabled: true)
        await probe.waitForCalls(1)
        await sleeper.waitForSleepCount(1)
        controller = nil
        try expect(weakController == nil, "polling task strongly retained its controller")

        center.post(name: wakeName, object: nil)
        await sleeper.releaseFirst()
        for _ in 0..<20 { await Task.yield() }
        let finalCount = await probe.count()
        try expect(finalCount == 1, "deallocated controller allowed a later wake or interval refresh")
    }
}

#if canImport(XCTest)
import XCTest

final class PollingControllerTests: XCTestCase {
    @MainActor func testLaunchIntervalWakeAndDisableBoundaries() async throws { try await PollingControllerTestSupport.launchIntervalWakeAndDisableBoundaries() }
    @MainActor func testDisabledLaunchAndRepeatedStartDoNotRefresh() async throws { try await PollingControllerTestSupport.disabledLaunchAndRepeatedStartDoNotRefresh() }
    @MainActor func testLocalPollingRereadsSQLiteWithoutWHOOP() async throws { try await PollingControllerTestSupport.localPollingRereadsSQLiteWithoutWHOOP() }
    @MainActor func testSuspendedLaunchOffThenEnableUsesNewDelayedGeneration() async throws { try await PollingControllerTestSupport.suspendedLaunchOffThenEnableUsesNewDelayedGeneration() }
    @MainActor func testDroppingControllerCancelsLoopAndRemovesWakeObserver() async throws { try await PollingControllerTestSupport.droppingControllerCancelsLoopAndRemovesWakeObserver() }
}
#else
import Testing

@Suite struct PollingControllerTests {
    @Test @MainActor func launchIntervalWakeAndDisableBoundaries() async throws { try await PollingControllerTestSupport.launchIntervalWakeAndDisableBoundaries() }
    @Test @MainActor func disabledLaunchAndRepeatedStartDoNotRefresh() async throws { try await PollingControllerTestSupport.disabledLaunchAndRepeatedStartDoNotRefresh() }
    @Test @MainActor func localPollingRereadsSQLiteWithoutWHOOP() async throws { try await PollingControllerTestSupport.localPollingRereadsSQLiteWithoutWHOOP() }
    @Test @MainActor func suspendedLaunchOffThenEnableUsesNewDelayedGeneration() async throws { try await PollingControllerTestSupport.suspendedLaunchOffThenEnableUsesNewDelayedGeneration() }
    @Test @MainActor func droppingControllerCancelsLoopAndRemovesWakeObserver() async throws { try await PollingControllerTestSupport.droppingControllerCancelsLoopAndRemovesWakeObserver() }
}
#endif
