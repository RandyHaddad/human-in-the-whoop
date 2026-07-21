import Dispatch
import Foundation

@testable import HumanInTheWhoopCore

private enum ChargeEngineTestSupport {
    static let now = Date(timeIntervalSince1970: 1_800_000_000.25)

    struct Fixture {
        let databaseURL: URL
        let store: SQLiteStateStore
        let engine: ChargeEngine

        func cleanUp() {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    static func makeFixture() throws -> Fixture {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.sqlite3")
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        return Fixture(
            databaseURL: databaseURL,
            store: store,
            engine: ChargeEngine(store: store, now: { now })
        )
    }

    static func recovery(
        cycleID: Int64 = 100,
        score: Int = 72,
        sleepPerformance: Double? = 91,
        cycleStrain: Double? = 4.5,
        cycleStart: Date = Date(timeIntervalSince1970: 1_799_800_000),
        validatedAt: Date = Date(timeIntervalSince1970: 1_799_999_900.25)
    ) -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: cycleID,
            sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            recoveryScore: score,
            createdAt: Date(timeIntervalSince1970: 1_799_900_000),
            updatedAt: Date(timeIntervalSince1970: 1_799_999_800),
            cycleStart: cycleStart,
            cycleEnd: nil,
            sleepPerformance: sleepPerformance,
            cycleStrain: cycleStrain,
            recentWorkout: WorkoutSnapshot(
                strain: 8.25,
                endedAt: Date(timeIntervalSince1970: 1_799_950_000)
            ),
            secondaryDataComplete: true,
            validatedAt: validatedAt
        )
    }

    static func input(
        sessionID: String = "session-a",
        turnID: String = "turn-a",
        hookEventName: String = "UserPromptSubmit",
        prompt: String = "hello"
    ) -> HookInput {
        HookInput(
            sessionID: sessionID,
            turnID: turnID,
            hookEventName: hookEventName,
            prompt: prompt
        )
    }

    static func enable(_ fixture: Fixture, recovery: RecoverySnapshot) throws {
        try fixture.engine.setEnabled(true)
        try fixture.engine.applyRecovery(recovery)
    }

    static func concurrentPromptDecisionsAtChargeOne() throws -> ([ChargeDecision], PersistentState) {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try enable(fixture, recovery: recovery(score: 1))

        let secondStore = try SQLiteStateStore(databaseURL: fixture.databaseURL)
        let secondEngine = ChargeEngine(store: secondStore, now: { now })
        let engines = [fixture.engine, secondEngine]
        let results = LockedPromptResults()
        let ready = DispatchGroup()
        let finished = DispatchGroup()
        let start = DispatchSemaphore(value: 0)

        for (index, engine) in engines.enumerated() {
            ready.enter()
            finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                ready.leave()
                start.wait()

                do {
                    let decision = try engine.handlePrompt(
                        input(
                            sessionID: "session-\(index)",
                            turnID: "turn-\(index)"
                        )
                    )
                    results.append(decision)
                } catch {
                    results.append(error: error)
                }
            }
        }

        ready.wait()
        for _ in engines {
            start.signal()
        }
        finished.wait()

        guard results.errors.isEmpty else {
            throw ConcurrentPromptFailure(descriptions: results.errors)
        }
        return (results.decisions, try fixture.engine.currentState())
    }

    private struct ConcurrentPromptFailure: Error {
        let descriptions: [String]
    }
}

private final class LockedPromptResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDecisions: [ChargeDecision] = []
    private var storedErrors: [String] = []

    var decisions: [ChargeDecision] {
        lock.withLock { storedDecisions }
    }

    var errors: [String] {
        lock.withLock { storedErrors }
    }

    func append(_ decision: ChargeDecision) {
        lock.withLock { storedDecisions.append(decision) }
    }

    func append(error: Error) {
        lock.withLock { storedErrors.append(error.localizedDescription) }
    }
}

private struct ExpectedPromptCommitError: Error {}

#if canImport(XCTest)
import XCTest

final class ChargeEngineTests: XCTestCase {
    func testHookInputUsesTheRequiredSnakeCaseCodingKeys() throws {
        let input = ChargeEngineTestSupport.input(prompt: "line one\nline two")

        let data = try JSONEncoder().encode(input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(object["session_id"], "session-a")
        XCTAssertEqual(object["turn_id"], "turn-a")
        XCTAssertEqual(object["hook_event_name"], "UserPromptSubmit")
        XCTAssertEqual(object["prompt"], "line one\nline two")
        XCTAssertEqual(try JSONDecoder().decode(HookInput.self, from: data), input)
    }

    func testThrowingPromptDecisionCallbackRollsBackEveryPromptMutation() throws {
        let positive = try ChargeEngineTestSupport.makeFixture()
        defer { positive.cleanUp() }
        try ChargeEngineTestSupport.enable(
            positive,
            recovery: ChargeEngineTestSupport.recovery(score: 2)
        )
        let positiveBefore = try positive.engine.currentState()

        XCTAssertThrowsError(
            try positive.engine.withPromptDecision(
                for: ChargeEngineTestSupport.input()
            ) { decision -> Void in
                XCTAssertEqual(decision, .passThrough)
                throw ExpectedPromptCommitError()
            }
        )
        XCTAssertEqual(try positive.engine.currentState(), positiveBefore)

        let zero = try ChargeEngineTestSupport.makeFixture()
        defer { zero.cleanUp() }
        try ChargeEngineTestSupport.enable(
            zero,
            recovery: ChargeEngineTestSupport.recovery(score: 0)
        )
        let zeroBefore = try zero.engine.currentState()

        XCTAssertThrowsError(
            try zero.engine.withPromptDecision(
                for: ChargeEngineTestSupport.input()
            ) { decision -> Void in
                guard case .redirect = decision else {
                    return XCTFail("Expected redirect, got \(decision)")
                }
                throw ExpectedPromptCommitError()
            }
        )
        XCTAssertEqual(try zero.engine.currentState(), zeroBefore)
        XCTAssertNil(try zero.engine.currentState().pendingOverride)

        let degraded = try ChargeEngineTestSupport.makeFixture()
        defer { degraded.cleanUp() }
        try degraded.engine.setEnabled(true)
        let degradedBefore = try degraded.engine.currentState()

        XCTAssertThrowsError(
            try degraded.engine.withPromptDecision(
                for: ChargeEngineTestSupport.input()
            ) { decision -> Void in
                guard case .degradedWarning = decision else {
                    return XCTFail("Expected degraded warning, got \(decision)")
                }
                throw ExpectedPromptCommitError()
            }
        )
        XCTAssertEqual(try degraded.engine.currentState(), degradedBefore)
        XCTAssertFalse(try degraded.engine.currentState().degradedWarningEmitted)
    }

    func testRecoveryInitializesChargeAndSameCycleRefreshDoesNotRefill() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let initial = ChargeEngineTestSupport.recovery(score: 72)

        try fixture.engine.setEnabled(true)
        try fixture.engine.applyRecovery(initial)
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 72)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(prompt: "")),
            .passThrough
        )

        let refreshed = ChargeEngineTestSupport.recovery(
            score: 88,
            sleepPerformance: 97,
            cycleStrain: 6.75,
            validatedAt: ChargeEngineTestSupport.now
        )
        try fixture.engine.markSyncFailure("temporary outage", invalidatesCache: false)
        try fixture.engine.applyRecovery(refreshed)

        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.recovery, refreshed)
        XCTAssertEqual(state.chargeRemaining, 71)
        XCTAssertNil(state.degradedReason)
        XCTAssertFalse(state.degradedWarningEmitted)
        XCTAssertNil(state.lastSyncError)
        XCTAssertEqual(state.lastSyncAttemptAt, refreshed.validatedAt)
        XCTAssertEqual(state.lastSyncSuccessAt, refreshed.validatedAt)
    }

    func testNewCycleResetsChargeEvenWhenRemainingChargeIsHigher() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(cycleID: 100, score: 90)
        )
        try fixture.store.mutate { state in
            state.chargeRemaining = 80
            state.pendingOverride = PendingOverride(sessionID: "old", redirectedTurnID: "old-turn")
        }
        try fixture.engine.setEnabled(false)
        try fixture.engine.setEnabled(true)
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 80)

        let nextCycle = ChargeEngineTestSupport.recovery(
            cycleID: 101,
            score: 35,
            cycleStart: Date(timeIntervalSince1970: 1_799_800_001)
        )
        try fixture.engine.applyRecovery(nextCycle)

        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.recovery, nextCycle)
        XCTAssertEqual(state.chargeRemaining, 35)
        XCTAssertNil(state.pendingOverride)
    }

    func testPromptsSpendThroughZeroThenRedirectWithoutGoingNegative() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 2)
        )

        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "turn-1")),
            .passThrough
        )
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 1)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(
                    turnID: "turn-2",
                    hookEventName: "engine-does-not-route-events",
                    prompt: "multiline\nprompt"
                )
            ),
            .passThrough
        )
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 0)

        let recovery = try XCTUnwrap(try fixture.engine.currentState().recovery)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "turn-3")),
            .redirect(recovery: recovery)
        )
        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.chargeRemaining, 0)
        XCTAssertEqual(
            state.pendingOverride,
            PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-3")
        )
    }

    func testContinueOnceIsNormalizedOneShotForThePendingSession() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 0)
        )
        _ = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "redirected"))

        XCTAssertEqual(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "override", prompt: " \n CoNtInUe OnCe\t")
            ),
            .continueOnce
        )
        var state = try fixture.engine.currentState()
        XCTAssertEqual(state.chargeRemaining, 0)
        XCTAssertNil(state.pendingOverride)

        let recovery = try XCTUnwrap(state.recovery)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "after-override")),
            .redirect(recovery: recovery)
        )
        state = try fixture.engine.currentState()
        XCTAssertEqual(state.chargeRemaining, 0)
        XCTAssertEqual(state.pendingOverride?.redirectedTurnID, "after-override")
    }

    func testOverrideIsAdvertisedOnlyAfterThreeConsecutiveRedirectsInOneSession() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 0)
        )
        let recovery = try XCTUnwrap(try fixture.engine.currentState().recovery)

        XCTAssertEqual(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "first")
            ),
            .redirect(recovery: recovery)
        )
        XCTAssertEqual(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount, 1)

        XCTAssertEqual(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "second")
            ),
            .redirect(recovery: recovery)
        )
        XCTAssertEqual(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount, 2)

        XCTAssertEqual(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "third")
            ),
            .repeatedRedirect(recovery: recovery)
        )
        XCTAssertEqual(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount, 3)

        XCTAssertEqual(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(
                    sessionID: "different-session",
                    turnID: "new-session"
                )
            ),
            .redirect(recovery: recovery)
        )
        XCTAssertEqual(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount, 1)
    }

    func testLegacyPendingOverrideDefaultsToFirstRedirect() throws {
        let data = Data(
            #"{"sessionID":"session-a","redirectedTurnID":"turn-a"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(PendingOverride.self, from: data)

        XCTAssertEqual(decoded.consecutiveRedirectCount, 1)
    }

    func testContinueOnceTextAtPositiveChargeSpendsAndPassesThroughNormally() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 2)
        )
        let pending = PendingOverride(sessionID: "session-a", redirectedTurnID: "earlier-turn")
        try fixture.store.mutate { state in
            state.pendingOverride = pending
        }

        XCTAssertEqual(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "current-turn", prompt: " \n CONTINUE ONCE\t")
            ),
            .passThrough
        )
        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.chargeRemaining, 1)
        XCTAssertEqual(state.pendingOverride, pending)
    }

    func testUnmatchedContinueOncePreservesPendingRedirect() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 0)
        )
        _ = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "original"))
        let pending = try XCTUnwrap(try fixture.engine.currentState().pendingOverride)

        let decision = try fixture.engine.handlePrompt(
            ChargeEngineTestSupport.input(
                sessionID: "session-b",
                turnID: "wrong-session",
                prompt: "continue once"
            )
        )
        guard case let .nothingToContinue(message) = decision else {
            return XCTFail("Expected nothingToContinue, got \(decision)")
        }
        XCTAssertFalse(message.isEmpty)
        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.chargeRemaining, 0)
        XCTAssertEqual(state.pendingOverride, pending)
    }

    func testSoftOffReenableRequiresRefreshThenResumesSameCycleCharge() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let recovery = ChargeEngineTestSupport.recovery(score: 2)
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: recovery
        )
        let active = try fixture.engine.currentState()
        try fixture.engine.setEnabled(true)
        XCTAssertEqual(try fixture.engine.currentState(), active)

        let pending = PendingOverride(sessionID: "session-a", redirectedTurnID: "earlier-turn")
        try fixture.store.mutate { state in
            state.pendingOverride = pending
        }
        try fixture.engine.setEnabled(false)
        let paused = try fixture.engine.currentState()

        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input()),
            .passThrough
        )
        XCTAssertEqual(try fixture.engine.currentState(), paused)

        try fixture.engine.setEnabled(true)
        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.recovery, recovery)
        XCTAssertEqual(state.chargeRemaining, 2)
        XCTAssertEqual(state.pendingOverride, pending)
        XCTAssertFalse(state.degradedWarningEmitted)
        XCTAssertEqual(state.lastSyncError, SyncFailureReason.refreshRequired.rawValue)

        let warning = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "refresh-1"))
        guard case let .degradedWarning(message) = warning else {
            return XCTFail("Expected refresh-required warning, got \(warning)")
        }
        XCTAssertEqual(message, SyncFailureReason.refreshRequired.userMessage)
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 2)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "refresh-2")),
            .passThrough
        )
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 2)

        try fixture.engine.setEnabled(true)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "already-enabled")),
            .passThrough
        )
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 2)

        try fixture.engine.applyRecovery(
            ChargeEngineTestSupport.recovery(score: 99, validatedAt: ChargeEngineTestSupport.now)
        )
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 2)
        XCTAssertEqual(try fixture.engine.currentState().pendingOverride, pending)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "resumed")),
            .passThrough
        )
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 1)
        XCTAssertEqual(try fixture.engine.currentState().pendingOverride, pending)
    }

    func testDegradedWarningEmitsOncePerActiveEpochEvenWhenReasonChanges() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let recovery = ChargeEngineTestSupport.recovery(score: 72)
        try ChargeEngineTestSupport.enable(fixture, recovery: recovery)
        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)

        let first = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "first"))
        guard case let .degradedWarning(message) = first else {
            return XCTFail("Expected degradedWarning, got \(first)")
        }
        XCTAssertEqual(message, SyncFailureReason.unavailable.userMessage)
        XCTAssertTrue(try fixture.engine.currentState().degradedWarningEmitted)

        try fixture.engine.markSyncFailure(.authentication, invalidatesCache: false)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "second")),
            .passThrough
        )
        XCTAssertTrue(try fixture.engine.currentState().degradedWarningEmitted)

        try fixture.engine.applyRecovery(recovery)
        try fixture.engine.markSyncFailure(.rateLimited, invalidatesCache: false)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "third")),
            .degradedWarning(message: SyncFailureReason.rateLimited.userMessage)
        )
    }

    func testNoninvalidatingFailurePreservesCacheButDegrades() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let recovery = ChargeEngineTestSupport.recovery(score: 72)
        try ChargeEngineTestSupport.enable(fixture, recovery: recovery)

        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)

        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.recovery, recovery)
        XCTAssertEqual(state.chargeRemaining, 72)
        XCTAssertEqual(state.degradedReason, SyncFailureReason.unavailable.userMessage)
        XCTAssertEqual(state.lastSyncAttemptAt, ChargeEngineTestSupport.now)
        XCTAssertEqual(state.lastSyncError, SyncFailureReason.unavailable.rawValue)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input()),
            .degradedWarning(message: SyncFailureReason.unavailable.userMessage)
        )
        XCTAssertEqual(try fixture.engine.currentState().chargeRemaining, 72)
    }

    func testInvalidatingFailureClearsCachedChargeRecoveryAndPending() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 0)
        )
        _ = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input())

        try fixture.engine.markSyncFailure(.authentication, invalidatesCache: true)

        let state = try fixture.engine.currentState()
        XCTAssertNil(state.recovery)
        XCTAssertNil(state.chargeRemaining)
        XCTAssertNil(state.pendingOverride)
        XCTAssertEqual(state.degradedReason, SyncFailureReason.authentication.userMessage)
        XCTAssertEqual(state.lastSyncError, SyncFailureReason.authentication.rawValue)
        XCTAssertFalse(state.degradedWarningEmitted)
    }

    func testRawSyncFailureTextIsNeverPersistedOrDisplayed() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 72)
        )
        let rawSecret = "Authorization: Bearer sk-live-super-secret"

        try fixture.engine.markSyncFailure(rawSecret, invalidatesCache: false)

        let state = try fixture.engine.currentState()
        let encodedState = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
        XCTAssertFalse(encodedState.contains(rawSecret))
        XCTAssertEqual(state.lastSyncError, SyncFailureReason.unavailable.rawValue)
        XCTAssertEqual(state.degradedReason, SyncFailureReason.unavailable.userMessage)
        let decision = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input())
        guard case let .degradedWarning(message) = decision else {
            return XCTFail("Expected sanitized degraded warning, got \(decision)")
        }
        XCTAssertFalse(message.contains(rawSecret))
        XCTAssertEqual(message, SyncFailureReason.unavailable.userMessage)
    }

    func testResetDemoUsesCurrentRecoveryClearsPendingAndWritesLocalAudit() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 64)
        )
        try fixture.store.mutate { state in
            state.chargeRemaining = 0
            state.pendingOverride = PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a")
            state.degradedWarningEmitted = true
        }

        XCTAssertEqual(try fixture.engine.resetDemo(), 64)

        let state = try fixture.engine.currentState()
        XCTAssertEqual(state.chargeRemaining, 64)
        XCTAssertNil(state.pendingOverride)
        XCTAssertFalse(state.degradedWarningEmitted)
        let events = try fixture.store.readAuditEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].name, "charge.demo_reset")
        XCTAssertEqual(events[0].occurredAt, ChargeEngineTestSupport.now)
        XCTAssertEqual(events[0].metadata["reset_source"], "demo_manual")
        XCTAssertEqual(events[0].metadata["current_score"], "64")
        XCTAssertFalse(events[0].metadata["reset_at", default: ""].isEmpty)
    }

    func testResetDemoAtomicallyRejectsActiveDegradedEpoch() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 40)
        )
        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)
        XCTAssertEqual(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "warned")),
            .degradedWarning(message: SyncFailureReason.unavailable.userMessage)
        )
        try fixture.store.mutate { state in
            state.chargeRemaining = 0
            state.pendingOverride = PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a")
        }
        let before = try fixture.engine.currentState()

        XCTAssertThrowsError(try fixture.engine.resetDemo())
        XCTAssertEqual(try fixture.engine.currentState(), before)
        XCTAssertTrue(try fixture.store.readAuditEvents().isEmpty)
    }

    func testResetDemoDisabledOrWithoutRecoveryThrowsWithoutMutation() throws {
        let disabled = try ChargeEngineTestSupport.makeFixture()
        defer { disabled.cleanUp() }
        try disabled.engine.applyRecovery(ChargeEngineTestSupport.recovery(score: 40))
        let disabledBefore = try disabled.engine.currentState()
        XCTAssertThrowsError(try disabled.engine.resetDemo()) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(try disabled.engine.currentState(), disabledBefore)
        XCTAssertTrue(try disabled.store.readAuditEvents().isEmpty)

        let missingRecovery = try ChargeEngineTestSupport.makeFixture()
        defer { missingRecovery.cleanUp() }
        try missingRecovery.engine.setEnabled(true)
        let missingBefore = try missingRecovery.engine.currentState()
        XCTAssertThrowsError(try missingRecovery.engine.resetDemo()) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(try missingRecovery.engine.currentState(), missingBefore)
        XCTAssertTrue(try missingRecovery.store.readAuditEvents().isEmpty)
    }

    func testResetDemoAtomicallyRejectsEndedRecovery() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 72)
        )
        try fixture.store.mutate { state in
            state.chargeRemaining = 18
            state.recovery?.cycleEnd = ChargeEngineTestSupport.now
        }
        let before = try fixture.engine.currentState()

        XCTAssertThrowsError(try fixture.engine.resetDemo())
        XCTAssertEqual(try fixture.engine.currentState(), before)
        XCTAssertTrue(try fixture.store.readAuditEvents().isEmpty)
    }

    func testResetDemoRollsBackStateWhenAtomicAuditWriteFails() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 58)
        )
        try fixture.store.mutate { state in
            state.chargeRemaining = 0
            state.pendingOverride = PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a")
        }
        let before = try fixture.engine.currentState()
        fixture.store.simulateNextAuditWriteFailureForTesting()

        XCTAssertThrowsError(try fixture.engine.resetDemo())

        XCTAssertEqual(try fixture.engine.currentState(), before)
        XCTAssertTrue(try fixture.store.readAuditEvents().isEmpty)
    }

    func testInvalidRecoveryScoresAreRejectedWithoutChangingState() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 50)
        )

        for score in [-1, 101] {
            let before = try fixture.engine.currentState()
            XCTAssertThrowsError(
                try fixture.engine.applyRecovery(
                    ChargeEngineTestSupport.recovery(cycleID: Int64(200 + score), score: score)
                )
            )
            XCTAssertEqual(try fixture.engine.currentState(), before)
        }
    }

    func testResetDemoRejectsCorruptRecoveryScoreWithoutStateOrAuditChanges() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(score: 50)
        )
        try fixture.store.mutate { state in
            state.recovery?.recoveryScore = 101
            state.chargeRemaining = 0
        }
        let before = try fixture.engine.currentState()

        XCTAssertThrowsError(try fixture.engine.resetDemo())

        XCTAssertEqual(try fixture.engine.currentState(), before)
        XCTAssertTrue(try fixture.store.readAuditEvents().isEmpty)
    }

    func testCorruptPersistedChargeFailsOpenWithOneSanitizedWarning() throws {
        for corruptCharge in [-1, 101] {
            let fixture = try ChargeEngineTestSupport.makeFixture()
            defer { fixture.cleanUp() }
            try ChargeEngineTestSupport.enable(
                fixture,
                recovery: ChargeEngineTestSupport.recovery(score: 50)
            )
            try fixture.store.mutate { state in
                state.chargeRemaining = corruptCharge
            }

            XCTAssertEqual(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "corrupt-1")),
                .degradedWarning(message: SyncFailureReason.ledgerCorrupt.userMessage)
            )
            var state = try fixture.engine.currentState()
            XCTAssertEqual(state.chargeRemaining, corruptCharge)
            XCTAssertNil(state.pendingOverride)
            XCTAssertEqual(state.lastSyncError, SyncFailureReason.ledgerCorrupt.rawValue)
            XCTAssertEqual(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "corrupt-2")),
                .passThrough
            )
            state = try fixture.engine.currentState()
            XCTAssertEqual(state.chargeRemaining, corruptCharge)
            XCTAssertNil(state.pendingOverride)
        }
    }

    func testCorruptPersistedRecoveryBlocksSpendOverrideAndRedirect() throws {
        for (corruptScore, charge) in [(-1, 2), (101, 0)] {
            let fixture = try ChargeEngineTestSupport.makeFixture()
            defer { fixture.cleanUp() }
            try ChargeEngineTestSupport.enable(
                fixture,
                recovery: ChargeEngineTestSupport.recovery(score: 50)
            )
            let pending = PendingOverride(sessionID: "session-a", redirectedTurnID: "earlier-turn")
            try fixture.store.mutate { state in
                state.recovery?.recoveryScore = corruptScore
                state.chargeRemaining = charge
                if charge == 0 {
                    state.pendingOverride = pending
                }
            }
            let prompt = charge == 0 ? "continue once" : "ordinary prompt"

            XCTAssertEqual(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(prompt: prompt)),
                .degradedWarning(message: SyncFailureReason.ledgerCorrupt.userMessage)
            )
            var state = try fixture.engine.currentState()
            XCTAssertEqual(state.recovery?.recoveryScore, corruptScore)
            XCTAssertEqual(state.chargeRemaining, charge)
            XCTAssertEqual(state.pendingOverride, charge == 0 ? pending : nil)
            XCTAssertEqual(
                try fixture.engine.handlePrompt(
                    ChargeEngineTestSupport.input(turnID: "second", prompt: "ordinary prompt")
                ),
                .passThrough
            )
            state = try fixture.engine.currentState()
            XCTAssertEqual(state.recovery?.recoveryScore, corruptScore)
            XCTAssertEqual(state.chargeRemaining, charge)
            XCTAssertEqual(state.pendingOverride, charge == 0 ? pending : nil)
        }
    }

    func testSameCycleRefreshWithInvalidRetainedChargeStaysLedgerCorruptWithoutRefillOrSpam() throws {
        let retainedCharges: [Int?] = [nil, 101]

        for retainedCharge in retainedCharges {
            let fixture = try ChargeEngineTestSupport.makeFixture()
            defer { fixture.cleanUp() }
            let initial = ChargeEngineTestSupport.recovery(score: 72)
            try ChargeEngineTestSupport.enable(fixture, recovery: initial)
            try fixture.store.mutate { state in
                state.chargeRemaining = retainedCharge
            }

            let firstRefresh = ChargeEngineTestSupport.recovery(
                score: 88,
                validatedAt: ChargeEngineTestSupport.now
            )
            try fixture.engine.applyRecovery(firstRefresh)

            var state = try fixture.engine.currentState()
            XCTAssertEqual(state.recovery, firstRefresh)
            XCTAssertEqual(state.chargeRemaining, retainedCharge)
            XCTAssertEqual(state.degradedReason, SyncFailureReason.ledgerCorrupt.userMessage)
            XCTAssertFalse(state.degradedWarningEmitted)
            XCTAssertEqual(state.lastSyncAttemptAt, firstRefresh.validatedAt)
            XCTAssertEqual(state.lastSyncSuccessAt, initial.validatedAt)
            XCTAssertEqual(state.lastSyncError, SyncFailureReason.ledgerCorrupt.rawValue)
            XCTAssertEqual(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "warn")),
                .degradedWarning(message: SyncFailureReason.ledgerCorrupt.userMessage)
            )

            let repeatedRefresh = ChargeEngineTestSupport.recovery(
                score: 89,
                validatedAt: ChargeEngineTestSupport.now.addingTimeInterval(60)
            )
            try fixture.engine.applyRecovery(repeatedRefresh)

            state = try fixture.engine.currentState()
            XCTAssertEqual(state.recovery, repeatedRefresh)
            XCTAssertEqual(state.chargeRemaining, retainedCharge)
            XCTAssertEqual(state.degradedReason, SyncFailureReason.ledgerCorrupt.userMessage)
            XCTAssertTrue(state.degradedWarningEmitted)
            XCTAssertEqual(state.lastSyncAttemptAt, repeatedRefresh.validatedAt)
            XCTAssertEqual(state.lastSyncSuccessAt, initial.validatedAt)
            XCTAssertEqual(state.lastSyncError, SyncFailureReason.ledgerCorrupt.rawValue)
            XCTAssertEqual(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "no-spam")),
                .passThrough
            )
        }
    }

    func testConcurrentPromptsAtOneSpendOnceThenRedirect() throws {
        let (decisions, state) = try ChargeEngineTestSupport.concurrentPromptDecisionsAtChargeOne()

        XCTAssertEqual(decisions.filter { $0 == .passThrough }.count, 1)
        XCTAssertEqual(
            decisions.filter {
                if case .redirect = $0 { return true }
                return false
            }.count,
            1
        )
        XCTAssertEqual(state.chargeRemaining, 0)
    }
}
#else
import Testing

@Suite struct ChargeEngineTests {
    @Test func hookInputUsesTheRequiredSnakeCaseCodingKeys() throws {
        let input = ChargeEngineTestSupport.input(prompt: "line one\nline two")
        let data = try JSONEncoder().encode(input)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(object["session_id"] == "session-a")
        #expect(object["turn_id"] == "turn-a")
        #expect(object["hook_event_name"] == "UserPromptSubmit")
        #expect(object["prompt"] == "line one\nline two")
        #expect(try JSONDecoder().decode(HookInput.self, from: data) == input)
    }

    @Test func throwingPromptDecisionCallbackRollsBackEveryPromptMutation() throws {
        let positive = try ChargeEngineTestSupport.makeFixture()
        defer { positive.cleanUp() }
        try ChargeEngineTestSupport.enable(
            positive,
            recovery: ChargeEngineTestSupport.recovery(score: 2)
        )
        let positiveBefore = try positive.engine.currentState()

        #expect(throws: ExpectedPromptCommitError.self) {
            try positive.engine.withPromptDecision(
                for: ChargeEngineTestSupport.input()
            ) { decision -> Void in
                #expect(decision == .passThrough)
                throw ExpectedPromptCommitError()
            }
        }
        #expect(try positive.engine.currentState() == positiveBefore)

        let zero = try ChargeEngineTestSupport.makeFixture()
        defer { zero.cleanUp() }
        try ChargeEngineTestSupport.enable(
            zero,
            recovery: ChargeEngineTestSupport.recovery(score: 0)
        )
        let zeroBefore = try zero.engine.currentState()

        #expect(throws: ExpectedPromptCommitError.self) {
            try zero.engine.withPromptDecision(
                for: ChargeEngineTestSupport.input()
            ) { decision -> Void in
                guard case .redirect = decision else {
                    Issue.record("Expected redirect, got \(decision)")
                    return
                }
                throw ExpectedPromptCommitError()
            }
        }
        #expect(try zero.engine.currentState() == zeroBefore)
        #expect(try zero.engine.currentState().pendingOverride == nil)

        let degraded = try ChargeEngineTestSupport.makeFixture()
        defer { degraded.cleanUp() }
        try degraded.engine.setEnabled(true)
        let degradedBefore = try degraded.engine.currentState()

        #expect(throws: ExpectedPromptCommitError.self) {
            try degraded.engine.withPromptDecision(
                for: ChargeEngineTestSupport.input()
            ) { decision -> Void in
                guard case .degradedWarning = decision else {
                    Issue.record("Expected degraded warning, got \(decision)")
                    return
                }
                throw ExpectedPromptCommitError()
            }
        }
        #expect(try degraded.engine.currentState() == degradedBefore)
        #expect(try degraded.engine.currentState().degradedWarningEmitted == false)
    }

    @Test func recoveryInitializesChargeAndSameCycleRefreshDoesNotRefill() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let initial = ChargeEngineTestSupport.recovery(score: 72)

        try fixture.engine.setEnabled(true)
        try fixture.engine.applyRecovery(initial)
        #expect(try fixture.engine.currentState().chargeRemaining == 72)
        #expect(try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(prompt: "")) == .passThrough)

        let refreshed = ChargeEngineTestSupport.recovery(
            score: 88,
            sleepPerformance: 97,
            cycleStrain: 6.75,
            validatedAt: ChargeEngineTestSupport.now
        )
        try fixture.engine.markSyncFailure("temporary outage", invalidatesCache: false)
        try fixture.engine.applyRecovery(refreshed)

        let state = try fixture.engine.currentState()
        #expect(state.recovery == refreshed)
        #expect(state.chargeRemaining == 71)
        #expect(state.degradedReason == nil)
        #expect(state.degradedWarningEmitted == false)
        #expect(state.lastSyncError == nil)
        #expect(state.lastSyncAttemptAt == refreshed.validatedAt)
        #expect(state.lastSyncSuccessAt == refreshed.validatedAt)
    }

    @Test func newCycleResetsChargeEvenWhenRemainingChargeIsHigher() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(
            fixture,
            recovery: ChargeEngineTestSupport.recovery(cycleID: 100, score: 90)
        )
        try fixture.store.mutate { state in
            state.chargeRemaining = 80
            state.pendingOverride = PendingOverride(sessionID: "old", redirectedTurnID: "old-turn")
        }
        try fixture.engine.setEnabled(false)
        try fixture.engine.setEnabled(true)
        #expect(try fixture.engine.currentState().chargeRemaining == 80)

        let nextCycle = ChargeEngineTestSupport.recovery(
            cycleID: 101,
            score: 35,
            cycleStart: Date(timeIntervalSince1970: 1_799_800_001)
        )
        try fixture.engine.applyRecovery(nextCycle)
        let state = try fixture.engine.currentState()
        #expect(state.recovery == nextCycle)
        #expect(state.chargeRemaining == 35)
        #expect(state.pendingOverride == nil)
    }

    @Test func promptsSpendThroughZeroThenRedirectWithoutGoingNegative() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 2))

        #expect(try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "turn-1")) == .passThrough)
        #expect(try fixture.engine.currentState().chargeRemaining == 1)
        #expect(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(
                    turnID: "turn-2",
                    hookEventName: "engine-does-not-route-events",
                    prompt: "multiline\nprompt"
                )
            ) == .passThrough
        )
        #expect(try fixture.engine.currentState().chargeRemaining == 0)

        let recovery = try #require(try fixture.engine.currentState().recovery)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "turn-3"))
                == .redirect(recovery: recovery)
        )
        let state = try fixture.engine.currentState()
        #expect(state.chargeRemaining == 0)
        #expect(state.pendingOverride == PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-3"))
    }

    @Test func continueOnceIsNormalizedOneShotForThePendingSession() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 0))
        _ = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "redirected"))

        #expect(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "override", prompt: " \n CoNtInUe OnCe\t")
            ) == .continueOnce
        )
        var state = try fixture.engine.currentState()
        #expect(state.chargeRemaining == 0)
        #expect(state.pendingOverride == nil)

        let recovery = try #require(state.recovery)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "after-override"))
                == .redirect(recovery: recovery)
        )
        state = try fixture.engine.currentState()
        #expect(state.chargeRemaining == 0)
        #expect(state.pendingOverride?.redirectedTurnID == "after-override")
    }

    @Test func overrideIsAdvertisedOnlyAfterThreeConsecutiveRedirectsInOneSession() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 0))
        let recovery = try #require(try fixture.engine.currentState().recovery)

        #expect(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "first")
            ) == .redirect(recovery: recovery)
        )
        #expect(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount == 1)

        #expect(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "second")
            ) == .redirect(recovery: recovery)
        )
        #expect(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount == 2)

        #expect(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "third")
            ) == .repeatedRedirect(recovery: recovery)
        )
        #expect(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount == 3)

        #expect(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(
                    sessionID: "different-session",
                    turnID: "new-session"
                )
            ) == .redirect(recovery: recovery)
        )
        #expect(try fixture.engine.currentState().pendingOverride?.consecutiveRedirectCount == 1)
    }

    @Test func legacyPendingOverrideDefaultsToFirstRedirect() throws {
        let data = Data(
            #"{"sessionID":"session-a","redirectedTurnID":"turn-a"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(PendingOverride.self, from: data)

        #expect(decoded.consecutiveRedirectCount == 1)
    }

    @Test func continueOnceTextAtPositiveChargeSpendsAndPassesThroughNormally() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 2))
        let pending = PendingOverride(sessionID: "session-a", redirectedTurnID: "earlier-turn")
        try fixture.store.mutate { state in
            state.pendingOverride = pending
        }

        #expect(
            try fixture.engine.handlePrompt(
                ChargeEngineTestSupport.input(turnID: "current-turn", prompt: " \n CONTINUE ONCE\t")
            ) == .passThrough
        )
        let state = try fixture.engine.currentState()
        #expect(state.chargeRemaining == 1)
        #expect(state.pendingOverride == pending)
    }

    @Test func unmatchedContinueOncePreservesPendingRedirect() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 0))
        _ = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "original"))
        let pending = try #require(try fixture.engine.currentState().pendingOverride)

        let decision = try fixture.engine.handlePrompt(
            ChargeEngineTestSupport.input(
                sessionID: "session-b",
                turnID: "wrong-session",
                prompt: "continue once"
            )
        )
        guard case let .nothingToContinue(message) = decision else {
            Issue.record("Expected nothingToContinue, got \(decision)")
            return
        }
        #expect(message.isEmpty == false)
        let state = try fixture.engine.currentState()
        #expect(state.chargeRemaining == 0)
        #expect(state.pendingOverride == pending)
    }

    @Test func softOffReenableRequiresRefreshThenResumesSameCycleCharge() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let recovery = ChargeEngineTestSupport.recovery(score: 2)
        try ChargeEngineTestSupport.enable(fixture, recovery: recovery)
        let active = try fixture.engine.currentState()
        try fixture.engine.setEnabled(true)
        #expect(try fixture.engine.currentState() == active)

        let pending = PendingOverride(sessionID: "session-a", redirectedTurnID: "earlier-turn")
        try fixture.store.mutate { state in
            state.pendingOverride = pending
        }
        try fixture.engine.setEnabled(false)
        let paused = try fixture.engine.currentState()

        #expect(try fixture.engine.handlePrompt(ChargeEngineTestSupport.input()) == .passThrough)
        #expect(try fixture.engine.currentState() == paused)

        try fixture.engine.setEnabled(true)
        let state = try fixture.engine.currentState()
        #expect(state.recovery == recovery)
        #expect(state.chargeRemaining == 2)
        #expect(state.pendingOverride == pending)
        #expect(state.degradedWarningEmitted == false)
        #expect(state.lastSyncError == SyncFailureReason.refreshRequired.rawValue)

        let warning = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "refresh-1"))
        guard case let .degradedWarning(message) = warning else {
            Issue.record("Expected refresh-required warning, got \(warning)")
            return
        }
        #expect(message == SyncFailureReason.refreshRequired.userMessage)
        #expect(try fixture.engine.currentState().chargeRemaining == 2)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "refresh-2")) == .passThrough
        )
        #expect(try fixture.engine.currentState().chargeRemaining == 2)

        try fixture.engine.setEnabled(true)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "already-enabled")) == .passThrough
        )
        #expect(try fixture.engine.currentState().chargeRemaining == 2)

        try fixture.engine.applyRecovery(
            ChargeEngineTestSupport.recovery(score: 99, validatedAt: ChargeEngineTestSupport.now)
        )
        #expect(try fixture.engine.currentState().chargeRemaining == 2)
        #expect(try fixture.engine.currentState().pendingOverride == pending)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "resumed")) == .passThrough
        )
        #expect(try fixture.engine.currentState().chargeRemaining == 1)
        #expect(try fixture.engine.currentState().pendingOverride == pending)
    }

    @Test func degradedWarningEmitsOncePerActiveEpochEvenWhenReasonChanges() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let recovery = ChargeEngineTestSupport.recovery(score: 72)
        try ChargeEngineTestSupport.enable(fixture, recovery: recovery)
        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)

        let first = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "first"))
        guard case let .degradedWarning(message) = first else {
            Issue.record("Expected degradedWarning, got \(first)")
            return
        }
        #expect(message == SyncFailureReason.unavailable.userMessage)
        #expect(try fixture.engine.currentState().degradedWarningEmitted)

        try fixture.engine.markSyncFailure(.authentication, invalidatesCache: false)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "second")) == .passThrough
        )
        #expect(try fixture.engine.currentState().degradedWarningEmitted)

        try fixture.engine.applyRecovery(recovery)
        try fixture.engine.markSyncFailure(.rateLimited, invalidatesCache: false)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "third"))
                == .degradedWarning(message: SyncFailureReason.rateLimited.userMessage)
        )
    }

    @Test func noninvalidatingFailurePreservesCacheButDegrades() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        let recovery = ChargeEngineTestSupport.recovery(score: 72)
        try ChargeEngineTestSupport.enable(fixture, recovery: recovery)

        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)
        let state = try fixture.engine.currentState()
        #expect(state.recovery == recovery)
        #expect(state.chargeRemaining == 72)
        #expect(state.degradedReason == SyncFailureReason.unavailable.userMessage)
        #expect(state.lastSyncAttemptAt == ChargeEngineTestSupport.now)
        #expect(state.lastSyncError == SyncFailureReason.unavailable.rawValue)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input())
                == .degradedWarning(message: SyncFailureReason.unavailable.userMessage)
        )
        #expect(try fixture.engine.currentState().chargeRemaining == 72)
    }

    @Test func invalidatingFailureClearsCachedChargeRecoveryAndPending() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 0))
        _ = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input())

        try fixture.engine.markSyncFailure(.authentication, invalidatesCache: true)
        let state = try fixture.engine.currentState()
        #expect(state.recovery == nil)
        #expect(state.chargeRemaining == nil)
        #expect(state.pendingOverride == nil)
        #expect(state.degradedReason == SyncFailureReason.authentication.userMessage)
        #expect(state.lastSyncError == SyncFailureReason.authentication.rawValue)
        #expect(state.degradedWarningEmitted == false)
    }

    @Test func rawSyncFailureTextIsNeverPersistedOrDisplayed() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 72))
        let rawSecret = "Authorization: Bearer sk-live-super-secret"

        try fixture.engine.markSyncFailure(rawSecret, invalidatesCache: false)

        let state = try fixture.engine.currentState()
        let encodedState = try #require(String(data: JSONEncoder().encode(state), encoding: .utf8))
        #expect(encodedState.contains(rawSecret) == false)
        #expect(state.lastSyncError == SyncFailureReason.unavailable.rawValue)
        #expect(state.degradedReason == SyncFailureReason.unavailable.userMessage)
        let decision = try fixture.engine.handlePrompt(ChargeEngineTestSupport.input())
        guard case let .degradedWarning(message) = decision else {
            Issue.record("Expected sanitized degraded warning, got \(decision)")
            return
        }
        #expect(message.contains(rawSecret) == false)
        #expect(message == SyncFailureReason.unavailable.userMessage)
    }

    @Test func resetDemoUsesCurrentRecoveryClearsPendingAndWritesLocalAudit() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 64))
        try fixture.store.mutate { state in
            state.chargeRemaining = 0
            state.pendingOverride = PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a")
            state.degradedWarningEmitted = true
        }

        #expect(try fixture.engine.resetDemo() == 64)
        let state = try fixture.engine.currentState()
        #expect(state.chargeRemaining == 64)
        #expect(state.pendingOverride == nil)
        #expect(state.degradedWarningEmitted == false)
        let events = try fixture.store.readAuditEvents()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.name == "charge.demo_reset")
        #expect(event.occurredAt == ChargeEngineTestSupport.now)
        #expect(event.metadata["reset_source"] == "demo_manual")
        #expect(event.metadata["current_score"] == "64")
        #expect(event.metadata["reset_at", default: ""].isEmpty == false)
    }

    @Test func resetDemoAtomicallyRejectsActiveDegradedEpoch() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 40))
        try fixture.engine.markSyncFailure(.unavailable, invalidatesCache: false)
        #expect(
            try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "warned"))
                == .degradedWarning(message: SyncFailureReason.unavailable.userMessage)
        )
        try fixture.store.mutate { state in
            state.chargeRemaining = 0
            state.pendingOverride = PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a")
        }
        let before = try fixture.engine.currentState()

        do {
            _ = try fixture.engine.resetDemo()
            Issue.record("Expected degraded Demo Reset to throw")
        } catch {}
        #expect(try fixture.engine.currentState() == before)
        #expect(try fixture.store.readAuditEvents().isEmpty)
    }

    @Test func resetDemoDisabledOrWithoutRecoveryThrowsWithoutMutation() throws {
        let disabled = try ChargeEngineTestSupport.makeFixture()
        defer { disabled.cleanUp() }
        try disabled.engine.applyRecovery(ChargeEngineTestSupport.recovery(score: 40))
        let disabledBefore = try disabled.engine.currentState()
        do {
            _ = try disabled.engine.resetDemo()
            Issue.record("Expected disabled reset to throw")
        } catch {
            #expect(error.localizedDescription.isEmpty == false)
        }
        #expect(try disabled.engine.currentState() == disabledBefore)
        #expect(try disabled.store.readAuditEvents().isEmpty)

        let missingRecovery = try ChargeEngineTestSupport.makeFixture()
        defer { missingRecovery.cleanUp() }
        try missingRecovery.engine.setEnabled(true)
        let missingBefore = try missingRecovery.engine.currentState()
        do {
            _ = try missingRecovery.engine.resetDemo()
            Issue.record("Expected reset without Recovery to throw")
        } catch {
            #expect(error.localizedDescription.isEmpty == false)
        }
        #expect(try missingRecovery.engine.currentState() == missingBefore)
        #expect(try missingRecovery.store.readAuditEvents().isEmpty)
    }

    @Test func resetDemoAtomicallyRejectsEndedRecovery() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 72))
        try fixture.store.mutate { state in
            state.chargeRemaining = 18
            state.recovery?.cycleEnd = ChargeEngineTestSupport.now
        }
        let before = try fixture.engine.currentState()

        do {
            _ = try fixture.engine.resetDemo()
            Issue.record("Expected ended Recovery Demo Reset to throw")
        } catch {}
        #expect(try fixture.engine.currentState() == before)
        #expect(try fixture.store.readAuditEvents().isEmpty)
    }

    @Test func resetDemoRollsBackStateWhenAtomicAuditWriteFails() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 58))
        try fixture.store.mutate { state in
            state.chargeRemaining = 0
            state.pendingOverride = PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a")
        }
        let before = try fixture.engine.currentState()
        fixture.store.simulateNextAuditWriteFailureForTesting()

        do {
            _ = try fixture.engine.resetDemo()
            Issue.record("Expected the atomic audit write to fail")
        } catch {}

        #expect(try fixture.engine.currentState() == before)
        #expect(try fixture.store.readAuditEvents().isEmpty)
    }

    @Test func invalidRecoveryScoresAreRejectedWithoutChangingState() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 50))

        for score in [-1, 101] {
            let before = try fixture.engine.currentState()
            do {
                try fixture.engine.applyRecovery(
                    ChargeEngineTestSupport.recovery(cycleID: Int64(200 + score), score: score)
                )
                Issue.record("Expected invalid Recovery score \(score) to throw")
            } catch {}
            #expect(try fixture.engine.currentState() == before)
        }
    }

    @Test func resetDemoRejectsCorruptRecoveryScoreWithoutStateOrAuditChanges() throws {
        let fixture = try ChargeEngineTestSupport.makeFixture()
        defer { fixture.cleanUp() }
        try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 50))
        try fixture.store.mutate { state in
            state.recovery?.recoveryScore = 101
            state.chargeRemaining = 0
        }
        let before = try fixture.engine.currentState()

        do {
            _ = try fixture.engine.resetDemo()
            Issue.record("Expected corrupt Recovery score to reject reset")
        } catch {}

        #expect(try fixture.engine.currentState() == before)
        #expect(try fixture.store.readAuditEvents().isEmpty)
    }

    @Test func corruptPersistedChargeFailsOpenWithOneSanitizedWarning() throws {
        for corruptCharge in [-1, 101] {
            let fixture = try ChargeEngineTestSupport.makeFixture()
            defer { fixture.cleanUp() }
            try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 50))
            try fixture.store.mutate { state in
                state.chargeRemaining = corruptCharge
            }

            #expect(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "corrupt-1"))
                    == .degradedWarning(message: SyncFailureReason.ledgerCorrupt.userMessage)
            )
            var state = try fixture.engine.currentState()
            #expect(state.chargeRemaining == corruptCharge)
            #expect(state.pendingOverride == nil)
            #expect(state.lastSyncError == SyncFailureReason.ledgerCorrupt.rawValue)
            #expect(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "corrupt-2"))
                    == .passThrough
            )
            state = try fixture.engine.currentState()
            #expect(state.chargeRemaining == corruptCharge)
            #expect(state.pendingOverride == nil)
        }
    }

    @Test func corruptPersistedRecoveryBlocksSpendOverrideAndRedirect() throws {
        for (corruptScore, charge) in [(-1, 2), (101, 0)] {
            let fixture = try ChargeEngineTestSupport.makeFixture()
            defer { fixture.cleanUp() }
            try ChargeEngineTestSupport.enable(fixture, recovery: ChargeEngineTestSupport.recovery(score: 50))
            let pending = PendingOverride(sessionID: "session-a", redirectedTurnID: "earlier-turn")
            try fixture.store.mutate { state in
                state.recovery?.recoveryScore = corruptScore
                state.chargeRemaining = charge
                if charge == 0 {
                    state.pendingOverride = pending
                }
            }
            let prompt = charge == 0 ? "continue once" : "ordinary prompt"

            #expect(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(prompt: prompt))
                    == .degradedWarning(message: SyncFailureReason.ledgerCorrupt.userMessage)
            )
            var state = try fixture.engine.currentState()
            #expect(state.recovery?.recoveryScore == corruptScore)
            #expect(state.chargeRemaining == charge)
            #expect(state.pendingOverride == (charge == 0 ? pending : nil))
            #expect(
                try fixture.engine.handlePrompt(
                    ChargeEngineTestSupport.input(turnID: "second", prompt: "ordinary prompt")
                ) == .passThrough
            )
            state = try fixture.engine.currentState()
            #expect(state.recovery?.recoveryScore == corruptScore)
            #expect(state.chargeRemaining == charge)
            #expect(state.pendingOverride == (charge == 0 ? pending : nil))
        }
    }

    @Test func sameCycleRefreshWithInvalidRetainedChargeStaysLedgerCorruptWithoutRefillOrSpam() throws {
        let retainedCharges: [Int?] = [nil, 101]

        for retainedCharge in retainedCharges {
            let fixture = try ChargeEngineTestSupport.makeFixture()
            defer { fixture.cleanUp() }
            let initial = ChargeEngineTestSupport.recovery(score: 72)
            try ChargeEngineTestSupport.enable(fixture, recovery: initial)
            try fixture.store.mutate { state in
                state.chargeRemaining = retainedCharge
            }

            let firstRefresh = ChargeEngineTestSupport.recovery(
                score: 88,
                validatedAt: ChargeEngineTestSupport.now
            )
            try fixture.engine.applyRecovery(firstRefresh)

            var state = try fixture.engine.currentState()
            #expect(state.recovery == firstRefresh)
            #expect(state.chargeRemaining == retainedCharge)
            #expect(state.degradedReason == SyncFailureReason.ledgerCorrupt.userMessage)
            #expect(state.degradedWarningEmitted == false)
            #expect(state.lastSyncAttemptAt == firstRefresh.validatedAt)
            #expect(state.lastSyncSuccessAt == initial.validatedAt)
            #expect(state.lastSyncError == SyncFailureReason.ledgerCorrupt.rawValue)
            #expect(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "warn"))
                    == .degradedWarning(message: SyncFailureReason.ledgerCorrupt.userMessage)
            )

            let repeatedRefresh = ChargeEngineTestSupport.recovery(
                score: 89,
                validatedAt: ChargeEngineTestSupport.now.addingTimeInterval(60)
            )
            try fixture.engine.applyRecovery(repeatedRefresh)

            state = try fixture.engine.currentState()
            #expect(state.recovery == repeatedRefresh)
            #expect(state.chargeRemaining == retainedCharge)
            #expect(state.degradedReason == SyncFailureReason.ledgerCorrupt.userMessage)
            #expect(state.degradedWarningEmitted)
            #expect(state.lastSyncAttemptAt == repeatedRefresh.validatedAt)
            #expect(state.lastSyncSuccessAt == initial.validatedAt)
            #expect(state.lastSyncError == SyncFailureReason.ledgerCorrupt.rawValue)
            #expect(
                try fixture.engine.handlePrompt(ChargeEngineTestSupport.input(turnID: "no-spam")) == .passThrough
            )
        }
    }

    @Test func concurrentPromptsAtOneSpendOnceThenRedirect() throws {
        let (decisions, state) = try ChargeEngineTestSupport.concurrentPromptDecisionsAtChargeOne()

        #expect(decisions.filter { $0 == .passThrough }.count == 1)
        #expect(
            decisions.filter {
                if case .redirect = $0 { return true }
                return false
            }.count == 1
        )
        #expect(state.chargeRemaining == 0)
    }
}
#endif
