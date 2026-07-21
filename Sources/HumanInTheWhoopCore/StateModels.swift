import Foundation

public struct RecoverySnapshot: Codable, Equatable, Sendable {
    public var cycleID: Int64
    public var sleepID: UUID
    public var recoveryScore: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var cycleStart: Date
    public var cycleEnd: Date?
    public var sleepPerformance: Double?
    public var cycleStrain: Double?
    public var recentWorkout: WorkoutSnapshot?
    public var secondaryDataComplete: Bool
    public var validatedAt: Date

    public init(
        cycleID: Int64,
        sleepID: UUID,
        recoveryScore: Int,
        createdAt: Date,
        updatedAt: Date,
        cycleStart: Date,
        cycleEnd: Date?,
        sleepPerformance: Double?,
        cycleStrain: Double?,
        recentWorkout: WorkoutSnapshot?,
        secondaryDataComplete: Bool,
        validatedAt: Date
    ) {
        self.cycleID = cycleID
        self.sleepID = sleepID
        self.recoveryScore = recoveryScore
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cycleStart = cycleStart
        self.cycleEnd = cycleEnd
        self.sleepPerformance = sleepPerformance
        self.cycleStrain = cycleStrain
        self.recentWorkout = recentWorkout
        self.secondaryDataComplete = secondaryDataComplete
        self.validatedAt = validatedAt
    }
}

public struct WorkoutSnapshot: Codable, Equatable, Sendable {
    public var strain: Double
    public var endedAt: Date

    public init(strain: Double, endedAt: Date) {
        self.strain = strain
        self.endedAt = endedAt
    }
}

/// A validated scored WHOOP workout crossing from sync into the local ledger.
/// It is intentionally separate from `WorkoutSnapshot`, which remains the
/// small six-hour presentation input used by Recovery Redirect.
public struct WorkoutAwardCandidate: Equatable, Sendable {
    public var id: UUID
    public var strain: Double
    public var endedAt: Date

    public init(id: UUID, strain: Double, endedAt: Date) {
        self.id = id
        self.strain = strain
        self.endedAt = endedAt
    }
}

public struct WorkoutChargeAward: Codable, Equatable, Sendable {
    public var workoutID: UUID
    public var cycleID: Int64
    public var workoutEndedAt: Date
    public var strain: Double
    public var earnedCharge: Int
    public var appliedCharge: Int
    public var resultingCharge: Int
    public var awardedAt: Date

    public init(
        workoutID: UUID,
        cycleID: Int64,
        workoutEndedAt: Date,
        strain: Double,
        earnedCharge: Int,
        appliedCharge: Int,
        resultingCharge: Int,
        awardedAt: Date
    ) {
        self.workoutID = workoutID
        self.cycleID = cycleID
        self.workoutEndedAt = workoutEndedAt
        self.strain = strain
        self.earnedCharge = earnedCharge
        self.appliedCharge = appliedCharge
        self.resultingCharge = resultingCharge
        self.awardedAt = awardedAt
    }
}

/// One continuous On epoch. Dropping this value is the durable Off boundary;
/// recreating it on enable prevents workouts completed while Off from being
/// credited retroactively.
public struct WorkoutRewardEpoch: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var cycleID: Int64?
    public var processedWorkoutIDs: [UUID]
    public var lastAward: WorkoutChargeAward?

    public init(
        startedAt: Date,
        cycleID: Int64?,
        processedWorkoutIDs: [UUID] = [],
        lastAward: WorkoutChargeAward? = nil
    ) {
        self.startedAt = startedAt
        self.cycleID = cycleID
        self.processedWorkoutIDs = processedWorkoutIDs
        self.lastAward = lastAward
    }
}

public struct PendingOverride: Codable, Equatable, Sendable {
    public var sessionID: String
    public var redirectedTurnID: String
    public var consecutiveRedirectCount: Int

    public init(
        sessionID: String,
        redirectedTurnID: String,
        consecutiveRedirectCount: Int = 1
    ) {
        self.sessionID = sessionID
        self.redirectedTurnID = redirectedTurnID
        self.consecutiveRedirectCount = min(3, max(1, consecutiveRedirectCount))
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case redirectedTurnID
        case consecutiveRedirectCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        redirectedTurnID = try container.decode(String.self, forKey: .redirectedTurnID)
        let decodedCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consecutiveRedirectCount
        ) ?? 1
        consecutiveRedirectCount = min(3, max(1, decodedCount))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(redirectedTurnID, forKey: .redirectedTurnID)
        try container.encode(consecutiveRedirectCount, forKey: .consecutiveRedirectCount)
    }
}

public struct PersistentState: Codable, Equatable, Sendable {
    public var enabled = false
    public var chargeRemaining: Int? = nil
    public var recovery: RecoverySnapshot? = nil
    public var degradedReason: String? = nil
    public var degradedWarningEmitted = false
    public var pendingOverride: PendingOverride? = nil
    public var lastSyncAttemptAt: Date? = nil
    public var lastSyncSuccessAt: Date? = nil
    public var lastSyncError: String? = nil
    public var syncOperationID: UUID? = nil
    /// Optional so pre-replenishment JSON decodes as a safe uninitialized
    /// epoch. The next enabled sync creates a no-backfill baseline.
    public var workoutRewards: WorkoutRewardEpoch? = nil

    public init() {}
}

public struct AuditEvent: Codable, Equatable, Sendable {
    public var name: String
    public var occurredAt: Date
    public var metadata: [String: String]

    public init(name: String, occurredAt: Date, metadata: [String: String]) {
        self.name = name
        self.occurredAt = occurredAt
        self.metadata = metadata
    }
}
