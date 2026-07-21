import Foundation
@testable import HumanInTheWhoopCore

private enum WorkoutReplenishmentTestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }
        func read() -> Date { lock.withLock { value } }
        func set(_ value: Date) { lock.withLock { self.value = value } }
    }

    struct Fixture {
        let directory: URL
        let store: SQLiteStateStore
        let engine: ChargeEngine
        let clock: Clock

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    static let now = Date(timeIntervalSince1970: 2_200_000_000)
    static let sleepID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let workoutA = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let workoutB = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func makeFixture(enabledAt: Date = now.addingTimeInterval(-4 * 60 * 60)) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try SQLiteStateStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        let clock = Clock(enabledAt)
        let engine = ChargeEngine(store: store, now: { clock.read() })
        try engine.setEnabled(true)
        return Fixture(directory: directory, store: store, engine: engine, clock: clock)
    }

    static func recovery(
        cycleID: Int64 = 100,
        score: Int = 40,
        cycleStart: Date = now.addingTimeInterval(-12 * 60 * 60),
        updatedAt: Date = now.addingTimeInterval(-2 * 60 * 60),
        validatedAt: Date = now.addingTimeInterval(-2 * 60 * 60)
    ) -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: cycleID,
            sleepID: sleepID,
            recoveryScore: score,
            createdAt: cycleStart.addingTimeInterval(60),
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

    static func candidate(
        id: UUID,
        strain: Double,
        endedAt: Date
    ) -> WorkoutAwardCandidate {
        WorkoutAwardCandidate(id: id, strain: strain, endedAt: endedAt)
    }

    @discardableResult
    static func applyRefresh(
        _ fixture: Fixture,
        recovery: RecoverySnapshot,
        candidates: [WorkoutAwardCandidate]
    ) throws -> RecoveryApplicationResult {
        fixture.clock.set(recovery.validatedAt)
        let operationID = UUID()
        guard case .started = try fixture.engine.beginSyncIfEnabled(operationID: operationID) else {
            throw Failure(description: "enabled refresh did not start")
        }
        return try fixture.engine.applyRecoveryAndWorkoutsIfEnabled(
            recovery,
            workoutCandidates: candidates,
            syncOperationID: operationID
        )
    }

    static func policyAnchorsAndValidation() throws {
        try expect(WorkoutChargePolicy.award(for: 0) == 1, "zero Strain did not earn the minimum")
        try expect(WorkoutChargePolicy.award(for: 10) == 11, "Strain 10 mapping changed")
        try expect(WorkoutChargePolicy.award(for: 14) == 22, "Strain 14 mapping changed")
        try expect(WorkoutChargePolicy.award(for: 18) == 37, "Strain 18 mapping changed")
        try expect(WorkoutChargePolicy.award(for: 21) == 50, "Strain 21 mapping changed")
        try expect(WorkoutChargePolicy.award(for: -0.01) == nil, "negative Strain was accepted")
        try expect(WorkoutChargePolicy.award(for: 21.01) == nil, "out-of-range Strain was accepted")
        try expect(WorkoutChargePolicy.award(for: .nan) == nil, "nonfinite Strain was accepted")
    }

    static func chronologicalAwardsCapAndDeduplicate() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let initial = recovery(score: 70)
        try fixture.engine.applyRecovery(initial)
        let firstEnd = now.addingTimeInterval(-60 * 60)
        let secondEnd = now.addingTimeInterval(-30 * 60)
        let refreshed = recovery(
            score: 70,
            updatedAt: now.addingTimeInterval(-60),
            validatedAt: now
        )

        try expect(
            try applyRefresh(
                fixture,
                recovery: refreshed,
                candidates: [
                    candidate(id: workoutB, strain: 18, endedAt: secondEnd),
                    candidate(id: workoutA, strain: 14, endedAt: firstEnd),
                    candidate(id: workoutA, strain: 14, endedAt: firstEnd),
                ]
            ) == .applied,
            "workout refresh did not apply"
        )
        var state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 100, "chronological awards did not cap at 100")
        try expect(state.workoutRewards?.processedWorkoutIDs == [workoutA, workoutB], "workouts were not consumed once in order")
        try expect(state.workoutRewards?.lastAward?.earnedCharge == 37, "last award stored the wrong earned amount")
        try expect(state.workoutRewards?.lastAward?.appliedCharge == 8, "overflow was not discarded")
        try expect(try fixture.store.readAuditEvents().count == 2, "awards did not write one audit each")

        let repeated = recovery(
            score: 70,
            updatedAt: now,
            validatedAt: now.addingTimeInterval(60)
        )
        try applyRefresh(
            fixture,
            recovery: repeated,
            candidates: [
                candidate(id: workoutA, strain: 21, endedAt: firstEnd),
                candidate(id: workoutB, strain: 21, endedAt: secondEnd),
            ]
        )
        state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 100, "duplicate refresh changed Charge")
        try expect(try fixture.store.readAuditEvents().count == 2, "duplicate refresh wrote more audits")
    }

    static func positiveAwardClearsRedirectWithoutReplay() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let initial = recovery(score: 1)
        try fixture.engine.applyRecovery(initial)
        _ = try fixture.engine.handlePrompt(
            HookInput(sessionID: "session", turnID: "spend", hookEventName: "UserPromptSubmit", prompt: "one")
        )
        _ = try fixture.engine.handlePrompt(
            HookInput(sessionID: "session", turnID: "redirect", hookEventName: "UserPromptSubmit", prompt: "two")
        )
        try expect(try fixture.engine.currentState().pendingOverride != nil, "redirect was not pending")

        let refreshed = recovery(
            score: 1,
            updatedAt: now.addingTimeInterval(-60),
            validatedAt: now
        )
        try applyRefresh(
            fixture,
            recovery: refreshed,
            candidates: [candidate(id: workoutA, strain: 10, endedAt: now.addingTimeInterval(-30 * 60))]
        )
        var state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 11, "workout did not replenish zero Charge")
        try expect(state.pendingOverride == nil, "positive award retained redirect metadata")
        try expect(
            try fixture.engine.handlePrompt(
                HookInput(sessionID: "session", turnID: "next", hookEventName: "UserPromptSubmit", prompt: "ordinary")
            ) == .passThrough,
            "post-refill prompt did not behave normally"
        )
        state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 10, "post-refill prompt did not spend exactly one")
    }

    static func offEpochRejectsRetroactiveWorkout() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let initial = recovery(score: 20)
        try fixture.engine.applyRecovery(initial)
        fixture.clock.set(now.addingTimeInterval(-2 * 60 * 60))
        try fixture.engine.setEnabled(false)
        fixture.clock.set(now.addingTimeInterval(-30 * 60))
        try fixture.engine.setEnabled(true)

        let refreshed = recovery(
            score: 20,
            updatedAt: now.addingTimeInterval(-60),
            validatedAt: now
        )
        try applyRefresh(
            fixture,
            recovery: refreshed,
            candidates: [
                candidate(id: workoutA, strain: 21, endedAt: now.addingTimeInterval(-60 * 60)),
                candidate(id: workoutB, strain: 10, endedAt: now.addingTimeInterval(-10 * 60)),
            ]
        )
        let state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 31, "Off workout was credited or On workout was missed")
        try expect(state.workoutRewards?.processedWorkoutIDs == [workoutB], "Off workout was consumed as eligible")
    }

    static func newRecoveryExcludesPriorCycleWorkout() throws {
        let fixture = try makeFixture(enabledAt: now.addingTimeInterval(-24 * 60 * 60))
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(
            recovery(cycleID: 100, score: 5, cycleStart: now.addingTimeInterval(-24 * 60 * 60))
        )
        let newCycleStart = now.addingTimeInterval(-8 * 60 * 60)
        let next = recovery(
            cycleID: 101,
            score: 40,
            cycleStart: newCycleStart,
            updatedAt: now.addingTimeInterval(-60),
            validatedAt: now
        )
        try applyRefresh(
            fixture,
            recovery: next,
            candidates: [
                candidate(id: workoutA, strain: 21, endedAt: newCycleStart.addingTimeInterval(-60)),
                candidate(id: workoutB, strain: 10, endedAt: newCycleStart.addingTimeInterval(60)),
            ]
        )
        let state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 51, "prior-cycle workout crossed the Recovery boundary")
        try expect(state.workoutRewards?.cycleID == 101, "reward epoch did not advance cycles")
        try expect(state.workoutRewards?.processedWorkoutIDs == [workoutB], "prior-cycle workout was consumed")
    }

    static func fullChargeStillConsumesWorkout() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery(score: 100))
        let endedAt = now.addingTimeInterval(-30 * 60)
        let first = recovery(score: 100, updatedAt: now.addingTimeInterval(-60), validatedAt: now)
        try applyRefresh(
            fixture,
            recovery: first,
            candidates: [candidate(id: workoutA, strain: 14, endedAt: endedAt)]
        )
        var state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 100, "full Charge changed")
        try expect(state.workoutRewards?.lastAward?.appliedCharge == 0, "full award was not recorded as overflow")

        _ = try fixture.engine.handlePrompt(
            HookInput(sessionID: "session", turnID: "spend", hookEventName: "UserPromptSubmit", prompt: "spend")
        )
        let repeated = recovery(score: 100, updatedAt: now, validatedAt: now.addingTimeInterval(60))
        try applyRefresh(
            fixture,
            recovery: repeated,
            candidates: [candidate(id: workoutA, strain: 21, endedAt: endedAt)]
        )
        state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 99, "consumed full-Charge workout awarded later")
    }

    static func awardAndAuditRollbackTogether() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.applyRecovery(recovery(score: 10))
        let refreshed = recovery(score: 10, updatedAt: now.addingTimeInterval(-60), validatedAt: now)
        fixture.clock.set(now)
        let operationID = UUID()
        guard case .started = try fixture.engine.beginSyncIfEnabled(operationID: operationID) else {
            throw Failure(description: "enabled refresh did not start")
        }
        let before = try fixture.engine.currentState()
        fixture.store.simulateNextAuditWriteFailureForTesting()

        var rejected = false
        do {
            _ = try fixture.engine.applyRecoveryAndWorkoutsIfEnabled(
                refreshed,
                workoutCandidates: [candidate(id: workoutA, strain: 14, endedAt: now.addingTimeInterval(-30 * 60))],
                syncOperationID: operationID
            )
        } catch {
            rejected = true
        }
        try expect(rejected, "simulated audit failure did not fail the award")
        try expect(try fixture.engine.currentState() == before, "failed award did not roll back exact state")
        try expect(try fixture.store.readAuditEvents().isEmpty, "failed award retained an audit")
    }

    static func legacyStateDecodesWithoutRewardEpoch() throws {
        let legacy = Data(#"{"enabled":true,"degradedWarningEmitted":false}"#.utf8)
        let state = try JSONDecoder().decode(PersistentState.self, from: legacy)
        try expect(state.enabled, "legacy enabled state changed")
        try expect(state.workoutRewards == nil, "legacy state fabricated retroactive eligibility")
    }
}

#if canImport(XCTest)
import XCTest

final class WorkoutReplenishmentTests: XCTestCase {
    func testPolicyAnchorsAndValidation() throws { try WorkoutReplenishmentTestSupport.policyAnchorsAndValidation() }
    func testChronologicalAwardsCapAndDeduplicate() throws { try WorkoutReplenishmentTestSupport.chronologicalAwardsCapAndDeduplicate() }
    func testPositiveAwardClearsRedirectWithoutReplay() throws { try WorkoutReplenishmentTestSupport.positiveAwardClearsRedirectWithoutReplay() }
    func testOffEpochRejectsRetroactiveWorkout() throws { try WorkoutReplenishmentTestSupport.offEpochRejectsRetroactiveWorkout() }
    func testNewRecoveryExcludesPriorCycleWorkout() throws { try WorkoutReplenishmentTestSupport.newRecoveryExcludesPriorCycleWorkout() }
    func testFullChargeStillConsumesWorkout() throws { try WorkoutReplenishmentTestSupport.fullChargeStillConsumesWorkout() }
    func testAwardAndAuditRollbackTogether() throws { try WorkoutReplenishmentTestSupport.awardAndAuditRollbackTogether() }
    func testLegacyStateDecodesWithoutRewardEpoch() throws { try WorkoutReplenishmentTestSupport.legacyStateDecodesWithoutRewardEpoch() }
}
#else
import Testing

@Suite struct WorkoutReplenishmentTests {
    @Test func policyAnchorsAndValidation() throws { try WorkoutReplenishmentTestSupport.policyAnchorsAndValidation() }
    @Test func chronologicalAwardsCapAndDeduplicate() throws { try WorkoutReplenishmentTestSupport.chronologicalAwardsCapAndDeduplicate() }
    @Test func positiveAwardClearsRedirectWithoutReplay() throws { try WorkoutReplenishmentTestSupport.positiveAwardClearsRedirectWithoutReplay() }
    @Test func offEpochRejectsRetroactiveWorkout() throws { try WorkoutReplenishmentTestSupport.offEpochRejectsRetroactiveWorkout() }
    @Test func newRecoveryExcludesPriorCycleWorkout() throws { try WorkoutReplenishmentTestSupport.newRecoveryExcludesPriorCycleWorkout() }
    @Test func fullChargeStillConsumesWorkout() throws { try WorkoutReplenishmentTestSupport.fullChargeStillConsumesWorkout() }
    @Test func awardAndAuditRollbackTogether() throws { try WorkoutReplenishmentTestSupport.awardAndAuditRollbackTogether() }
    @Test func legacyStateDecodesWithoutRewardEpoch() throws { try WorkoutReplenishmentTestSupport.legacyStateDecodesWithoutRewardEpoch() }
}
#endif
