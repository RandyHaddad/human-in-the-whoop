import Foundation
@testable import HumanInTheWhoopWHOOP

private enum WhoopDTOTestSupport {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static let cycleJSON = #"""
    {
      "records": [{
        "id": 93845,
        "start": "2026-07-18T07:11:44.774Z",
        "end": null,
        "score_state": "SCORED",
        "score": { "strain": 12.4 }
      }],
      "next_token": "next-page"
    }
    """#

    static let recoveryJSON = #"""
    {
      "cycle_id": 93845,
      "sleep_id": "550E8400-E29B-41D4-A716-446655440000",
      "created_at": "2026-07-18T12:00:00Z",
      "updated_at": "2026-07-18T12:05:01.123Z",
      "score_state": "SCORED",
      "score": { "recovery_score": 72 }
    }
    """#

    static let sleepJSON = #"""
    {
      "id": "550E8400-E29B-41D4-A716-446655440000",
      "cycle_id": 93845,
      "score_state": "SCORED",
      "score": { "sleep_performance_percentage": 86.5 }
    }
    """#

    static let workoutJSON = #"""
    {
      "records": [{
        "id": "650E8400-E29B-41D4-A716-446655440000",
        "end": "2026-07-18T15:30:45Z",
        "score_state": "SCORED",
        "score": { "strain": 14.2 }
      }],
      "next_token": null
    }
    """#

    static let tokenJSON = #"""
    {
      "access_token": "replacement-access",
      "refresh_token": "replacement-refresh",
      "expires_in": 3600,
      "token_type": "bearer",
      "scope": "offline read:recovery"
    }
    """#

    static let unknownScoreStateCycleJSON = #"""
    {
      "records": [{
        "id": 93846,
        "start": "2026-07-19T07:11:44.774Z",
        "score_state": "FUTURE_SCORE_STATE"
      }],
      "next_token": null
    }
    """#
}

#if canImport(XCTest)
import XCTest

final class WhoopDTOTests: XCTestCase {
    func testCycleCollectionDecodesFractionalTimestampOptionalEndAndStrain() throws {
        let collection = try WhoopDTOTestSupport.decode(WhoopCycleCollectionDTO.self, WhoopDTOTestSupport.cycleJSON)
        XCTAssertEqual(collection.records.count, 1)
        XCTAssertEqual(collection.nextToken, "next-page")
        XCTAssertEqual(collection.records[0].id, 93_845)
        XCTAssertNil(collection.records[0].end)
        XCTAssertEqual(collection.records[0].scoreState, .scored)
        XCTAssertEqual(collection.records[0].score?.strain, 12.4)
    }

    func testRecoveryDecodesFractionalAndNonfractionalTimestamps() throws {
        let recovery = try WhoopDTOTestSupport.decode(WhoopRecoveryDTO.self, WhoopDTOTestSupport.recoveryJSON)
        XCTAssertEqual(recovery.cycleID, 93_845)
        XCTAssertEqual(recovery.sleepID, UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        XCTAssertLessThan(recovery.createdAt, recovery.updatedAt)
        XCTAssertEqual(recovery.scoreState, .scored)
        XCTAssertEqual(recovery.score?.recoveryScore, 72)
    }

    func testSleepDecodesPerformance() throws {
        let sleep = try WhoopDTOTestSupport.decode(WhoopSleepDTO.self, WhoopDTOTestSupport.sleepJSON)
        XCTAssertEqual(sleep.id, UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        XCTAssertEqual(sleep.cycleID, 93_845)
        XCTAssertEqual(sleep.score?.sleepPerformancePercentage, 86.5)
    }

    func testWorkoutCollectionDecodesEndAndStrain() throws {
        let collection = try WhoopDTOTestSupport.decode(WhoopWorkoutCollectionDTO.self, WhoopDTOTestSupport.workoutJSON)
        XCTAssertEqual(collection.records.count, 1)
        XCTAssertEqual(collection.records[0].id, UUID(uuidString: "650E8400-E29B-41D4-A716-446655440000"))
        XCTAssertEqual(collection.records[0].scoreState, .scored)
        XCTAssertEqual(collection.records[0].score?.strain, 14.2)
    }

    func testTokenResponseDecodesSnakeCaseFields() throws {
        let token = try WhoopDTOTestSupport.decode(WhoopTokenResponseDTO.self, WhoopDTOTestSupport.tokenJSON)
        XCTAssertEqual(token.accessToken, "replacement-access")
        XCTAssertEqual(token.refreshToken, "replacement-refresh")
        XCTAssertEqual(token.expiresIn, 3_600)
        XCTAssertEqual(token.tokenType, "bearer")
        XCTAssertEqual(token.scope, "offline read:recovery")
    }

    func testAllScoreStatesUseExactWhoopRawValues() throws {
        XCTAssertEqual(WhoopScoreState.scored.rawValue, "SCORED")
        XCTAssertEqual(WhoopScoreState.pendingScore.rawValue, "PENDING_SCORE")
        XCTAssertEqual(WhoopScoreState.unscorable.rawValue, "UNSCORABLE")
    }

    func testUnknownScoreStateSurvivesCollectionDecodeAndCodableRoundTrip() throws {
        let collection = try WhoopDTOTestSupport.decode(
            WhoopCycleCollectionDTO.self,
            WhoopDTOTestSupport.unknownScoreStateCycleJSON
        )
        let state = collection.records[0].scoreState
        XCTAssertEqual(state, .unknown("FUTURE_SCORE_STATE"))
        XCTAssertEqual(state.rawValue, "FUTURE_SCORE_STATE")
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(WhoopScoreState.self, from: encoded), state)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""FUTURE_SCORE_STATE""#)
    }
}
#else
import Testing

@Suite struct WhoopDTOTests {
    @Test func cycleCollectionDecodesFractionalTimestampOptionalEndAndStrain() throws {
        let collection = try WhoopDTOTestSupport.decode(WhoopCycleCollectionDTO.self, WhoopDTOTestSupport.cycleJSON)
        #expect(collection.records.count == 1)
        #expect(collection.nextToken == "next-page")
        #expect(collection.records[0].id == 93_845)
        #expect(collection.records[0].end == nil)
        #expect(collection.records[0].scoreState == .scored)
        #expect(collection.records[0].score?.strain == 12.4)
    }

    @Test func recoveryDecodesFractionalAndNonfractionalTimestamps() throws {
        let recovery = try WhoopDTOTestSupport.decode(WhoopRecoveryDTO.self, WhoopDTOTestSupport.recoveryJSON)
        #expect(recovery.cycleID == 93_845)
        #expect(recovery.sleepID == UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        #expect(recovery.createdAt < recovery.updatedAt)
        #expect(recovery.scoreState == .scored)
        #expect(recovery.score?.recoveryScore == 72)
    }

    @Test func sleepDecodesPerformance() throws {
        let sleep = try WhoopDTOTestSupport.decode(WhoopSleepDTO.self, WhoopDTOTestSupport.sleepJSON)
        #expect(sleep.id == UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        #expect(sleep.cycleID == 93_845)
        #expect(sleep.score?.sleepPerformancePercentage == 86.5)
    }

    @Test func workoutCollectionDecodesEndAndStrain() throws {
        let collection = try WhoopDTOTestSupport.decode(WhoopWorkoutCollectionDTO.self, WhoopDTOTestSupport.workoutJSON)
        #expect(collection.records.count == 1)
        #expect(collection.records[0].id == UUID(uuidString: "650E8400-E29B-41D4-A716-446655440000"))
        #expect(collection.records[0].scoreState == .scored)
        #expect(collection.records[0].score?.strain == 14.2)
    }

    @Test func tokenResponseDecodesSnakeCaseFields() throws {
        let token = try WhoopDTOTestSupport.decode(WhoopTokenResponseDTO.self, WhoopDTOTestSupport.tokenJSON)
        #expect(token.accessToken == "replacement-access")
        #expect(token.refreshToken == "replacement-refresh")
        #expect(token.expiresIn == 3_600)
        #expect(token.tokenType == "bearer")
        #expect(token.scope == "offline read:recovery")
    }

    @Test func allScoreStatesUseExactWhoopRawValues() {
        #expect(WhoopScoreState.scored.rawValue == "SCORED")
        #expect(WhoopScoreState.pendingScore.rawValue == "PENDING_SCORE")
        #expect(WhoopScoreState.unscorable.rawValue == "UNSCORABLE")
    }

    @Test func unknownScoreStateSurvivesCollectionDecodeAndCodableRoundTrip() throws {
        let collection = try WhoopDTOTestSupport.decode(
            WhoopCycleCollectionDTO.self,
            WhoopDTOTestSupport.unknownScoreStateCycleJSON
        )
        let state = collection.records[0].scoreState
        #expect(state == .unknown("FUTURE_SCORE_STATE"))
        #expect(state.rawValue == "FUTURE_SCORE_STATE")
        let encoded = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(WhoopScoreState.self, from: encoded) == state)
        #expect(String(decoding: encoded, as: UTF8.self) == #""FUTURE_SCORE_STATE""#)
    }
}
#endif
