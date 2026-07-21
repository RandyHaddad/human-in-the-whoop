import Dispatch
import Foundation

import HumanInTheWhoopCore

private enum HITWHookIntegrationTestSupport {
    static let promptSentinel = "hitw-prompt-sentinel-\(UUID().uuidString)-\(UUID().uuidString)"
    static let redirectSystemMessage = "Human in the Whoop — Charge 0/100. Touch grass."
    static let continueOnceContext = "Human in the Whoop granted this one-turn override. Perform the immediately preceding redirected request normally for this turn only. Do not redirect again this turn. Charge remains 0/100. The override itself does not refill Charge; a newly scored WHOOP workout can replenish Charge after Human in the Whoop refreshes. The next submitted prompt is subject to redirect again unless Charge has been replenished."

    struct Fixture {
        let root: URL

        var databaseURL: URL {
            root.appendingPathComponent("state.sqlite3")
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    struct Execution {
        let terminationStatus: Int32
        let stdout: Data
        let stderr: Data
    }

    struct ScenarioFailure: Error, CustomStringConvertible {
        let description: String
    }

    final class PipeReadResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Data, Error>?

        func complete(_ result: Result<Data, Error>) {
            lock.withLock {
                self.result = result
            }
        }

        func value() throws -> Data {
            try lock.withLock {
                guard let result else {
                    throw ScenarioFailure(description: "pipe reader did not complete")
                }
                return try result.get()
            }
        }
    }

    static func defaultDisabledIsSilentAndDoesNotChangeState() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStateStore(databaseURL: fixture.databaseURL)
        let initialState = try store.read()

        let execution = try run(input: inputData(), stateRoot: fixture.root)

        try requireSilentSuccess(execution)
        let finalState = try store.read()
        let auditEvents = try store.readAuditEvents()
        try require(finalState == initialState, "disabled hook changed persistent state")
        try require(auditEvents.isEmpty, "disabled hook wrote an audit event")
    }

    static func readyChargeSeventyTwoSpendsOneSilentlyWithoutStoringPrompt() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReadyState(fixture: fixture, charge: 72)

        let execution = try run(input: inputData(), stateRoot: fixture.root)

        try requireSilentSuccess(execution)
        let state = try store.read()
        let auditEvents = try store.readAuditEvents()
        try require(state.chargeRemaining == 71, "ready hook did not spend exactly one Charge")
        try require(state.pendingOverride == nil, "ready hook created a pending redirect")
        try require(auditEvents.isEmpty, "ready hook wrote an audit event")
        try require(
            !databaseFamilyContains(Data(promptSentinel.utf8), fixture: fixture),
            "ready hook stored prompt text"
        )
    }

    static func lastChargePointPassesThroughAndReachesZero() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReadyState(fixture: fixture, charge: 1)

        let execution = try run(input: inputData(), stateRoot: fixture.root)

        try requireSilentSuccess(execution)
        let state = try store.read()
        try require(state.chargeRemaining == 0, "last Charge point did not reach zero")
        try require(state.pendingOverride == nil, "last Charge point redirected instead of proceeding")
    }

    static func zeroChargeEmitsExactRedirectAndSetsPendingOverride() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReadyState(fixture: fixture, charge: 0)

        let execution = try run(input: inputData(), stateRoot: fixture.root)

        try requireSuccessfulExecution(execution)
        let output = try decodeOutput(execution.stdout)
        try require(output.continue, "redirect output did not allow Codex to consume hook context")
        try require(output.systemMessage == redirectSystemMessage, "redirect system warning changed")
        try require(output.hookSpecificOutput?.hookEventName == "UserPromptSubmit", "redirect event name changed")
        try requireStandardRedirectContext(output.hookSpecificOutput?.additionalContext)

        let state = try store.read()
        try require(state.chargeRemaining == 0, "redirect changed zero Charge")
        try require(
            state.pendingOverride == PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-a"),
            "redirect did not persist the exact pending session and turn"
        )
    }

    static func continueOnceClearsPendingThenNextPromptRedirectsAgain() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReadyState(fixture: fixture, charge: 0)

        let first = try run(input: inputData(), stateRoot: fixture.root)
        try requireSuccessfulExecution(first)
        _ = try decodeOutput(first.stdout)

        let override = try run(
            input: inputData(turnID: "turn-b", prompt: " \nConTinue OnCe\t"),
            stateRoot: fixture.root
        )
        try requireSuccessfulExecution(override)
        let overrideOutput = try decodeOutput(override.stdout)
        try require(overrideOutput.continue, "continue-once output did not continue")
        try require(overrideOutput.systemMessage == nil, "continue-once output added a system warning")
        try require(overrideOutput.hookSpecificOutput?.hookEventName == "UserPromptSubmit", "continue-once event name changed")
        try require(overrideOutput.hookSpecificOutput?.additionalContext == continueOnceContext, "continue-once context changed")
        var state = try store.read()
        try require(state.chargeRemaining == 0, "continue once refilled Charge")
        try require(state.pendingOverride == nil, "continue once did not clear the pending redirect")

        let next = try run(
            input: inputData(turnID: "turn-c", prompt: "prompt"),
            stateRoot: fixture.root
        )
        try requireSuccessfulExecution(next)
        let nextOutput = try decodeOutput(next.stdout)
        try require(nextOutput.systemMessage == redirectSystemMessage, "next prompt did not redirect again")
        try requireStandardRedirectContext(nextOutput.hookSpecificOutput?.additionalContext)
        state = try store.read()
        try require(state.chargeRemaining == 0, "next redirect changed zero Charge")
        try require(
            state.pendingOverride == PendingOverride(sessionID: "session-a", redirectedTurnID: "turn-c"),
            "next redirect did not replace the pending turn"
        )
    }

    static func degradedStateWarnsOnceWithoutHookContext() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStateStore(databaseURL: fixture.databaseURL)
        try ChargeEngine(store: store).setEnabled(true)

        let first = try run(input: inputData(), stateRoot: fixture.root)

        try requireSuccessfulExecution(first)
        let output = try decodeOutput(first.stdout)
        try require(output.continue, "degraded warning did not let ordinary Codex handling continue")
        try require(output.systemMessage == "WHOOP refresh is required before Charge can resume.", "degraded warning changed")
        try require(output.hookSpecificOutput == nil, "degraded warning included hook-specific redirect context")

        let second = try run(
            input: inputData(turnID: "turn-b"),
            stateRoot: fixture.root
        )
        try requireSilentSuccess(second)
        let finalState = try store.read()
        try require(finalState.degradedWarningEmitted, "degraded warning was not recorded as emitted")
    }

    static func malformedJSONFailsOpenBeforeCreatingState() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        let execution = try run(input: Data("{not-json".utf8), stateRoot: fixture.root)

        try requireSilentSuccess(execution)
        try require(!FileManager.default.fileExists(atPath: fixture.root.path), "malformed JSON created the state root")
    }

    static func emptyStdinFailsOpenBeforeCreatingState() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        let execution = try run(input: Data(), stateRoot: fixture.root)

        try requireSilentSuccess(execution)
        try require(!FileManager.default.fileExists(atPath: fixture.root.path), "empty stdin created the state root")
    }

    static func unsupportedEventIsIgnoredBeforeCreatingState() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        let execution = try run(
            input: inputData(hookEventName: "SessionStart"),
            stateRoot: fixture.root
        )

        try requireSilentSuccess(execution)
        try require(!FileManager.default.fileExists(atPath: fixture.root.path), "unsupported event created the state root")
    }

    static func databaseFailureFailsOpen() throws {
        let uniqueDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HITWHookIntegrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateRootFile = uniqueDirectory.appendingPathComponent("state-root")
        defer { try? FileManager.default.removeItem(at: uniqueDirectory) }
        try FileManager.default.createDirectory(at: uniqueDirectory, withIntermediateDirectories: true)
        try Data("regular file, not a directory".utf8).write(to: stateRootFile)

        let execution = try run(input: inputData(), stateRoot: stateRootFile)

        try requireSilentSuccess(execution)
    }

    static func closedStdoutRollsBackZeroChargeRedirect() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReadyState(fixture: fixture, charge: 0)

        let execution = try run(
            input: inputData(),
            stateRoot: fixture.root,
            closeStdoutReadBeforeLaunch: true
        )

        try requireSilentSuccess(execution)
        let state = try store.read()
        try require(state.chargeRemaining == 0, "failed redirect delivery changed zero Charge")
        try require(state.pendingOverride == nil, "failed redirect delivery committed a pending override")
    }

    static func closedStdoutRollsBackDegradedWarningEmission() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStateStore(databaseURL: fixture.databaseURL)
        try ChargeEngine(store: store).setEnabled(true)

        let execution = try run(
            input: inputData(),
            stateRoot: fixture.root,
            closeStdoutReadBeforeLaunch: true
        )

        try requireSilentSuccess(execution)
        let state = try store.read()
        try require(!state.degradedWarningEmitted, "failed warning delivery was marked emitted")
    }

    static func oversizedValidInputFailsOpenBeforeCreatingState() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let oversizedPrompt = String(repeating: "v", count: 1_048_576)

        let execution = try run(
            input: inputData(prompt: oversizedPrompt),
            stateRoot: fixture.root
        )

        try requireSilentSuccess(execution)
        try require(!FileManager.default.fileExists(atPath: fixture.root.path), "oversized valid input created state")
    }

    static func oversizedMalformedInputFailsOpenBeforeCreatingState() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let malformed = Data(repeating: 0x7B, count: 1_048_578)

        let execution = try run(input: malformed, stateRoot: fixture.root)

        try requireSilentSuccess(execution)
        try require(!FileManager.default.fileExists(atPath: fixture.root.path), "oversized malformed input created state")
    }

    private static func makeFixture() -> Fixture {
        Fixture(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("HITWHookIntegrationTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    private static func seedReadyState(fixture: Fixture, charge: Int) throws -> SQLiteStateStore {
        let store = try SQLiteStateStore(databaseURL: fixture.databaseURL)
        let engine = ChargeEngine(store: store)
        try engine.setEnabled(true)
        try engine.applyRecovery(recovery())
        try store.mutate { state in
            state.chargeRemaining = charge
        }
        return store
    }

    private static func recovery() -> RecoverySnapshot {
        let now = Date()
        return RecoverySnapshot(
            cycleID: 101,
            sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            recoveryScore: 72,
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

    private static func inputData(
        sessionID: String = "session-a",
        turnID: String = "turn-a",
        hookEventName: String = "UserPromptSubmit",
        prompt: String? = nil
    ) throws -> Data {
        try JSONEncoder().encode(
            HookInput(
                sessionID: sessionID,
                turnID: turnID,
                hookEventName: hookEventName,
                prompt: prompt ?? promptSentinel
            )
        )
    }

    private static func run(
        input: Data,
        stateRoot: URL,
        closeStdoutReadBeforeLaunch: Bool = false
    ) throws -> Execution {
        let binaryURL = hookBinaryURL
        try require(
            FileManager.default.isExecutableFile(atPath: binaryURL.path),
            "expected built executable at \(binaryURL.path)"
        )

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = binaryURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["HITW_STATE_ROOT": stateRoot.path],
            uniquingKeysWith: { _, testValue in testValue }
        )

        if closeStdoutReadBeforeLaunch {
            try stdoutPipe.fileHandleForReading.close()
        }

        try process.run()
        let readGroup = DispatchGroup()
        let stdoutRead = closeStdoutReadBeforeLaunch
            ? nil
            : beginReading(stdoutPipe.fileHandleForReading, group: readGroup)
        let stderrRead = beginReading(stderrPipe.fileHandleForReading, group: readGroup)
        try stdinPipe.fileHandleForWriting.write(contentsOf: input)
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        readGroup.wait()

        return Execution(
            terminationStatus: process.terminationStatus,
            stdout: try stdoutRead?.value() ?? Data(),
            stderr: try stderrRead.value()
        )
    }

    private static func beginReading(
        _ fileHandle: FileHandle,
        group: DispatchGroup
    ) -> PipeReadResult {
        let readResult = PipeReadResult()
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            readResult.complete(
                Result {
                    try fileHandle.readToEnd() ?? Data()
                }
            )
        }
        return readResult
    }

    private static var hookBinaryURL: URL {
        if let override = ProcessInfo.processInfo.environment["HITW_HOOK_TEST_BINARY"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }

        return packageRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("hitw-hook")
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func decodeOutput(_ data: Data) throws -> CodexHookOutput {
        try require(!data.isEmpty, "expected JSON on stdout")
        do {
            return try JSONDecoder().decode(CodexHookOutput.self, from: data)
        } catch {
            throw ScenarioFailure(description: "stdout was not valid CodexHookOutput JSON: \(error)")
        }
    }

    private static func requireSilentSuccess(_ execution: Execution) throws {
        try requireSuccessfulExecution(execution)
        try require(execution.stdout.isEmpty, "expected zero stdout bytes")
    }

    private static func requireSuccessfulExecution(_ execution: Execution) throws {
        try require(execution.terminationStatus == 0, "hook exited \(execution.terminationStatus)")
        try require(execution.stderr.isEmpty, "expected zero stderr bytes")
    }

    private static func requireStandardRedirectContext(_ optionalContext: String?) throws {
        let context = try optionalContext ?? {
            throw ScenarioFailure(description: "redirect context was missing")
        }()
        let lowercase = context.lowercased()
        try require(
            context.hasPrefix("Human in the Whoop is enabled and working as designed."),
            "redirect context lost the feature boundary"
        )
        try require(context.contains("Charge is 0/100."), "redirect context lost zero Charge")
        try require(context.contains("“Touch grass.”"), "redirect context lost the selected voice")
        try require(context.contains("Recommend "), "redirect context did not select an activity")
        try require(context.contains("Recovery 72/100"), "redirect context lost Recovery")
        try require(context.contains("sleep performance 90%"), "redirect context lost sleep context")
        try require(context.contains("current cycle Strain 8"), "redirect context lost cycle Strain")
        try require(context.contains("no validated recent workout"), "redirect context lost workout context")
        try require(
            context.contains("secondary WHOOP context complete"),
            "redirect context lost completeness"
        )
        try require(context.contains("green_recovery"), "redirect context lost selection reason")
        try require(lowercase.contains("local context:"), "redirect context lost local date and time")
        try require(!lowercase.contains("continue once"), "first redirect advertised the override")
        try require(!context.contains("(activity)"), "redirect context emitted a literal placeholder")
    }

    private static func databaseFamilyContains(_ bytes: Data, fixture: Fixture) -> Bool {
        [
            fixture.databaseURL,
            URL(fileURLWithPath: fixture.databaseURL.path + "-wal"),
            URL(fileURLWithPath: fixture.databaseURL.path + "-shm"),
        ]
            .compactMap { try? Data(contentsOf: $0) }
            .contains { $0.range(of: bytes) != nil }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ScenarioFailure(description: message)
        }
    }
}

#if canImport(XCTest)
import XCTest

final class HITWHookIntegrationTests: XCTestCase {
    func testDefaultDisabledIsSilentAndDoesNotChangeState() throws {
        try HITWHookIntegrationTestSupport.defaultDisabledIsSilentAndDoesNotChangeState()
    }

    func testReadyChargeSeventyTwoSpendsOneSilentlyWithoutStoringPrompt() throws {
        try HITWHookIntegrationTestSupport.readyChargeSeventyTwoSpendsOneSilentlyWithoutStoringPrompt()
    }

    func testLastChargePointPassesThroughAndReachesZero() throws {
        try HITWHookIntegrationTestSupport.lastChargePointPassesThroughAndReachesZero()
    }

    func testZeroChargeEmitsExactRedirectAndSetsPendingOverride() throws {
        try HITWHookIntegrationTestSupport.zeroChargeEmitsExactRedirectAndSetsPendingOverride()
    }

    func testContinueOnceClearsPendingThenNextPromptRedirectsAgain() throws {
        try HITWHookIntegrationTestSupport.continueOnceClearsPendingThenNextPromptRedirectsAgain()
    }

    func testDegradedStateWarnsOnceWithoutHookContext() throws {
        try HITWHookIntegrationTestSupport.degradedStateWarnsOnceWithoutHookContext()
    }

    func testMalformedJSONFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.malformedJSONFailsOpenBeforeCreatingState()
    }

    func testEmptyStdinFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.emptyStdinFailsOpenBeforeCreatingState()
    }

    func testUnsupportedEventIsIgnoredBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.unsupportedEventIsIgnoredBeforeCreatingState()
    }

    func testDatabaseFailureFailsOpen() throws {
        try HITWHookIntegrationTestSupport.databaseFailureFailsOpen()
    }

    func testClosedStdoutRollsBackZeroChargeRedirect() throws {
        try HITWHookIntegrationTestSupport.closedStdoutRollsBackZeroChargeRedirect()
    }

    func testClosedStdoutRollsBackDegradedWarningEmission() throws {
        try HITWHookIntegrationTestSupport.closedStdoutRollsBackDegradedWarningEmission()
    }

    func testOversizedValidInputFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.oversizedValidInputFailsOpenBeforeCreatingState()
    }

    func testOversizedMalformedInputFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.oversizedMalformedInputFailsOpenBeforeCreatingState()
    }
}
#else
import Testing

@Suite struct HITWHookIntegrationTests {
    @Test func defaultDisabledIsSilentAndDoesNotChangeState() throws {
        try HITWHookIntegrationTestSupport.defaultDisabledIsSilentAndDoesNotChangeState()
    }

    @Test func readyChargeSeventyTwoSpendsOneSilentlyWithoutStoringPrompt() throws {
        try HITWHookIntegrationTestSupport.readyChargeSeventyTwoSpendsOneSilentlyWithoutStoringPrompt()
    }

    @Test func lastChargePointPassesThroughAndReachesZero() throws {
        try HITWHookIntegrationTestSupport.lastChargePointPassesThroughAndReachesZero()
    }

    @Test func zeroChargeEmitsExactRedirectAndSetsPendingOverride() throws {
        try HITWHookIntegrationTestSupport.zeroChargeEmitsExactRedirectAndSetsPendingOverride()
    }

    @Test func continueOnceClearsPendingThenNextPromptRedirectsAgain() throws {
        try HITWHookIntegrationTestSupport.continueOnceClearsPendingThenNextPromptRedirectsAgain()
    }

    @Test func degradedStateWarnsOnceWithoutHookContext() throws {
        try HITWHookIntegrationTestSupport.degradedStateWarnsOnceWithoutHookContext()
    }

    @Test func malformedJSONFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.malformedJSONFailsOpenBeforeCreatingState()
    }

    @Test func emptyStdinFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.emptyStdinFailsOpenBeforeCreatingState()
    }

    @Test func unsupportedEventIsIgnoredBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.unsupportedEventIsIgnoredBeforeCreatingState()
    }

    @Test func databaseFailureFailsOpen() throws {
        try HITWHookIntegrationTestSupport.databaseFailureFailsOpen()
    }

    @Test func closedStdoutRollsBackZeroChargeRedirect() throws {
        try HITWHookIntegrationTestSupport.closedStdoutRollsBackZeroChargeRedirect()
    }

    @Test func closedStdoutRollsBackDegradedWarningEmission() throws {
        try HITWHookIntegrationTestSupport.closedStdoutRollsBackDegradedWarningEmission()
    }

    @Test func oversizedValidInputFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.oversizedValidInputFailsOpenBeforeCreatingState()
    }

    @Test func oversizedMalformedInputFailsOpenBeforeCreatingState() throws {
        try HITWHookIntegrationTestSupport.oversizedMalformedInputFailsOpenBeforeCreatingState()
    }
}
#endif
