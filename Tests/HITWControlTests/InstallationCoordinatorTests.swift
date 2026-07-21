import Foundation
@testable import HumanInTheWhoopControlSupport
import HumanInTheWhoopCore

private enum InstallationCoordinatorTestSupport {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }
    }

    static func fixture() throws -> (URL, SQLiteStateStore, ChargeEngine, HookConfigInstaller, URL) {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let physical = temporaryPath.hasPrefix("/var/") ? "/private\(temporaryPath)" : temporaryPath
        let root = URL(fileURLWithPath: physical, isDirectory: true)
            .appendingPathComponent("hitw-install-coordinator-\(UUID().uuidString)", isDirectory: true)
        let database = root.appendingPathComponent("state.sqlite3")
        let hooks = root.appendingPathComponent("codex/hooks.json")
        let binary = root.appendingPathComponent("bin/hitw-hook")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hook".utf8).write(to: binary)
        let store = try SQLiteStateStore(databaseURL: database)
        let engine = ChargeEngine(store: store)
        let installer = try HookConfigInstaller(hooksFile: hooks, hookBinary: binary)
        return (root, store, engine, installer, hooks)
    }

    static func seedDistinctEnabledState(_ store: SQLiteStateStore) throws {
        try store.mutate { state in
            state.enabled = true
            state.chargeRemaining = 17
            state.degradedReason = "prior reason"
            state.degradedWarningEmitted = true
            state.lastSyncError = "prior error"
            state.syncOperationID = UUID()
        }
    }

    static func failureAfterSoftOffRestoresExactLedgerAndHook() throws {
        let (root, store, engine, installer, hooks) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDistinctEnabledState(store)
        let priorState = try store.read()
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let priorHooks = Data("{\"hooks\":{},\"exact\":\"prior bytes\"}\n".utf8)
        try priorHooks.write(to: hooks)

        do {
            _ = try InstallationCoordinator(
                engine: engine,
                installer: installer,
                injectedFault: .afterSoftOff
            ).establishSoftOffAndHook()
            throw Failure(description: "injected failure unexpectedly succeeded")
        } catch let error as Failure { throw error } catch { }

        try expect(try store.read() == priorState, "ledger was not restored byte-semantically")
        try expect(try Data(contentsOf: hooks) == priorHooks, "hook changed before hook commit")
    }

    static func failureAfterHookCommitRestoresExactLedgerAndHookPresence() throws {
        for hadPriorHook in [false, true] {
            let (root, store, engine, installer, hooks) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try seedDistinctEnabledState(store)
            let priorState = try store.read()
            let priorHooks = Data("{\"hooks\":{},\"exact\":\"prior bytes\"}\n".utf8)
            if hadPriorHook {
                try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
                try priorHooks.write(to: hooks)
            }

            do {
                _ = try InstallationCoordinator(
                    engine: engine,
                    installer: installer,
                    injectedFault: .afterHookCommit
                ).establishSoftOffAndHook()
                throw Failure(description: "post-hook injected failure unexpectedly succeeded")
            } catch let error as Failure { throw error } catch { }

            try expect(try store.read() == priorState, "post-hook failure did not restore exact ledger")
            if hadPriorHook {
                try expect(try Data(contentsOf: hooks) == priorHooks, "prior hook bytes were not restored")
            } else {
                try expect(!FileManager.default.fileExists(atPath: hooks.path), "new hooks.json survived rollback")
            }
        }
    }

    static func concurrentEnableDuringHookCommitCannotReportSoftOffSuccess() throws {
        for hadPriorHook in [false, true] {
            let (root, store, engine, _, hooks) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try seedDistinctEnabledState(store)
            let priorHooks = Data("{\"hooks\":{},\"exact\":\"prior bytes\"}\n".utf8)
            if hadPriorHook {
                try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
                try priorHooks.write(to: hooks)
            }
            let binary = root.appendingPathComponent("bin/hitw-hook")
            let concurrentEngine = ChargeEngine(
                store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
            )
            let installer = try HookConfigInstaller(
                hooksFile: hooks,
                hookBinary: binary,
                testHooks: HookConfigInstallerTestHooks { point in
                    if point == .afterRenameBeforeDirectorySync {
                        try concurrentEngine.setEnabled(true)
                    }
                }
            )

            do {
                _ = try InstallationCoordinator(engine: engine, installer: installer)
                    .establishSoftOffAndHook()
                throw Failure(description: "coordinator reported Soft Off after a concurrent enable")
            } catch let error as Failure {
                throw error
            } catch {
                try expect(
                    !error.localizedDescription.localizedCaseInsensitiveContains("compensation"),
                    "clean concurrent-state handling was mislabeled as incomplete compensation"
                )
            }

            let concurrentState = try store.read()
            try expect(concurrentState.enabled, "coordinator overwrote the concurrent enable")
            try expect(
                concurrentState.degradedReason == SyncFailureReason.refreshRequired.userMessage,
                "concurrent enable state was not preserved exactly"
            )
            if hadPriorHook {
                try expect(try Data(contentsOf: hooks) == priorHooks, "prior hook bytes were not restored after concurrent enable")
            } else {
                try expect(!FileManager.default.fileExists(atPath: hooks.path), "new hook survived concurrent-enable rollback")
            }
        }
    }

    static func concurrentLedgerAndHookChangesReportIncompleteCompensation() throws {
        let (root, store, engine, _, hooks) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedDistinctEnabledState(store)
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let priorHooks = Data("{\"hooks\":{},\"exact\":\"prior bytes\"}\n".utf8)
        let externalHooks = Data("{\"hooks\":{},\"external\":true}\n".utf8)
        try priorHooks.write(to: hooks)
        let binary = root.appendingPathComponent("bin/hitw-hook")
        let concurrentEngine = ChargeEngine(
            store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite3"))
        )
        let installer = try HookConfigInstaller(
            hooksFile: hooks,
            hookBinary: binary,
            testHooks: HookConfigInstallerTestHooks { point in
                if point == .afterRenameBeforeDirectorySync {
                    try concurrentEngine.setEnabled(true)
                    try externalHooks.write(to: hooks, options: .atomic)
                }
            }
        )

        do {
            _ = try InstallationCoordinator(engine: engine, installer: installer)
                .establishSoftOffAndHook()
            throw Failure(description: "coordinator reported success after concurrent ledger and hook changes")
        } catch let error as Failure {
            throw error
        } catch let error as InstallationCoordinatorError {
            guard case .compensationFailed = error else {
                throw Failure(description: "coordinator did not report incomplete compensation: \(error)")
            }
        }

        try expect(try store.read().enabled, "coordinator overwrote concurrent ledger state")
        try expect(try Data(contentsOf: hooks) == externalHooks, "coordinator overwrote concurrent hook bytes")
    }

    static func hookEditBeforeFinalConfirmationCannotReportSuccess() throws {
        for changesLedger in [false, true] {
            let (root, store, engine, _, hooks) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try seedDistinctEnabledState(store)
            let priorState = try store.read()
            let concurrentEnableAt = Date(timeIntervalSince1970: 2_300_000_000)
            var expectedConcurrentState = priorState
            expectedConcurrentState.enabled = true
            expectedConcurrentState.syncOperationID = nil
            expectedConcurrentState.workoutRewards = WorkoutRewardEpoch(
                startedAt: concurrentEnableAt,
                cycleID: priorState.recovery?.cycleID
            )
            expectedConcurrentState.degradedReason = SyncFailureReason.refreshRequired.userMessage
            expectedConcurrentState.degradedWarningEmitted = false
            expectedConcurrentState.lastSyncError = SyncFailureReason.refreshRequired.rawValue
            try FileManager.default.createDirectory(
                at: hooks.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("{\"hooks\":{},\"exact\":\"prior bytes\"}\n".utf8).write(to: hooks)
            let externalHooks = Data("{\"hooks\":{},\"external\":\"after install\"}\n".utf8)
            let concurrentEngine = ChargeEngine(
                store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite3")),
                now: { concurrentEnableAt }
            )
            let installer = try HookConfigInstaller(
                hooksFile: hooks,
                hookBinary: root.appendingPathComponent("bin/hitw-hook")
            )
            let coordinator = InstallationCoordinator(
                engine: engine,
                installer: installer,
                injectedFault: nil,
                testHooks: InstallationCoordinatorTestHooks { point in
                    guard point == .beforeFinalHookConfirmation else { return }
                    if changesLedger { try concurrentEngine.setEnabled(true) }
                    try externalHooks.write(to: hooks, options: .atomic)
                }
            )

            do {
                _ = try coordinator.establishSoftOffAndHook()
                throw Failure(description: "coordinator reported success after the committed hook changed")
            } catch let error as Failure {
                throw error
            } catch let error as InstallationCoordinatorError {
                guard case .hookNotRetained = error else {
                    throw Failure(description: "hook conflict returned the wrong error: \(error)")
                }
            }

            try expect(try Data(contentsOf: hooks) == externalHooks, "coordinator overwrote the outsider hook")
            let finalState = try store.read()
            if changesLedger {
                try expect(finalState == expectedConcurrentState, "concurrent ledger was not preserved exactly")
            } else {
                try expect(finalState == priorState, "hook conflict did not restore the prior ledger")
            }
        }
    }
}

#if canImport(XCTest)
import XCTest

final class InstallationCoordinatorTests: XCTestCase {
    func testFailureAfterSoftOffRestoresExactLedgerAndHook() throws {
        try InstallationCoordinatorTestSupport.failureAfterSoftOffRestoresExactLedgerAndHook()
    }
    func testFailureAfterHookCommitRestoresExactLedgerAndHookPresence() throws {
        try InstallationCoordinatorTestSupport.failureAfterHookCommitRestoresExactLedgerAndHookPresence()
    }
    func testConcurrentEnableDuringHookCommitCannotReportSoftOffSuccess() throws {
        try InstallationCoordinatorTestSupport.concurrentEnableDuringHookCommitCannotReportSoftOffSuccess()
    }
    func testConcurrentLedgerAndHookChangesReportIncompleteCompensation() throws {
        try InstallationCoordinatorTestSupport.concurrentLedgerAndHookChangesReportIncompleteCompensation()
    }
    func testHookEditBeforeFinalConfirmationCannotReportSuccess() throws {
        try InstallationCoordinatorTestSupport.hookEditBeforeFinalConfirmationCannotReportSuccess()
    }
}
#else
import Testing

@Suite(.serialized) struct InstallationCoordinatorTests {
    @Test func failureAfterSoftOffRestoresExactLedgerAndHook() throws {
        try InstallationCoordinatorTestSupport.failureAfterSoftOffRestoresExactLedgerAndHook()
    }
    @Test func failureAfterHookCommitRestoresExactLedgerAndHookPresence() throws {
        try InstallationCoordinatorTestSupport.failureAfterHookCommitRestoresExactLedgerAndHookPresence()
    }
    @Test func concurrentEnableDuringHookCommitCannotReportSoftOffSuccess() throws {
        try InstallationCoordinatorTestSupport.concurrentEnableDuringHookCommitCannotReportSoftOffSuccess()
    }
    @Test func concurrentLedgerAndHookChangesReportIncompleteCompensation() throws {
        try InstallationCoordinatorTestSupport.concurrentLedgerAndHookChangesReportIncompleteCompensation()
    }
    @Test func hookEditBeforeFinalConfirmationCannotReportSuccess() throws {
        try InstallationCoordinatorTestSupport.hookEditBeforeFinalConfirmationCannotReportSuccess()
    }
}
#endif
