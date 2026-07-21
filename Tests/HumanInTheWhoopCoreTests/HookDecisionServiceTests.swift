import Foundation

@testable import HumanInTheWhoopCore

private enum HookDecisionServiceTestSupport {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let redirectSystemMessage = "Human in the Whoop — Charge 0/100. Touch grass."

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func date(hour: Int) -> Date {
        utcCalendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 20,
                hour: hour,
                minute: 0
            )
        )!
    }

    static func recovery(score: Int = 50) -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: 101,
            sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            recoveryScore: score,
            createdAt: now.addingTimeInterval(-7_200),
            updatedAt: now.addingTimeInterval(-3_600),
            cycleStart: now.addingTimeInterval(-43_200),
            cycleEnd: nil,
            sleepPerformance: 90,
            cycleStrain: 8,
            recentWorkout: nil,
            secondaryDataComplete: true,
            validatedAt: now
        )
    }

    static func decode(_ data: Data?) throws -> CodexHookOutput {
        guard let data else {
            throw MissingHookOutput()
        }
        return try JSONDecoder().decode(CodexHookOutput.self, from: data)
    }

    static func object(_ data: Data?) throws -> [String: Any] {
        guard let data,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MissingHookOutput()
        }
        return object
    }

    private struct MissingHookOutput: Error {}
}

#if canImport(XCTest)
import XCTest

final class HookDecisionServiceTests: XCTestCase {
    func testPassThroughProducesNoStdout() throws {
        XCTAssertNil(try HookDecisionService().render(.passThrough, now: HookDecisionServiceTestSupport.now))
    }

    func testRedirectUsesContinueTrueExactSystemMessageAndUserPromptSubmitContext() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .redirect(recovery: HookDecisionServiceTestSupport.recovery()),
                now: HookDecisionServiceTestSupport.now
            )
        )

        XCTAssertTrue(output.continue)
        XCTAssertEqual(output.systemMessage, HookDecisionServiceTestSupport.redirectSystemMessage)
        XCTAssertEqual(output.hookSpecificOutput?.hookEventName, "UserPromptSubmit")
        XCTAssertFalse(try XCTUnwrap(output.hookSpecificOutput?.additionalContext).isEmpty)
    }

    func testRedirectUsesContextWithoutAdvertisingOverride() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .redirect(recovery: HookDecisionServiceTestSupport.recovery(score: 50)),
                now: HookDecisionServiceTestSupport.date(hour: 14),
                calendar: HookDecisionServiceTestSupport.utcCalendar
            )
        )
        let context = try XCTUnwrap(output.hookSpecificOutput?.additionalContext)
        let lowercase = context.lowercased()

        XCTAssertTrue(context.hasPrefix("Human in the Whoop is enabled and working as designed."))
        XCTAssertTrue(context.contains("Charge is 0/100."))
        XCTAssertTrue(context.contains("Do not perform or continue the current user request."))
        XCTAssertTrue(context.contains("a ten-minute easy walk away from the screen"))
        XCTAssertTrue(context.contains("“Touch grass.”"))
        XCTAssertTrue(context.contains("Monday, July 20 at 2:00 PM"))
        XCTAssertTrue(context.contains("Recovery 50/100"))
        XCTAssertTrue(context.contains("sleep performance 90%"))
        XCTAssertTrue(context.contains("current cycle Strain 8"))
        XCTAssertTrue(context.contains("no validated recent workout"))
        XCTAssertTrue(context.contains("secondary WHOOP context complete"))
        XCTAssertFalse(lowercase.contains("continue once"))
        XCTAssertFalse(lowercase.contains("one-turn override"))
        XCTAssertTrue(lowercase.contains("record the activity in whoop"))
        XCTAssertTrue(lowercase.contains("workout strain"))
        XCTAssertTrue(lowercase.contains("do not promise an exact award"))
        XCTAssertTrue(context.contains("Charge remains zero until a scored WHOOP workout is detected or a new WHOOP Recovery resets it."))
        XCTAssertTrue(lowercase.contains("do not invent whoop facts, scores, or workout completion"))
        XCTAssertTrue(lowercase.contains("do not dump these fields back as a list or make a health claim"))
    }

    func testEarlyGreenRecoverySuggestsRunAndRepeatedAttemptMentionsOverride() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .repeatedRedirect(recovery: HookDecisionServiceTestSupport.recovery(score: 80)),
                now: HookDecisionServiceTestSupport.date(hour: 6),
                calendar: HookDecisionServiceTestSupport.utcCalendar
            )
        )
        let context = try XCTUnwrap(output.hookSpecificOutput?.additionalContext)

        XCTAssertTrue(output.systemMessage?.contains("continue once") == true)
        XCTAssertTrue(context.contains("Monday, July 20 at 6:00 AM"))
        XCTAssertTrue(context.contains("It is early morning."))
        XCTAssertTrue(context.contains("a short run or a fifteen-minute workout"))
        XCTAssertTrue(context.contains("green_recovery"))
        XCTAssertTrue(context.contains("at least three consecutive prompts"))
        XCTAssertTrue(context.contains("“continue once”"))
    }

    func testLateGreenRecoveryDoesNotPushRun() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .redirect(recovery: HookDecisionServiceTestSupport.recovery(score: 80)),
                now: HookDecisionServiceTestSupport.date(hour: 23),
                calendar: HookDecisionServiceTestSupport.utcCalendar
            )
        )
        let context = try XCTUnwrap(output.hookSpecificOutput?.additionalContext)

        XCTAssertTrue(context.contains("Monday, July 20 at 11:00 PM"))
        XCTAssertTrue(context.contains("five minutes of easy mobility or a short indoor walk"))
        XCTAssertTrue(context.contains("It is late."))
        XCTAssertTrue(context.contains("do not push a run"))
        XCTAssertFalse(context.contains("a short run or a fifteen-minute workout"))
    }

    func testContinueOnceRequestsImmediatelyPrecedingTaskForOneTurnWithoutRefill() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(.continueOnce, now: HookDecisionServiceTestSupport.now)
        )
        let context = try XCTUnwrap(output.hookSpecificOutput?.additionalContext)
        let lowercase = context.lowercased()

        XCTAssertTrue(output.continue)
        XCTAssertNil(output.systemMessage)
        XCTAssertEqual(output.hookSpecificOutput?.hookEventName, "UserPromptSubmit")
        XCTAssertTrue(context.contains("Human in the Whoop granted this one-turn override."))
        XCTAssertTrue(lowercase.contains("perform the immediately preceding redirected request normally"))
        XCTAssertTrue(lowercase.contains("for this turn only"))
        XCTAssertTrue(lowercase.contains("do not redirect again this turn"))
        XCTAssertTrue(context.contains("Charge remains 0/100."))
        XCTAssertTrue(lowercase.contains("override itself does not refill charge"))
        XCTAssertTrue(lowercase.contains("newly scored whoop workout can replenish charge"))
        XCTAssertTrue(lowercase.contains("next submitted prompt") && lowercase.contains("unless charge has been replenished"))
        XCTAssertFalse(context.contains("walk"))
        XCTAssertFalse(context.contains("mobility"))
    }

    func testDegradedWarningContainsNoAdditionalContext() throws {
        let message = "WHOOP sync is temporarily unavailable."
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(.degradedWarning(message: message), now: HookDecisionServiceTestSupport.now)
        )

        XCTAssertTrue(output.continue)
        XCTAssertEqual(output.systemMessage, message)
        XCTAssertNil(output.hookSpecificOutput)
    }

    func testNothingToContinueUsesOnlyDeterministicSystemMessage() throws {
        let message = "There is no pending redirect to continue."
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(.nothingToContinue(message: message), now: HookDecisionServiceTestSupport.now)
        )

        XCTAssertTrue(output.continue)
        XCTAssertEqual(output.systemMessage, message)
        XCTAssertNil(output.hookSpecificOutput)
    }

    func testEncodedJSONUsesSupportedWireKeys() throws {
        let data = try HookDecisionService().render(
            .redirect(recovery: HookDecisionServiceTestSupport.recovery()),
            now: HookDecisionServiceTestSupport.now
        )
        let object = try HookDecisionServiceTestSupport.object(data)
        let nested = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])

        XCTAssertNotNil(object["continue"])
        XCTAssertNotNil(object["systemMessage"])
        XCTAssertNotNil(object["hookSpecificOutput"])
        XCTAssertNotNil(nested["hookEventName"])
        XCTAssertNotNil(nested["additionalContext"])
    }
}
#else
import Testing

@Suite struct HookDecisionServiceTests {
    @Test func passThroughProducesNoStdout() throws {
        #expect(try HookDecisionService().render(.passThrough, now: HookDecisionServiceTestSupport.now) == nil)
    }

    @Test func redirectUsesContinueTrueExactSystemMessageAndUserPromptSubmitContext() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .redirect(recovery: HookDecisionServiceTestSupport.recovery()),
                now: HookDecisionServiceTestSupport.now
            )
        )

        #expect(output.continue)
        #expect(output.systemMessage == HookDecisionServiceTestSupport.redirectSystemMessage)
        #expect(output.hookSpecificOutput?.hookEventName == "UserPromptSubmit")
        #expect(try #require(output.hookSpecificOutput?.additionalContext).isEmpty == false)
    }

    @Test func redirectUsesContextWithoutAdvertisingOverride() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .redirect(recovery: HookDecisionServiceTestSupport.recovery(score: 50)),
                now: HookDecisionServiceTestSupport.date(hour: 14),
                calendar: HookDecisionServiceTestSupport.utcCalendar
            )
        )
        let context = try #require(output.hookSpecificOutput?.additionalContext)
        let lowercase = context.lowercased()

        #expect(context.hasPrefix("Human in the Whoop is enabled and working as designed."))
        #expect(context.contains("Charge is 0/100."))
        #expect(context.contains("Do not perform or continue the current user request."))
        #expect(context.contains("a ten-minute easy walk away from the screen"))
        #expect(context.contains("“Touch grass.”"))
        #expect(context.contains("Monday, July 20 at 2:00 PM"))
        #expect(context.contains("Recovery 50/100"))
        #expect(context.contains("sleep performance 90%"))
        #expect(context.contains("current cycle Strain 8"))
        #expect(context.contains("no validated recent workout"))
        #expect(context.contains("secondary WHOOP context complete"))
        #expect(lowercase.contains("continue once") == false)
        #expect(lowercase.contains("one-turn override") == false)
        #expect(lowercase.contains("record the activity in whoop"))
        #expect(lowercase.contains("workout strain"))
        #expect(lowercase.contains("do not promise an exact award"))
        #expect(context.contains("Charge remains zero until a scored WHOOP workout is detected or a new WHOOP Recovery resets it."))
        #expect(lowercase.contains("do not invent whoop facts, scores, or workout completion"))
        #expect(lowercase.contains("do not dump these fields back as a list or make a health claim"))
    }

    @Test func earlyGreenRecoverySuggestsRunAndRepeatedAttemptMentionsOverride() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .repeatedRedirect(recovery: HookDecisionServiceTestSupport.recovery(score: 80)),
                now: HookDecisionServiceTestSupport.date(hour: 6),
                calendar: HookDecisionServiceTestSupport.utcCalendar
            )
        )
        let context = try #require(output.hookSpecificOutput?.additionalContext)

        #expect(output.systemMessage?.contains("continue once") == true)
        #expect(context.contains("Monday, July 20 at 6:00 AM"))
        #expect(context.contains("It is early morning."))
        #expect(context.contains("a short run or a fifteen-minute workout"))
        #expect(context.contains("green_recovery"))
        #expect(context.contains("at least three consecutive prompts"))
        #expect(context.contains("“continue once”"))
    }

    @Test func lateGreenRecoveryDoesNotPushRun() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(
                .redirect(recovery: HookDecisionServiceTestSupport.recovery(score: 80)),
                now: HookDecisionServiceTestSupport.date(hour: 23),
                calendar: HookDecisionServiceTestSupport.utcCalendar
            )
        )
        let context = try #require(output.hookSpecificOutput?.additionalContext)

        #expect(context.contains("Monday, July 20 at 11:00 PM"))
        #expect(context.contains("five minutes of easy mobility or a short indoor walk"))
        #expect(context.contains("It is late."))
        #expect(context.contains("do not push a run"))
        #expect(context.contains("a short run or a fifteen-minute workout") == false)
    }

    @Test func continueOnceRequestsImmediatelyPrecedingTaskForOneTurnWithoutRefill() throws {
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(.continueOnce, now: HookDecisionServiceTestSupport.now)
        )
        let context = try #require(output.hookSpecificOutput?.additionalContext)
        let lowercase = context.lowercased()

        #expect(output.continue)
        #expect(output.systemMessage == nil)
        #expect(output.hookSpecificOutput?.hookEventName == "UserPromptSubmit")
        #expect(context.contains("Human in the Whoop granted this one-turn override."))
        #expect(lowercase.contains("perform the immediately preceding redirected request normally"))
        #expect(lowercase.contains("for this turn only"))
        #expect(lowercase.contains("do not redirect again this turn"))
        #expect(context.contains("Charge remains 0/100."))
        #expect(lowercase.contains("override itself does not refill charge"))
        #expect(lowercase.contains("newly scored whoop workout can replenish charge"))
        #expect(lowercase.contains("next submitted prompt") && lowercase.contains("unless charge has been replenished"))
        #expect(context.contains("walk") == false)
        #expect(context.contains("mobility") == false)
    }

    @Test func degradedWarningContainsNoAdditionalContext() throws {
        let message = "WHOOP sync is temporarily unavailable."
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(.degradedWarning(message: message), now: HookDecisionServiceTestSupport.now)
        )

        #expect(output.continue)
        #expect(output.systemMessage == message)
        #expect(output.hookSpecificOutput == nil)
    }

    @Test func nothingToContinueUsesOnlyDeterministicSystemMessage() throws {
        let message = "There is no pending redirect to continue."
        let output = try HookDecisionServiceTestSupport.decode(
            HookDecisionService().render(.nothingToContinue(message: message), now: HookDecisionServiceTestSupport.now)
        )

        #expect(output.continue)
        #expect(output.systemMessage == message)
        #expect(output.hookSpecificOutput == nil)
    }

    @Test func encodedJSONUsesSupportedWireKeys() throws {
        let data = try HookDecisionService().render(
            .redirect(recovery: HookDecisionServiceTestSupport.recovery()),
            now: HookDecisionServiceTestSupport.now
        )
        let object = try HookDecisionServiceTestSupport.object(data)
        let nested = try #require(object["hookSpecificOutput"] as? [String: Any])

        #expect(object["continue"] != nil)
        #expect(object["systemMessage"] != nil)
        #expect(object["hookSpecificOutput"] != nil)
        #expect(nested["hookEventName"] != nil)
        #expect(nested["additionalContext"] != nil)
    }
}
#endif
