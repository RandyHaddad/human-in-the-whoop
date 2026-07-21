import Foundation
@testable import HumanInTheWhoopCore

private enum RecoveryApplicationTestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Fixture {
        let databaseURL: URL
        let firstStore: SQLiteStateStore
        let firstEngine: ChargeEngine
        let secondEngine: ChargeEngine

        func cleanUp() {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    static let now = Date(timeIntervalSince1970: 2_100_000_000)
    static let sleepID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func makeFixture() throws -> Fixture {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.sqlite3")
        let firstStore = try SQLiteStateStore(databaseURL: databaseURL)
        let secondStore = try SQLiteStateStore(databaseURL: databaseURL)
        return Fixture(
            databaseURL: databaseURL,
            firstStore: firstStore,
            firstEngine: ChargeEngine(store: firstStore, now: { now }),
            secondEngine: ChargeEngine(store: secondStore, now: { now })
        )
    }

    static func snapshot(
        cycleID: Int64,
        cycleStart: Date,
        updatedAt: Date,
        score: Int,
        validatedAt: Date
    ) -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: cycleID,
            sleepID: sleepID,
            recoveryScore: score,
            createdAt: updatedAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            cycleStart: cycleStart,
            cycleEnd: nil,
            sleepPerformance: 90,
            cycleStrain: 8,
            recentWorkout: nil,
            secondaryDataComplete: true,
            validatedAt: validatedAt
        )
    }

    static func applyIfEnabledIsAtomic() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.firstEngine.setEnabled(true)
        let current = snapshot(
            cycleID: 99,
            cycleStart: now.addingTimeInterval(-2_000),
            updatedAt: now.addingTimeInterval(-200),
            score: 40,
            validatedAt: now.addingTimeInterval(-20)
        )
        try fixture.firstEngine.applyRecovery(current)
        try fixture.firstStore.mutate { state in
            state.chargeRemaining = 12
            state.pendingOverride = PendingOverride(sessionID: "paused", redirectedTurnID: "turn")
        }
        try fixture.firstEngine.setEnabled(false)
        let incoming = snapshot(
            cycleID: 100,
            cycleStart: now.addingTimeInterval(-1_000),
            updatedAt: now.addingTimeInterval(-100),
            score: 70,
            validatedAt: now
        )
        let before = try fixture.firstEngine.currentState()

        let disabled = try fixture.firstEngine.applyRecoveryIfEnabled(incoming)
        try expect(disabled == .disabled, "disabled atomic apply returned wrong result")
        try expect(try fixture.firstEngine.currentState() == before, "disabled atomic apply mutated state")

        let attempt = try fixture.firstEngine.recordSyncAttemptIfEnabled()
        try expect(attempt == .disabled, "disabled atomic attempt returned wrong result")
        try expect(try fixture.firstEngine.currentState() == before, "disabled atomic attempt mutated state")

        let failure = try fixture.firstEngine.markSyncFailureIfEnabled(
            .authentication,
            invalidatesCache: true,
            expectedRecovery: before.recovery
        )
        try expect(failure == .disabled, "disabled atomic failure returned wrong result")
        try expect(try fixture.firstEngine.currentState() == before, "disabled atomic failure mutated state")

        let retained = try fixture.firstEngine.recordRetainedCacheFailureIfEnabled(
            .unavailable,
            expectedRecovery: before.recovery
        )
        try expect(retained == .disabled, "disabled atomic retained-cache write returned wrong result")
        try expect(try fixture.firstEngine.currentState() == before, "disabled atomic retained-cache write mutated state")

        try fixture.firstEngine.setEnabled(true)
        let applied = try fixture.firstEngine.applyRecoveryIfEnabled(incoming)
        try expect(applied == .applied, "enabled atomic apply did not apply")
        let state = try fixture.firstEngine.currentState()
        try expect(state.recovery == incoming && state.chargeRemaining == 70, "enabled atomic apply mapped wrong ledger")
    }

    static func independentEnginesIgnoreOlderOrEqualStartDifferentCycles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.firstEngine.setEnabled(true)
        let cycleStart = now.addingTimeInterval(-1_000)
        let current = snapshot(
            cycleID: 200,
            cycleStart: cycleStart,
            updatedAt: now.addingTimeInterval(-100),
            score: 60,
            validatedAt: now.addingTimeInterval(-10)
        )
        try fixture.firstEngine.applyRecovery(current)
        let pending = PendingOverride(sessionID: "current", redirectedTurnID: "turn")
        try fixture.firstStore.mutate { state in
            state.chargeRemaining = 17
            state.pendingOverride = pending
        }
        let before = try fixture.firstEngine.currentState()

        let older = snapshot(
            cycleID: 199,
            cycleStart: cycleStart.addingTimeInterval(-1),
            updatedAt: now,
            score: 99,
            validatedAt: now
        )
        try fixture.secondEngine.applyRecovery(older)
        try expect(try fixture.firstEngine.currentState() == before, "older different cycle replaced/refilled newer ledger")

        let equalStart = snapshot(
            cycleID: 201,
            cycleStart: cycleStart,
            updatedAt: now,
            score: 1,
            validatedAt: now
        )
        let result = try fixture.secondEngine.applyRecoveryIfEnabled(equalStart)
        try expect(result == .ignoredStale, "equal-start different cycle was not stale")
        try expect(try fixture.firstEngine.currentState() == before, "equal-start different cycle mutated ledger")
    }

    static func sameCycleRejectsOlderUpdateAndAcceptsEqualOrNewer() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.firstEngine.setEnabled(true)
        let cycleStart = now.addingTimeInterval(-1_000)
        let updatedAt = now.addingTimeInterval(-100)
        let current = snapshot(
            cycleID: 200,
            cycleStart: cycleStart,
            updatedAt: updatedAt,
            score: 60,
            validatedAt: now.addingTimeInterval(-20)
        )
        try fixture.firstEngine.applyRecovery(current)
        try fixture.firstStore.mutate { $0.chargeRemaining = 17 }
        let before = try fixture.firstEngine.currentState()

        let older = snapshot(
            cycleID: 200,
            cycleStart: cycleStart,
            updatedAt: updatedAt.addingTimeInterval(-1),
            score: 99,
            validatedAt: now.addingTimeInterval(-10)
        )
        let stale = try fixture.secondEngine.applyRecoveryIfEnabled(older)
        try expect(stale == .ignoredStale, "older same-cycle update was not stale")
        try expect(try fixture.firstEngine.currentState() == before, "older same-cycle update changed state")

        let olderValidation = snapshot(
            cycleID: 200,
            cycleStart: cycleStart,
            updatedAt: updatedAt,
            score: 77,
            validatedAt: current.validatedAt.addingTimeInterval(-1)
        )
        let staleValidation = try fixture.secondEngine.applyRecoveryIfEnabled(olderValidation)
        try expect(staleValidation == .ignoredStale, "older validation at equal update time was not stale")
        try expect(try fixture.firstEngine.currentState() == before, "older validation at equal update time changed state")

        let equal = snapshot(
            cycleID: 200,
            cycleStart: cycleStart,
            updatedAt: updatedAt,
            score: 88,
            validatedAt: now
        )
        let applied = try fixture.secondEngine.applyRecoveryIfEnabled(equal)
        try expect(applied == .applied, "equal same-cycle update was not applied")
        let state = try fixture.firstEngine.currentState()
        try expect(state.recovery == equal, "equal same-cycle snapshot was not updated")
        try expect(state.chargeRemaining == 17, "equal same-cycle update refilled Charge")
    }

    static func expectedBaselineProtectsSupersedingRecovery() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.firstEngine.setEnabled(true)
        let nilBaseline = try fixture.firstEngine.currentState().recovery
        let current = snapshot(
            cycleID: 200,
            cycleStart: now.addingTimeInterval(-1_000),
            updatedAt: now.addingTimeInterval(-100),
            score: 60,
            validatedAt: now.addingTimeInterval(-10)
        )
        try fixture.secondEngine.applyRecovery(current)
        try fixture.firstStore.mutate { $0.chargeRemaining = 17 }
        var before = try fixture.firstEngine.currentState()

        let nilFailure = try fixture.firstEngine.markSyncFailureIfEnabled(
            .invalidData,
            invalidatesCache: true,
            expectedRecovery: nilBaseline
        )
        try expect(nilFailure == .superseded, "nil baseline did not detect a superseding Recovery")
        try expect(try fixture.firstEngine.currentState() == before, "nil-baseline failure changed newer state")
        let nilRetained = try fixture.firstEngine.recordRetainedCacheFailureIfEnabled(
            .unavailable,
            expectedRecovery: nilBaseline
        )
        try expect(nilRetained == .superseded, "nil retained-cache baseline missed a superseding Recovery")
        try expect(try fixture.firstEngine.currentState() == before, "nil-baseline retained-cache write changed newer state")

        let later = snapshot(
            cycleID: 201,
            cycleStart: current.cycleStart.addingTimeInterval(1),
            updatedAt: now,
            score: 80,
            validatedAt: now
        )
        try fixture.secondEngine.applyRecovery(later)
        try fixture.firstStore.mutate { $0.chargeRemaining = 19 }
        before = try fixture.firstEngine.currentState()
        let retained = try fixture.firstEngine.recordRetainedCacheFailureIfEnabled(
            .unavailable,
            expectedRecovery: current
        )
        try expect(retained == .superseded, "non-nil baseline did not detect a superseding Recovery")
        try expect(try fixture.firstEngine.currentState() == before, "superseded retained-cache write changed newer state")
        let failure = try fixture.firstEngine.markSyncFailureIfEnabled(
            .authentication,
            invalidatesCache: true,
            expectedRecovery: current
        )
        try expect(failure == .superseded, "non-nil failure baseline missed a superseding Recovery")
        try expect(try fixture.firstEngine.currentState() == before, "superseded failure changed newer state")
    }

    static func strictlyLaterCycleResets() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.firstEngine.setEnabled(true)
        let current = snapshot(
            cycleID: 200,
            cycleStart: now.addingTimeInterval(-1_000),
            updatedAt: now.addingTimeInterval(-100),
            score: 90,
            validatedAt: now.addingTimeInterval(-10)
        )
        try fixture.firstEngine.applyRecovery(current)
        try fixture.firstStore.mutate { state in
            state.chargeRemaining = 80
            state.pendingOverride = PendingOverride(sessionID: "old", redirectedTurnID: "turn")
        }

        let later = snapshot(
            cycleID: 201,
            cycleStart: current.cycleStart.addingTimeInterval(1),
            updatedAt: now,
            score: 30,
            validatedAt: now
        )
        let result = try fixture.secondEngine.applyRecoveryIfEnabled(later)
        try expect(result == .applied, "strictly later cycle was not applied")
        let state = try fixture.firstEngine.currentState()
        try expect(state.recovery == later && state.chargeRemaining == 30, "later cycle did not reset Charge")
        try expect(state.pendingOverride == nil, "later cycle did not clear pending override")
    }

    static func legacyStateWithoutSyncOperationIDDecodes() throws {
        let legacyJSON = Data(
            #"{"enabled":true,"degradedWarningEmitted":false}"#.utf8
        )
        let state = try JSONDecoder().decode(PersistentState.self, from: legacyJSON)
        try expect(state.enabled, "legacy enabled state changed during decode")
        try expect(state.syncOperationID == nil, "missing legacy sync operation ID was not nil")
    }

    static func durableSyncOperationCASGuardsTerminalApply() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.firstEngine.setEnabled(true)
        let current = snapshot(
            cycleID: 200,
            cycleStart: now.addingTimeInterval(-1_000),
            updatedAt: now.addingTimeInterval(-100),
            score: 60,
            validatedAt: now.addingTimeInterval(-10)
        )
        try fixture.firstEngine.applyRecovery(current)
        try fixture.firstStore.mutate { $0.chargeRemaining = 17 }

        let oldOperationID = UUID()
        guard case .started(let oldBaseline) = try fixture.firstEngine.beginSyncIfEnabled(
            operationID: oldOperationID
        ) else {
            throw Failure(description: "enabled old operation did not start")
        }
        try expect(oldBaseline.recovery == current, "atomic sync begin captured the wrong baseline")
        try expect(oldBaseline.syncOperationID == oldOperationID, "atomic sync begin omitted its token")

        let laterOperationID = UUID()
        guard case .started(let laterBaseline) = try fixture.secondEngine.beginSyncIfEnabled(
            operationID: laterOperationID
        ) else {
            throw Failure(description: "enabled later operation did not start")
        }
        try expect(laterBaseline.syncOperationID == laterOperationID, "later begin did not replace the token")
        try expect(
            try fixture.firstEngine.syncOperationReadiness(operationID: oldOperationID) == .superseded,
            "old token remained current after later begin"
        )

        let next = snapshot(
            cycleID: 201,
            cycleStart: current.cycleStart.addingTimeInterval(1),
            updatedAt: now,
            score: 80,
            validatedAt: now
        )
        let beforeOldApply = try fixture.firstEngine.currentState()
        let oldApply = try fixture.firstEngine.applyRecoveryIfEnabled(
            next,
            syncOperationID: oldOperationID
        )
        try expect(oldApply == .superseded, "old token applied a terminal Recovery")
        try expect(try fixture.firstEngine.currentState() == beforeOldApply, "old token mutated current state")

        let laterApply = try fixture.secondEngine.applyRecoveryIfEnabled(
            next,
            syncOperationID: laterOperationID
        )
        try expect(laterApply == .applied, "current token could not apply Recovery")
        let state = try fixture.firstEngine.currentState()
        try expect(state.recovery == next && state.chargeRemaining == 80, "current token applied the wrong ledger")
        try expect(state.syncOperationID == nil, "terminal current apply did not clear its token")
    }
}

#if canImport(XCTest)
import XCTest

final class RecoveryApplicationTests: XCTestCase {
    func testApplyIfEnabledIsAtomic() throws { try RecoveryApplicationTestSupport.applyIfEnabledIsAtomic() }
    func testIndependentEnginesIgnoreOlderOrEqualStartDifferentCycles() throws { try RecoveryApplicationTestSupport.independentEnginesIgnoreOlderOrEqualStartDifferentCycles() }
    func testSameCycleRejectsOlderUpdateAndAcceptsEqualOrNewer() throws { try RecoveryApplicationTestSupport.sameCycleRejectsOlderUpdateAndAcceptsEqualOrNewer() }
    func testExpectedBaselineProtectsSupersedingRecovery() throws { try RecoveryApplicationTestSupport.expectedBaselineProtectsSupersedingRecovery() }
    func testStrictlyLaterCycleResets() throws { try RecoveryApplicationTestSupport.strictlyLaterCycleResets() }
    func testLegacyStateWithoutSyncOperationIDDecodes() throws { try RecoveryApplicationTestSupport.legacyStateWithoutSyncOperationIDDecodes() }
    func testDurableSyncOperationCASGuardsTerminalApply() throws { try RecoveryApplicationTestSupport.durableSyncOperationCASGuardsTerminalApply() }
}
#else
import Testing

@Suite struct RecoveryApplicationTests {
    @Test func applyIfEnabledIsAtomic() throws { try RecoveryApplicationTestSupport.applyIfEnabledIsAtomic() }
    @Test func independentEnginesIgnoreOlderOrEqualStartDifferentCycles() throws { try RecoveryApplicationTestSupport.independentEnginesIgnoreOlderOrEqualStartDifferentCycles() }
    @Test func sameCycleRejectsOlderUpdateAndAcceptsEqualOrNewer() throws { try RecoveryApplicationTestSupport.sameCycleRejectsOlderUpdateAndAcceptsEqualOrNewer() }
    @Test func expectedBaselineProtectsSupersedingRecovery() throws { try RecoveryApplicationTestSupport.expectedBaselineProtectsSupersedingRecovery() }
    @Test func strictlyLaterCycleResets() throws { try RecoveryApplicationTestSupport.strictlyLaterCycleResets() }
    @Test func legacyStateWithoutSyncOperationIDDecodes() throws { try RecoveryApplicationTestSupport.legacyStateWithoutSyncOperationIDDecodes() }
    @Test func durableSyncOperationCASGuardsTerminalApply() throws { try RecoveryApplicationTestSupport.durableSyncOperationCASGuardsTerminalApply() }
}
#endif
