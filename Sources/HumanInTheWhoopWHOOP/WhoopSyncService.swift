import Foundation
import HumanInTheWhoopCore

public enum SyncOutcome: Equatable, Sendable {
    case refreshed(RecoverySnapshot)
    case retainedCache(message: String)
    case degraded(reason: String)
}

public actor WhoopSyncService {
    private let api: any WhoopAPI
    private let engine: ChargeEngine
    private let now: @Sendable () -> Date
    private var activeRefresh: (id: UUID, task: Task<SyncOutcome, Never>)?

    private static let authenticationMessage = "WHOOP authentication is required."
    private static let invalidDataMessage = "WHOOP returned data that could not be validated."
    private static let rateLimitedMessage = "WHOOP sync is temporarily rate limited."
    private static let unavailableMessage = "WHOOP sync is temporarily unavailable."
    private static let cancelledMessage = "Refresh cancelled."
    private static let softOffMessage = "Human in the Whoop is off."
    private static let staleRecoveryMessage = "A newer WHOOP Recovery is already active."
    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    public init(
        api: any WhoopAPI,
        engine: ChargeEngine,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.engine = engine
        self.now = now
    }

    public func refresh() async -> SyncOutcome {
        if let activeRefresh {
            do {
                if try engine.syncOperationReadiness(operationID: activeRefresh.id) == .applied {
                    return await activeRefresh.task.value
                }
            } catch {
                return .degraded(reason: Self.unavailableMessage)
            }
        }

        let operationID = UUID()
        let initialState: PersistentState
        do {
            switch try engine.beginSyncIfEnabled(operationID: operationID) {
            case .started(let state):
                initialState = state
            case .disabled:
                return .degraded(reason: Self.softOffMessage)
            }
        } catch {
            return .degraded(reason: Self.unavailableMessage)
        }

        let task = Task {
            await self.performRefresh(
                operationID: operationID,
                initialState: initialState
            )
        }
        activeRefresh = (operationID, task)
        let outcome = await task.value
        if activeRefresh?.id == operationID {
            activeRefresh = nil
        }
        return outcome
    }

    private func performRefresh(
        operationID: UUID,
        initialState: PersistentState
    ) async -> SyncOutcome {
        do {
            if let readinessOutcome = readinessOutcome(
                operationID: operationID,
                expectedRecovery: initialState.recovery
            ) {
                return readinessOutcome
            }
            try Task.checkCancellation()
            let cycle: WhoopCycleDTO
            do {
                cycle = try await api.latestCycle()
            } catch {
                if let readinessOutcome = readinessOutcome(
                    operationID: operationID,
                    expectedRecovery: initialState.recovery
                ) {
                    return readinessOutcome
                }
                return handlePrimaryError(
                    error,
                    state: initialState,
                    provenCycleID: nil,
                    operationID: operationID
                )
            }

            if let readinessOutcome = readinessOutcome(
                operationID: operationID,
                expectedRecovery: initialState.recovery
            ) {
                return readinessOutcome
            }
            try Task.checkCancellation()
            guard Self.isValidActiveCycle(cycle) else {
                return markInvalidData(
                    expectedRecovery: initialState.recovery,
                    operationID: operationID
                )
            }

            if let readinessOutcome = readinessOutcome(
                operationID: operationID,
                expectedRecovery: initialState.recovery
            ) {
                return readinessOutcome
            }
            let recovery: WhoopRecoveryDTO
            do {
                recovery = try await api.recovery(cycleID: cycle.id)
            } catch {
                if let readinessOutcome = readinessOutcome(
                    operationID: operationID,
                    expectedRecovery: initialState.recovery
                ) {
                    return readinessOutcome
                }
                return handlePrimaryError(
                    error,
                    state: initialState,
                    provenCycleID: cycle.id,
                    operationID: operationID
                )
            }

            if let readinessOutcome = readinessOutcome(
                operationID: operationID,
                expectedRecovery: initialState.recovery
            ) {
                return readinessOutcome
            }
            try Task.checkCancellation()
            guard Self.isValidPrimaryRecovery(recovery, cycleID: cycle.id) else {
                return markInvalidData(
                    expectedRecovery: initialState.recovery,
                    operationID: operationID
                )
            }

            let cycleStrain = Self.validCycleStrain(cycle)
            var secondaryDataComplete = cycleStrain != nil

            var sleepPerformance: Double?
            if let readinessOutcome = readinessOutcome(
                operationID: operationID,
                expectedRecovery: initialState.recovery
            ) {
                return readinessOutcome
            }
            do {
                let sleep = try await api.sleep(cycleID: cycle.id)
                if let readinessOutcome = readinessOutcome(
                    operationID: operationID,
                    expectedRecovery: initialState.recovery
                ) {
                    return readinessOutcome
                }
                sleepPerformance = Self.validSleepPerformance(
                    sleep,
                    cycleID: cycle.id,
                    sleepID: recovery.sleepID
                )
                if sleepPerformance == nil {
                    secondaryDataComplete = false
                }
            } catch {
                if let readinessOutcome = readinessOutcome(
                    operationID: operationID,
                    expectedRecovery: initialState.recovery
                ) {
                    return readinessOutcome
                }
                if Self.isCancellation(error) {
                    return cancellationOutcome(
                        state: initialState,
                        operationID: operationID
                    )
                }
                if Self.isAuthentication(error) {
                    return markAuthenticationFailure(
                        expectedRecovery: initialState.recovery,
                        operationID: operationID
                    )
                }
                sleepPerformance = nil
                secondaryDataComplete = false
            }

            try Task.checkCancellation()
            let refreshTime = now()
            guard refreshTime.timeIntervalSinceReferenceDate.isFinite else {
                return retainOrDegradeTransient(
                    .unavailable,
                    state: initialState,
                    provenCycleID: cycle.id,
                    operationID: operationID
                )
            }
            var recentWorkout: WorkoutSnapshot?
            var workoutAwardCandidates: [WorkoutAwardCandidate] = []
            if let readinessOutcome = readinessOutcome(
                operationID: operationID,
                expectedRecovery: initialState.recovery
            ) {
                return readinessOutcome
            }
            do {
                let recommendationStart = refreshTime.addingTimeInterval(-6 * 60 * 60)
                let rewardStart = max(
                    initialState.workoutRewards?.startedAt ?? refreshTime,
                    cycle.start
                )
                let workouts = try await api.workouts(
                    start: min(recommendationStart, rewardStart),
                    end: refreshTime
                )
                if let readinessOutcome = readinessOutcome(
                    operationID: operationID,
                    expectedRecovery: initialState.recovery
                ) {
                    return readinessOutcome
                }
                let result = Self.validateWorkouts(
                    workouts,
                    now: refreshTime,
                    rewardEligibleAfter: rewardStart
                )
                recentWorkout = result.recent
                workoutAwardCandidates = result.awardCandidates
                if !result.complete {
                    secondaryDataComplete = false
                }
            } catch {
                if let readinessOutcome = readinessOutcome(
                    operationID: operationID,
                    expectedRecovery: initialState.recovery
                ) {
                    return readinessOutcome
                }
                if Self.isCancellation(error) {
                    return cancellationOutcome(
                        state: initialState,
                        operationID: operationID
                    )
                }
                if Self.isAuthentication(error) {
                    return markAuthenticationFailure(
                        expectedRecovery: initialState.recovery,
                        operationID: operationID
                    )
                }
                recentWorkout = nil
                workoutAwardCandidates = []
                secondaryDataComplete = false
            }

            try Task.checkCancellation()
            let snapshot = RecoverySnapshot(
                cycleID: cycle.id,
                sleepID: recovery.sleepID,
                recoveryScore: recovery.score!.recoveryScore,
                createdAt: recovery.createdAt,
                updatedAt: recovery.updatedAt,
                cycleStart: cycle.start,
                cycleEnd: cycle.end,
                sleepPerformance: sleepPerformance,
                cycleStrain: cycleStrain,
                recentWorkout: recentWorkout,
                secondaryDataComplete: secondaryDataComplete,
                validatedAt: refreshTime
            )

            do {
                switch try engine.applyRecoveryAndWorkoutsIfEnabled(
                    snapshot,
                    workoutCandidates: workoutAwardCandidates,
                    syncOperationID: operationID
                ) {
                case .applied:
                    return .refreshed(snapshot)
                case .disabled:
                    return .degraded(reason: Self.softOffMessage)
                case .ignoredStale:
                    return .retainedCache(message: Self.staleRecoveryMessage)
                case .superseded:
                    return supersededOutcome(
                        expectedRecovery: initialState.recovery
                    )
                }
            } catch {
                return .degraded(reason: Self.unavailableMessage)
            }
        } catch is CancellationError {
            return cancellationOutcome(
                state: initialState,
                operationID: operationID
            )
        } catch {
            return markUnavailable(
                invalidatesCache: false,
                expectedRecovery: initialState.recovery,
                operationID: operationID
            )
        }
    }

    private func readinessOutcome(
        operationID: UUID,
        expectedRecovery: RecoverySnapshot?
    ) -> SyncOutcome? {
        do {
            switch try engine.syncOperationReadiness(operationID: operationID) {
            case .applied:
                return nil
            case .disabled:
                return .degraded(reason: Self.softOffMessage)
            case .superseded:
                return supersededOutcome(expectedRecovery: expectedRecovery)
            }
        } catch {
            return .degraded(reason: Self.unavailableMessage)
        }
    }

    private func handlePrimaryError(
        _ error: any Error,
        state: PersistentState,
        provenCycleID: Int64?,
        operationID: UUID
    ) -> SyncOutcome {
        if Self.isCancellation(error) {
            return cancellationOutcome(state: state, operationID: operationID)
        }
        if Self.isAuthentication(error) {
            return markAuthenticationFailure(
                expectedRecovery: state.recovery,
                operationID: operationID
            )
        }

        guard let apiError = error as? WhoopAPIError else {
            return retainOrDegradeTransient(
                .unavailable,
                state: state,
                provenCycleID: provenCycleID,
                operationID: operationID
            )
        }
        switch apiError {
        case .notFound, .decoding, .invalidResponse:
            return markInvalidData(
                expectedRecovery: state.recovery,
                operationID: operationID
            )
        case .rateLimited:
            return retainOrDegradeTransient(
                .rateLimited,
                state: state,
                provenCycleID: provenCycleID,
                operationID: operationID
            )
        case .server, .transport:
            return retainOrDegradeTransient(
                .unavailable,
                state: state,
                provenCycleID: provenCycleID,
                operationID: operationID
            )
        case .authenticationFailed, .missingCredentials:
            return markAuthenticationFailure(
                expectedRecovery: state.recovery,
                operationID: operationID
            )
        }
    }

    private func retainOrDegradeTransient(
        _ reason: SyncFailureReason,
        state: PersistentState,
        provenCycleID: Int64?,
        operationID: UUID
    ) -> SyncOutcome {
        let cacheIsValid = Self.hasValidCachedLedger(state)
        let canRetain: Bool
        if let provenCycleID {
            canRetain = cacheIsValid && state.recovery?.cycleID == provenCycleID
        } else {
            canRetain = cacheIsValid
                && state.enabled
                && state.degradedReason == nil
        }

        if canRetain {
            do {
                switch try engine.recordRetainedCacheFailureIfEnabled(
                    reason,
                    expectedRecovery: state.recovery,
                    syncOperationID: operationID
                ) {
                case .applied:
                    return .retainedCache(message: Self.message(for: reason))
                case .disabled:
                    return .degraded(reason: Self.softOffMessage)
                case .superseded:
                    return supersededOutcome(expectedRecovery: state.recovery)
                }
            } catch {
                return markUnavailable(
                    invalidatesCache: true,
                    expectedRecovery: state.recovery,
                    operationID: operationID
                )
            }
        }

        let invalidatesCache: Bool
        if let provenCycleID {
            invalidatesCache = !cacheIsValid || state.recovery?.cycleID != provenCycleID
        } else {
            invalidatesCache = !cacheIsValid
        }
        return markFailure(
            reason,
            invalidatesCache: invalidatesCache,
            expectedRecovery: state.recovery,
            operationID: operationID
        )
    }

    private func cancellationOutcome(
        state: PersistentState,
        operationID: UUID
    ) -> SyncOutcome {
        do {
            switch try engine.finishSyncIfCurrent(operationID: operationID) {
            case .applied:
                if Self.hasValidCachedLedger(state) {
                    return .retainedCache(message: Self.cancelledMessage)
                }
                return .degraded(reason: Self.cancelledMessage)
            case .disabled:
                return .degraded(reason: Self.softOffMessage)
            case .superseded:
                return supersededOutcome(expectedRecovery: state.recovery)
            }
        } catch {
            return .degraded(reason: Self.unavailableMessage)
        }
    }

    private func markAuthenticationFailure(
        expectedRecovery: RecoverySnapshot?,
        operationID: UUID
    ) -> SyncOutcome {
        markFailure(
            .authentication,
            invalidatesCache: true,
            expectedRecovery: expectedRecovery,
            operationID: operationID
        )
    }

    private func markInvalidData(
        expectedRecovery: RecoverySnapshot?,
        operationID: UUID
    ) -> SyncOutcome {
        markFailure(
            .invalidData,
            invalidatesCache: true,
            expectedRecovery: expectedRecovery,
            operationID: operationID
        )
    }

    private func markUnavailable(
        invalidatesCache: Bool,
        expectedRecovery: RecoverySnapshot?,
        operationID: UUID
    ) -> SyncOutcome {
        markFailure(
            .unavailable,
            invalidatesCache: invalidatesCache,
            expectedRecovery: expectedRecovery,
            operationID: operationID
        )
    }

    private func markFailure(
        _ reason: SyncFailureReason,
        invalidatesCache: Bool,
        expectedRecovery: RecoverySnapshot?,
        operationID: UUID
    ) -> SyncOutcome {
        do {
            switch try engine.markSyncFailureIfEnabled(
                reason,
                invalidatesCache: invalidatesCache,
                expectedRecovery: expectedRecovery,
                syncOperationID: operationID
            ) {
            case .applied:
                return .degraded(reason: Self.message(for: reason))
            case .disabled:
                return .degraded(reason: Self.softOffMessage)
            case .superseded:
                return supersededOutcome(expectedRecovery: expectedRecovery)
            }
        } catch {
            return .degraded(reason: Self.message(for: reason))
        }
    }

    private func supersededOutcome(
        expectedRecovery: RecoverySnapshot?
    ) -> SyncOutcome {
        do {
            let state = try engine.currentState()
            guard state.enabled else {
                return .degraded(reason: Self.softOffMessage)
            }
            guard state.degradedReason == nil,
                  Self.hasValidCachedLedger(state),
                  Self.isSupersedingRecovery(
                      state.recovery,
                      expectedRecovery: expectedRecovery
                  )
            else {
                return .degraded(reason: Self.unavailableMessage)
            }
            return .retainedCache(message: Self.staleRecoveryMessage)
        } catch {
            return .degraded(reason: Self.unavailableMessage)
        }
    }

    private static func message(for reason: SyncFailureReason) -> String {
        switch reason {
        case .authentication:
            authenticationMessage
        case .rateLimited:
            rateLimitedMessage
        case .invalidData:
            invalidDataMessage
        case .unavailable, .refreshRequired, .ledgerCorrupt:
            unavailableMessage
        }
    }

    private static func isAuthentication(_ error: any Error) -> Bool {
        guard let error = error as? WhoopAPIError else { return false }
        return switch error {
        case .authenticationFailed, .missingCredentials:
            true
        default:
            false
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError
    }

    private static func isValidActiveCycle(_ cycle: WhoopCycleDTO) -> Bool {
        cycle.id > 0
            && cycle.start.timeIntervalSinceReferenceDate.isFinite
            && cycle.end == nil
    }

    private static func isValidPrimaryRecovery(
        _ recovery: WhoopRecoveryDTO,
        cycleID: Int64
    ) -> Bool {
        recovery.cycleID == cycleID
            && recovery.cycleID > 0
            && recovery.sleepID != zeroUUID
            && recovery.createdAt.timeIntervalSinceReferenceDate.isFinite
            && recovery.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && recovery.scoreState == .scored
            && recovery.score.map { (0...100).contains($0.recoveryScore) } == true
    }

    private static func validCycleStrain(_ cycle: WhoopCycleDTO) -> Double? {
        guard cycle.scoreState == .scored,
              let strain = cycle.score?.strain,
              strain.isFinite,
              (0...21).contains(strain)
        else {
            return nil
        }
        return strain
    }

    private static func validSleepPerformance(
        _ sleep: WhoopSleepDTO?,
        cycleID: Int64,
        sleepID: UUID
    ) -> Double? {
        guard let sleep,
              sleep.id == sleepID,
              sleep.id != zeroUUID,
              sleep.cycleID == cycleID,
              sleep.scoreState == .scored,
              let performance = sleep.score?.sleepPerformancePercentage,
              performance.isFinite,
              (0...100).contains(performance)
        else {
            return nil
        }
        return performance
    }

    private static func validateWorkouts(
        _ workouts: [WhoopWorkoutDTO],
        now: Date,
        rewardEligibleAfter: Date
    ) -> (
        recent: WorkoutSnapshot?,
        awardCandidates: [WorkoutAwardCandidate],
        complete: Bool
    ) {
        let earliest = now.addingTimeInterval(-6 * 60 * 60)
        var complete = true
        var eligible: [WhoopWorkoutDTO] = []
        var awardCandidates: [WorkoutAwardCandidate] = []

        for workout in workouts {
            guard workout.id != zeroUUID,
                  workout.end.timeIntervalSinceReferenceDate.isFinite,
                  workout.scoreState == .scored,
                  let strain = workout.score?.strain,
                  strain.isFinite,
                  (0...21).contains(strain)
            else {
                complete = false
                continue
            }
            if workout.end >= earliest, workout.end <= now {
                eligible.append(workout)
            }
            if workout.end >= rewardEligibleAfter, workout.end <= now {
                awardCandidates.append(
                    WorkoutAwardCandidate(
                        id: workout.id,
                        strain: strain,
                        endedAt: workout.end
                    )
                )
            }
        }

        let selected = eligible.sorted { lhs, rhs in
            let lhsStrain = lhs.score!.strain
            let rhsStrain = rhs.score!.strain
            if lhsStrain != rhsStrain { return lhsStrain > rhsStrain }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first

        let recent = selected.map {
            WorkoutSnapshot(strain: $0.score!.strain, endedAt: $0.end)
        }
        return (recent, awardCandidates, complete)
    }

    private static func hasValidCachedLedger(_ state: PersistentState) -> Bool {
        guard let recovery = state.recovery,
              let charge = state.chargeRemaining,
              recovery.cycleID > 0,
              recovery.sleepID != zeroUUID,
              (0...100).contains(recovery.recoveryScore),
              (0...100).contains(charge),
              recovery.createdAt.timeIntervalSinceReferenceDate.isFinite,
              recovery.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              recovery.cycleStart.timeIntervalSinceReferenceDate.isFinite,
              recovery.validatedAt.timeIntervalSinceReferenceDate.isFinite,
              recovery.cycleEnd == nil
        else {
            return false
        }
        return true
    }

    private static func isSupersedingRecovery(
        _ current: RecoverySnapshot?,
        expectedRecovery: RecoverySnapshot?
    ) -> Bool {
        guard let current, current != expectedRecovery else {
            return false
        }
        guard let expectedRecovery else {
            return true
        }
        if current.cycleID != expectedRecovery.cycleID {
            return current.cycleStart > expectedRecovery.cycleStart
        }
        return current.updatedAt > expectedRecovery.updatedAt
            || (
                current.updatedAt == expectedRecovery.updatedAt
                    && current.validatedAt >= expectedRecovery.validatedAt
            )
    }
}
