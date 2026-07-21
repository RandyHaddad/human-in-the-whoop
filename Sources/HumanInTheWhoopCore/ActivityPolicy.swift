import Foundation

public enum ActivityKind: String, Codable, Equatable, Sendable {
    case gentleMovement
    case easyWalk
    case briskMovement
}

public struct ActivityRecommendation: Codable, Equatable, Sendable {
    public var kind: ActivityKind
    public var minutes: Int
    public var userFacingActivity: String
    public var reasonCode: String

    public init(
        kind: ActivityKind,
        minutes: Int,
        userFacingActivity: String,
        reasonCode: String
    ) {
        self.kind = kind
        self.minutes = minutes
        self.userFacingActivity = userFacingActivity
        self.reasonCode = reasonCode
    }
}

public enum ActivityPolicy {
    public static func select(
        from recovery: RecoverySnapshot,
        now: Date
    ) -> ActivityRecommendation {
        guard (0...100).contains(recovery.recoveryScore) else {
            return gentleMovement(reasonCode: "invalid_recovery")
        }

        if (0...33).contains(recovery.recoveryScore) {
            return gentleMovement(reasonCode: "low_recovery")
        }

        if let sleepPerformance = recovery.sleepPerformance,
           isValidSleepPerformance(sleepPerformance),
           sleepPerformance < 70
        {
            return gentleMovement(reasonCode: "low_sleep_performance")
        }

        if let cycleStrain = recovery.cycleStrain,
           isValidStrain(cycleStrain),
           cycleStrain >= 14
        {
            return gentleMovement(reasonCode: "high_cycle_strain")
        }

        if let workout = recovery.recentWorkout,
           isValidWorkout(workout),
           workout.strain >= 14,
           workout.endedAt >= now.addingTimeInterval(-6 * 60 * 60),
           workout.endedAt <= now
        {
            return gentleMovement(reasonCode: "recent_high_strain_workout")
        }

        if !hasCompleteValidSecondaryData(recovery) {
            return ActivityRecommendation(
                kind: .easyWalk,
                minutes: 5,
                userFacingActivity: "a five-minute easy walk away from the screen",
                reasonCode: "incomplete_secondary_data"
            )
        }

        if (34...66).contains(recovery.recoveryScore) {
            return ActivityRecommendation(
                kind: .easyWalk,
                minutes: 10,
                userFacingActivity: "a ten-minute easy walk away from the screen",
                reasonCode: "yellow_recovery"
            )
        }

        return ActivityRecommendation(
            kind: .briskMovement,
            minutes: 10,
            userFacingActivity: "a ten-minute brisk walk or light outdoor movement",
            reasonCode: "green_recovery"
        )
    }

    private static func gentleMovement(reasonCode: String) -> ActivityRecommendation {
        ActivityRecommendation(
            kind: .gentleMovement,
            minutes: 5,
            userFacingActivity: "a gentle five-minute walk or easy mobility away from the screen",
            reasonCode: reasonCode
        )
    }

    private static func hasCompleteValidSecondaryData(
        _ recovery: RecoverySnapshot
    ) -> Bool {
        guard recovery.secondaryDataComplete,
              let sleepPerformance = recovery.sleepPerformance,
              isValidSleepPerformance(sleepPerformance),
              let cycleStrain = recovery.cycleStrain,
              isValidStrain(cycleStrain)
        else {
            return false
        }

        guard let workout = recovery.recentWorkout else {
            return true
        }
        return isValidWorkout(workout)
    }

    private static func isValidSleepPerformance(_ value: Double) -> Bool {
        value.isFinite && (0...100).contains(value)
    }

    private static func isValidStrain(_ value: Double) -> Bool {
        value.isFinite && (0...21).contains(value)
    }

    private static func isValidWorkout(_ workout: WorkoutSnapshot) -> Bool {
        isValidStrain(workout.strain)
            && workout.endedAt.timeIntervalSinceReferenceDate.isFinite
    }
}
