import Foundation

@testable import HumanInTheWhoopCore

private enum ActivityPolicyTestSupport {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func recovery(
        score: Int = 80,
        sleepPerformance: Double? = 90,
        cycleStrain: Double? = 8,
        recentWorkout: WorkoutSnapshot? = nil,
        secondaryDataComplete: Bool = true
    ) -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: 101,
            sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            recoveryScore: score,
            createdAt: now.addingTimeInterval(-7_200),
            updatedAt: now.addingTimeInterval(-3_600),
            cycleStart: now.addingTimeInterval(-43_200),
            cycleEnd: nil,
            sleepPerformance: sleepPerformance,
            cycleStrain: cycleStrain,
            recentWorkout: recentWorkout,
            secondaryDataComplete: secondaryDataComplete,
            validatedAt: now
        )
    }

    static func recommendation(
        kind: ActivityKind,
        minutes: Int,
        activity: String,
        reasonCode: String
    ) -> ActivityRecommendation {
        ActivityRecommendation(
            kind: kind,
            minutes: minutes,
            userFacingActivity: activity,
            reasonCode: reasonCode
        )
    }

    static let gentleLowRecovery = recommendation(
        kind: .gentleMovement,
        minutes: 5,
        activity: "a gentle five-minute walk or easy mobility away from the screen",
        reasonCode: "low_recovery"
    )

    static let yellow = recommendation(
        kind: .easyWalk,
        minutes: 10,
        activity: "a ten-minute easy walk away from the screen",
        reasonCode: "yellow_recovery"
    )

    static let green = recommendation(
        kind: .briskMovement,
        minutes: 10,
        activity: "a ten-minute brisk walk or light outdoor movement",
        reasonCode: "green_recovery"
    )

    static let incomplete = recommendation(
        kind: .easyWalk,
        minutes: 5,
        activity: "a five-minute easy walk away from the screen",
        reasonCode: "incomplete_secondary_data"
    )
}

#if canImport(XCTest)
import XCTest

final class ActivityPolicyTests: XCTestCase {
    func testRedRecoverySelectsGentleFiveMinuteMovement() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 20),
            now: ActivityPolicyTestSupport.now
        )

        XCTAssertEqual(selected, ActivityPolicyTestSupport.gentleLowRecovery)
    }

    func testLowSleepOverridesGreenRecovery() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 90, sleepPerformance: 69.999),
            now: ActivityPolicyTestSupport.now
        )

        XCTAssertEqual(selected.kind, .gentleMovement)
        XCTAssertEqual(selected.minutes, 5)
        XCTAssertEqual(selected.reasonCode, "low_sleep_performance")
    }

    func testHighCycleStrainAt14SelectsGentleMovement() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 90, cycleStrain: 14),
            now: ActivityPolicyTestSupport.now
        )

        XCTAssertEqual(selected.kind, .gentleMovement)
        XCTAssertEqual(selected.reasonCode, "high_cycle_strain")
    }

    func testRecentWorkoutAt14ExactlySixHoursAgoSelectsGentleMovement() {
        let workout = WorkoutSnapshot(
            strain: 14,
            endedAt: ActivityPolicyTestSupport.now.addingTimeInterval(-6 * 60 * 60)
        )
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 90, recentWorkout: workout),
            now: ActivityPolicyTestSupport.now
        )

        XCTAssertEqual(selected.kind, .gentleMovement)
        XCTAssertEqual(selected.reasonCode, "recent_high_strain_workout")
    }

    func testWorkoutOlderThanSixHoursDoesNotOverrideGreenRecovery() {
        let workout = WorkoutSnapshot(
            strain: 14,
            endedAt: ActivityPolicyTestSupport.now.addingTimeInterval(-(6 * 60 * 60) - 0.001)
        )

        XCTAssertEqual(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 90, recentWorkout: workout),
                now: ActivityPolicyTestSupport.now
            ),
            ActivityPolicyTestSupport.green
        )
    }

    func testFutureWorkoutDoesNotOverrideGreenRecovery() {
        let workout = WorkoutSnapshot(
            strain: 20,
            endedAt: ActivityPolicyTestSupport.now.addingTimeInterval(0.001)
        )

        XCTAssertEqual(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 90, recentWorkout: workout),
                now: ActivityPolicyTestSupport.now
            ),
            ActivityPolicyTestSupport.green
        )
    }

    func testYellowRecoverySelectsTenMinuteEasyWalk() {
        XCTAssertEqual(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 50),
                now: ActivityPolicyTestSupport.now
            ),
            ActivityPolicyTestSupport.yellow
        )
    }

    func testGreenRecoverySelectsTenMinuteBriskMovement() {
        XCTAssertEqual(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80),
                now: ActivityPolicyTestSupport.now
            ),
            ActivityPolicyTestSupport.green
        )
    }

    func testMissingSecondaryDataSelectsFiveMinuteEasyWalk() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(
                score: 80,
                sleepPerformance: nil,
                cycleStrain: nil,
                secondaryDataComplete: false
            ),
            now: ActivityPolicyTestSupport.now
        )

        XCTAssertEqual(
            selected,
            ActivityPolicyTestSupport.recommendation(
                kind: .easyWalk,
                minutes: 5,
                activity: "a five-minute easy walk away from the screen",
                reasonCode: "incomplete_secondary_data"
            )
        )
    }

    func testCompleteSecondaryDataWithNoWorkoutIsNotIncomplete() {
        XCTAssertEqual(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80, recentWorkout: nil),
                now: ActivityPolicyTestSupport.now
            ),
            ActivityPolicyTestSupport.green
        )
    }

    func testInvalidSleepPerformanceSelectsIncompleteEasyWalk() {
        for sleepPerformance in [Double.nan, -0.001, 101] {
            XCTAssertEqual(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        sleepPerformance: sleepPerformance
                    ),
                    now: ActivityPolicyTestSupport.now
                ),
                ActivityPolicyTestSupport.incomplete
            )
        }
    }

    func testInvalidCycleStrainSelectsIncompleteEasyWalk() {
        for cycleStrain in [Double.nan, -1, 21.001] {
            XCTAssertEqual(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        cycleStrain: cycleStrain
                    ),
                    now: ActivityPolicyTestSupport.now
                ),
                ActivityPolicyTestSupport.incomplete
            )
        }
    }

    func testInvalidWorkoutStrainSelectsIncompleteEasyWalk() {
        for workoutStrain in [Double.nan, -0.001, 21.001] {
            let workout = WorkoutSnapshot(
                strain: workoutStrain,
                endedAt: ActivityPolicyTestSupport.now
            )
            XCTAssertEqual(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        recentWorkout: workout
                    ),
                    now: ActivityPolicyTestSupport.now
                ),
                ActivityPolicyTestSupport.incomplete
            )
        }
    }

    func testMissingRequiredSleepOrCycleWithCompleteFlagSelectsIncompleteEasyWalk() {
        for (sleepPerformance, cycleStrain) in [(nil, 8.0), (90.0, nil)] {
            XCTAssertEqual(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        sleepPerformance: sleepPerformance,
                        cycleStrain: cycleStrain
                    ),
                    now: ActivityPolicyTestSupport.now
                ),
                ActivityPolicyTestSupport.incomplete
            )
        }
    }

    func testNonfiniteWorkoutEndDateSelectsIncompleteEasyWalk() {
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let workout = WorkoutSnapshot(
                strain: 8,
                endedAt: Date(timeIntervalSinceReferenceDate: interval)
            )
            XCTAssertEqual(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        recentWorkout: workout
                    ),
                    now: ActivityPolicyTestSupport.now
                ),
                ActivityPolicyTestSupport.incomplete
            )
        }
    }

    func testValidHighRiskMetricWinsWhenAnotherSecondaryMetricIsInvalid() {
        let validLowSleep = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: 60,
            cycleStrain: .nan
        )
        XCTAssertEqual(
            ActivityPolicy.select(from: validLowSleep, now: ActivityPolicyTestSupport.now).reasonCode,
            "low_sleep_performance"
        )

        let validHighCycleStrain = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: .nan,
            cycleStrain: 14
        )
        XCTAssertEqual(
            ActivityPolicy.select(
                from: validHighCycleStrain,
                now: ActivityPolicyTestSupport.now
            ).reasonCode,
            "high_cycle_strain"
        )

        let validRecentWorkout = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: .nan,
            recentWorkout: WorkoutSnapshot(strain: 14, endedAt: ActivityPolicyTestSupport.now)
        )
        XCTAssertEqual(
            ActivityPolicy.select(from: validRecentWorkout, now: ActivityPolicyTestSupport.now).reasonCode,
            "recent_high_strain_workout"
        )
    }

    func testRecoveryAndSleepBoundariesAreInclusiveAndExact() {
        for (score, expected) in [
            (33, ActivityPolicyTestSupport.gentleLowRecovery),
            (34, ActivityPolicyTestSupport.yellow),
            (66, ActivityPolicyTestSupport.yellow),
            (67, ActivityPolicyTestSupport.green),
        ] {
            XCTAssertEqual(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(score: score),
                    now: ActivityPolicyTestSupport.now
                ),
                expected,
                "Unexpected recommendation for Recovery \(score)"
            )
        }

        XCTAssertEqual(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80, sleepPerformance: 70),
                now: ActivityPolicyTestSupport.now
            ),
            ActivityPolicyTestSupport.green
        )
        XCTAssertEqual(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80, cycleStrain: 13.999),
                now: ActivityPolicyTestSupport.now
            ),
            ActivityPolicyTestSupport.green
        )
    }

    func testConservativeTriggersAndIncompleteDataUseDeclaredPriority() {
        let allRiskTriggers = ActivityPolicyTestSupport.recovery(
            score: 33,
            sleepPerformance: 50,
            cycleStrain: 18,
            recentWorkout: WorkoutSnapshot(strain: 18, endedAt: ActivityPolicyTestSupport.now),
            secondaryDataComplete: false
        )
        XCTAssertEqual(
            ActivityPolicy.select(from: allRiskTriggers, now: ActivityPolicyTestSupport.now).reasonCode,
            "low_recovery"
        )

        let riskAndIncomplete = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: 69.999,
            secondaryDataComplete: false
        )
        XCTAssertEqual(
            ActivityPolicy.select(from: riskAndIncomplete, now: ActivityPolicyTestSupport.now).reasonCode,
            "low_sleep_performance"
        )

        for score in [50, 80] {
            let selected = ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(
                    score: score,
                    secondaryDataComplete: false
                ),
                now: ActivityPolicyTestSupport.now
            )
            XCTAssertEqual(selected.kind, .easyWalk)
            XCTAssertEqual(selected.minutes, 5)
            XCTAssertEqual(selected.reasonCode, "incomplete_secondary_data")
        }
    }
}
#else
import Testing

@Suite struct ActivityPolicyTests {
    @Test func redRecoverySelectsGentleFiveMinuteMovement() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 20),
            now: ActivityPolicyTestSupport.now
        )

        #expect(selected == ActivityPolicyTestSupport.gentleLowRecovery)
    }

    @Test func lowSleepOverridesGreenRecovery() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 90, sleepPerformance: 69.999),
            now: ActivityPolicyTestSupport.now
        )

        #expect(selected.kind == .gentleMovement)
        #expect(selected.minutes == 5)
        #expect(selected.reasonCode == "low_sleep_performance")
    }

    @Test func highCycleStrainAt14SelectsGentleMovement() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 90, cycleStrain: 14),
            now: ActivityPolicyTestSupport.now
        )

        #expect(selected.kind == .gentleMovement)
        #expect(selected.reasonCode == "high_cycle_strain")
    }

    @Test func recentWorkoutAt14ExactlySixHoursAgoSelectsGentleMovement() {
        let workout = WorkoutSnapshot(
            strain: 14,
            endedAt: ActivityPolicyTestSupport.now.addingTimeInterval(-6 * 60 * 60)
        )
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(score: 90, recentWorkout: workout),
            now: ActivityPolicyTestSupport.now
        )

        #expect(selected.kind == .gentleMovement)
        #expect(selected.reasonCode == "recent_high_strain_workout")
    }

    @Test func workoutOlderThanSixHoursDoesNotOverrideGreenRecovery() {
        let workout = WorkoutSnapshot(
            strain: 14,
            endedAt: ActivityPolicyTestSupport.now.addingTimeInterval(-(6 * 60 * 60) - 0.001)
        )

        #expect(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 90, recentWorkout: workout),
                now: ActivityPolicyTestSupport.now
            ) == ActivityPolicyTestSupport.green
        )
    }

    @Test func futureWorkoutDoesNotOverrideGreenRecovery() {
        let workout = WorkoutSnapshot(
            strain: 20,
            endedAt: ActivityPolicyTestSupport.now.addingTimeInterval(0.001)
        )

        #expect(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 90, recentWorkout: workout),
                now: ActivityPolicyTestSupport.now
            ) == ActivityPolicyTestSupport.green
        )
    }

    @Test func yellowRecoverySelectsTenMinuteEasyWalk() {
        #expect(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 50),
                now: ActivityPolicyTestSupport.now
            ) == ActivityPolicyTestSupport.yellow
        )
    }

    @Test func greenRecoverySelectsTenMinuteBriskMovement() {
        #expect(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80),
                now: ActivityPolicyTestSupport.now
            ) == ActivityPolicyTestSupport.green
        )
    }

    @Test func missingSecondaryDataSelectsFiveMinuteEasyWalk() {
        let selected = ActivityPolicy.select(
            from: ActivityPolicyTestSupport.recovery(
                score: 80,
                sleepPerformance: nil,
                cycleStrain: nil,
                secondaryDataComplete: false
            ),
            now: ActivityPolicyTestSupport.now
        )

        #expect(
            selected == ActivityPolicyTestSupport.recommendation(
                kind: .easyWalk,
                minutes: 5,
                activity: "a five-minute easy walk away from the screen",
                reasonCode: "incomplete_secondary_data"
            )
        )
    }

    @Test func completeSecondaryDataWithNoWorkoutIsNotIncomplete() {
        #expect(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80, recentWorkout: nil),
                now: ActivityPolicyTestSupport.now
            ) == ActivityPolicyTestSupport.green
        )
    }

    @Test func invalidSleepPerformanceSelectsIncompleteEasyWalk() {
        for sleepPerformance in [Double.nan, -0.001, 101] {
            #expect(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        sleepPerformance: sleepPerformance
                    ),
                    now: ActivityPolicyTestSupport.now
                ) == ActivityPolicyTestSupport.incomplete
            )
        }
    }

    @Test func invalidCycleStrainSelectsIncompleteEasyWalk() {
        for cycleStrain in [Double.nan, -1, 21.001] {
            #expect(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        cycleStrain: cycleStrain
                    ),
                    now: ActivityPolicyTestSupport.now
                ) == ActivityPolicyTestSupport.incomplete
            )
        }
    }

    @Test func invalidWorkoutStrainSelectsIncompleteEasyWalk() {
        for workoutStrain in [Double.nan, -0.001, 21.001] {
            let workout = WorkoutSnapshot(
                strain: workoutStrain,
                endedAt: ActivityPolicyTestSupport.now
            )
            #expect(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        recentWorkout: workout
                    ),
                    now: ActivityPolicyTestSupport.now
                ) == ActivityPolicyTestSupport.incomplete
            )
        }
    }

    @Test func missingRequiredSleepOrCycleWithCompleteFlagSelectsIncompleteEasyWalk() {
        for (sleepPerformance, cycleStrain) in [(nil, 8.0), (90.0, nil)] {
            #expect(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        sleepPerformance: sleepPerformance,
                        cycleStrain: cycleStrain
                    ),
                    now: ActivityPolicyTestSupport.now
                ) == ActivityPolicyTestSupport.incomplete
            )
        }
    }

    @Test func nonfiniteWorkoutEndDateSelectsIncompleteEasyWalk() {
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let workout = WorkoutSnapshot(
                strain: 8,
                endedAt: Date(timeIntervalSinceReferenceDate: interval)
            )
            #expect(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(
                        score: 80,
                        recentWorkout: workout
                    ),
                    now: ActivityPolicyTestSupport.now
                ) == ActivityPolicyTestSupport.incomplete
            )
        }
    }

    @Test func validHighRiskMetricWinsWhenAnotherSecondaryMetricIsInvalid() {
        let validLowSleep = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: 60,
            cycleStrain: .nan
        )
        #expect(
            ActivityPolicy.select(from: validLowSleep, now: ActivityPolicyTestSupport.now).reasonCode
                == "low_sleep_performance"
        )

        let validHighCycleStrain = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: .nan,
            cycleStrain: 14
        )
        #expect(
            ActivityPolicy.select(
                from: validHighCycleStrain,
                now: ActivityPolicyTestSupport.now
            ).reasonCode == "high_cycle_strain"
        )

        let validRecentWorkout = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: .nan,
            recentWorkout: WorkoutSnapshot(strain: 14, endedAt: ActivityPolicyTestSupport.now)
        )
        #expect(
            ActivityPolicy.select(from: validRecentWorkout, now: ActivityPolicyTestSupport.now).reasonCode
                == "recent_high_strain_workout"
        )
    }

    @Test func recoveryAndSleepBoundariesAreInclusiveAndExact() {
        for (score, expected) in [
            (33, ActivityPolicyTestSupport.gentleLowRecovery),
            (34, ActivityPolicyTestSupport.yellow),
            (66, ActivityPolicyTestSupport.yellow),
            (67, ActivityPolicyTestSupport.green),
        ] {
            #expect(
                ActivityPolicy.select(
                    from: ActivityPolicyTestSupport.recovery(score: score),
                    now: ActivityPolicyTestSupport.now
                ) == expected,
                "Unexpected recommendation for Recovery \(score)"
            )
        }

        #expect(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80, sleepPerformance: 70),
                now: ActivityPolicyTestSupport.now
            ) == ActivityPolicyTestSupport.green
        )
        #expect(
            ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(score: 80, cycleStrain: 13.999),
                now: ActivityPolicyTestSupport.now
            ) == ActivityPolicyTestSupport.green
        )
    }

    @Test func conservativeTriggersAndIncompleteDataUseDeclaredPriority() {
        let allRiskTriggers = ActivityPolicyTestSupport.recovery(
            score: 33,
            sleepPerformance: 50,
            cycleStrain: 18,
            recentWorkout: WorkoutSnapshot(strain: 18, endedAt: ActivityPolicyTestSupport.now),
            secondaryDataComplete: false
        )
        #expect(
            ActivityPolicy.select(from: allRiskTriggers, now: ActivityPolicyTestSupport.now).reasonCode
                == "low_recovery"
        )

        let riskAndIncomplete = ActivityPolicyTestSupport.recovery(
            score: 80,
            sleepPerformance: 69.999,
            secondaryDataComplete: false
        )
        #expect(
            ActivityPolicy.select(from: riskAndIncomplete, now: ActivityPolicyTestSupport.now).reasonCode
                == "low_sleep_performance"
        )

        for score in [50, 80] {
            let selected = ActivityPolicy.select(
                from: ActivityPolicyTestSupport.recovery(
                    score: score,
                    secondaryDataComplete: false
                ),
                now: ActivityPolicyTestSupport.now
            )
            #expect(selected.kind == .easyWalk)
            #expect(selected.minutes == 5)
            #expect(selected.reasonCode == "incomplete_secondary_data")
        }
    }
}
#endif
