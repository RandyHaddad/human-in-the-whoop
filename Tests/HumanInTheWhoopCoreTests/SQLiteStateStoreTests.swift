import Dispatch
import Foundation

@testable import HumanInTheWhoopCore

private enum SQLiteStateStoreTestSupport {
    static func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.sqlite3")
    }

    static func removeTestDirectory(containing databaseURL: URL) {
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    static func sampleRecovery() -> RecoverySnapshot {
        RecoverySnapshot(
            cycleID: 42,
            sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            recoveryScore: 81,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100.125),
            cycleStart: Date(timeIntervalSince1970: 1_699_900_000.125),
            cycleEnd: nil,
            sleepPerformance: 92.5,
            cycleStrain: 7.3,
            recentWorkout: WorkoutSnapshot(
                strain: 12.4,
                endedAt: Date(timeIntervalSince1970: 1_699_990_000.125)
            ),
            secondaryDataComplete: true,
            validatedAt: Date(timeIntervalSince1970: 1_700_000_200.125)
        )
    }

    static func concurrentDecrement(databaseURL: URL) throws -> PersistentState {
        let initialStore = try SQLiteStateStore(databaseURL: databaseURL)
        try initialStore.mutate { state in
            state.chargeRemaining = 50
        }

        let failures = LockedFailures()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "SQLiteStateStoreTests.concurrent", attributes: .concurrent)

        for _ in 0..<50 {
            group.enter()
            queue.async {
                defer { group.leave() }

                do {
                    let workerStore = try SQLiteStateStore(databaseURL: databaseURL)
                    try workerStore.mutate { state in
                        state.chargeRemaining = max(0, (state.chargeRemaining ?? 0) - 1)
                    }
                } catch {
                    failures.append(error)
                }
            }
        }

        group.wait()
        let errors = failures.values
        if !errors.isEmpty {
            throw ConcurrentMutationError(errors: errors)
        }

        return try SQLiteStateStore(databaseURL: databaseURL).read()
    }

    static func concurrentFirstOpen(rounds: Int = 20) throws {
        for _ in 0..<rounds {
            let databaseURL = makeDatabaseURL()
            defer { removeTestDirectory(containing: databaseURL) }

            let failures = LockedFailures()
            let ready = DispatchGroup()
            let finished = DispatchGroup()
            let start = DispatchSemaphore(value: 0)

            for _ in 0..<50 {
                ready.enter()
                finished.enter()
                Thread.detachNewThread {
                    defer { finished.leave() }
                    ready.leave()
                    start.wait()

                    do {
                        let store = try SQLiteStateStore(databaseURL: databaseURL)
                        _ = try store.read()
                    } catch {
                        failures.append(error)
                    }
                }
            }

            ready.wait()
            for _ in 0..<50 {
                start.signal()
            }
            finished.wait()

            let errors = failures.values
            if !errors.isEmpty {
                throw ConcurrentMutationError(errors: errors)
            }
        }
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    var values: [Error] {
        lock.withLock { errors }
    }

    func append(_ error: Error) {
        lock.withLock { errors.append(error) }
    }
}

private struct ConcurrentMutationError: Error, CustomStringConvertible {
    let errors: [Error]

    var description: String {
        "Concurrent mutations failed: \(errors.map(String.init(describing:)).joined(separator: "; "))"
    }
}

private struct ExpectedMutationError: Error {}

#if canImport(XCTest)
import XCTest

final class SQLiteStateStoreTests: XCTestCase {
    func testNewStoreUsesSafeDefaultsAndPrivatePermissions() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let state = try store.read()

        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.recovery)
        XCTAssertNil(state.chargeRemaining)

        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.deletingLastPathComponent().path)[.posixPermissions]
                as? NSNumber
        )
        let databasePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
        XCTAssertEqual(databasePermissions.intValue & 0o777, 0o600)
    }

    func testMutationPersistsAcrossIndependentStoreInstances() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let recovery = SQLiteStateStoreTestSupport.sampleRecovery()
        let firstStore = try SQLiteStateStore(databaseURL: databaseURL)
        try firstStore.mutate { state in
            state.enabled = true
            state.chargeRemaining = 17
            state.recovery = recovery
            state.degradedReason = "WHOOP unavailable"
            state.pendingOverride = PendingOverride(sessionID: "session", redirectedTurnID: "turn")
        }

        let secondStore = try SQLiteStateStore(databaseURL: databaseURL)
        let state = try secondStore.read()
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.chargeRemaining, 17)
        XCTAssertEqual(state.recovery, recovery)
        XCTAssertEqual(state.degradedReason, "WHOOP unavailable")
        XCTAssertEqual(
            state.pendingOverride,
            PendingOverride(sessionID: "session", redirectedTurnID: "turn")
        )
    }

    func testAppendsAndReadsAuditEvent() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let event = AuditEvent(
            name: "charge.decremented",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            metadata: ["remaining": "4", "source": "hook"]
        )

        try store.appendAudit(event)

        XCTAssertEqual(try store.readAuditEvents(), [event])
    }

    func testThrowingMutationBodyRollsBackChanges() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        XCTAssertThrowsError(
            try store.mutate { state in
                state.chargeRemaining = 9
                throw ExpectedMutationError()
            }
        )

        XCTAssertNil(try SQLiteStateStore(databaseURL: databaseURL).read().chargeRemaining)

        try store.mutate { state in
            state.chargeRemaining = 3
        }
        XCTAssertEqual(try store.read().chargeRemaining, 3)
    }

    func testRollbackFailureInvalidatesConnection() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        store.simulateNextRollbackFailureForTesting()

        XCTAssertThrowsError(
            try store.mutate { state in
                state.chargeRemaining = 9
                throw ExpectedMutationError()
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("mutation failed"))
            XCTAssertTrue(error.localizedDescription.contains("roll back"))
        }
        for _ in 0..<2 {
            XCTAssertThrowsError(try store.read()) { error in
                XCTAssertTrue(error.localizedDescription.contains("invalidated"))
            }
        }
    }

    func testConcurrentAtomicMutationsDoNotLoseUpdates() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let finalState = try SQLiteStateStoreTestSupport.concurrentDecrement(databaseURL: databaseURL)

        XCTAssertEqual(finalState.chargeRemaining, 0)
    }

    func testConcurrentFirstOpenDoesNotReturnBusy() throws {
        try SQLiteStateStoreTestSupport.concurrentFirstOpen()
    }
}
#else
import Testing

@Suite struct SQLiteStateStoreTests {
    @Test func newStoreUsesSafeDefaultsAndPrivatePermissions() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let state = try store.read()

        #expect(state.enabled == false)
        #expect(state.recovery == nil)
        #expect(state.chargeRemaining == nil)

        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(atPath: databaseURL.deletingLastPathComponent().path)[.posixPermissions]
                as? NSNumber
        )
        let databasePermissions = try #require(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        )
        #expect(directoryPermissions.intValue & 0o777 == 0o700)
        #expect(databasePermissions.intValue & 0o777 == 0o600)
    }

    @Test func mutationPersistsAcrossIndependentStoreInstances() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let recovery = SQLiteStateStoreTestSupport.sampleRecovery()
        let firstStore = try SQLiteStateStore(databaseURL: databaseURL)
        try firstStore.mutate { state in
            state.enabled = true
            state.chargeRemaining = 17
            state.recovery = recovery
            state.degradedReason = "WHOOP unavailable"
            state.pendingOverride = PendingOverride(sessionID: "session", redirectedTurnID: "turn")
        }

        let secondStore = try SQLiteStateStore(databaseURL: databaseURL)
        let state = try secondStore.read()
        #expect(state.enabled)
        #expect(state.chargeRemaining == 17)
        #expect(state.recovery == recovery)
        #expect(state.degradedReason == "WHOOP unavailable")
        #expect(state.pendingOverride == PendingOverride(sessionID: "session", redirectedTurnID: "turn"))
    }

    @Test func appendsAndReadsAuditEvent() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        let event = AuditEvent(
            name: "charge.decremented",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            metadata: ["remaining": "4", "source": "hook"]
        )

        try store.appendAudit(event)

        #expect(try store.readAuditEvents() == [event])
    }

    @Test func throwingMutationBodyRollsBackChanges() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        #expect(throws: ExpectedMutationError.self) {
            try store.mutate { state in
                state.chargeRemaining = 9
                throw ExpectedMutationError()
            }
        }

        #expect(try SQLiteStateStore(databaseURL: databaseURL).read().chargeRemaining == nil)

        try store.mutate { state in
            state.chargeRemaining = 3
        }
        #expect(try store.read().chargeRemaining == 3)
    }

    @Test func rollbackFailureInvalidatesConnection() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let store = try SQLiteStateStore(databaseURL: databaseURL)
        store.simulateNextRollbackFailureForTesting()

        do {
            try store.mutate { state in
                state.chargeRemaining = 9
                throw ExpectedMutationError()
            }
            #expect(Bool(false), "Expected mutation recovery to fail")
        } catch {
            #expect(error.localizedDescription.contains("mutation failed"))
            #expect(error.localizedDescription.contains("roll back"))
        }

        for _ in 0..<2 {
            do {
                _ = try store.read()
                #expect(Bool(false), "Expected invalidated store to reject reads")
            } catch {
                #expect(error.localizedDescription.contains("invalidated"))
            }
        }
    }

    @Test func concurrentAtomicMutationsDoNotLoseUpdates() throws {
        let databaseURL = SQLiteStateStoreTestSupport.makeDatabaseURL()
        defer { SQLiteStateStoreTestSupport.removeTestDirectory(containing: databaseURL) }

        let finalState = try SQLiteStateStoreTestSupport.concurrentDecrement(databaseURL: databaseURL)

        #expect(finalState.chargeRemaining == 0)
    }

    @Test func concurrentFirstOpenDoesNotReturnBusy() throws {
        try SQLiteStateStoreTestSupport.concurrentFirstOpen()
    }
}
#endif
