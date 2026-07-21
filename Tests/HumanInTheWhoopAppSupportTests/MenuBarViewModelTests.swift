import Foundation
@testable import HumanInTheWhoopAppSupport
@testable import HumanInTheWhoopCore

private actor RefreshProbe {
    private(set) var callCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspend = false

    func suspendNextCall() {
        shouldSuspend = true
    }

    func run(_ operation: @Sendable () throws -> Void = {}) async {
        callCount += 1
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        do {
            try operation()
        } catch {
            // The production boundary persists only typed failure state.
        }
    }

    func waitUntilCalled(_ expected: Int = 1) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func releaseFirst() {
        guard !releaseWaiters.isEmpty else { return }
        releaseWaiters.removeFirst().resume()
    }

    func count() -> Int { callCount }
}

private enum MenuBarViewModelTestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct ForcedStoreFailure: Error {}

    struct Fixture {
        let directory: URL
        let store: SQLiteStateStore
        let engine: ChargeEngine

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try SQLiteStateStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        return Fixture(
            directory: directory,
            store: store,
            engine: ChargeEngine(store: store, now: { now })
        )
    }

    static func recovery(
        score: Int = 72,
        updatedAt: Date = now.addingTimeInterval(-3_600),
        validatedAt: Date = now.addingTimeInterval(-60)
    ) -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: 100,
            sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            recoveryScore: score,
            createdAt: now.addingTimeInterval(-7_200),
            updatedAt: updatedAt,
            cycleStart: now.addingTimeInterval(-43_200),
            cycleEnd: nil,
            sleepPerformance: 82,
            cycleStrain: 8,
            recentWorkout: nil,
            secondaryDataComplete: true,
            validatedAt: validatedAt
        )
    }

    static func seedReady(_ fixture: Fixture, charge: Int = 72, score: Int = 72) throws {
        try fixture.engine.setEnabled(true)
        try fixture.engine.applyRecovery(recovery(score: score))
        try fixture.store.mutate { $0.chargeRemaining = charge }
    }

    @MainActor
    static func readyAndZeroPresentation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture)
        let probe = RefreshProbe()
        let model = try MenuBarViewModel(engine: fixture.engine) { await probe.run() }

        try expect(model.menuBarText == "72/100", "ready text was \(model.menuBarText)")
        try expect(model.currentChargeScore == 72, "ready blob score was not validated Charge")
        try expect(model.batterySystemImage == "battery.75", "ready battery was \(model.batterySystemImage)")

        try fixture.store.mutate { $0.chargeRemaining = 0 }
        try model.reloadLocalState()
        try expect(model.menuBarText == "0/100", "zero text was \(model.menuBarText)")
        try expect(model.currentChargeScore == 0, "zero blob score did not remain readable")
        try expect(model.batterySystemImage == "battery.0", "zero battery was \(model.batterySystemImage)")
    }

    @MainActor
    static func workoutAwardPresentationIsClosedAndCycleScoped() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 100, score: 72)
        let award = WorkoutChargeAward(
            workoutID: UUID(),
            cycleID: 100,
            workoutEndedAt: now.addingTimeInterval(-600),
            strain: 14,
            earnedCharge: 22,
            appliedCharge: 8,
            resultingCharge: 100,
            awardedAt: now
        )
        try fixture.store.mutate { state in
            state.workoutRewards?.cycleID = 100
            state.workoutRewards?.lastAward = award
        }
        let probe = RefreshProbe()
        let model = try MenuBarViewModel(engine: fixture.engine) { await probe.run() }

        try expect(model.lastWorkoutAwardText == "+8 Charge (+22 earned; capped)", "capped award copy was wrong")
        try fixture.store.mutate { $0.workoutRewards?.lastAward?.cycleID = 999 }
        try model.reloadLocalState()
        try expect(model.lastWorkoutAwardText == nil, "different-cycle award escaped presentation")
    }

    static func terminationSoftOffPreservesPausedLedger() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 18, score: 72)
        let pending = PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a")
        try fixture.store.mutate { $0.pendingOverride = pending }
        let before = try fixture.engine.currentState()

        try CompanionTerminationController(engine: fixture.engine).prepareForTermination()

        let after = try fixture.engine.currentState()
        try expect(!after.enabled, "termination did not persist Soft Off")
        try expect(after.recovery == before.recovery, "termination changed the paused Recovery cache")
        try expect(after.chargeRemaining == before.chargeRemaining, "termination changed paused Charge")
        try expect(after.pendingOverride == pending, "termination changed paused redirect state")
        try expect(after.syncOperationID == nil, "termination retained an in-flight sync token")
    }

    static func terminationRefusesUnconfirmedSoftOff() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 18, score: 72)
        fixture.store.simulateNextRollbackFailureForTesting()
        do {
            try fixture.store.mutate { _ in throw ForcedStoreFailure() }
        } catch {
            // This deliberately invalidates the original connection.
        }

        do {
            try CompanionTerminationController(engine: fixture.engine).prepareForTermination()
            throw Failure(description: "termination reported success without confirmed Soft Off")
        } catch is Failure {
            throw Failure(description: "termination reported success without confirmed Soft Off")
        } catch {
            let replacementStore = try SQLiteStateStore(
                databaseURL: fixture.directory.appendingPathComponent("state.sqlite3")
            )
            try expect(try replacementStore.read().enabled, "failed termination partially disabled the feature")
        }
    }

    @MainActor
    static func sanitizedRecoveryPresentationRejectsOffDegradedAndCorrupt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 18, score: 72)
        let model = try MenuBarViewModel(engine: fixture.engine) {}

        try expect(model.currentRecoveryScore == 72, "Ready did not expose validated Recovery")

        try fixture.engine.setEnabled(false)
        try model.reloadLocalState()
        try expect(model.currentRecoveryScore == nil, "Off exposed paused Recovery")
        try expect(model.currentChargeScore == nil, "Off exposed paused Charge in the blob")

        try fixture.engine.setEnabled(true)
        try model.reloadLocalState()
        try expect(model.currentRecoveryScore == nil, "refresh-required state exposed Recovery")

        try fixture.engine.applyRecovery(recovery())
        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)
        try model.reloadLocalState()
        try expect(model.currentRecoveryScore == nil, "degraded cache exposed Recovery")
        try expect(model.currentChargeScore == nil, "degraded cache exposed Charge in the blob")

        try fixture.store.mutate { state in
            state.degradedReason = nil
            state.lastSyncError = nil
            state.chargeRemaining = 101
        }
        try model.reloadLocalState()
        try expect(model.currentRecoveryScore == nil, "corrupt Charge exposed Recovery")
    }

    @MainActor
    static func readyStoreFailureLatchesUnavailablePresentation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 72, score: 72)
        let model = try MenuBarViewModel(engine: fixture.engine) {}
        try expect(model.menuBarText == "72/100", "fixture did not begin Ready")

        fixture.store.simulateNextRollbackFailureForTesting()
        do {
            try fixture.store.mutate { _ in throw ForcedStoreFailure() }
        } catch {
            // The failed rollback poisons all later reads and writes.
        }

        do {
            try model.reloadLocalState()
            throw Failure(description: "poisoned store unexpectedly reloaded")
        } catch is Failure {
            throw Failure(description: "poisoned store unexpectedly reloaded")
        } catch {
            // Expected local-state read failure.
        }

        try expect(model.menuBarText == "Unavailable", "store failure retained stale Charge")
        try expect(model.batterySystemImage == "battery.0", "store failure retained stale battery")
        try expect(
            model.unavailableWarningSystemImage == "exclamationmark.triangle.fill",
            "store failure did not show warning"
        )
        try expect(model.currentRecoveryScore == nil, "store failure retained Recovery")
        try expect(!model.canResetDemo, "store failure retained Demo Reset")
        try expect(model.resetConfirmationText == nil, "store failure retained reset target")
    }

    @MainActor
    static func offAndUnavailableHideChargeAndNeverRefreshOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery())
        let probe = RefreshProbe()
        let model = try MenuBarViewModel(engine: fixture.engine) { await probe.run() }

        try expect(model.menuBarText == "Off", "off did not display Off")
        try expect(model.batterySystemImage == "battery.0", "off battery was not disabled")
        await model.refreshNow()
        let offRefreshCount = await probe.count()
        try expect(offRefreshCount == 0, "manual refresh called WHOOP while Off")

        try seedReady(fixture)
        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)
        try model.reloadLocalState()
        try expect(model.menuBarText == "Unavailable", "degraded state exposed stale Charge")
        try expect(model.batterySystemImage == "battery.0", "unavailable battery was not disabled")
        try expect(
            model.unavailableWarningSystemImage == "exclamationmark.triangle.fill",
            "unavailable state did not expose a valid warning badge"
        )
    }

    @MainActor
    static func toggleOnRefreshesBeforeReadyAndOffPauses() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery())
        try fixture.store.mutate { $0.chargeRemaining = 18 }
        let probe = RefreshProbe()
        await probe.suspendNextCall()
        let refreshed = recovery(
            updatedAt: now.addingTimeInterval(-1_800),
            validatedAt: now
        )
        let model = try MenuBarViewModel(engine: fixture.engine) {
            await probe.run { _ = try fixture.engine.applyRecoveryIfEnabled(refreshed) }
        }

        let enabling = Task { @MainActor in await model.setEnabled(true) }
        await probe.waitUntilCalled()
        try expect(model.state.enabled, "toggle On was not persisted before refresh")
        try expect(model.isRefreshing, "toggle On did not expose refreshing state")
        try expect(model.menuBarText == "Unavailable", "toggle On became Ready before validation")
        await probe.release()
        await enabling.value
        let enabledRefreshCount = await probe.count()
        try expect(enabledRefreshCount == 1, "toggle On did not refresh exactly once")
        try expect(model.menuBarText == "18/100", "same cycle did not resume paused Charge")

        await model.setEnabled(false)
        try expect(!model.state.enabled && model.menuBarText == "Off", "toggle Off was not immediate")
        try expect(model.state.chargeRemaining == 18, "toggle Off deleted paused Charge")
        let disabledRefreshCount = await probe.count()
        try expect(disabledRefreshCount == 1, "toggle Off called WHOOP")
    }

    @MainActor
    static func manualRefreshIsExactlyOnceOnlyWhenEnabled() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture)
        let probe = RefreshProbe()
        let model = try MenuBarViewModel(engine: fixture.engine) { await probe.run() }

        await model.refreshNow()
        let firstCount = await probe.count()
        try expect(firstCount == 1, "Refresh Now did not call sync exactly once")
        await model.setEnabled(false)
        await model.refreshNow()
        let offCount = await probe.count()
        try expect(offCount == 1, "Refresh Now called sync while Off")
    }

    @MainActor
    static func failedEnableRemainsEnabledAndUnavailable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let probe = RefreshProbe()
        let model = try MenuBarViewModel(engine: fixture.engine) {
            await probe.run {
                try fixture.engine.markSyncFailure(.authentication, invalidatesCache: true)
            }
        }

        await model.setEnabled(true)
        let refreshCount = await probe.count()
        try expect(refreshCount == 1, "failed enable did not attempt one refresh")
        try expect(model.state.enabled, "refresh failure silently switched the feature Off")
        try expect(model.menuBarText == "Unavailable", "failed enable did not remain Unavailable")
        try expect(
            model.statusMessage == "WHOOP authentication is required.",
            "failed enable did not expose the sanitized degraded reason"
        )
    }

    @MainActor
    static func resetRequiresReadyAndUsesAtomicEngineReset() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 18, score: 72)
        let model = try MenuBarViewModel(engine: fixture.engine) {}

        try expect(model.canResetDemo, "valid Ready Recovery did not enable reset")
        try expect(
            model.resetConfirmationText
                == "Reset Charge from 18 to 72 across all local Codex windows? This does not change WHOOP data.",
            "reset confirmation did not use current and target values"
        )
        try model.confirmResetDemo()
        try expect(model.state.chargeRemaining == 72, "reset did not update local Charge")
        let audits = try fixture.store.readAuditEvents()
        try expect(audits.last?.name == "charge.demo_reset", "reset did not use audited engine operation")

        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)
        try model.reloadLocalState()
        try expect(!model.canResetDemo && model.resetConfirmationText == nil, "degraded cache exposed reset")
        do {
            try model.confirmResetDemo()
            throw Failure(description: "degraded reset unexpectedly succeeded")
        } catch is MenuBarViewModelError {
            // Expected UI guard; the engine is never invoked.
        }
    }

    @MainActor
    static func persistedStatusIsClosedSanitizedAndClearsOnSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 31, score: 72)
        try fixture.store.mutate { state in
            state.degradedReason = "access_token=super-secret"
            state.lastSyncError = "refresh_token=also-secret"
        }
        let model = try MenuBarViewModel(engine: fixture.engine) {}

        try expect(
            model.statusMessage == "Human in the Whoop is unavailable.",
            "unknown persisted status was not mapped to fixed generic copy"
        )
        try expect(!(model.statusMessage ?? "").contains("secret"), "persisted secret reached presentation")

        try fixture.store.mutate { state in
            state.degradedReason = SyncFailureReason.ledgerCorrupt.userMessage
            state.lastSyncError = SyncFailureReason.ledgerCorrupt.rawValue
        }
        try model.reloadLocalState()
        try expect(
            model.statusMessage == "Human in the Whoop is unavailable.",
            "corrupt state did not use fixed generic copy"
        )

        try fixture.store.mutate { state in
            state.degradedReason = nil
            state.lastSyncError = SyncFailureReason.rateLimited.rawValue
        }
        try model.reloadLocalState()
        try expect(
            model.statusMessage == SyncFailureReason.rateLimited.userMessage,
            "typed retained-cache status did not use fixed copy"
        )

        try fixture.store.mutate { $0.lastSyncError = nil }
        try model.reloadLocalState()
        try expect(model.statusMessage == nil, "successful Ready reload retained stale status copy")

        await model.setEnabled(false)
        try expect(model.unavailableWarningSystemImage == nil, "Off displayed the unavailable warning")
    }

    @MainActor
    static func staleResetConfirmationRechecksCoreAndReloadsOnFailure() async throws {
        let mutations: [(inout PersistentState) -> Void] = [
            { state in
                state.degradedReason = "access_token=secret"
                state.lastSyncError = "unknown-secret"
            },
            { state in
                state.recovery?.cycleEnd = now
            },
            { state in
                state.recovery = nil
                state.chargeRemaining = nil
            },
        ]

        for mutation in mutations {
            let fixture = try makeFixture()
            defer { fixture.cleanUp() }
            try seedReady(fixture, charge: 18, score: 72)
            let model = try MenuBarViewModel(engine: fixture.engine) {}
            try expect(model.canResetDemo, "fixture did not begin with a visible reset")
            try fixture.store.mutate(mutation)
            let before = try fixture.engine.currentState()

            do {
                try model.confirmResetDemo()
                throw Failure(description: "stale reset confirmation unexpectedly succeeded")
            } catch is MenuBarViewModelError {
                throw Failure(description: "stale view blocked locally instead of Core rechecking atomically")
            } catch {
                // Expected Core rejection.
            }

            try expect(try fixture.engine.currentState() == before, "failed reset mutated Core state")
            try expect(try fixture.store.readAuditEvents().isEmpty, "failed reset wrote an audit")
            try expect(!model.canResetDemo, "model did not reload after Core reset rejection")
            try expect(model.menuBarText == "Unavailable", "model did not present Unavailable after rejection")
            try expect(!(model.statusMessage ?? "").contains("secret"), "reset failure surfaced persisted secret")
        }
    }

    @MainActor
    static func offOnRevokesSuspendedRefreshAndSchedulesWithoutDuplicateImmediate() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery())
        try fixture.store.mutate { $0.chargeRemaining = 18 }
        let refreshProbe = RefreshProbe()
        await refreshProbe.suspendNextCall()
        let refreshed = recovery(
            updatedAt: now.addingTimeInterval(-1_800),
            validatedAt: now
        )
        let localSleeper = ControlledSleeper()
        let schedulerSleeper = ControlledSleeper()
        let model = try MenuBarViewModel(
            engine: fixture.engine,
            localStateSleeper: localSleeper
        ) {
            await refreshProbe.run { _ = try fixture.engine.applyRecoveryIfEnabled(refreshed) }
        }
        let controller = PollingController(
            sleeper: schedulerSleeper,
            notificationCenter: NotificationCenter(),
            wakeNotificationName: Notification.Name("unused.off-on")
        ) { [weak model] in
            await model?.refreshNow()
        }
        model.attachPollingController(controller)

        let firstEnable = Task { @MainActor in await model.setEnabled(true) }
        await refreshProbe.waitUntilCalled(1)
        try expect(model.isRefreshing, "first enable did not begin refresh")

        await model.setEnabled(false)
        try expect(!model.isRefreshing && model.menuBarText == "Off", "Off did not revoke suspended UI refresh")

        await model.setEnabled(true)
        let refreshedCount = await refreshProbe.count()
        try expect(refreshedCount == 2, "re-enable did not start one genuinely new immediate refresh")
        try expect(model.menuBarText == "18/100" && !model.isRefreshing, "new refresh did not reach Ready")
        await schedulerSleeper.waitForSleepCount(1)
        let schedulerDurations = await schedulerSleeper.durations()
        try expect(schedulerDurations == [900], "re-enable scheduler did not delay its first periodic refresh")

        await refreshProbe.release()
        await firstEnable.value
        let finalRefreshCount = await refreshProbe.count()
        try expect(finalRefreshCount == 2, "scheduler or stale enable duplicated immediate refresh")
        try expect(model.menuBarText == "18/100" && model.statusMessage == nil, "old refresh overwrote new Ready UI")
        controller.stop()
    }

    @MainActor
    static func duplicateOnDuringSuspendedEnablePreservesOriginalGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery())
        try fixture.store.mutate { $0.chargeRemaining = 18 }
        let refreshProbe = RefreshProbe()
        await refreshProbe.suspendNextCall()
        let refreshed = recovery(
            updatedAt: now.addingTimeInterval(-1_800),
            validatedAt: now
        )
        let schedulerSleeper = ControlledSleeper()
        let model = try MenuBarViewModel(engine: fixture.engine) {
            await refreshProbe.run { _ = try fixture.engine.applyRecoveryIfEnabled(refreshed) }
        }
        let controller = PollingController(
            sleeper: schedulerSleeper,
            notificationCenter: NotificationCenter(),
            wakeNotificationName: Notification.Name("unused.duplicate-on")
        ) { [weak model] in await model?.refreshNow() }
        model.attachPollingController(controller)

        let firstEnable = Task { @MainActor in await model.setEnabled(true) }
        await refreshProbe.waitUntilCalled()
        await model.setEnabled(true)
        let duringBarrierCount = await refreshProbe.count()
        try expect(duringBarrierCount == 1, "duplicate On started another refresh")

        await refreshProbe.release()
        await firstEnable.value
        await schedulerSleeper.waitForSleepCount(1)
        try expect(controller.isRunning, "duplicate On invalidated the original scheduler generation")
        let durations = await schedulerSleeper.durations()
        try expect(durations == [900], "original enable did not resume delayed polling")
        controller.stop()
    }

    @MainActor
    static func explicitOffStopsEverythingBeforePoisonedStoreAccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture)
        let refreshProbe = RefreshProbe()
        await refreshProbe.suspendNextCall()
        let schedulerSleeper = ControlledSleeper()
        let center = NotificationCenter()
        let wakeName = Notification.Name("poisoned.didWake")
        let model = try MenuBarViewModel(engine: fixture.engine) { await refreshProbe.run() }
        let controller = PollingController(
            sleeper: schedulerSleeper,
            notificationCenter: center,
            wakeNotificationName: wakeName
        ) { [weak model] in await model?.refreshNow() }
        model.attachPollingController(controller)
        await refreshProbe.waitUntilCalled()
        try expect(model.isRefreshing && controller.isRunning, "launch refresh did not suspend")

        fixture.store.simulateNextRollbackFailureForTesting()
        do {
            try fixture.store.mutate { _ in throw ForcedStoreFailure() }
        } catch {
            // The failed rollback poisons all later reads and writes.
        }

        await model.setEnabled(false)
        try expect(!model.isRefreshing, "Off did not revoke model refresh before failed storage access")
        try expect(!controller.isRunning, "Off did not stop scheduler before failed storage access")
        try expect(model.statusMessage == "Human in the Whoop is unavailable.", "failed durable Off lacked fixed status")
        try expect(model.menuBarText == "Unavailable", "failed durable Off retained stale Charge")
        try expect(model.batterySystemImage == "battery.0", "failed durable Off retained stale battery")
        try expect(
            model.unavailableWarningSystemImage == "exclamationmark.triangle.fill",
            "failed durable Off lacked unavailable warning"
        )
        try expect(model.currentRecoveryScore == nil, "failed durable Off retained Recovery")
        try expect(!model.canResetDemo, "failed durable Off retained Demo Reset")
        try expect(model.resetConfirmationText == nil, "failed durable Off retained reset target")

        center.post(name: wakeName, object: nil)
        await refreshProbe.release()
        await schedulerSleeper.releaseFirst()
        for _ in 0..<20 { await Task.yield() }
        let finalCount = await refreshProbe.count()
        try expect(finalCount == 1, "poisoned Off allowed later launch/wake/interval WHOOP calls")
    }

    @MainActor
    static func externalEnableReloadRefreshesOnceThenResumesDelayedPolling() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery())
        try fixture.store.mutate { $0.chargeRemaining = 18 }
        let refreshProbe = RefreshProbe()
        await refreshProbe.suspendNextCall()
        let refreshed = recovery(
            updatedAt: now.addingTimeInterval(-1_800),
            validatedAt: now
        )
        let schedulerSleeper = ControlledSleeper()
        let model = try MenuBarViewModel(engine: fixture.engine) {
            await refreshProbe.run { _ = try fixture.engine.applyRecoveryIfEnabled(refreshed) }
        }
        let controller = PollingController(
            sleeper: schedulerSleeper,
            notificationCenter: NotificationCenter(),
            wakeNotificationName: Notification.Name("unused.external-on")
        ) { [weak model] in await model?.refreshNow() }
        model.attachPollingController(controller)

        try fixture.engine.setEnabled(true)
        try model.reloadLocalState()
        await refreshProbe.waitUntilCalled()
        try model.reloadLocalState()
        await model.refreshNow()
        let whileSuspendedCount = await refreshProbe.count()
        try expect(whileSuspendedCount == 1, "external On or concurrent refresh duplicated immediate sync")

        await refreshProbe.release()
        await schedulerSleeper.waitForSleepCount(1)
        let finalCount = await refreshProbe.count()
        try expect(finalCount == 1, "external On performed more than one model-owned immediate refresh")
        try expect(model.menuBarText == "18/100", "external On refresh did not reach Ready")
        let durations = await schedulerSleeper.durations()
        try expect(durations == [900], "external On did not resume delayed polling")
        controller.stop()
    }

    @MainActor
    static func missedExternalOffOnUsesDurableRefreshRequirementExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 18)
        let refreshProbe = RefreshProbe()
        let refreshed = recovery(
            updatedAt: now.addingTimeInterval(-1_800),
            validatedAt: now
        )
        let schedulerSleeper = ControlledSleeper()
        let model = try MenuBarViewModel(engine: fixture.engine) {
            await refreshProbe.run { _ = try fixture.engine.applyRecoveryIfEnabled(refreshed) }
        }
        let controller = PollingController(
            sleeper: schedulerSleeper,
            notificationCenter: NotificationCenter(),
            wakeNotificationName: Notification.Name("unused.missed-external-off-on")
        ) { [weak model] in await model?.refreshNow() }
        model.attachPollingController(controller)
        await refreshProbe.waitUntilCalled()
        await schedulerSleeper.waitForSleepCount(1)
        controller.setEnabled(false)
        for _ in 0..<20 where !(await schedulerSleeper.durations()).isEmpty {
            await Task.yield()
        }
        let stoppedDurations = await schedulerSleeper.durations()
        try expect(stoppedDurations.isEmpty, "fixture did not cancel its launch scheduler")

        await refreshProbe.suspendNextCall()
        try fixture.engine.setEnabled(false)
        try fixture.engine.setEnabled(true)
        try expect(model.state.enabled, "fixture sampled external Off before the reload")
        try model.reloadLocalState()
        await refreshProbe.waitUntilCalled(2)
        let startedCount = await refreshProbe.count()
        try expect(startedCount == 2, "durable refreshRequired state did not start immediate validation")
        try model.reloadLocalState()
        await model.refreshNow()
        let inFlightCount = await refreshProbe.count()
        try expect(inFlightCount == 2, "refreshRequired reloads duplicated the immediate validation")

        await refreshProbe.release()
        await schedulerSleeper.waitForSleepCount(1)
        let finalCount = await refreshProbe.count()
        try expect(finalCount == 2, "missed external Off→On did not refresh exactly once")
        try expect(model.menuBarText == "18/100", "durable refresh requirement did not return to Ready")
        let durations = await schedulerSleeper.durations()
        try expect(durations == [900], "durable refresh requirement did not resume delayed polling")
        controller.stop()
    }

    @MainActor
    static func cancelledExternalRefreshDoesNotRetainModel() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery())
        let refreshProbe = RefreshProbe()
        await refreshProbe.suspendNextCall()
        weak var weakModel: MenuBarViewModel?
        var model: MenuBarViewModel? = try MenuBarViewModel(engine: fixture.engine) {
            await refreshProbe.run()
        }
        weakModel = model

        try fixture.engine.setEnabled(true)
        try model?.reloadLocalState()
        await refreshProbe.waitUntilCalled()
        try expect(model?.isRefreshing == true, "external validation did not reserve refresh state")

        await model?.setEnabled(false)
        model = nil
        let releasedModel = weakModel == nil
        await refreshProbe.release()
        try expect(releasedModel, "cancelled external refresh retained its model across await")
    }

    @MainActor
    static func durableReenablePreemptsOlderActiveRefresh() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery())
        try fixture.store.mutate { $0.chargeRemaining = 18 }
        let refreshProbe = RefreshProbe()
        let refreshed = recovery(
            updatedAt: now.addingTimeInterval(-1_800),
            validatedAt: now
        )
        let schedulerSleeper = ControlledSleeper()
        let model = try MenuBarViewModel(engine: fixture.engine) {
            await refreshProbe.run { _ = try fixture.engine.applyRecoveryIfEnabled(refreshed) }
        }
        let controller = PollingController(
            sleeper: schedulerSleeper,
            notificationCenter: NotificationCenter(),
            wakeNotificationName: Notification.Name("unused.preempt-old-refresh")
        ) { [weak model] in await model?.refreshNow() }
        model.attachPollingController(controller)

        // Establish sampled Ready state without starting the disabled scheduler.
        try fixture.engine.setEnabled(true)
        try fixture.engine.applyRecovery(refreshed)
        try model.reloadLocalState()
        try expect(model.menuBarText == "18/100", "fixture did not establish Ready state")

        await refreshProbe.suspendNextCall()
        let oldRefresh = Task { @MainActor in await model.refreshNow() }
        await refreshProbe.waitUntilCalled()
        await refreshProbe.suspendNextCall()

        try fixture.engine.setEnabled(false)
        try fixture.engine.setEnabled(true)
        try model.reloadLocalState()
        await refreshProbe.waitUntilCalled(2)
        let startedCount = await refreshProbe.count()
        guard startedCount == 2 else {
            await refreshProbe.release()
            await oldRefresh.value
            throw Failure(description: "durable re-enable adopted the pre-Off refresh instead of starting a new one")
        }

        await refreshProbe.releaseFirst()
        await oldRefresh.value
        try expect(model.isRefreshing, "old completion cleared the new validation generation")
        try expect(!controller.isRunning, "old completion resumed polling")
        let beforeNewCompletion = await schedulerSleeper.durations()
        try expect(beforeNewCompletion.isEmpty, "old completion scheduled the 900-second interval")

        await refreshProbe.releaseFirst()
        await schedulerSleeper.waitForSleepCount(1)
        try expect(!model.isRefreshing, "new validation did not finish")
        let finalCount = await refreshProbe.count()
        try expect(finalCount == 2, "durable re-enable started an unexpected refresh invocation")
        let durations = await schedulerSleeper.durations()
        try expect(durations == [900], "new validation did not resume delayed polling")
        controller.stop()
    }

    @MainActor
    static func durableReenableCancelsOldPollingGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, charge: 18)
        let refreshProbe = RefreshProbe()
        let refreshed = recovery(
            updatedAt: now.addingTimeInterval(-1_800),
            validatedAt: now
        )
        let schedulerSleeper = ControlledSleeper()
        let center = NotificationCenter()
        let wakeName = Notification.Name("running-controller.external-reenable")
        let model = try MenuBarViewModel(engine: fixture.engine) {
            await refreshProbe.run { _ = try fixture.engine.applyRecoveryIfEnabled(refreshed) }
        }
        let controller = PollingController(
            sleeper: schedulerSleeper,
            notificationCenter: center,
            wakeNotificationName: wakeName
        ) { [weak model] in await model?.refreshNow() }
        model.attachPollingController(controller)
        await refreshProbe.waitUntilCalled()
        await schedulerSleeper.waitForSleepCount(1)
        try expect(controller.isRunning, "fixture did not establish the old polling generation")

        await refreshProbe.suspendNextCall()
        try fixture.engine.setEnabled(false)
        try fixture.engine.setEnabled(true)
        try model.reloadLocalState()
        await refreshProbe.waitUntilCalled(2)
        guard !controller.isRunning else {
            await refreshProbe.release()
            controller.stop()
            throw Failure(description: "durable re-enable left the old polling generation running")
        }
        await schedulerSleeper.waitUntilIdle()
        let canceledDurations = await schedulerSleeper.durations()
        try expect(canceledDurations.isEmpty, "durable re-enable did not cancel the old 900-second waiter")

        center.post(name: wakeName, object: nil)
        await schedulerSleeper.releaseFirst()
        for _ in 0..<20 { await Task.yield() }
        let beforeValidationCount = await refreshProbe.count()
        try expect(beforeValidationCount == 2, "old deadline or wake refreshed during new validation")

        await refreshProbe.release()
        await schedulerSleeper.waitForSleepCount(1)
        try expect(controller.isRunning, "new validation did not start a fresh polling generation")
        let freshDurations = await schedulerSleeper.durations()
        try expect(freshDurations == [900], "new validation did not create exactly one fresh 900-second waiter")
        let finalCount = await refreshProbe.count()
        try expect(finalCount == 2, "fresh polling generation performed an immediate duplicate refresh")
        controller.stop()
    }
}

#if canImport(XCTest)
import XCTest

final class MenuBarViewModelTests: XCTestCase {
    @MainActor func testReadyAndZeroPresentation() async throws { try await MenuBarViewModelTestSupport.readyAndZeroPresentation() }
    @MainActor func testWorkoutAwardPresentationIsClosedAndCycleScoped() async throws { try await MenuBarViewModelTestSupport.workoutAwardPresentationIsClosedAndCycleScoped() }
    func testTerminationSoftOffPreservesPausedLedger() throws { try MenuBarViewModelTestSupport.terminationSoftOffPreservesPausedLedger() }
    func testTerminationRefusesUnconfirmedSoftOff() throws { try MenuBarViewModelTestSupport.terminationRefusesUnconfirmedSoftOff() }
    @MainActor func testSanitizedRecoveryPresentationRejectsOffDegradedAndCorrupt() async throws { try await MenuBarViewModelTestSupport.sanitizedRecoveryPresentationRejectsOffDegradedAndCorrupt() }
    @MainActor func testReadyStoreFailureLatchesUnavailablePresentation() async throws { try await MenuBarViewModelTestSupport.readyStoreFailureLatchesUnavailablePresentation() }
    @MainActor func testOffAndUnavailableHideChargeAndNeverRefreshOff() async throws { try await MenuBarViewModelTestSupport.offAndUnavailableHideChargeAndNeverRefreshOff() }
    @MainActor func testToggleOnRefreshesBeforeReadyAndOffPauses() async throws { try await MenuBarViewModelTestSupport.toggleOnRefreshesBeforeReadyAndOffPauses() }
    @MainActor func testManualRefreshIsExactlyOnceOnlyWhenEnabled() async throws { try await MenuBarViewModelTestSupport.manualRefreshIsExactlyOnceOnlyWhenEnabled() }
    @MainActor func testFailedEnableRemainsEnabledAndUnavailable() async throws { try await MenuBarViewModelTestSupport.failedEnableRemainsEnabledAndUnavailable() }
    @MainActor func testResetRequiresReadyAndUsesAtomicEngineReset() async throws { try await MenuBarViewModelTestSupport.resetRequiresReadyAndUsesAtomicEngineReset() }
    @MainActor func testPersistedStatusIsClosedSanitizedAndClearsOnSuccess() async throws { try await MenuBarViewModelTestSupport.persistedStatusIsClosedSanitizedAndClearsOnSuccess() }
    @MainActor func testStaleResetConfirmationRechecksCoreAndReloadsOnFailure() async throws { try await MenuBarViewModelTestSupport.staleResetConfirmationRechecksCoreAndReloadsOnFailure() }
    @MainActor func testOffOnRevokesSuspendedRefreshAndSchedulesWithoutDuplicateImmediate() async throws { try await MenuBarViewModelTestSupport.offOnRevokesSuspendedRefreshAndSchedulesWithoutDuplicateImmediate() }
    @MainActor func testDuplicateOnDuringSuspendedEnablePreservesOriginalGeneration() async throws { try await MenuBarViewModelTestSupport.duplicateOnDuringSuspendedEnablePreservesOriginalGeneration() }
    @MainActor func testExplicitOffStopsEverythingBeforePoisonedStoreAccess() async throws { try await MenuBarViewModelTestSupport.explicitOffStopsEverythingBeforePoisonedStoreAccess() }
    @MainActor func testExternalEnableReloadRefreshesOnceThenResumesDelayedPolling() async throws { try await MenuBarViewModelTestSupport.externalEnableReloadRefreshesOnceThenResumesDelayedPolling() }
    @MainActor func testMissedExternalOffOnUsesDurableRefreshRequirementExactlyOnce() async throws { try await MenuBarViewModelTestSupport.missedExternalOffOnUsesDurableRefreshRequirementExactlyOnce() }
    @MainActor func testCancelledExternalRefreshDoesNotRetainModel() async throws { try await MenuBarViewModelTestSupport.cancelledExternalRefreshDoesNotRetainModel() }
    @MainActor func testDurableReenablePreemptsOlderActiveRefresh() async throws { try await MenuBarViewModelTestSupport.durableReenablePreemptsOlderActiveRefresh() }
    @MainActor func testDurableReenableCancelsOldPollingGeneration() async throws { try await MenuBarViewModelTestSupport.durableReenableCancelsOldPollingGeneration() }
}
#else
import Testing

@Suite struct MenuBarViewModelTests {
    @Test @MainActor func readyAndZeroPresentation() async throws { try await MenuBarViewModelTestSupport.readyAndZeroPresentation() }
    @Test @MainActor func workoutAwardPresentationIsClosedAndCycleScoped() async throws { try await MenuBarViewModelTestSupport.workoutAwardPresentationIsClosedAndCycleScoped() }
    @Test func terminationSoftOffPreservesPausedLedger() throws { try MenuBarViewModelTestSupport.terminationSoftOffPreservesPausedLedger() }
    @Test func terminationRefusesUnconfirmedSoftOff() throws { try MenuBarViewModelTestSupport.terminationRefusesUnconfirmedSoftOff() }
    @Test @MainActor func sanitizedRecoveryPresentationRejectsOffDegradedAndCorrupt() async throws { try await MenuBarViewModelTestSupport.sanitizedRecoveryPresentationRejectsOffDegradedAndCorrupt() }
    @Test @MainActor func readyStoreFailureLatchesUnavailablePresentation() async throws { try await MenuBarViewModelTestSupport.readyStoreFailureLatchesUnavailablePresentation() }
    @Test @MainActor func offAndUnavailableHideChargeAndNeverRefreshOff() async throws { try await MenuBarViewModelTestSupport.offAndUnavailableHideChargeAndNeverRefreshOff() }
    @Test @MainActor func toggleOnRefreshesBeforeReadyAndOffPauses() async throws { try await MenuBarViewModelTestSupport.toggleOnRefreshesBeforeReadyAndOffPauses() }
    @Test @MainActor func manualRefreshIsExactlyOnceOnlyWhenEnabled() async throws { try await MenuBarViewModelTestSupport.manualRefreshIsExactlyOnceOnlyWhenEnabled() }
    @Test @MainActor func failedEnableRemainsEnabledAndUnavailable() async throws { try await MenuBarViewModelTestSupport.failedEnableRemainsEnabledAndUnavailable() }
    @Test @MainActor func resetRequiresReadyAndUsesAtomicEngineReset() async throws { try await MenuBarViewModelTestSupport.resetRequiresReadyAndUsesAtomicEngineReset() }
    @Test @MainActor func persistedStatusIsClosedSanitizedAndClearsOnSuccess() async throws { try await MenuBarViewModelTestSupport.persistedStatusIsClosedSanitizedAndClearsOnSuccess() }
    @Test @MainActor func staleResetConfirmationRechecksCoreAndReloadsOnFailure() async throws { try await MenuBarViewModelTestSupport.staleResetConfirmationRechecksCoreAndReloadsOnFailure() }
    @Test @MainActor func offOnRevokesSuspendedRefreshAndSchedulesWithoutDuplicateImmediate() async throws { try await MenuBarViewModelTestSupport.offOnRevokesSuspendedRefreshAndSchedulesWithoutDuplicateImmediate() }
    @Test @MainActor func duplicateOnDuringSuspendedEnablePreservesOriginalGeneration() async throws { try await MenuBarViewModelTestSupport.duplicateOnDuringSuspendedEnablePreservesOriginalGeneration() }
    @Test @MainActor func explicitOffStopsEverythingBeforePoisonedStoreAccess() async throws { try await MenuBarViewModelTestSupport.explicitOffStopsEverythingBeforePoisonedStoreAccess() }
    @Test @MainActor func externalEnableReloadRefreshesOnceThenResumesDelayedPolling() async throws { try await MenuBarViewModelTestSupport.externalEnableReloadRefreshesOnceThenResumesDelayedPolling() }
    @Test @MainActor func missedExternalOffOnUsesDurableRefreshRequirementExactlyOnce() async throws { try await MenuBarViewModelTestSupport.missedExternalOffOnUsesDurableRefreshRequirementExactlyOnce() }
    @Test @MainActor func cancelledExternalRefreshDoesNotRetainModel() async throws { try await MenuBarViewModelTestSupport.cancelledExternalRefreshDoesNotRetainModel() }
    @Test @MainActor func durableReenablePreemptsOlderActiveRefresh() async throws { try await MenuBarViewModelTestSupport.durableReenablePreemptsOlderActiveRefresh() }
    @Test @MainActor func durableReenableCancelsOldPollingGeneration() async throws { try await MenuBarViewModelTestSupport.durableReenableCancelsOldPollingGeneration() }
}
#endif
