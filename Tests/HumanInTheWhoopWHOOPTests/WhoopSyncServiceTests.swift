import Foundation
@testable import HumanInTheWhoopCore
@testable import HumanInTheWhoopWHOOP

private enum FakeReply<Value: Sendable>: Sendable {
    case success(Value)
    case failure(WhoopAPIError)
    case cancelled
}

private enum FakeEndpoint: Hashable, Sendable {
    case latestCycle
    case recovery
    case sleep
    case workouts
}

private actor FakeAPIBarrier {
    private var arrivals = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func suspend() async {
        arrivals += 1
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForArrival() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor FakeWhoopAPI: WhoopAPI {
    struct Trace: Sendable {
        let calls: [String]
        let workoutWindows: [(Date, Date)]
    }

    private var cycles: [FakeReply<WhoopCycleDTO>]
    private var recoveries: [FakeReply<WhoopRecoveryDTO>]
    private var sleeps: [FakeReply<WhoopSleepDTO?>]
    private var workoutLists: [FakeReply<[WhoopWorkoutDTO]>]
    private let barriers: [FakeEndpoint: FakeAPIBarrier]
    private var calls: [String] = []
    private var workoutWindows: [(Date, Date)] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        cycles: [FakeReply<WhoopCycleDTO>],
        recoveries: [FakeReply<WhoopRecoveryDTO>],
        sleeps: [FakeReply<WhoopSleepDTO?>],
        workouts: [FakeReply<[WhoopWorkoutDTO]>],
        barriers: [FakeEndpoint: FakeAPIBarrier] = [:]
    ) {
        self.cycles = cycles
        self.recoveries = recoveries
        self.sleeps = sleeps
        self.workoutLists = workouts
        self.barriers = barriers
    }

    func latestCycle() async throws -> WhoopCycleDTO {
        recordCall("latestCycle")
        if let barrier = barriers[.latestCycle] { await barrier.suspend() }
        return try Self.resolve(cycles.removeFirst())
    }

    func recovery(cycleID: Int64) async throws -> WhoopRecoveryDTO {
        recordCall("recovery:\(cycleID)")
        if let barrier = barriers[.recovery] { await barrier.suspend() }
        return try Self.resolve(recoveries.removeFirst())
    }

    func sleep(cycleID: Int64) async throws -> WhoopSleepDTO? {
        recordCall("sleep:\(cycleID)")
        if let barrier = barriers[.sleep] { await barrier.suspend() }
        return try Self.resolve(sleeps.removeFirst())
    }

    func workouts(start: Date, end: Date) async throws -> [WhoopWorkoutDTO] {
        recordCall("workouts")
        workoutWindows.append((start, end))
        if let barrier = barriers[.workouts] { await barrier.suspend() }
        return try Self.resolve(workoutLists.removeFirst())
    }

    func trace() -> Trace {
        Trace(calls: calls, workoutWindows: workoutWindows)
    }

    func waitForCallCount(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { callCountWaiters.append((count, $0)) }
    }

    private func recordCall(_ call: String) {
        calls.append(call)
        let ready = callCountWaiters.filter { calls.count >= $0.0 }
        callCountWaiters.removeAll { calls.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    private static func resolve<T>(_ reply: FakeReply<T>) throws -> T {
        switch reply {
        case .success(let value):
            value
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }
}

private enum WhoopSyncServiceTestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let now = Date(timeIntervalSince1970: 2_000_000_000.25)
    static let sleepID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let workoutA = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let workoutB = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        private var scriptedValues: [Date] = []

        init(_ value: Date) { self.value = value }
        func read() -> Date {
            lock.withLock {
                guard !scriptedValues.isEmpty else { return value }
                return scriptedValues.removeFirst()
            }
        }
        func set(_ value: Date) { lock.withLock { self.value = value } }
        func script(_ values: [Date]) { lock.withLock { scriptedValues = values } }
    }

    struct Fixture {
        let databaseURL: URL
        let store: SQLiteStateStore
        let engine: ChargeEngine
        let api: FakeWhoopAPI
        let service: WhoopSyncService
        let clock: Clock

        func cleanUp() {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func cycle(
        id: Int64 = 100,
        start: Date = now.addingTimeInterval(-12 * 60 * 60),
        end: Date? = nil,
        state: WhoopScoreState = .scored,
        strain: Double? = 11.5
    ) -> WhoopCycleDTO {
        WhoopCycleDTO(
            id: id,
            start: start,
            end: end,
            scoreState: state,
            score: strain.map(WhoopCycleScoreDTO.init(strain:))
        )
    }

    static func recovery(
        cycleID: Int64 = 100,
        sleepID: UUID = sleepID,
        createdAt: Date = now.addingTimeInterval(-5 * 60 * 60),
        updatedAt: Date = now.addingTimeInterval(-4 * 60 * 60),
        state: WhoopScoreState = .scored,
        score: Int? = 72
    ) -> WhoopRecoveryDTO {
        WhoopRecoveryDTO(
            cycleID: cycleID,
            sleepID: sleepID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            scoreState: state,
            score: score.map(WhoopRecoveryScoreDTO.init(recoveryScore:))
        )
    }

    static func sleep(
        id: UUID = sleepID,
        cycleID: Int64 = 100,
        state: WhoopScoreState = .scored,
        performance: Double? = 88.5
    ) -> WhoopSleepDTO {
        WhoopSleepDTO(
            id: id,
            cycleID: cycleID,
            scoreState: state,
            score: performance.map(WhoopSleepScoreDTO.init(sleepPerformancePercentage:))
        )
    }

    static func workout(
        id: UUID = workoutA,
        end: Date = now.addingTimeInterval(-60 * 60),
        state: WhoopScoreState = .scored,
        strain: Double? = 14.25
    ) -> WhoopWorkoutDTO {
        WhoopWorkoutDTO(
            id: id,
            end: end,
            scoreState: state,
            score: strain.map(WhoopWorkoutScoreDTO.init(strain:))
        )
    }

    static func snapshot(
        cycleID: Int64 = 100,
        score: Int = 72,
        cycleEnd: Date? = nil,
        validatedAt: Date = now.addingTimeInterval(-120)
    ) -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: cycleID,
            sleepID: sleepID,
            recoveryScore: score,
            createdAt: now.addingTimeInterval(-5 * 60 * 60),
            updatedAt: now.addingTimeInterval(-4 * 60 * 60),
            cycleStart: now.addingTimeInterval(-12 * 60 * 60),
            cycleEnd: cycleEnd,
            sleepPerformance: 88.5,
            cycleStrain: 11.5,
            recentWorkout: WorkoutSnapshot(
                strain: 14.25,
                endedAt: now.addingTimeInterval(-60 * 60)
            ),
            secondaryDataComplete: true,
            validatedAt: validatedAt
        )
    }

    static func makeFixture(
        databaseURL providedDatabaseURL: URL? = nil,
        cycles: [FakeReply<WhoopCycleDTO>] = [.success(cycle())],
        recoveries: [FakeReply<WhoopRecoveryDTO>] = [.success(recovery())],
        sleeps: [FakeReply<WhoopSleepDTO?>] = [.success(sleep())],
        workouts: [FakeReply<[WhoopWorkoutDTO]>] = [.success([workout()])],
        barriers: [FakeEndpoint: FakeAPIBarrier] = [:]
    ) throws -> Fixture {
        let databaseURL = providedDatabaseURL
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("state.sqlite3")
        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let clock = Clock(now)
        let engine = ChargeEngine(store: store, now: { clock.read() })
        let api = FakeWhoopAPI(
            cycles: cycles,
            recoveries: recoveries,
            sleeps: sleeps,
            workouts: workouts,
            barriers: barriers
        )
        return Fixture(
            databaseURL: databaseURL,
            store: store,
            engine: engine,
            api: api,
            service: WhoopSyncService(api: api, engine: engine, now: { clock.read() }),
            clock: clock
        )
    }

    static func seedReady(_ fixture: Fixture, snapshot: RecoverySnapshot = snapshot()) throws {
        try fixture.engine.setEnabled(true)
        try fixture.engine.applyRecovery(snapshot)
    }

    static func engineBookkeepingSeams() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let cached = snapshot(score: 63)
        try seedReady(fixture, snapshot: cached)
        let pending = PendingOverride(sessionID: "session", redirectedTurnID: "turn")
        try fixture.store.mutate { state in
            state.pendingOverride = pending
            state.lastSyncAttemptAt = nil
        }
        let beforeAttempt = try fixture.engine.currentState()

        try fixture.engine.recordSyncAttempt()
        var expectedAttempt = beforeAttempt
        expectedAttempt.lastSyncAttemptAt = now
        try expect(try fixture.engine.currentState() == expectedAttempt, "attempt changed more than its timestamp")

        try fixture.store.mutate { state in
            state.degradedReason = "old fixed warning"
            state.degradedWarningEmitted = true
            state.lastSyncError = SyncFailureReason.refreshRequired.rawValue
        }
        let beforeRetain = try fixture.engine.currentState()
        try fixture.engine.recordRetainedCacheFailure(.rateLimited)
        let retained = try fixture.engine.currentState()
        try expect(retained.recovery == beforeRetain.recovery, "retention changed Recovery")
        try expect(retained.chargeRemaining == beforeRetain.chargeRemaining, "retention refilled Charge")
        try expect(retained.pendingOverride == pending, "retention changed pending override")
        try expect(retained.lastSyncSuccessAt == beforeRetain.lastSyncSuccessAt, "retention recorded success")
        try expect(retained.lastSyncAttemptAt == now, "retention did not record engine time")
        try expect(retained.lastSyncError == SyncFailureReason.rateLimited.rawValue, "retention error was not sanitized")
        try expect(retained.degradedReason == nil, "valid cache did not clear degradation")
        try expect(!retained.degradedWarningEmitted, "valid cache did not reset warning epoch")

        let beforeUnsafeReason = retained
        var unsafeReasonRejected = false
        do {
            try fixture.engine.recordRetainedCacheFailure(.authentication)
        } catch {
            unsafeReasonRejected = true
        }
        try expect(unsafeReasonRejected, "nontransient retained-cache reason was accepted")
        try expect(try fixture.engine.currentState() == beforeUnsafeReason, "unsafe retention reason mutated state")

        try fixture.store.mutate { state in
            state.recovery?.cycleEnd = now
            state.degradedReason = SyncFailureReason.refreshRequired.userMessage
        }
        let invalidBefore = try fixture.engine.currentState()
        var rejected = false
        do {
            try fixture.engine.recordRetainedCacheFailure(.unavailable)
        } catch {
            rejected = true
        }
        try expect(rejected, "ended cached Recovery was accepted")
        try expect(try fixture.engine.currentState() == invalidBefore, "failed retention mutated or repaired the ledger")
    }

    static func scoredRecoveryBuildsCompleteSnapshotAndCharge() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.setEnabled(true)

        let outcome = await fixture.service.refresh()
        let expected = snapshot(validatedAt: now)
        try expect(outcome == .refreshed(expected), "complete refresh outcome was wrong")
        let state = try fixture.engine.currentState()
        try expect(state.recovery == expected, "snapshot was not persisted exactly")
        try expect(state.chargeRemaining == 72, "Recovery did not initialize Charge")
        try expect(state.lastSyncAttemptAt == now, "success attempt timestamp was wrong")
        try expect(state.lastSyncSuccessAt == now, "success timestamp was wrong")
        try expect(state.lastSyncError == nil && state.degradedReason == nil, "success remained degraded")
        let trace = await fixture.api.trace()
        try expect(trace.calls == ["latestCycle", "recovery:100", "sleep:100", "workouts"], "refresh call sequence was wrong")
        try expect(trace.workoutWindows.count == 1, "workouts was not called once")
        try expect(trace.workoutWindows[0].0 == now.addingTimeInterval(-6 * 60 * 60), "workout start was wrong")
        try expect(trace.workoutWindows[0].1 == now, "workout end was wrong")
    }

    static func sameCycleNeverRefillsAndNewCycleAlwaysResets() async throws {
        let same = try makeFixture(recoveries: [.success(recovery(score: 94))])
        defer { same.cleanUp() }
        try seedReady(same, snapshot: snapshot(score: 72))
        _ = try same.engine.handlePrompt(
            HookInput(sessionID: "s", turnID: "t", hookEventName: "UserPromptSubmit", prompt: "spend")
        )
        try expect(try same.engine.currentState().chargeRemaining == 71, "test did not spend Charge")
        _ = await same.service.refresh()
        try expect(try same.engine.currentState().chargeRemaining == 71, "same cycle refilled Charge")
        try expect(try same.engine.currentState().recovery?.recoveryScore == 94, "same-cycle Recovery was not refreshed")

        for (remaining, score) in [(80, 30), (10, 91)] {
            let next = try makeFixture(
                cycles: [.success(cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60)))],
                recoveries: [.success(recovery(cycleID: 101, score: score))],
                sleeps: [.success(sleep(cycleID: 101))]
            )
            defer { next.cleanUp() }
            try seedReady(next, snapshot: snapshot(cycleID: 100, score: 55))
            let pending = PendingOverride(sessionID: "old", redirectedTurnID: "old")
            try next.store.mutate { state in
                state.chargeRemaining = remaining
                state.pendingOverride = pending
            }
            _ = await next.service.refresh()
            let state = try next.engine.currentState()
            try expect(state.chargeRemaining == score, "new cycle did not reset Charge to Recovery")
            try expect(state.pendingOverride == nil, "new cycle did not clear pending override")
        }
    }

    static func ineligibleRecoveryStatesInvalidate() async throws {
        let cases: [(WhoopScoreState, Int?)] = [
            (.pendingScore, 72), (.unscorable, 72), (.unknown("FUTURE"), 72), (.scored, nil),
        ]
        for (state, score) in cases {
            let fixture = try makeFixture(recoveries: [.success(recovery(state: state, score: score))])
            defer { fixture.cleanUp() }
            try seedReady(fixture)
            let outcome = await fixture.service.refresh()
            try expect(outcome == .degraded(reason: "WHOOP returned data that could not be validated."), "ineligible Recovery was not invalid data")
            let persisted = try fixture.engine.currentState()
            try expect(persisted.recovery == nil && persisted.chargeRemaining == nil, "ineligible Recovery retained cache")
            try expect(persisted.lastSyncError == SyncFailureReason.invalidData.rawValue, "ineligible error was not sanitized")
        }
    }

    static func authenticationAndMissingCredentialsInvalidate() async throws {
        let fixtures = [
            try makeFixture(cycles: [.failure(.missingCredentials)]),
            try makeFixture(recoveries: [.failure(.authenticationFailed)]),
        ]
        for fixture in fixtures {
            defer { fixture.cleanUp() }
            try seedReady(fixture)
            let outcome = await fixture.service.refresh()
            try expect(outcome == .degraded(reason: "WHOOP authentication is required."), "auth outcome was wrong")
            let state = try fixture.engine.currentState()
            try expect(state.recovery == nil && state.chargeRemaining == nil, "auth retained cache")
            try expect(state.lastSyncError == SyncFailureReason.authentication.rawValue, "auth error was not sanitized")
        }
    }

    static func transientBeforeLatestRetainsOnlyCurrentReadyCache() async throws {
        let cases: [(WhoopAPIError, SyncFailureReason, String)] = [
            (.rateLimited, .rateLimited, "WHOOP sync is temporarily rate limited."),
            (.server(status: 503), .unavailable, "WHOOP sync is temporarily unavailable."),
            (.transport(message: "secret raw text"), .unavailable, "WHOOP sync is temporarily unavailable."),
        ]
        for (error, reason, message) in cases {
            let fixture = try makeFixture(cycles: [.failure(error)])
            defer { fixture.cleanUp() }
            let cached = snapshot(score: 64)
            try seedReady(fixture, snapshot: cached)
            try fixture.store.mutate { $0.chargeRemaining = 23 }
            let oldSuccess = try fixture.engine.currentState().lastSyncSuccessAt
            let outcome = await fixture.service.refresh()
            try expect(outcome == .retainedCache(message: message), "Ready cache was not retained")
            let state = try fixture.engine.currentState()
            try expect(state.recovery == cached && state.chargeRemaining == 23, "retention changed ledger")
            try expect(state.degradedReason == nil, "retained cache degraded readiness")
            try expect(state.lastSyncError == reason.rawValue, "retained error was wrong")
            try expect(state.lastSyncAttemptAt == now && state.lastSyncSuccessAt == oldSuccess, "retention timestamps were wrong")
            try expect(!String(describing: outcome).contains("secret raw text"), "raw transport text escaped")
        }
    }

    static func refreshRequiredDoesNotResumeBeforeLatestButSameCycleProofCanResume() async throws {
        let beforeLatest = try makeFixture(cycles: [.failure(.rateLimited)])
        defer { beforeLatest.cleanUp() }
        try seedReady(beforeLatest)
        try beforeLatest.engine.setEnabled(false)
        try beforeLatest.engine.setEnabled(true)
        let cached = try beforeLatest.engine.currentState().recovery
        let charge = try beforeLatest.engine.currentState().chargeRemaining
        let outcome = await beforeLatest.service.refresh()
        try expect(outcome == .degraded(reason: "WHOOP sync is temporarily rate limited."), "refresh-required cache resumed before latest proof")
        var state = try beforeLatest.engine.currentState()
        try expect(state.recovery == cached && state.chargeRemaining == charge, "refresh-required transient discarded future proof cache")
        try expect(state.degradedReason != nil, "refresh-required transient became Ready")

        let afterLatest = try makeFixture(recoveries: [.failure(.transport(message: "hidden"))])
        defer { afterLatest.cleanUp() }
        try seedReady(afterLatest)
        try afterLatest.engine.setEnabled(false)
        try afterLatest.engine.setEnabled(true)
        let oldRecovery = try afterLatest.engine.currentState().recovery
        let resumed = await afterLatest.service.refresh()
        try expect(resumed == .retainedCache(message: "WHOOP sync is temporarily unavailable."), "same-cycle proof did not resume cache")
        state = try afterLatest.engine.currentState()
        try expect(state.recovery == oldRecovery && state.chargeRemaining == 72, "same-cycle proof changed ledger")
        try expect(state.degradedReason == nil, "same-cycle proof did not clear refresh-required")
    }

    static func transientWithoutCacheAndDifferentCycleDegrade() async throws {
        let empty = try makeFixture(cycles: [.failure(.server(status: 500))])
        defer { empty.cleanUp() }
        try empty.engine.setEnabled(true)
        let emptyOutcome = await empty.service.refresh()
        try expect(emptyOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."), "transient without cache did not degrade")
        try expect(try empty.engine.currentState().recovery == nil, "transient invented cache")

        let different = try makeFixture(
            cycles: [.success(cycle(id: 101))],
            recoveries: [.failure(.rateLimited)]
        )
        defer { different.cleanUp() }
        try seedReady(different, snapshot: snapshot(cycleID: 100))
        let differentOutcome = await different.service.refresh()
        try expect(differentOutcome == .degraded(reason: "WHOOP sync is temporarily rate limited."), "different cycle retained old cache")
        let state = try different.engine.currentState()
        try expect(state.recovery == nil && state.chargeRemaining == nil, "proven different cycle did not invalidate old cache")
    }

    static func endedLatestAndEndedCacheCannotMaskFailure() async throws {
        let endedLatest = try makeFixture(cycles: [.success(cycle(end: now.addingTimeInterval(-1)))])
        defer { endedLatest.cleanUp() }
        try seedReady(endedLatest)
        let outcome = await endedLatest.service.refresh()
        try expect(outcome == .degraded(reason: "WHOOP returned data that could not be validated."), "ended latest cycle was not invalid")
        try expect(try endedLatest.engine.currentState().recovery == nil, "ended latest retained cache")

        let endedCache = try makeFixture(cycles: [.failure(.server(status: 503))])
        defer { endedCache.cleanUp() }
        try seedReady(endedCache)
        try endedCache.store.mutate { $0.recovery?.cycleEnd = now.addingTimeInterval(-60) }
        let endedOutcome = await endedCache.service.refresh()
        try expect(endedOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."), "ended cache masked outage")
        let state = try endedCache.engine.currentState()
        try expect(state.recovery == nil && state.chargeRemaining == nil, "ended cache was not invalidated")
    }

    static func deletedRecoveryAndPrimarySemanticErrorsInvalidate() async throws {
        for error in [WhoopAPIError.notFound, .decoding, .invalidResponse] {
            let deleted = try makeFixture(recoveries: [.failure(error)])
            defer { deleted.cleanUp() }
            try seedReady(deleted)
            let deletedOutcome = await deleted.service.refresh()
            try expect(deletedOutcome == .degraded(reason: "WHOOP returned data that could not be validated."), "invalid/deleted Recovery did not invalidate")
            try expect(try deleted.engine.currentState().recovery == nil, "invalid/deleted Recovery retained cache")
        }

        let invalidCycles = [
            cycle(id: 0),
            cycle(start: Date(timeIntervalSinceReferenceDate: .infinity)),
            cycle(end: now),
        ]
        for invalidCycle in invalidCycles {
            let fixture = try makeFixture(cycles: [.success(invalidCycle)])
            defer { fixture.cleanUp() }
            try seedReady(fixture)
            _ = await fixture.service.refresh()
            try expect(try fixture.engine.currentState().lastSyncError == SyncFailureReason.invalidData.rawValue, "invalid cycle was accepted")
            try expect(try fixture.engine.currentState().recovery == nil, "invalid cycle retained cache")
        }

        let invalidRecoveries = [
            recovery(cycleID: 101), recovery(sleepID: zeroUUID), recovery(score: -1), recovery(score: 101),
            recovery(createdAt: Date(timeIntervalSinceReferenceDate: .infinity)),
            recovery(updatedAt: Date(timeIntervalSinceReferenceDate: .infinity)),
        ]
        for invalidRecovery in invalidRecoveries {
            let fixture = try makeFixture(recoveries: [.success(invalidRecovery)])
            defer { fixture.cleanUp() }
            try seedReady(fixture)
            _ = await fixture.service.refresh()
            try expect(try fixture.engine.currentState().lastSyncError == SyncFailureReason.invalidData.rawValue, "invalid Recovery was accepted")
            try expect(try fixture.engine.currentState().recovery == nil, "invalid Recovery retained cache")
        }
    }

    static func secondaryFailuresDoNotInvalidatePrimary() async throws {
        let errors: [WhoopAPIError] = [
            .rateLimited, .server(status: 503), .transport(message: "hidden"),
            .notFound, .decoding, .invalidResponse,
        ]
        for error in errors {
            let fixture = try makeFixture(
                sleeps: [.failure(error)],
                workouts: [.failure(error)]
            )
            defer { fixture.cleanUp() }
            try fixture.engine.setEnabled(true)
            let outcome = await fixture.service.refresh()
            guard case .refreshed(let snapshot) = outcome else {
                throw Failure(description: "secondary failure blocked primary: \(error)")
            }
            try expect(snapshot.recoveryScore == 72, "primary Recovery was lost")
            try expect(snapshot.cycleStrain == 11.5 && snapshot.sleepPerformance == nil && snapshot.recentWorkout == nil, "failed secondary fields were wrong")
            try expect(!snapshot.secondaryDataComplete, "secondary failures reported complete")
            let state = try fixture.engine.currentState()
            try expect(state.chargeRemaining == 72 && state.degradedReason == nil, "secondary failures degraded primary")
        }
    }

    static func secondaryAuthenticationInvalidatesPrimary() async throws {
        let fixtures = [
            try makeFixture(sleeps: [.failure(.authenticationFailed)]),
            try makeFixture(workouts: [.failure(.missingCredentials)]),
        ]
        for fixture in fixtures {
            defer { fixture.cleanUp() }
            try seedReady(fixture)
            let outcome = await fixture.service.refresh()
            try expect(outcome == .degraded(reason: "WHOOP authentication is required."), "secondary auth did not fail refresh")
            let state = try fixture.engine.currentState()
            try expect(state.recovery == nil && state.chargeRemaining == nil, "secondary auth retained primary/cache")
            try expect(state.lastSyncError == SyncFailureReason.authentication.rawValue, "secondary auth error was wrong")
        }
    }

    static func emptyWorkoutsAreComplete() async throws {
        let fixture = try makeFixture(workouts: [.success([])])
        defer { fixture.cleanUp() }
        try fixture.engine.setEnabled(true)
        let outcome = await fixture.service.refresh()
        guard case .refreshed(let snapshot) = outcome else {
            throw Failure(description: "empty workouts blocked refresh")
        }
        try expect(snapshot.recentWorkout == nil, "empty workouts produced a workout")
        try expect(snapshot.secondaryDataComplete, "successful empty workout list was incomplete")
    }

    static func workoutSelectionUsesWindowStrainAndDeterministicTies() async throws {
        let oldestInclusive = workout(id: workoutA, end: now.addingTimeInterval(-6 * 60 * 60), strain: 12)
        let tiedEarlier = workout(id: workoutA, end: now.addingTimeInterval(-2 * 60 * 60), strain: 18)
        let tiedLater = workout(id: workoutB, end: now.addingTimeInterval(-60 * 60), strain: 18)
        let future = workout(end: now.addingTimeInterval(1), strain: 21)
        let tooOld = workout(end: now.addingTimeInterval(-6 * 60 * 60 - 1), strain: 21)
        let atNow = workout(end: now, strain: 10)
        let fixture = try makeFixture(
            workouts: [.success([future, tooOld, oldestInclusive, tiedEarlier, atNow, tiedLater])]
        )
        defer { fixture.cleanUp() }
        try fixture.engine.setEnabled(true)
        let outcome = await fixture.service.refresh()
        guard case .refreshed(let snapshot) = outcome else {
            throw Failure(description: "valid workout collection blocked refresh")
        }
        try expect(snapshot.recentWorkout == WorkoutSnapshot(strain: 18, endedAt: tiedLater.end), "highest recent workout/tie rule was wrong")
        try expect(snapshot.secondaryDataComplete, "valid future/old workouts made secondary incomplete")

        for ordering in [
            [workout(id: workoutB, strain: 15), workout(id: workoutA, strain: 15)],
            [workout(id: workoutA, strain: 15), workout(id: workoutB, strain: 15)],
        ] {
            let tie = try makeFixture(workouts: [.success(ordering)])
            defer { tie.cleanUp() }
            try tie.engine.setEnabled(true)
            let tieOutcome = await tie.service.refresh()
            guard case .refreshed(let tieSnapshot) = tieOutcome else {
                throw Failure(description: "stable UUID tie blocked refresh")
            }
            try expect(tieSnapshot.recentWorkout == WorkoutSnapshot(strain: 15, endedAt: now.addingTimeInterval(-60 * 60)), "stable tie changed snapshot")
        }
    }

    static func invalidSecondaryRecordsArePartialButUseful() async throws {
        let fixture = try makeFixture(
            cycles: [.success(cycle(strain: 22))],
            sleeps: [.success(sleep(id: workoutB, performance: 101))],
            workouts: [.success([
                workout(strain: 9),
                workout(id: zeroUUID, strain: 20),
                workout(id: workoutB, state: .pendingScore, strain: 19),
                workout(id: workoutB, end: Date(timeIntervalSinceReferenceDate: .infinity), strain: 18),
                workout(id: workoutB, strain: .infinity),
                workout(id: workoutB, state: .unknown("FUTURE"), strain: 17),
                workout(id: workoutB, strain: nil),
                workout(id: workoutB, strain: -1),
                workout(id: workoutB, strain: 22),
            ])]
        )
        defer { fixture.cleanUp() }
        try fixture.engine.setEnabled(true)
        let outcome = await fixture.service.refresh()
        guard case .refreshed(let snapshot) = outcome else {
            throw Failure(description: "invalid secondary records blocked primary")
        }
        try expect(snapshot.cycleStrain == nil && snapshot.sleepPerformance == nil, "invalid cycle/sleep semantic data escaped")
        try expect(snapshot.recentWorkout == WorkoutSnapshot(strain: 9, endedAt: now.addingTimeInterval(-60 * 60)), "useful valid workout was discarded")
        try expect(!snapshot.secondaryDataComplete, "invalid secondary records reported complete")
    }

    static func cancellationOnlyRecordsAttempt() async throws {
        let cached = try makeFixture(cycles: [.cancelled])
        defer { cached.cleanUp() }
        try seedReady(cached, snapshot: snapshot(score: 61))
        try cached.store.mutate { $0.chargeRemaining = 17 }
        let before = try cached.engine.currentState()
        let outcome = await cached.service.refresh()
        try expect(outcome == .retainedCache(message: "Refresh cancelled."), "cached cancellation outcome was wrong")
        var expected = before
        expected.lastSyncAttemptAt = now
        try expect(try cached.engine.currentState() == expected, "cancellation mutated outage/readiness state")

        let noCache = try makeFixture(recoveries: [.cancelled])
        defer { noCache.cleanUp() }
        try noCache.engine.setEnabled(true)
        let noCacheBefore = try noCache.engine.currentState()
        let noCacheOutcome = await noCache.service.refresh()
        try expect(noCacheOutcome == .degraded(reason: "Refresh cancelled."), "no-cache cancellation outcome was wrong")
        var noCacheExpected = noCacheBefore
        noCacheExpected.lastSyncAttemptAt = now
        try expect(try noCache.engine.currentState() == noCacheExpected, "no-cache cancellation marked sync failure")

        let secondary = try makeFixture(sleeps: [.cancelled])
        defer { secondary.cleanUp() }
        try seedReady(secondary)
        let secondaryBefore = try secondary.engine.currentState()
        let secondaryOutcome = await secondary.service.refresh()
        try expect(secondaryOutcome == .retainedCache(message: "Refresh cancelled."), "secondary cancellation outcome was wrong")
        var secondaryExpected = secondaryBefore
        secondaryExpected.lastSyncAttemptAt = now
        try expect(try secondary.engine.currentState() == secondaryExpected, "secondary cancellation applied primary or failure")

        let refreshRequired = try makeFixture(cycles: [.cancelled])
        defer { refreshRequired.cleanUp() }
        try seedReady(refreshRequired)
        try refreshRequired.engine.setEnabled(false)
        try refreshRequired.engine.setEnabled(true)
        let degradedBefore = try refreshRequired.engine.currentState()
        let degradedOutcome = await refreshRequired.service.refresh()
        try expect(degradedOutcome == .retainedCache(message: "Refresh cancelled."), "valid degraded ledger did not use deterministic cancellation outcome")
        var degradedExpected = degradedBefore
        degradedExpected.lastSyncAttemptAt = now
        try expect(try refreshRequired.engine.currentState() == degradedExpected, "cancellation resumed refresh-required cache")
    }

    static func secondarySemanticsAndBoundariesAreExact() async throws {
        let invalidCycles: [(WhoopScoreState, Double?)] = [
            (.pendingScore, 10), (.unscorable, 10), (.unknown("FUTURE"), 10),
            (.scored, nil), (.scored, -1), (.scored, 22), (.scored, .infinity),
        ]
        for (scoreState, strain) in invalidCycles {
            let fixture = try makeFixture(cycles: [.success(cycle(state: scoreState, strain: strain))])
            defer { fixture.cleanUp() }
            try fixture.engine.setEnabled(true)
            guard case .refreshed(let snapshot) = await fixture.service.refresh() else {
                throw Failure(description: "invalid cycle secondary blocked primary")
            }
            try expect(snapshot.cycleStrain == nil && !snapshot.secondaryDataComplete, "invalid cycle strain escaped")
        }

        let invalidSleeps: [WhoopSleepDTO?] = [
            nil,
            sleep(id: workoutB),
            sleep(cycleID: 101),
            sleep(state: .pendingScore),
            sleep(state: .unscorable),
            sleep(state: .unknown("FUTURE")),
            sleep(performance: nil),
            sleep(performance: -1),
            sleep(performance: 101),
            sleep(performance: .infinity),
        ]
        for invalidSleep in invalidSleeps {
            let fixture = try makeFixture(sleeps: [.success(invalidSleep)])
            defer { fixture.cleanUp() }
            try fixture.engine.setEnabled(true)
            guard case .refreshed(let snapshot) = await fixture.service.refresh() else {
                throw Failure(description: "invalid sleep secondary blocked primary")
            }
            try expect(snapshot.sleepPerformance == nil && !snapshot.secondaryDataComplete, "invalid sleep performance escaped")
        }

        let boundary = try makeFixture(
            cycles: [.success(cycle(strain: 21))],
            sleeps: [.success(sleep(performance: 100))],
            workouts: [.success([workout(strain: 0), workout(id: workoutB, strain: 21)])]
        )
        defer { boundary.cleanUp() }
        try boundary.engine.setEnabled(true)
        guard case .refreshed(let boundarySnapshot) = await boundary.service.refresh() else {
            throw Failure(description: "valid secondary boundaries blocked primary")
        }
        try expect(boundarySnapshot.cycleStrain == 21, "cycle strain 21 was rejected")
        try expect(boundarySnapshot.sleepPerformance == 100, "sleep performance 100 was rejected")
        try expect(boundarySnapshot.recentWorkout?.strain == 21, "workout strain 21 was rejected")
        try expect(boundarySnapshot.secondaryDataComplete, "valid secondary boundaries were incomplete")
    }

    static func invalidClockAndStorageFailuresDoNotCallAPI() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.engine.setEnabled(true)
        fixture.clock.set(Date(timeIntervalSinceReferenceDate: .infinity))
        let before = try fixture.engine.currentState()
        let outcome = await fixture.service.refresh()
        try expect(outcome == .degraded(reason: "WHOOP sync is temporarily unavailable."), "storage failure output was not fixed: \(outcome)")
        try expect(try fixture.engine.currentState() == before, "failed attempt timestamp partially mutated state")
        let trace = await fixture.api.trace()
        try expect(trace.calls.isEmpty, "API was called after attempt storage failed")

        let brokenStore = try makeFixture()
        defer { brokenStore.cleanUp() }
        brokenStore.store.simulateNextRollbackFailureForTesting()
        do {
            try brokenStore.store.mutate { _ in
                throw Failure(description: "force rollback")
            }
        } catch {}
        let brokenOutcome = await brokenStore.service.refresh()
        try expect(brokenOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."), "store read failure output was not fixed")
        let brokenTrace = await brokenStore.api.trace()
        try expect(brokenTrace.calls.isEmpty, "API was called after store became unavailable")
    }

    static func softOffSkipsAttemptAndNetworkThenReenableRefreshes() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try seedReady(fixture, snapshot: snapshot(score: 72))
        try fixture.store.mutate { state in
            state.pendingOverride = PendingOverride(sessionID: "paused", redirectedTurnID: "paused-turn")
            state.lastSyncError = SyncFailureReason.unavailable.rawValue
        }
        try fixture.engine.setEnabled(false)
        let before = try fixture.engine.currentState()

        let offOutcome = await fixture.service.refresh()
        try expect(offOutcome == .degraded(reason: "Human in the Whoop is off."), "Soft Off outcome was wrong")
        try expect(try fixture.engine.currentState() == before, "Soft Off mutated persisted state")
        var trace = await fixture.api.trace()
        try expect(trace.calls.isEmpty, "Soft Off crossed the API boundary")

        try fixture.engine.setEnabled(true)
        guard case .refreshed(let refreshed) = await fixture.service.refresh() else {
            throw Failure(description: "re-enabled service did not refresh")
        }
        try expect(refreshed.cycleID == 100 && refreshed.recoveryScore == 72, "re-enabled refresh mapped wrong Recovery")
        let state = try fixture.engine.currentState()
        try expect(state.enabled && state.degradedReason == nil, "re-enabled refresh did not become Ready")
        try expect(state.pendingOverride?.sessionID == "paused", "same-cycle re-enable changed pending state")
        trace = await fixture.api.trace()
        try expect(trace.calls == ["latestCycle", "recovery:100", "sleep:100", "workouts"], "re-enable refresh call sequence was wrong")
    }

    static func invalidValidationClockUsesTransientCacheRules() async throws {
        let invalidTime = Date(timeIntervalSinceReferenceDate: .infinity)

        let same = try makeFixture()
        defer { same.cleanUp() }
        let cached = snapshot(score: 66)
        try seedReady(same, snapshot: cached)
        try same.store.mutate { $0.chargeRemaining = 19 }
        let oldSuccess = try same.engine.currentState().lastSyncSuccessAt
        same.clock.script([now, invalidTime, now])
        let sameOutcome = await same.service.refresh()
        try expect(sameOutcome == .retainedCache(message: "WHOOP sync is temporarily unavailable."), "invalid validation clock did not retain proven same-cycle cache")
        var state = try same.engine.currentState()
        try expect(state.recovery == cached && state.chargeRemaining == 19, "invalid clock changed same-cycle ledger")
        try expect(state.degradedReason == nil && state.lastSyncError == SyncFailureReason.unavailable.rawValue, "invalid clock did not record safe retained error")
        try expect(state.lastSyncAttemptAt == now && state.lastSyncSuccessAt == oldSuccess, "invalid clock retained timestamps were wrong")
        var trace = await same.api.trace()
        try expect(trace.calls == ["latestCycle", "recovery:100", "sleep:100"], "invalid clock should stop before workouts")

        let empty = try makeFixture()
        defer { empty.cleanUp() }
        try empty.engine.setEnabled(true)
        empty.clock.script([now, invalidTime, now])
        let emptyOutcome = await empty.service.refresh()
        try expect(emptyOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."), "invalid clock without cache did not degrade")
        state = try empty.engine.currentState()
        try expect(state.recovery == nil && state.chargeRemaining == nil, "invalid clock without cache created a ledger")
        try expect(state.degradedReason == "WHOOP sync is temporarily unavailable." && state.lastSyncError == SyncFailureReason.unavailable.rawValue, "invalid clock without cache did not persist unavailable")
        trace = await empty.api.trace()
        try expect(trace.calls == ["latestCycle", "recovery:100", "sleep:100"], "invalid no-cache clock should stop before workouts")

        let different = try makeFixture()
        defer { different.cleanUp() }
        try seedReady(different, snapshot: snapshot(cycleID: 99, score: 55))
        different.clock.script([now, invalidTime, now])
        let differentOutcome = await different.service.refresh()
        try expect(differentOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."), "invalid clock with different cache did not degrade")
        state = try different.engine.currentState()
        try expect(state.recovery == nil && state.chargeRemaining == nil && state.pendingOverride == nil, "invalid clock retained a different-cycle cache")
        try expect(state.lastSyncError == SyncFailureReason.unavailable.rawValue, "different-cycle invalid clock error was wrong")
    }

    static func midflightSoftOffStopsAtEveryAPIStage() async throws {
        let cases: [(FakeEndpoint, [String])] = [
            (.latestCycle, ["latestCycle"]),
            (.recovery, ["latestCycle", "recovery:100"]),
            (.sleep, ["latestCycle", "recovery:100", "sleep:100"]),
            (.workouts, ["latestCycle", "recovery:100", "sleep:100", "workouts"]),
        ]

        for (endpoint, expectedCalls) in cases {
            let barrier = FakeAPIBarrier()
            let fixture = try makeFixture(barriers: [endpoint: barrier])
            defer { fixture.cleanUp() }
            let cached = snapshot(score: 42)
            try seedReady(fixture, snapshot: cached)
            try fixture.store.mutate { state in
                state.chargeRemaining = 13
                state.pendingOverride = PendingOverride(sessionID: "paused", redirectedTurnID: "turn")
            }

            let refresh = Task { await fixture.service.refresh() }
            await barrier.waitForArrival()
            try fixture.engine.setEnabled(false)
            let paused = try fixture.engine.currentState()
            await barrier.release()
            let outcome = await refresh.value

            try expect(outcome == .degraded(reason: "Human in the Whoop is off."), "mid-flight Off outcome was wrong at \(endpoint)")
            try expect(try fixture.engine.currentState() == paused, "mid-flight Off mutated paused state at \(endpoint)")
            let trace = await fixture.api.trace()
            try expect(trace.calls == expectedCalls, "mid-flight Off issued later API calls at \(endpoint): \(trace.calls)")
        }

        let failureBarrier = FakeAPIBarrier()
        let lateFailure = try makeFixture(
            cycles: [.failure(.authenticationFailed)],
            barriers: [.latestCycle: failureBarrier]
        )
        defer { lateFailure.cleanUp() }
        try seedReady(lateFailure, snapshot: snapshot(score: 42))
        try lateFailure.store.mutate { $0.chargeRemaining = 13 }
        let refresh = Task { await lateFailure.service.refresh() }
        await failureBarrier.waitForArrival()
        try lateFailure.engine.setEnabled(false)
        let paused = try lateFailure.engine.currentState()
        await failureBarrier.release()
        let outcome = await refresh.value
        try expect(outcome == .degraded(reason: "Human in the Whoop is off."), "late auth failure overrode Soft Off")
        try expect(try lateFailure.engine.currentState() == paused, "late auth failure invalidated paused cache")
        let trace = await lateFailure.api.trace()
        try expect(trace.calls == ["latestCycle"], "late auth failure issued another API call")
    }

    static func overlappingRefreshesAreSingleFlightAndWaiterCancellationSafe() async throws {
        let barrier = FakeAPIBarrier()
        let count = 10
        let fixture = try makeFixture(
            cycles: Array(repeating: .success(cycle()), count: count),
            recoveries: Array(repeating: .success(recovery()), count: count),
            sleeps: Array(repeating: .success(sleep()), count: count),
            workouts: Array(repeating: .success([workout()]), count: count),
            barriers: [.latestCycle: barrier]
        )
        defer { fixture.cleanUp() }
        try fixture.engine.setEnabled(true)

        var callers: [Task<SyncOutcome, Never>] = [Task { await fixture.service.refresh() }]
        await barrier.waitForArrival()
        for _ in 1..<count {
            callers.append(Task { await fixture.service.refresh() })
        }
        for _ in 0..<100 { await Task.yield() }
        callers[1].cancel()
        await barrier.release()

        var outcomes: [SyncOutcome] = []
        for caller in callers { outcomes.append(await caller.value) }
        guard let first = outcomes.first else { throw Failure(description: "single-flight returned no outcomes") }
        try expect(outcomes.allSatisfy { $0 == first }, "single-flight callers returned different outcomes")
        guard case .refreshed = first else { throw Failure(description: "single-flight did not refresh") }
        let trace = await fixture.api.trace()
        try expect(trace.calls == ["latestCycle", "recovery:100", "sleep:100", "workouts"], "overlapping refreshes did not coalesce: \(trace.calls)")
        let state = try fixture.engine.currentState()
        try expect(state.recovery?.cycleID == 100 && state.chargeRemaining == 72, "waiter cancellation corrupted shared refresh state")
    }

    static func syncMapsStaleApplicationsToRetainedCache() async throws {
        let message = "A newer WHOOP Recovery is already active."

        let different = try makeFixture(
            cycles: [.success(cycle(id: 199, start: now.addingTimeInterval(-12 * 60 * 60)))],
            recoveries: [.success(recovery(cycleID: 199, updatedAt: now.addingTimeInterval(-30 * 60)))],
            sleeps: [.success(sleep(cycleID: 199))]
        )
        defer { different.cleanUp() }
        let currentDifferent = snapshot(cycleID: 200, score: 61)
        try seedReady(different, snapshot: currentDifferent)
        try different.store.mutate { $0.chargeRemaining = 17 }
        let differentSuccess = try different.engine.currentState().lastSyncSuccessAt
        let differentOutcome = await different.service.refresh()
        try expect(differentOutcome == .retainedCache(message: message), "older different cycle stale outcome was wrong")
        var state = try different.engine.currentState()
        try expect(state.recovery == currentDifferent && state.chargeRemaining == 17, "older different cycle replaced/refilled state")
        try expect(state.lastSyncSuccessAt == differentSuccess, "stale different cycle recorded success")

        let same = try makeFixture(
            recoveries: [.success(recovery(updatedAt: now.addingTimeInterval(-5 * 60 * 60), score: 99))]
        )
        defer { same.cleanUp() }
        let currentSame = snapshot(score: 61)
        try seedReady(same, snapshot: currentSame)
        try same.store.mutate { $0.chargeRemaining = 17 }
        let sameOutcome = await same.service.refresh()
        try expect(sameOutcome == .retainedCache(message: message), "older same-cycle stale outcome was wrong")
        state = try same.engine.currentState()
        try expect(state.recovery == currentSame && state.chargeRemaining == 17, "older same-cycle update changed state")
    }

    static func staleFailuresCannotInvalidateNewerCrossProcessRecovery() async throws {
        let cases: [(
            name: String,
            endpoint: FakeEndpoint,
            cycles: [FakeReply<WhoopCycleDTO>],
            recoveries: [FakeReply<WhoopRecoveryDTO>]
        )] = [
            (
                "pre-latest-transport",
                .latestCycle,
                [.failure(.transport(message: "hidden"))],
                [.success(recovery(cycleID: 101))]
            ),
            (
                "proven-cycle-transport",
                .recovery,
                [.success(cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60)))],
                [.failure(.transport(message: "hidden"))]
            ),
            (
                "not-found",
                .recovery,
                [.success(cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60)))],
                [.failure(.notFound)]
            ),
            (
                "pending-invalid",
                .recovery,
                [.success(cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60)))],
                [.success(recovery(cycleID: 101, state: .pendingScore))]
            ),
        ]

        for testCase in cases {
            let barrier = FakeAPIBarrier()
            let stale = try makeFixture(
                cycles: testCase.cycles,
                recoveries: testCase.recoveries,
                barriers: [testCase.endpoint: barrier]
            )
            defer { stale.cleanUp() }
            try seedReady(stale, snapshot: snapshot(cycleID: 100, score: 50))

            let newer = try makeFixture(
                databaseURL: stale.databaseURL,
                cycles: [.success(cycle(id: 102, start: now.addingTimeInterval(-10 * 60 * 60)))],
                recoveries: [.success(recovery(cycleID: 102, score: 82))],
                sleeps: [.success(sleep(cycleID: 102))]
            )

            let staleRefresh = Task { await stale.service.refresh() }
            await barrier.waitForArrival()
            let newerOutcome = await newer.service.refresh()
            guard case .refreshed(let newerSnapshot) = newerOutcome else {
                throw Failure(description: "newer service did not apply cycle 102 for \(testCase.name)")
            }
            try expect(newerSnapshot.cycleID == 102, "newer service applied the wrong cycle for \(testCase.name)")
            let spend = try newer.engine.handlePrompt(
                HookInput(
                    sessionID: "newer-process",
                    turnID: "spent-turn",
                    hookEventName: "UserPromptSubmit",
                    prompt: "spend one"
                )
            )
            try expect(spend == .passThrough, "newer process did not spend Charge for \(testCase.name)")
            let spentState = try newer.engine.currentState()
            try expect(spentState.chargeRemaining == 81, "newer process Charge was not spent for \(testCase.name)")

            await barrier.release()
            let staleOutcome = await staleRefresh.value
            try expect(
                staleOutcome == .retainedCache(message: "A newer WHOOP Recovery is already active."),
                "stale \(testCase.name) failure did not map to the newer-cache outcome"
            )
            try expect(
                try stale.engine.currentState() == spentState,
                "stale \(testCase.name) failure altered cycle 102 or its spent Charge"
            )
        }
    }

    static func laterInvalidatingRefreshPreventsOlderSuccessfulResurrection() async throws {
        let invalidatingReplies: [(String, FakeReply<WhoopRecoveryDTO>)] = [
            ("pending", .success(recovery(cycleID: 102, state: .pendingScore))),
            ("unscorable", .success(recovery(cycleID: 102, state: .unscorable))),
            ("not-found", .failure(.notFound)),
        ]

        for (name, invalidatingReply) in invalidatingReplies {
            let oldBarrier = FakeAPIBarrier()
            let old = try makeFixture(
                cycles: [.success(cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60)))],
                recoveries: [.success(recovery(cycleID: 101, score: 72))],
                sleeps: [.success(sleep(cycleID: 101))],
                barriers: [.workouts: oldBarrier]
            )
            defer { old.cleanUp() }
            try seedReady(old, snapshot: snapshot(cycleID: 100, score: 50))
            try old.store.mutate { state in
                state.chargeRemaining = 0
                state.pendingOverride = PendingOverride(
                    sessionID: "exhausted",
                    redirectedTurnID: "old-turn"
                )
            }

            let later = try makeFixture(
                databaseURL: old.databaseURL,
                cycles: [.success(cycle(id: 102, start: now.addingTimeInterval(-10 * 60 * 60)))],
                recoveries: [invalidatingReply]
            )

            let oldRefresh = Task { await old.service.refresh() }
            await oldBarrier.waitForArrival()
            let laterOutcome = await later.service.refresh()
            try expect(
                laterOutcome == .degraded(reason: "WHOOP returned data that could not be validated."),
                "later \(name) refresh did not invalidate"
            )
            let invalidatedState = try later.engine.currentState()
            try expect(
                invalidatedState.recovery == nil
                    && invalidatedState.chargeRemaining == nil
                    && invalidatedState.pendingOverride == nil,
                "later \(name) refresh did not clear the exhausted ledger"
            )

            await oldBarrier.release()
            let oldOutcome = await oldRefresh.value
            try expect(
                oldOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."),
                "older successful refresh was not superseded by \(name)"
            )
            try expect(
                try old.engine.currentState() == invalidatedState,
                "older successful refresh resurrected Recovery after \(name)"
            )
        }
    }

    static func laterRefreshStartStopsOlderBeforeAdditionalEndpoints() async throws {
        let oldBarrier = FakeAPIBarrier()
        let old = try makeFixture(
            cycles: [.success(cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60)))],
            recoveries: [.success(recovery(cycleID: 101))],
            sleeps: [.success(sleep(cycleID: 101))],
            barriers: [.latestCycle: oldBarrier]
        )
        defer { old.cleanUp() }
        try seedReady(old, snapshot: snapshot(cycleID: 100, score: 50))

        let laterBarrier = FakeAPIBarrier()
        let later = try makeFixture(
            databaseURL: old.databaseURL,
            cycles: [.success(cycle(id: 102, start: now.addingTimeInterval(-10 * 60 * 60)))],
            recoveries: [.success(recovery(cycleID: 102, score: 80))],
            sleeps: [.success(sleep(cycleID: 102))],
            barriers: [.latestCycle: laterBarrier]
        )

        let oldRefresh = Task { await old.service.refresh() }
        await oldBarrier.waitForArrival()
        let laterRefresh = Task { await later.service.refresh() }
        await laterBarrier.waitForArrival()

        await oldBarrier.release()
        let oldOutcome = await oldRefresh.value
        await laterBarrier.release()
        let laterOutcome = await laterRefresh.value

        try expect(
            oldOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."),
            "later refresh start did not supersede older refresh"
        )
        let oldTrace = await old.api.trace()
        try expect(
            oldTrace.calls == ["latestCycle"],
            "superseded refresh issued additional endpoints: \(oldTrace.calls)"
        )
        guard case .refreshed(let laterSnapshot) = laterOutcome else {
            throw Failure(description: "later refresh did not finish after superseding older refresh")
        }
        try expect(laterSnapshot.cycleID == 102, "later refresh applied the wrong cycle")
    }

    static func offOnCannotReviveSupersededOperation() async throws {
        let barrier = FakeAPIBarrier()
        let old = try makeFixture(
            cycles: [.success(cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60)))],
            recoveries: [.success(recovery(cycleID: 101))],
            sleeps: [.success(sleep(cycleID: 101))],
            barriers: [.recovery: barrier]
        )
        defer { old.cleanUp() }
        try seedReady(old, snapshot: snapshot(cycleID: 100, score: 50))
        try old.store.mutate { $0.chargeRemaining = 0 }
        let control = try makeFixture(databaseURL: old.databaseURL)

        let oldRefresh = Task { await old.service.refresh() }
        await barrier.waitForArrival()
        try control.engine.setEnabled(false)
        try control.engine.setEnabled(true)
        let resumedState = try control.engine.currentState()

        await barrier.release()
        let outcome = await oldRefresh.value
        try expect(
            outcome == .degraded(reason: "WHOOP sync is temporarily unavailable."),
            "Off/on did not supersede the old operation"
        )
        try expect(
            try old.engine.currentState() == resumedState,
            "old operation revived Recovery or Charge after Off/on"
        )
        let trace = await old.api.trace()
        try expect(
            trace.calls == ["latestCycle", "recovery:101"],
            "Off/on superseded operation issued later endpoints: \(trace.calls)"
        )
    }

    static func offOnStartsNewRefreshInsteadOfJoiningSupersededSingleFlight() async throws {
        let barrier = FakeAPIBarrier()
        let repeatedCycle = cycle(id: 101, start: now.addingTimeInterval(-11 * 60 * 60))
        let repeatedRecovery = recovery(cycleID: 101)
        let fixture = try makeFixture(
            cycles: [.success(repeatedCycle), .success(repeatedCycle)],
            recoveries: [.success(repeatedRecovery), .success(repeatedRecovery)],
            sleeps: [.success(sleep(cycleID: 101))],
            workouts: [.success([])],
            barriers: [.recovery: barrier]
        )
        defer { fixture.cleanUp() }
        try seedReady(fixture, snapshot: snapshot(cycleID: 100, score: 50))
        try fixture.store.mutate { $0.chargeRemaining = 0 }

        let oldRefresh = Task { await fixture.service.refresh() }
        await barrier.waitForArrival()
        try fixture.engine.setEnabled(false)
        try fixture.engine.setEnabled(true)

        let newRefresh = Task { await fixture.service.refresh() }
        await fixture.api.waitForCallCount(4)
        let beforeRelease = await fixture.api.trace()
        try expect(
            beforeRelease.calls.filter { $0 == "latestCycle" }.count == 2,
            "re-enable refresh joined a superseded single-flight: \(beforeRelease.calls)"
        )

        await barrier.release()
        let newOutcome = await newRefresh.value
        let oldOutcome = await oldRefresh.value
        guard case .refreshed(let snapshot) = newOutcome else {
            throw Failure(description: "new operation did not refresh after Off/on: \(newOutcome)")
        }
        try expect(snapshot.cycleID == 101, "new operation applied the wrong Recovery")
        try expect(
            oldOutcome == .degraded(reason: "WHOOP sync is temporarily unavailable."),
            "superseded old operation did not fail open"
        )
        let state = try fixture.engine.currentState()
        try expect(
            state.enabled && state.degradedReason == nil
                && state.recovery?.cycleID == 101 && state.chargeRemaining == 72,
            "new operation did not reach Ready"
        )
    }

    static func workoutReplenishmentUsesEnableWindowAndDeduplicates() async throws {
        let fixture = try makeFixture(
            cycles: [.success(cycle()), .success(cycle())],
            recoveries: [.success(recovery()), .success(recovery())],
            sleeps: [.success(sleep()), .success(sleep())],
            workouts: [.success([workout()]), .success([workout(strain: 21)])]
        )
        defer { fixture.cleanUp() }
        let enabledAt = now.addingTimeInterval(-10 * 60 * 60)
        fixture.clock.set(enabledAt)
        try fixture.engine.setEnabled(true)
        try fixture.engine.applyRecovery(
            snapshot(score: 20, validatedAt: enabledAt.addingTimeInterval(60))
        )
        try fixture.store.mutate { $0.chargeRemaining = 0 }
        fixture.clock.set(now)

        guard case .refreshed = await fixture.service.refresh() else {
            throw Failure(description: "workout award refresh did not succeed")
        }
        var state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 23, "WHOOP Strain did not replenish Charge")
        try expect(state.workoutRewards?.processedWorkoutIDs == [workoutA], "workout UUID was not consumed")
        try expect(state.workoutRewards?.lastAward?.earnedCharge == 23, "sync stored the wrong award")
        var trace = await fixture.api.trace()
        try expect(trace.workoutWindows.first?.0 == enabledAt, "sync did not reconcile from the On boundary")

        guard case .refreshed = await fixture.service.refresh() else {
            throw Failure(description: "duplicate workout refresh did not succeed")
        }
        state = try fixture.engine.currentState()
        try expect(state.chargeRemaining == 23, "duplicate workout UUID replenished again after edit")
        try expect(try fixture.store.readAuditEvents().count == 1, "duplicate workout wrote a second award audit")
        trace = await fixture.api.trace()
        try expect(trace.workoutWindows.count == 2, "second refresh omitted workout reconciliation")
    }
}

#if canImport(XCTest)
import XCTest

final class WhoopSyncServiceTests: XCTestCase {
    func testEngineBookkeepingSeams() async throws { try await WhoopSyncServiceTestSupport.engineBookkeepingSeams() }
    func testScoredRecoveryBuildsCompleteSnapshotAndCharge() async throws { try await WhoopSyncServiceTestSupport.scoredRecoveryBuildsCompleteSnapshotAndCharge() }
    func testSameCycleNeverRefillsAndNewCycleAlwaysResets() async throws { try await WhoopSyncServiceTestSupport.sameCycleNeverRefillsAndNewCycleAlwaysResets() }
    func testIneligibleRecoveryStatesInvalidate() async throws { try await WhoopSyncServiceTestSupport.ineligibleRecoveryStatesInvalidate() }
    func testAuthenticationAndMissingCredentialsInvalidate() async throws { try await WhoopSyncServiceTestSupport.authenticationAndMissingCredentialsInvalidate() }
    func testTransientBeforeLatestRetainsOnlyCurrentReadyCache() async throws { try await WhoopSyncServiceTestSupport.transientBeforeLatestRetainsOnlyCurrentReadyCache() }
    func testRefreshRequiredDoesNotResumeBeforeLatestButSameCycleProofCanResume() async throws { try await WhoopSyncServiceTestSupport.refreshRequiredDoesNotResumeBeforeLatestButSameCycleProofCanResume() }
    func testTransientWithoutCacheAndDifferentCycleDegrade() async throws { try await WhoopSyncServiceTestSupport.transientWithoutCacheAndDifferentCycleDegrade() }
    func testEndedLatestAndEndedCacheCannotMaskFailure() async throws { try await WhoopSyncServiceTestSupport.endedLatestAndEndedCacheCannotMaskFailure() }
    func testDeletedRecoveryAndPrimarySemanticErrorsInvalidate() async throws { try await WhoopSyncServiceTestSupport.deletedRecoveryAndPrimarySemanticErrorsInvalidate() }
    func testSecondaryFailuresDoNotInvalidatePrimary() async throws { try await WhoopSyncServiceTestSupport.secondaryFailuresDoNotInvalidatePrimary() }
    func testSecondaryAuthenticationInvalidatesPrimary() async throws { try await WhoopSyncServiceTestSupport.secondaryAuthenticationInvalidatesPrimary() }
    func testEmptyWorkoutsAreComplete() async throws { try await WhoopSyncServiceTestSupport.emptyWorkoutsAreComplete() }
    func testWorkoutSelectionUsesWindowStrainAndDeterministicTies() async throws { try await WhoopSyncServiceTestSupport.workoutSelectionUsesWindowStrainAndDeterministicTies() }
    func testInvalidSecondaryRecordsArePartialButUseful() async throws { try await WhoopSyncServiceTestSupport.invalidSecondaryRecordsArePartialButUseful() }
    func testCancellationOnlyRecordsAttempt() async throws { try await WhoopSyncServiceTestSupport.cancellationOnlyRecordsAttempt() }
    func testSecondarySemanticsAndBoundariesAreExact() async throws { try await WhoopSyncServiceTestSupport.secondarySemanticsAndBoundariesAreExact() }
    func testInvalidClockAndStorageFailuresDoNotCallAPI() async throws { try await WhoopSyncServiceTestSupport.invalidClockAndStorageFailuresDoNotCallAPI() }
    func testSoftOffSkipsAttemptAndNetworkThenReenableRefreshes() async throws { try await WhoopSyncServiceTestSupport.softOffSkipsAttemptAndNetworkThenReenableRefreshes() }
    func testInvalidValidationClockUsesTransientCacheRules() async throws { try await WhoopSyncServiceTestSupport.invalidValidationClockUsesTransientCacheRules() }
    func testMidflightSoftOffStopsAtEveryAPIStage() async throws { try await WhoopSyncServiceTestSupport.midflightSoftOffStopsAtEveryAPIStage() }
    func testOverlappingRefreshesAreSingleFlightAndWaiterCancellationSafe() async throws { try await WhoopSyncServiceTestSupport.overlappingRefreshesAreSingleFlightAndWaiterCancellationSafe() }
    func testSyncMapsStaleApplicationsToRetainedCache() async throws { try await WhoopSyncServiceTestSupport.syncMapsStaleApplicationsToRetainedCache() }
    func testStaleFailuresCannotInvalidateNewerCrossProcessRecovery() async throws { try await WhoopSyncServiceTestSupport.staleFailuresCannotInvalidateNewerCrossProcessRecovery() }
    func testLaterInvalidatingRefreshPreventsOlderSuccessfulResurrection() async throws { try await WhoopSyncServiceTestSupport.laterInvalidatingRefreshPreventsOlderSuccessfulResurrection() }
    func testLaterRefreshStartStopsOlderBeforeAdditionalEndpoints() async throws { try await WhoopSyncServiceTestSupport.laterRefreshStartStopsOlderBeforeAdditionalEndpoints() }
    func testOffOnCannotReviveSupersededOperation() async throws { try await WhoopSyncServiceTestSupport.offOnCannotReviveSupersededOperation() }
    func testOffOnStartsNewRefreshInsteadOfJoiningSupersededSingleFlight() async throws { try await WhoopSyncServiceTestSupport.offOnStartsNewRefreshInsteadOfJoiningSupersededSingleFlight() }
    func testWorkoutReplenishmentUsesEnableWindowAndDeduplicates() async throws { try await WhoopSyncServiceTestSupport.workoutReplenishmentUsesEnableWindowAndDeduplicates() }
}
#else
import Testing

@Suite struct WhoopSyncServiceTests {
    @Test func engineBookkeepingSeams() async throws { try await WhoopSyncServiceTestSupport.engineBookkeepingSeams() }
    @Test func scoredRecoveryBuildsCompleteSnapshotAndCharge() async throws { try await WhoopSyncServiceTestSupport.scoredRecoveryBuildsCompleteSnapshotAndCharge() }
    @Test func sameCycleNeverRefillsAndNewCycleAlwaysResets() async throws { try await WhoopSyncServiceTestSupport.sameCycleNeverRefillsAndNewCycleAlwaysResets() }
    @Test func ineligibleRecoveryStatesInvalidate() async throws { try await WhoopSyncServiceTestSupport.ineligibleRecoveryStatesInvalidate() }
    @Test func authenticationAndMissingCredentialsInvalidate() async throws { try await WhoopSyncServiceTestSupport.authenticationAndMissingCredentialsInvalidate() }
    @Test func transientBeforeLatestRetainsOnlyCurrentReadyCache() async throws { try await WhoopSyncServiceTestSupport.transientBeforeLatestRetainsOnlyCurrentReadyCache() }
    @Test func refreshRequiredDoesNotResumeBeforeLatestButSameCycleProofCanResume() async throws { try await WhoopSyncServiceTestSupport.refreshRequiredDoesNotResumeBeforeLatestButSameCycleProofCanResume() }
    @Test func transientWithoutCacheAndDifferentCycleDegrade() async throws { try await WhoopSyncServiceTestSupport.transientWithoutCacheAndDifferentCycleDegrade() }
    @Test func endedLatestAndEndedCacheCannotMaskFailure() async throws { try await WhoopSyncServiceTestSupport.endedLatestAndEndedCacheCannotMaskFailure() }
    @Test func deletedRecoveryAndPrimarySemanticErrorsInvalidate() async throws { try await WhoopSyncServiceTestSupport.deletedRecoveryAndPrimarySemanticErrorsInvalidate() }
    @Test func secondaryFailuresDoNotInvalidatePrimary() async throws { try await WhoopSyncServiceTestSupport.secondaryFailuresDoNotInvalidatePrimary() }
    @Test func secondaryAuthenticationInvalidatesPrimary() async throws { try await WhoopSyncServiceTestSupport.secondaryAuthenticationInvalidatesPrimary() }
    @Test func emptyWorkoutsAreComplete() async throws { try await WhoopSyncServiceTestSupport.emptyWorkoutsAreComplete() }
    @Test func workoutSelectionUsesWindowStrainAndDeterministicTies() async throws { try await WhoopSyncServiceTestSupport.workoutSelectionUsesWindowStrainAndDeterministicTies() }
    @Test func invalidSecondaryRecordsArePartialButUseful() async throws { try await WhoopSyncServiceTestSupport.invalidSecondaryRecordsArePartialButUseful() }
    @Test func cancellationOnlyRecordsAttempt() async throws { try await WhoopSyncServiceTestSupport.cancellationOnlyRecordsAttempt() }
    @Test func secondarySemanticsAndBoundariesAreExact() async throws { try await WhoopSyncServiceTestSupport.secondarySemanticsAndBoundariesAreExact() }
    @Test func invalidClockAndStorageFailuresDoNotCallAPI() async throws { try await WhoopSyncServiceTestSupport.invalidClockAndStorageFailuresDoNotCallAPI() }
    @Test func softOffSkipsAttemptAndNetworkThenReenableRefreshes() async throws { try await WhoopSyncServiceTestSupport.softOffSkipsAttemptAndNetworkThenReenableRefreshes() }
    @Test func invalidValidationClockUsesTransientCacheRules() async throws { try await WhoopSyncServiceTestSupport.invalidValidationClockUsesTransientCacheRules() }
    @Test func midflightSoftOffStopsAtEveryAPIStage() async throws { try await WhoopSyncServiceTestSupport.midflightSoftOffStopsAtEveryAPIStage() }
    @Test func overlappingRefreshesAreSingleFlightAndWaiterCancellationSafe() async throws { try await WhoopSyncServiceTestSupport.overlappingRefreshesAreSingleFlightAndWaiterCancellationSafe() }
    @Test func syncMapsStaleApplicationsToRetainedCache() async throws { try await WhoopSyncServiceTestSupport.syncMapsStaleApplicationsToRetainedCache() }
    @Test func staleFailuresCannotInvalidateNewerCrossProcessRecovery() async throws { try await WhoopSyncServiceTestSupport.staleFailuresCannotInvalidateNewerCrossProcessRecovery() }
    @Test func laterInvalidatingRefreshPreventsOlderSuccessfulResurrection() async throws { try await WhoopSyncServiceTestSupport.laterInvalidatingRefreshPreventsOlderSuccessfulResurrection() }
    @Test func laterRefreshStartStopsOlderBeforeAdditionalEndpoints() async throws { try await WhoopSyncServiceTestSupport.laterRefreshStartStopsOlderBeforeAdditionalEndpoints() }
    @Test func offOnCannotReviveSupersededOperation() async throws { try await WhoopSyncServiceTestSupport.offOnCannotReviveSupersededOperation() }
    @Test func offOnStartsNewRefreshInsteadOfJoiningSupersededSingleFlight() async throws { try await WhoopSyncServiceTestSupport.offOnStartsNewRefreshInsteadOfJoiningSupersededSingleFlight() }
    @Test func workoutReplenishmentUsesEnableWindowAndDeduplicates() async throws { try await WhoopSyncServiceTestSupport.workoutReplenishmentUsesEnableWindowAndDeduplicates() }
}
#endif
