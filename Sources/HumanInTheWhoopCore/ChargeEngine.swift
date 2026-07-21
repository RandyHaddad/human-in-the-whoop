import Foundation

public enum SyncFailureReason: String, Codable, Equatable, Sendable {
    case unavailable
    case authentication
    case rateLimited
    case invalidData
    case refreshRequired
    case ledgerCorrupt

    public var userMessage: String {
        switch self {
        case .unavailable:
            "WHOOP sync is temporarily unavailable."
        case .authentication:
            "WHOOP authentication is required."
        case .rateLimited:
            "WHOOP sync is temporarily rate limited."
        case .invalidData:
            "WHOOP returned data that could not be validated."
        case .refreshRequired:
            "WHOOP refresh is required before Charge can resume."
        case .ledgerCorrupt:
            "Local Charge data could not be validated."
        }
    }
}

public enum RecoveryApplicationResult: Equatable, Sendable {
    case applied
    case disabled
    case ignoredStale
    case superseded
}

public enum EnabledSyncMutationResult: Equatable, Sendable {
    case applied
    case disabled
    case superseded
}

public enum SyncStartResult: Equatable, Sendable {
    case started(PersistentState)
    case disabled
}

/// Opaque in-memory rollback token for the bounded local installer transaction.
/// It is intentionally not Codable and is never written to logs or shell output.
public struct InstallationSoftOffSnapshot: Sendable {
    fileprivate let prior: PersistentState
    fileprivate let softOff: PersistentState
}

public final class ChargeEngine: @unchecked Sendable {
    private let store: SQLiteStateStore
    private let now: @Sendable () -> Date

    private static let continueOnceCommand = "continue once"
    private static let nothingToContinueMessage = "There is no pending redirect to continue."

    public init(
        store: SQLiteStateStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    public func handlePrompt(_ input: HookInput) throws -> ChargeDecision {
        try withPromptDecision(for: input) { $0 }
    }

    /// Runs prompt mutation and its synchronous consumer in the same transaction.
    /// If the consumer throws, no prompt state is committed.
    public func withPromptDecision<T>(
        for input: HookInput,
        _ body: (ChargeDecision) throws -> T
    ) throws -> T {
        try store.mutate { state in
            try body(Self.promptDecision(for: input, state: &state))
        }
    }

    public func applyRecovery(_ snapshot: RecoverySnapshot) throws {
        _ = try applyRecovery(
            snapshot,
            requiresEnabled: false,
            syncOperationID: nil,
            workoutCandidates: nil
        )
    }

    public func applyRecoveryIfEnabled(
        _ snapshot: RecoverySnapshot
    ) throws -> RecoveryApplicationResult {
        try applyRecovery(
            snapshot,
            requiresEnabled: true,
            syncOperationID: nil,
            workoutCandidates: nil
        )
    }

    public func applyRecoveryIfEnabled(
        _ snapshot: RecoverySnapshot,
        syncOperationID: UUID
    ) throws -> RecoveryApplicationResult {
        try applyRecovery(
            snapshot,
            requiresEnabled: true,
            syncOperationID: syncOperationID,
            workoutCandidates: nil
        )
    }

    public func applyRecoveryAndWorkoutsIfEnabled(
        _ snapshot: RecoverySnapshot,
        workoutCandidates: [WorkoutAwardCandidate],
        syncOperationID: UUID
    ) throws -> RecoveryApplicationResult {
        try applyRecovery(
            snapshot,
            requiresEnabled: true,
            syncOperationID: syncOperationID,
            workoutCandidates: workoutCandidates
        )
    }

    private func applyRecovery(
        _ snapshot: RecoverySnapshot,
        requiresEnabled: Bool,
        syncOperationID: UUID?,
        workoutCandidates: [WorkoutAwardCandidate]?
    ) throws -> RecoveryApplicationResult {
        try store.mutateAndAppendAudits { state in
            if requiresEnabled, !state.enabled {
                return (.disabled, [])
            }
            if let syncOperationID, state.syncOperationID != syncOperationID {
                return (.superseded, [])
            }
            guard Self.isValidLedgerValue(snapshot.recoveryScore) else {
                throw ChargeEngineError.invalidRecoveryScore
            }
            guard snapshot.cycleStart.timeIntervalSinceReferenceDate.isFinite,
                  snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  snapshot.validatedAt.timeIntervalSinceReferenceDate.isFinite
            else {
                throw ChargeEngineError.invalidRecoveryChronology
            }

            if let current = state.recovery {
                if current.cycleID != snapshot.cycleID {
                    guard snapshot.cycleStart > current.cycleStart else {
                        if syncOperationID != nil {
                            state.syncOperationID = nil
                        }
                        return (.ignoredStale, [])
                    }
                } else {
                    guard snapshot.updatedAt > current.updatedAt
                            || (
                                snapshot.updatedAt == current.updatedAt
                                    && snapshot.validatedAt >= current.validatedAt
                            )
                    else {
                        if syncOperationID != nil {
                            state.syncOperationID = nil
                        }
                        return (.ignoredStale, [])
                    }
                }
            }
            let startsNewCycle = state.recovery?.cycleID != snapshot.cycleID

            state.recovery = snapshot
            state.lastSyncAttemptAt = snapshot.validatedAt
            if startsNewCycle {
                state.chargeRemaining = snapshot.recoveryScore
                state.pendingOverride = nil
                state.degradedReason = nil
                state.degradedWarningEmitted = false
                state.lastSyncSuccessAt = snapshot.validatedAt
                state.lastSyncError = nil
            } else {
                switch Self.validateReadyState(state) {
                case .ready:
                    state.degradedReason = nil
                    state.degradedWarningEmitted = false
                    state.lastSyncSuccessAt = snapshot.validatedAt
                    state.lastSyncError = nil
                case .missing, .corrupt:
                    Self.transitionToLedgerCorrupt(&state)
                }
            }

            var auditEvents: [AuditEvent] = []
            if let workoutCandidates {
                auditEvents = try Self.applyWorkoutAwards(
                    workoutCandidates,
                    recovery: snapshot,
                    state: &state
                )
            }
            if syncOperationID != nil {
                state.syncOperationID = nil
            }
            return (.applied, auditEvents)
        }
    }

    public func beginSyncIfEnabled(
        operationID: UUID
    ) throws -> SyncStartResult {
        let attemptedAt = now()
        return try store.mutate { state in
            guard state.enabled else {
                return .disabled
            }
            guard attemptedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ChargeEngineError.invalidSyncTimestamp
            }
            if state.workoutRewards == nil {
                state.workoutRewards = WorkoutRewardEpoch(
                    startedAt: attemptedAt,
                    cycleID: state.recovery?.cycleID
                )
            }
            state.lastSyncAttemptAt = attemptedAt
            state.syncOperationID = operationID
            return .started(state)
        }
    }

    public func syncOperationReadiness(
        operationID: UUID
    ) throws -> EnabledSyncMutationResult {
        let state = try store.read()
        guard state.enabled else {
            return .disabled
        }
        guard state.syncOperationID == operationID else {
            return .superseded
        }
        return .applied
    }

    public func finishSyncIfCurrent(
        operationID: UUID
    ) throws -> EnabledSyncMutationResult {
        try store.mutate { state in
            guard state.enabled else {
                return .disabled
            }
            guard state.syncOperationID == operationID else {
                return .superseded
            }
            state.syncOperationID = nil
            return .applied
        }
    }

    /// Records that a refresh is about to cross the network boundary without
    /// changing Recovery, Charge, or readiness.
    public func recordSyncAttempt() throws {
        _ = try recordSyncAttempt(requiresEnabled: false)
    }

    public func recordSyncAttemptIfEnabled() throws -> EnabledSyncMutationResult {
        try recordSyncAttempt(requiresEnabled: true)
    }

    private func recordSyncAttempt(
        requiresEnabled: Bool
    ) throws -> EnabledSyncMutationResult {
        let attemptedAt = now()
        return try store.mutate { state in
            if requiresEnabled, !state.enabled {
                return .disabled
            }
            guard attemptedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ChargeEngineError.invalidSyncTimestamp
            }
            state.lastSyncAttemptAt = attemptedAt
            return .applied
        }
    }

    /// Records a sanitized transient failure while retaining a proven active
    /// Recovery ledger. This never repairs or refills Charge.
    public func recordRetainedCacheFailure(_ reason: SyncFailureReason) throws {
        _ = try recordRetainedCacheFailure(
            reason,
            requiresEnabled: false,
            expectedRecovery: nil,
            syncOperationID: nil
        )
    }

    public func recordRetainedCacheFailureIfEnabled(
        _ reason: SyncFailureReason,
        expectedRecovery: RecoverySnapshot?
    ) throws -> EnabledSyncMutationResult {
        try recordRetainedCacheFailure(
            reason,
            requiresEnabled: true,
            expectedRecovery: .some(expectedRecovery),
            syncOperationID: nil
        )
    }

    public func recordRetainedCacheFailureIfEnabled(
        _ reason: SyncFailureReason,
        expectedRecovery: RecoverySnapshot?,
        syncOperationID: UUID
    ) throws -> EnabledSyncMutationResult {
        try recordRetainedCacheFailure(
            reason,
            requiresEnabled: true,
            expectedRecovery: .some(expectedRecovery),
            syncOperationID: syncOperationID
        )
    }

    private func recordRetainedCacheFailure(
        _ reason: SyncFailureReason,
        requiresEnabled: Bool,
        expectedRecovery: RecoverySnapshot??,
        syncOperationID: UUID?
    ) throws -> EnabledSyncMutationResult {
        let attemptedAt = now()
        return try store.mutate { state in
            if requiresEnabled, !state.enabled {
                return .disabled
            }
            if let syncOperationID, state.syncOperationID != syncOperationID {
                return .superseded
            }
            if let expectedRecovery, state.recovery != expectedRecovery {
                return .superseded
            }
            guard attemptedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ChargeEngineError.invalidSyncTimestamp
            }
            guard reason == .unavailable || reason == .rateLimited,
                  case .ready = Self.validateReadyState(state),
                  let recovery = state.recovery,
                  Self.isValidActiveCachedRecovery(recovery)
            else {
                throw ChargeEngineError.invalidRetainedCache
            }

            state.lastSyncAttemptAt = attemptedAt
            state.lastSyncError = reason.rawValue
            state.degradedReason = nil
            state.degradedWarningEmitted = false
            if syncOperationID != nil {
                state.syncOperationID = nil
            }
            return .applied
        }
    }

    public func markSyncFailure(_ reason: String, invalidatesCache: Bool) throws {
        let safeReason = SyncFailureReason(rawValue: reason) ?? .unavailable
        try markSyncFailure(safeReason, invalidatesCache: invalidatesCache)
    }

    public func markSyncFailure(
        _ reason: SyncFailureReason,
        invalidatesCache: Bool
    ) throws {
        _ = try markSyncFailure(
            reason,
            invalidatesCache: invalidatesCache,
            requiresEnabled: false,
            expectedRecovery: nil,
            syncOperationID: nil
        )
    }

    public func markSyncFailureIfEnabled(
        _ reason: SyncFailureReason,
        invalidatesCache: Bool,
        expectedRecovery: RecoverySnapshot?
    ) throws -> EnabledSyncMutationResult {
        try markSyncFailure(
            reason,
            invalidatesCache: invalidatesCache,
            requiresEnabled: true,
            expectedRecovery: .some(expectedRecovery),
            syncOperationID: nil
        )
    }

    public func markSyncFailureIfEnabled(
        _ reason: SyncFailureReason,
        invalidatesCache: Bool,
        expectedRecovery: RecoverySnapshot?,
        syncOperationID: UUID
    ) throws -> EnabledSyncMutationResult {
        try markSyncFailure(
            reason,
            invalidatesCache: invalidatesCache,
            requiresEnabled: true,
            expectedRecovery: .some(expectedRecovery),
            syncOperationID: syncOperationID
        )
    }

    private func markSyncFailure(
        _ reason: SyncFailureReason,
        invalidatesCache: Bool,
        requiresEnabled: Bool,
        expectedRecovery: RecoverySnapshot??,
        syncOperationID: UUID?
    ) throws -> EnabledSyncMutationResult {
        let failedAt = now()
        return try store.mutate { state in
            if requiresEnabled, !state.enabled {
                return .disabled
            }
            if let syncOperationID, state.syncOperationID != syncOperationID {
                return .superseded
            }
            if let expectedRecovery, state.recovery != expectedRecovery {
                return .superseded
            }
            let wasDegraded = state.degradedReason != nil

            state.lastSyncAttemptAt = failedAt
            state.lastSyncError = reason.rawValue
            state.degradedReason = reason.userMessage
            if !wasDegraded {
                state.degradedWarningEmitted = false
            }

            if invalidatesCache {
                state.recovery = nil
                state.chargeRemaining = nil
                state.pendingOverride = nil
            }
            if syncOperationID != nil {
                state.syncOperationID = nil
            }
            return .applied
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        try store.mutate { state in
            guard enabled else {
                state.enabled = false
                state.syncOperationID = nil
                state.workoutRewards = nil
                return
            }

            guard !state.enabled else {
                return
            }

            let enabledAt = now()
            guard enabledAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ChargeEngineError.invalidSyncTimestamp
            }

            state.enabled = true
            state.syncOperationID = nil
            state.workoutRewards = WorkoutRewardEpoch(
                startedAt: enabledAt,
                cycleID: state.recovery?.cycleID
            )
            state.degradedReason = SyncFailureReason.refreshRequired.userMessage
            state.degradedWarningEmitted = false
            state.lastSyncError = SyncFailureReason.refreshRequired.rawValue
        }
    }

    /// Captures the exact state and enters Soft Off without crossing the WHOOP
    /// boundary. The returned token exists only in the installer process.
    public func prepareInstallationSoftOff() throws -> InstallationSoftOffSnapshot {
        try store.mutate { state in
            let prior = state
            state.enabled = false
            state.syncOperationID = nil
            state.workoutRewards = nil
            return InstallationSoftOffSnapshot(prior: prior, softOff: state)
        }
    }

    /// Restores the exact pre-install state only while the ledger still equals
    /// the Soft Off state produced by this token. A concurrent change is never
    /// overwritten during compensation.
    public func restoreInstallationState(_ snapshot: InstallationSoftOffSnapshot) throws {
        guard try restoreInstallationStateIfCurrent(snapshot) else {
            throw ChargeEngineError.installationStateChanged
        }
    }

    /// Restores the exact pre-install state only if this installer still owns
    /// the current Soft Off state. A concurrent ledger is preserved unchanged.
    public func restoreInstallationStateIfCurrent(
        _ snapshot: InstallationSoftOffSnapshot
    ) throws -> Bool {
        try store.mutate { state in
            guard state == snapshot.softOff else { return false }
            state = snapshot.prior
            return true
        }
    }

    /// Atomically confirms that the installer-owned Soft Off snapshot is still
    /// current. This is an assertion only; a concurrent state is never changed.
    public func confirmInstallationSoftOff(_ snapshot: InstallationSoftOffSnapshot) throws -> Bool {
        try store.mutate { state in
            state == snapshot.softOff
        }
    }

    /// Resets only local demonstration state. Charge and its audit event commit
    /// or roll back together in one local database transaction.
    public func resetDemo() throws -> Int {
        let resetAt = now()
        return try store.mutateAndAppendAudit { state -> (Int, AuditEvent) in
            guard state.enabled else {
                throw ChargeEngineError.demoResetRequiresEnabledFeature
            }
            guard state.degradedReason == nil,
                  case let .ready(recovery, _) = Self.validateReadyState(state),
                  Self.isValidActiveCachedRecovery(recovery)
            else {
                throw ChargeEngineError.demoResetRequiresReadyState
            }

            let charge = recovery.recoveryScore
            state.chargeRemaining = charge
            state.pendingOverride = nil
            state.degradedWarningEmitted = false

            let event = AuditEvent(
                name: "charge.demo_reset",
                occurredAt: resetAt,
                metadata: [
                    "reset_source": "demo_manual",
                    "reset_at": Self.format(resetAt),
                    "current_score": String(charge),
                ]
            )
            return (charge, event)
        }
    }

    public func currentState() throws -> PersistentState {
        try store.read()
    }

    /// Coordinated logical deletion. This deliberately preserves the database
    /// file so an already-running hook or companion cannot continue on an
    /// unlinked, divergent SQLite ledger.
    public func deleteLocalData() throws {
        try store.resetToDefaults()
    }

    private static func promptDecision(
        for input: HookInput,
        state: inout PersistentState
    ) -> ChargeDecision {
        guard state.enabled else {
            return .passThrough
        }

        let recovery: RecoverySnapshot
        let charge: Int
        switch validateReadyState(state) {
        case let .ready(validRecovery, validCharge):
            recovery = validRecovery
            charge = validCharge
        case .corrupt:
            transitionToLedgerCorrupt(&state)
            return degradedDecision(
                state: &state,
                message: SyncFailureReason.ledgerCorrupt.userMessage
            )
        case .missing:
            let reason = sanitizeDegradedState(&state)
            return degradedDecision(state: &state, message: reason.userMessage)
        }

        if state.degradedReason != nil {
            let reason = sanitizeDegradedState(&state)
            return degradedDecision(state: &state, message: reason.userMessage)
        }

        if charge > 0 {
            state.chargeRemaining = max(0, charge - 1)
            return .passThrough
        }

        let normalizedPrompt = input.prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedPrompt == continueOnceCommand,
           charge == 0,
           state.pendingOverride?.sessionID == input.sessionID
        {
            state.pendingOverride = nil
            return .continueOnce
        }

        if normalizedPrompt == continueOnceCommand {
            return .nothingToContinue(message: nothingToContinueMessage)
        }

        // Engine-produced Charge is never negative. Normalizing here also keeps a
        // malformed persisted value from escaping the zero-charge redirect state.
        state.chargeRemaining = 0
        let consecutiveRedirectCount: Int
        if let pending = state.pendingOverride,
           pending.sessionID == input.sessionID
        {
            consecutiveRedirectCount = min(3, pending.consecutiveRedirectCount + 1)
        } else {
            consecutiveRedirectCount = 1
        }
        state.pendingOverride = PendingOverride(
            sessionID: input.sessionID,
            redirectedTurnID: input.turnID,
            consecutiveRedirectCount: consecutiveRedirectCount
        )
        if consecutiveRedirectCount >= 3 {
            return .repeatedRedirect(recovery: recovery)
        }
        return .redirect(recovery: recovery)
    }

    private enum ReadyValidation {
        case ready(recovery: RecoverySnapshot, charge: Int)
        case missing
        case corrupt
    }

    private static func validateReadyState(_ state: PersistentState) -> ReadyValidation {
        if let recovery = state.recovery,
           !isValidLedgerValue(recovery.recoveryScore)
        {
            return .corrupt
        }
        if let charge = state.chargeRemaining,
           !isValidLedgerValue(charge)
        {
            return .corrupt
        }
        guard let recovery = state.recovery,
              let charge = state.chargeRemaining
        else {
            return .missing
        }
        return .ready(recovery: recovery, charge: charge)
    }

    private static func isValidLedgerValue(_ value: Int) -> Bool {
        (0...100).contains(value)
    }

    private static func isValidActiveCachedRecovery(_ recovery: RecoverySnapshot) -> Bool {
        recovery.cycleID > 0
            && recovery.sleepID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            && isValidLedgerValue(recovery.recoveryScore)
            && recovery.createdAt.timeIntervalSinceReferenceDate.isFinite
            && recovery.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && recovery.cycleStart.timeIntervalSinceReferenceDate.isFinite
            && recovery.validatedAt.timeIntervalSinceReferenceDate.isFinite
            && recovery.cycleEnd == nil
    }

    private static func applyWorkoutAwards(
        _ candidates: [WorkoutAwardCandidate],
        recovery: RecoverySnapshot,
        state: inout PersistentState
    ) throws -> [AuditEvent] {
        guard state.enabled,
              case .ready = validateReadyState(state)
        else {
            return []
        }

        var epoch = state.workoutRewards ?? WorkoutRewardEpoch(
            startedAt: recovery.validatedAt,
            cycleID: recovery.cycleID
        )
        guard epoch.startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ChargeEngineError.invalidWorkoutRewardEpoch
        }
        if epoch.cycleID != recovery.cycleID {
            epoch.cycleID = recovery.cycleID
            epoch.processedWorkoutIDs = []
            epoch.lastAward = nil
        }

        let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        let eligibleAfter = max(epoch.startedAt, recovery.cycleStart)
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.endedAt != rhs.endedAt { return lhs.endedAt < rhs.endedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var processed = Set(epoch.processedWorkoutIDs)
        var events: [AuditEvent] = []

        for candidate in ordered {
            guard candidate.id != zeroUUID,
                  candidate.endedAt.timeIntervalSinceReferenceDate.isFinite,
                  let earned = WorkoutChargePolicy.award(for: candidate.strain)
            else {
                throw ChargeEngineError.invalidWorkoutCandidate
            }
            guard candidate.endedAt >= eligibleAfter,
                  candidate.endedAt <= recovery.validatedAt,
                  !processed.contains(candidate.id)
            else {
                continue
            }
            guard let currentCharge = state.chargeRemaining,
                  isValidLedgerValue(currentCharge)
            else {
                throw ChargeEngineError.invalidWorkoutLedger
            }

            let resultingCharge = min(100, currentCharge + earned)
            let appliedCharge = resultingCharge - currentCharge
            let award = WorkoutChargeAward(
                workoutID: candidate.id,
                cycleID: recovery.cycleID,
                workoutEndedAt: candidate.endedAt,
                strain: candidate.strain,
                earnedCharge: earned,
                appliedCharge: appliedCharge,
                resultingCharge: resultingCharge,
                awardedAt: recovery.validatedAt
            )
            state.chargeRemaining = resultingCharge
            if appliedCharge > 0 {
                state.pendingOverride = nil
            }
            processed.insert(candidate.id)
            epoch.processedWorkoutIDs.append(candidate.id)
            epoch.lastAward = award
            events.append(
                AuditEvent(
                    name: "charge.workout_awarded",
                    occurredAt: recovery.validatedAt,
                    metadata: [
                        "applied_charge": String(appliedCharge),
                        "cycle_id": String(recovery.cycleID),
                        "earned_charge": String(earned),
                        "resulting_charge": String(resultingCharge),
                        "workout_ended_at": format(candidate.endedAt),
                    ]
                )
            )
        }

        state.workoutRewards = epoch
        return events
    }

    private static func transitionToLedgerCorrupt(_ state: inout PersistentState) {
        let wasDegraded = state.degradedReason != nil
        state.degradedReason = SyncFailureReason.ledgerCorrupt.userMessage
        state.lastSyncError = SyncFailureReason.ledgerCorrupt.rawValue
        if !wasDegraded {
            state.degradedWarningEmitted = false
        }
    }

    private static func sanitizeDegradedState(
        _ state: inout PersistentState
    ) -> SyncFailureReason {
        let wasDegraded = state.degradedReason != nil
        let reason = state.lastSyncError
            .flatMap(SyncFailureReason.init(rawValue:)) ?? .unavailable
        state.lastSyncError = reason.rawValue
        state.degradedReason = reason.userMessage
        if !wasDegraded {
            state.degradedWarningEmitted = false
        }
        return reason
    }

    private static func degradedDecision(
        state: inout PersistentState,
        message: String
    ) -> ChargeDecision {
        guard !state.degradedWarningEmitted else {
            return .passThrough
        }

        state.degradedWarningEmitted = true
        return .degradedWarning(message: message)
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private enum ChargeEngineError: LocalizedError {
    case demoResetRequiresEnabledFeature
    case demoResetRequiresReadyState
    case invalidRecoveryScore
    case invalidRecoveryChronology
    case invalidRetainedCache
    case invalidSyncTimestamp
    case invalidWorkoutCandidate
    case invalidWorkoutLedger
    case invalidWorkoutRewardEpoch
    case installationStateChanged

    var errorDescription: String? {
        switch self {
        case .demoResetRequiresEnabledFeature:
            "Demo reset requires Human in the Whoop to be enabled."
        case .demoResetRequiresReadyState:
            "Demo reset requires an enabled, ready Recovery and Charge ledger."
        case .invalidRecoveryScore:
            "Recovery score must be between 0 and 100."
        case .invalidRecoveryChronology:
            "Recovery chronology must use finite timestamps."
        case .invalidRetainedCache:
            "Retained Recovery and Charge must form a valid active ledger."
        case .invalidSyncTimestamp:
            "Sync timestamps must be finite."
        case .invalidWorkoutCandidate:
            "Workout award data could not be validated."
        case .invalidWorkoutLedger:
            "Workout Charge requires a valid current ledger."
        case .invalidWorkoutRewardEpoch:
            "Workout reward timing could not be validated."
        case .installationStateChanged:
            "Local Charge state changed while the installer was compensating."
        }
    }
}
