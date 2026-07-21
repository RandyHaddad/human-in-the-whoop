import Darwin
import Foundation
import HumanInTheWhoopCore

private enum HITWControlIntegrationTestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Fixture {
        let root: URL

        var database: URL { root.appendingPathComponent("state.sqlite3") }
        var hooksFile: URL { root.appendingPathComponent("codex/hooks.json") }
        var hookBinary: URL { root.appendingPathComponent("bin/hitw-hook") }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    struct Execution {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static let now = Date(timeIntervalSince1970: 2_000_000_000)

    static func makeFixture() -> Fixture {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let physicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        return Fixture(
            root: URL(fileURLWithPath: physicalTemporaryPath, isDirectory: true)
                .appendingPathComponent("hitwctl-test-\(UUID().uuidString)", isDirectory: true)
        )
    }

    static func makeIsolatedCoordinatorFixture() throws -> Fixture {
        let fixture = Fixture(
            root: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("hitwctl-coordinator-test-\(UUID().uuidString)", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        return fixture
    }

    static func defaultJSONStatusIsDeterministicAndSanitized() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }

        let result = try run(["status", "--json"], fixture: fixture)

        try expect(result.status == 0, "status failed: \(result.stderr)")
        try expect(result.stderr.isEmpty, "status wrote stderr")
        try expect(
            result.stdout == "{\"charge\":null,\"feature\":\"off\",\"last_successful_refresh\":null,\"recovery_cycle_id\":null,\"recovery_score\":null}\n",
            "unexpected JSON status: \(result.stdout)"
        )
        try expect(!result.stdout.contains("token"), "status exposed a token field")
        try expect(!result.stdout.contains("prompt"), "status exposed a prompt field")
        try expect(!result.stdout.contains("sleep"), "status exposed raw sleep data")
    }

    static func publicUsageListsOnlyApprovedCommands() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        for arguments in [[], ["unknown-command"]] {
            let result = try run(arguments, fixture: fixture)
            try expect(result.status == 2, "invalid invocation did not return usage status")
            try expect(!result.stderr.contains("install-soft-off-hook"), "public usage exposed installer-only command")
            try expect(result.stderr.contains("install-hook"), "public usage omitted approved hook command")
            try expect(result.stderr.contains("delete-local-data --yes"), "public usage omitted approved deletion command")
        }
    }

    static func readyJSONStatusIncludesOnlyApprovedFields() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReady(fixture, charge: 18)
        try store.mutate { $0.lastSyncSuccessAt = now }

        let result = try run(["status", "--json"], fixture: fixture)

        try expect(result.status == 0, "ready status failed: \(result.stderr)")
        let object = try decodeObject(result.stdout)
        try expect(Set(object.keys) == [
            "feature", "charge", "recovery_score", "recovery_cycle_id", "last_successful_refresh",
        ], "status exposed unexpected fields: \(object.keys)")
        try expect(object["feature"] as? String == "ready", "ready feature changed")
        try expect((object["charge"] as? NSNumber)?.intValue == 18, "Charge changed")
        try expect((object["recovery_score"] as? NSNumber)?.intValue == 72, "Recovery changed")
        try expect((object["recovery_cycle_id"] as? NSNumber)?.int64Value == 420, "cycle changed")
        try expect(object["last_successful_refresh"] as? String == "2033-05-18T03:33:20.000Z", "timestamp changed")
    }

    static func disableSoftPausesAndRetainsLedger() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReady(fixture, charge: 18)

        let result = try run(["disable"], fixture: fixture)

        try expect(result.status == 0, "disable failed: \(result.stderr)")
        let state = try store.read()
        try expect(!state.enabled, "disable did not turn feature Off")
        try expect(state.chargeRemaining == 18, "disable deleted paused Charge")
        try expect(state.recovery?.cycleID == 420, "disable deleted Recovery")
    }

    static func disabledRefreshFailsWithoutMutatingState() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try SQLiteStateStore(databaseURL: fixture.database)
        let before = try store.read()

        let result = try run(["refresh", "--json"], fixture: fixture)

        try expect(result.status != 0, "refresh while Off unexpectedly succeeded")
        try expect(result.stderr.contains("off"), "refresh did not explain Soft Off")
        try expect(try store.read() == before, "refresh while Off mutated state")
    }

    static func resetDemoRequiresLiteralYes() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReady(fixture, charge: 18)

        let rejected = try run(["reset-demo"], fixture: fixture)
        try expect(rejected.status == 2, "reset without --yes did not return usage failure")
        try expect(try store.read().chargeRemaining == 18, "rejected reset mutated Charge")

        let accepted = try run(["reset-demo", "--yes"], fixture: fixture)
        try expect(accepted.status == 0, "confirmed reset failed: \(accepted.stderr)")
        try expect(try store.read().chargeRemaining == 72, "confirmed reset did not restore Recovery")
    }

    static func installAndUninstallUseOnlyExplicitFixturePaths() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original: [String: Any] = [
            "future": true,
            "hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "/tmp/keep"]]]]],
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        try originalData.write(to: fixture.hooksFile)

        let installed = try run([
            "install-hook",
            "--hooks-file", fixture.hooksFile.path,
            "--hook-binary", fixture.hookBinary.path,
        ], fixture: fixture)
        try expect(installed.status == 0, "CLI install failed: \(installed.stderr)")
        var root = try decodeFile(fixture.hooksFile)
        try expect(root["future"] as? Bool == true, "CLI install changed unknown data")
        try expect(countOwnedHandlers(root, binary: fixture.hookBinary) == 1, "CLI install did not add exactly one handler")

        let uninstalled = try run([
            "uninstall-hook",
            "--hooks-file", fixture.hooksFile.path,
            "--hook-binary", fixture.hookBinary.path,
        ], fixture: fixture)
        try expect(uninstalled.status == 0, "CLI uninstall failed: \(uninstalled.stderr)")
        root = try decodeFile(fixture.hooksFile)
        try expect(root["future"] as? Bool == true, "CLI uninstall changed unknown data")
        try expect(countOwnedHandlers(root, binary: fixture.hookBinary) == 0, "CLI uninstall retained handler")
        guard let hooks = root["hooks"] as? [String: Any] else {
            throw Failure(description: "CLI uninstall removed hooks root")
        }
        try expect(hooks["PreToolUse"] != nil, "CLI uninstall removed PreToolUse")
        try expect(!FileManager.default.fileExists(atPath: fixture.database.path), "hook command touched state DB")
    }

    static func crossProcessHookWritersPreserveBothMutations() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let first = fixture.root.appendingPathComponent("first/hitw-hook")
        let second = fixture.root.appendingPathComponent("second/hitw-hook")
        for binary in [first, second] {
            try FileManager.default.createDirectory(
                at: binary.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("hook".utf8).write(to: binary)
        }

        let processes = try [first, second].map { binary -> Process in
            let process = Process()
            process.executableURL = controlBinary
            process.arguments = [
                "install-hook", "--hooks-file", fixture.hooksFile.path,
                "--hook-binary", binary.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["HITW_STATE_ROOT": fixture.root.path],
                uniquingKeysWith: { _, testValue in testValue }
            )
            try process.run()
            return process
        }
        for process in processes {
            process.waitUntilExit()
            try expect(process.terminationStatus == 0, "concurrent hook writer failed")
        }
        let root = try decodeFile(fixture.hooksFile)
        try expect(countOwnedHandlers(root, binary: first) == 1, "first concurrent semantic edit was lost")
        try expect(countOwnedHandlers(root, binary: second) == 1, "second concurrent semantic edit was lost")
    }

    static func deleteLocalDataRequiresYesAndLogicallyResetsEveryConnection() throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let store = try seedReady(fixture, charge: 18)
        _ = try store.read()
        let unrelated = fixture.root.appendingPathComponent("keep-me")
        try Data("keep".utf8).write(to: unrelated)

        let rejected = try run(["delete-local-data"], fixture: fixture)
        try expect(rejected.status == 2, "delete without --yes did not return usage failure")
        try expect(FileManager.default.fileExists(atPath: fixture.database.path), "rejected delete removed DB")

        let accepted = try run(["delete-local-data", "--yes"], fixture: fixture)
        try expect(accepted.status == 0, "confirmed delete failed: \(accepted.stderr)")
        try expect(try store.read() == PersistentState(), "existing connection retained deleted state")
        let reopened = try SQLiteStateStore(databaseURL: fixture.database)
        try expect(try reopened.read() == PersistentState(), "reopened connection retained deleted state")
        try expect(try reopened.readAuditEvents().isEmpty, "logical deletion retained audit events")
        try expect(FileManager.default.fileExists(atPath: fixture.database.path), "logical deletion unlinked live DB")
        try expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep", "delete removed unrelated data")
    }

    static func deleteLocalDataRejectsNonregularAndAncestorSymlinkPaths() throws {
        for kind in ["directory", "symlink", "fifo"] {
            let fixture = makeFixture()
            defer { fixture.cleanUp() }
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            let outside = fixture.root.appendingPathComponent("outside")
            switch kind {
            case "directory":
                try FileManager.default.createDirectory(at: fixture.database, withIntermediateDirectories: true)
                try Data("sentinel".utf8).write(to: fixture.database.appendingPathComponent("sentinel"))
            case "symlink":
                try Data("outside".utf8).write(to: outside)
                try FileManager.default.createSymbolicLink(at: fixture.database, withDestinationURL: outside)
            default:
                guard mkfifo(fixture.database.path, 0o600) == 0 else {
                    throw Failure(description: "could not create FIFO fixture")
                }
            }

            let result = try run(["delete-local-data", "--yes"], fixture: fixture)
            try expect(result.status != 0, "delete accepted \(kind) database path")
            if kind == "directory" {
                try expect(
                    try String(contentsOf: fixture.database.appendingPathComponent("sentinel"), encoding: .utf8) == "sentinel",
                    "delete recursively removed a directory database path"
                )
            } else if kind == "symlink" {
                try expect(try String(contentsOf: outside, encoding: .utf8) == "outside", "delete followed DB symlink")
            }
        }

        let outer = makeFixture()
        defer { outer.cleanUp() }
        let realRoot = outer.root.appendingPathComponent("real", isDirectory: true)
        let linkedRoot = outer.root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let result = try run(
            ["delete-local-data", "--yes"],
            fixture: Fixture(root: linkedRoot)
        )
        try expect(result.status != 0, "delete accepted an ancestor symlink")
        try expect(!FileManager.default.fileExists(atPath: realRoot.appendingPathComponent("state.sqlite3").path), "delete created data through ancestor symlink")
    }

    static func lexicalTraversalStateRootIsRejectedBeforeEveryMutation() throws {
        let container = makeFixture().root
        defer { try? FileManager.default.removeItem(at: container) }
        let safe = container.appendingPathComponent("safe", isDirectory: true)
        let target = container.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        let fixture = Fixture(root: target)
        let store = try seedReady(fixture, charge: 18)
        let before = try store.read()
        let traversal = "\(container.path)/safe/../target"

        let deleted = try run(
            ["delete-local-data", "--yes"],
            fixture: fixture,
            stateRootPath: traversal
        )
        try expect(deleted.status != 0, "delete accepted a lexical traversal root")
        try expect(try store.read() == before, "delete reset traversal target")

        let toggled = try run(
            ["_test-set-enabled-local", "--yes", "--value", "off"],
            fixture: fixture,
            stateRootPath: traversal,
            environmentOverrides: ["HITW_INSTALL_TEST_MODE": "1"]
        )
        try expect(toggled.status != 0, "test state seam accepted a lexical traversal root")
        try expect(try store.read() == before, "test state seam mutated traversal target")

        try FileManager.default.createDirectory(
            at: fixture.hookBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hook".utf8).write(to: fixture.hookBinary)
        let faulted = try run(
            [
                "install-soft-off-hook",
                "--hooks-file", fixture.hooksFile.path,
                "--hook-binary", fixture.hookBinary.path,
            ],
            fixture: fixture,
            stateRootPath: traversal,
            environmentOverrides: [
                "HITW_INSTALL_TEST_MODE": "1",
                "HITW_INSTALL_TEST_FAIL_AT": "after-disable",
            ]
        )
        try expect(faulted.status != 0, "install fault seam accepted a lexical traversal root")
        try expect(faulted.stderr.localizedCaseInsensitiveContains("unsafe"), "fault seam did not report unsafe root")
        try expect(try store.read() == before, "install fault seam mutated traversal target")
    }

    static func internalCoordinatorRequiresExplicitIsolatedPathsBeforeMutation() throws {
        let fixture = try makeIsolatedCoordinatorFixture()
        defer { fixture.cleanUp() }
        let store = try seedReady(fixture, charge: 18)
        let before = try store.read()
        try FileManager.default.createDirectory(
            at: fixture.hookBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hook".utf8).write(to: fixture.hookBinary)
        let seamEnvironment = [
            "HITW_INSTALL_TEST_MODE": "1",
            "HITW_INSTALL_TEST_FAIL_AT": "after-disable",
        ]

        for arguments in [
            ["install-soft-off-hook"],
            ["install-soft-off-hook", "--hooks-file", fixture.hooksFile.path],
            ["install-soft-off-hook", "--hook-binary", fixture.hookBinary.path],
        ] {
            let result = try run(
                arguments,
                fixture: fixture,
                environmentOverrides: seamEnvironment
            )
            try expect(result.status == 2, "internal coordinator accepted omitted explicit paths")
            try expect(result.stderr.contains("explicit"), "omitted internal path was not explained")
            try expect(try store.read() == before, "omitted internal path mutated the ledger")
            try expect(!FileManager.default.fileExists(atPath: fixture.hooksFile.path), "omitted internal path created hooks")
        }

        let outsideRoot = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("hitwctl-nonisolated-\(UUID().uuidString)", isDirectory: true)
        let unsafeCases: [(String, String)] = [
            ("--hooks-file", outsideRoot.appendingPathComponent("hooks.json").path),
            ("--hook-binary", outsideRoot.appendingPathComponent("hitw-hook").path),
            ("--hooks-file", "\(fixture.root.path)/safe/../codex/hooks.json"),
            ("--hook-binary", "\(fixture.root.path)//bin/hitw-hook"),
        ]
        for (option, value) in unsafeCases {
            let hooks = option == "--hooks-file" ? value : fixture.hooksFile.path
            let binary = option == "--hook-binary" ? value : fixture.hookBinary.path
            let result = try run(
                [
                    "install-soft-off-hook",
                    "--hooks-file", hooks,
                    "--hook-binary", binary,
                ],
                fixture: fixture,
                environmentOverrides: seamEnvironment
            )
            try expect(result.status != 0, "internal coordinator accepted unsafe \(option)")
            try expect(result.stderr.localizedCaseInsensitiveContains("unsafe"), "unsafe \(option) was not explained")
            try expect(try store.read() == before, "unsafe \(option) mutated the ledger")
            try expect(!FileManager.default.fileExists(atPath: outsideRoot.path), "unsafe test path created an outside artifact")
        }

        for unsafeStateRoot in [
            outsideRoot.appendingPathComponent("state").path,
            "/tmp/\(fixture.root.lastPathComponent)",
        ] {
            let result = try run(
                [
                    "install-soft-off-hook",
                    "--hooks-file", fixture.hooksFile.path,
                    "--hook-binary", fixture.hookBinary.path,
                ],
                fixture: fixture,
                stateRootPath: unsafeStateRoot,
                environmentOverrides: seamEnvironment
            )
            try expect(result.status != 0, "internal coordinator accepted unsafe state root")
            try expect(result.stderr.localizedCaseInsensitiveContains("unsafe"), "unsafe state root was not explained")
            try expect(try store.read() == before, "unsafe state root mutated the real ledger")
            try expect(!FileManager.default.fileExists(atPath: outsideRoot.path), "unsafe state root created an outside artifact")
        }
    }

    static func internalCoordinatorRejectsEmptyFaultSeamOutsideTestMode() throws {
        let fixture = try makeIsolatedCoordinatorFixture()
        defer { fixture.cleanUp() }
        let store = try seedReady(fixture, charge: 18)
        let before = try store.read()
        try FileManager.default.createDirectory(
            at: fixture.hookBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hook".utf8).write(to: fixture.hookBinary)

        let result = try run(
            [
                "install-soft-off-hook",
                "--hooks-file", fixture.hooksFile.path,
                "--hook-binary", fixture.hookBinary.path,
            ],
            fixture: fixture,
            environmentOverrides: [
                "HITW_INSTALL_TEST_MODE": "0",
                "HITW_INSTALL_TEST_FAIL_AT": "",
            ]
        )

        try expect(result.status != 0, "internal coordinator accepted an empty fault seam outside test mode")
        try expect(try store.read() == before, "empty fault seam mutated the ledger")
        try expect(!FileManager.default.fileExists(atPath: fixture.hooksFile.path), "empty fault seam created a hook")
    }

    static func internalCoordinatorRejectsSymlinkLeavesBeforeMutation() throws {
        for leaf in ["state", "hooks"] {
            let fixture = try makeIsolatedCoordinatorFixture()
            defer { fixture.cleanUp() }
            try FileManager.default.createDirectory(
                at: fixture.hookBinary.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: fixture.hooksFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("hook".utf8).write(to: fixture.hookBinary)
            let sentinel = fixture.root.appendingPathComponent("sentinel-\(leaf)")
            let sentinelData = Data("do-not-touch-\(leaf)".utf8)
            try sentinelData.write(to: sentinel)
            if leaf == "state" {
                try FileManager.default.createSymbolicLink(at: fixture.database, withDestinationURL: sentinel)
            } else {
                try FileManager.default.createSymbolicLink(at: fixture.hooksFile, withDestinationURL: sentinel)
            }

            let result = try run(
                [
                    "install-soft-off-hook",
                    "--hooks-file", fixture.hooksFile.path,
                    "--hook-binary", fixture.hookBinary.path,
                ],
                fixture: fixture,
                environmentOverrides: [
                    "HITW_INSTALL_TEST_MODE": "1",
                    "HITW_INSTALL_TEST_FAIL_AT": "after-disable",
                ]
            )
            try expect(result.status != 0, "internal coordinator accepted symlinked \(leaf) leaf")
            try expect(result.stderr.localizedCaseInsensitiveContains("unsafe"), "symlinked \(leaf) was not explained")
            try expect(try Data(contentsOf: sentinel) == sentinelData, "symlinked \(leaf) referent changed")
        }

        for boundary in ["hooks-parent", "hook-binary"] {
            let fixture = try makeIsolatedCoordinatorFixture()
            defer { fixture.cleanUp() }
            let store = try seedReady(fixture, charge: 18)
            let before = try store.read()
            let outside = fixture.root.appendingPathComponent("outside-\(boundary)", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            if boundary == "hooks-parent" {
                try FileManager.default.createDirectory(
                    at: fixture.hookBinary.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("hook".utf8).write(to: fixture.hookBinary)
                try FileManager.default.createSymbolicLink(
                    at: fixture.hooksFile.deletingLastPathComponent(),
                    withDestinationURL: outside
                )
            } else {
                try FileManager.default.createDirectory(
                    at: fixture.hooksFile.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: fixture.hookBinary.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let realBinary = outside.appendingPathComponent("hitw-hook")
                try Data("hook".utf8).write(to: realBinary)
                try FileManager.default.createSymbolicLink(at: fixture.hookBinary, withDestinationURL: realBinary)
            }

            let result = try run(
                [
                    "install-soft-off-hook",
                    "--hooks-file", fixture.hooksFile.path,
                    "--hook-binary", fixture.hookBinary.path,
                ],
                fixture: fixture,
                environmentOverrides: [
                    "HITW_INSTALL_TEST_MODE": "1",
                    "HITW_INSTALL_TEST_FAIL_AT": "after-disable",
                ]
            )
            try expect(result.status != 0, "internal coordinator accepted symlinked \(boundary)")
            try expect(result.stderr.localizedCaseInsensitiveContains("unsafe"), "symlinked \(boundary) was not explained")
            try expect(try store.read() == before, "symlinked \(boundary) mutated the ledger")
            try expect(
                !FileManager.default.fileExists(atPath: outside.appendingPathComponent("hooks.json").path),
                "symlinked \(boundary) created an outside hook artifact"
            )
        }
    }

    static func compensationFailureUsesExplicitSanitizedExit() throws {
        let fixture = try makeIsolatedCoordinatorFixture()
        defer { fixture.cleanUp() }
        _ = try seedReady(fixture, charge: 18)
        try FileManager.default.createDirectory(
            at: fixture.hookBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("hook".utf8).write(to: fixture.hookBinary)

        let result = try run(
            [
                "install-soft-off-hook",
                "--hooks-file", fixture.hooksFile.path,
                "--hook-binary", fixture.hookBinary.path,
            ],
            fixture: fixture,
            environmentOverrides: [
                "HITW_INSTALL_TEST_MODE": "1",
                "HITW_INSTALL_TEST_FAIL_AT": "compensation-conflict",
            ]
        )

        try expect(
            result.status == 3,
            "incomplete coordinator compensation did not use exit 3: status=\(result.status), stderr=\(result.stderr)"
        )
        try expect(
            result.stderr.contains("Installation compensation is incomplete"),
            "incomplete coordinator compensation was not stated explicitly"
        )
        try expect(
            result.stderr.contains("Do not assume Soft Off or hook restoration"),
            "incomplete coordinator compensation omitted safe guidance"
        )
        try expect(!result.stderr.contains(fixture.root.path), "compensation error exposed a local path")
    }

    static func localTestToggleRejectsSymlinkDatabaseBeforeMutation() throws {
        let safe = try makeIsolatedCoordinatorFixture()
        let outside = try makeIsolatedCoordinatorFixture()
        defer {
            safe.cleanUp()
            outside.cleanUp()
        }
        let outsideStore = try seedReady(outside, charge: 18)
        let before = try outsideStore.read()
        try FileManager.default.createSymbolicLink(
            at: safe.database,
            withDestinationURL: outside.database
        )

        let result = try run(
            ["_test-set-enabled-local", "--yes", "--value", "off"],
            fixture: safe,
            environmentOverrides: ["HITW_INSTALL_TEST_MODE": "1"]
        )

        try expect(result.status != 0, "local test toggle accepted a symlinked database")
        try expect(result.stderr.localizedCaseInsensitiveContains("unsafe"), "symlinked test database was not explained")
        try expect(try outsideStore.read() == before, "local test toggle mutated the database symlink referent")
    }

    private static func seedReady(_ fixture: Fixture, charge: Int) throws -> SQLiteStateStore {
        let store = try SQLiteStateStore(databaseURL: fixture.database)
        let engine = ChargeEngine(store: store, now: { now })
        try engine.setEnabled(true)
        try engine.applyRecovery(
            RecoverySnapshot(
                cycleID: 420,
                sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                recoveryScore: 72,
                createdAt: now.addingTimeInterval(-7_200),
                updatedAt: now.addingTimeInterval(-3_600),
                cycleStart: now.addingTimeInterval(-43_200),
                cycleEnd: nil,
                sleepPerformance: 82,
                cycleStrain: 8,
                recentWorkout: nil,
                secondaryDataComplete: true,
                validatedAt: now
            )
        )
        try store.mutate { $0.chargeRemaining = charge }
        return store
    }

    private static func run(
        _ arguments: [String],
        fixture: Fixture,
        stateRootPath: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) throws -> Execution {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = controlBinary
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        var baseEnvironment = ProcessInfo.processInfo.environment
        baseEnvironment.removeValue(forKey: "HITW_INSTALL_TEST_MODE")
        baseEnvironment.removeValue(forKey: "HITW_INSTALL_TEST_FAIL_AT")
        process.environment = baseEnvironment.merging(
            ["HITW_STATE_ROOT": stateRootPath ?? fixture.root.path].merging(
                environmentOverrides,
                uniquingKeysWith: { _, override in override }
            ),
            uniquingKeysWith: { _, testValue in testValue }
        )
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return Execution(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private static var controlBinary: URL {
        if let override = ProcessInfo.processInfo.environment["HITW_CONTROL_TEST_BINARY"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }

        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("hitwctl")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/hitwctl")
    }

    private static func decodeObject(_ string: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            throw Failure(description: "stdout was not a JSON object: \(string)")
        }
        return object
    }

    private static func decodeFile(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure(description: "file was not a JSON object")
        }
        return object
    }

    private static func countOwnedHandlers(_ root: [String: Any], binary: URL) -> Int {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["UserPromptSubmit"] as? [[String: Any]]
        else { return 0 }
        let expected = "\"\(binary.path)\""
        return groups
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { $0["type"] as? String == "command" && $0["command"] as? String == expected }
            .count
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }
}

#if canImport(XCTest)
import XCTest

final class HITWControlIntegrationTests: XCTestCase {
    func testPublicUsageListsOnlyApprovedCommands() throws {
        try HITWControlIntegrationTestSupport.publicUsageListsOnlyApprovedCommands()
    }
    func testDefaultJSONStatusIsDeterministicAndSanitized() throws {
        try HITWControlIntegrationTestSupport.defaultJSONStatusIsDeterministicAndSanitized()
    }
    func testReadyJSONStatusIncludesOnlyApprovedFields() throws {
        try HITWControlIntegrationTestSupport.readyJSONStatusIncludesOnlyApprovedFields()
    }
    func testDisableSoftPausesAndRetainsLedger() throws {
        try HITWControlIntegrationTestSupport.disableSoftPausesAndRetainsLedger()
    }
    func testDisabledRefreshFailsWithoutMutatingState() throws {
        try HITWControlIntegrationTestSupport.disabledRefreshFailsWithoutMutatingState()
    }
    func testResetDemoRequiresLiteralYes() throws {
        try HITWControlIntegrationTestSupport.resetDemoRequiresLiteralYes()
    }
    func testInstallAndUninstallUseOnlyExplicitFixturePaths() throws {
        try HITWControlIntegrationTestSupport.installAndUninstallUseOnlyExplicitFixturePaths()
    }
    func testCrossProcessHookWritersPreserveBothMutations() throws {
        try HITWControlIntegrationTestSupport.crossProcessHookWritersPreserveBothMutations()
    }
    func testDeleteLocalDataRequiresYesAndLogicallyResetsEveryConnection() throws {
        try HITWControlIntegrationTestSupport.deleteLocalDataRequiresYesAndLogicallyResetsEveryConnection()
    }
    func testDeleteLocalDataRejectsNonregularAndAncestorSymlinkPaths() throws {
        try HITWControlIntegrationTestSupport.deleteLocalDataRejectsNonregularAndAncestorSymlinkPaths()
    }
    func testLexicalTraversalStateRootIsRejectedBeforeEveryMutation() throws {
        try HITWControlIntegrationTestSupport.lexicalTraversalStateRootIsRejectedBeforeEveryMutation()
    }
    func testInternalCoordinatorRequiresExplicitIsolatedPathsBeforeMutation() throws {
        try HITWControlIntegrationTestSupport.internalCoordinatorRequiresExplicitIsolatedPathsBeforeMutation()
    }
    func testInternalCoordinatorRejectsEmptyFaultSeamOutsideTestMode() throws {
        try HITWControlIntegrationTestSupport.internalCoordinatorRejectsEmptyFaultSeamOutsideTestMode()
    }
    func testInternalCoordinatorRejectsSymlinkLeavesBeforeMutation() throws {
        try HITWControlIntegrationTestSupport.internalCoordinatorRejectsSymlinkLeavesBeforeMutation()
    }
    func testCompensationFailureUsesExplicitSanitizedExit() throws {
        try HITWControlIntegrationTestSupport.compensationFailureUsesExplicitSanitizedExit()
    }
    func testLocalTestToggleRejectsSymlinkDatabaseBeforeMutation() throws {
        try HITWControlIntegrationTestSupport.localTestToggleRejectsSymlinkDatabaseBeforeMutation()
    }
}
#else
import Testing

@Suite(.serialized) struct HITWControlIntegrationTests {
    @Test func publicUsageListsOnlyApprovedCommands() throws {
        try HITWControlIntegrationTestSupport.publicUsageListsOnlyApprovedCommands()
    }
    @Test func defaultJSONStatusIsDeterministicAndSanitized() throws {
        try HITWControlIntegrationTestSupport.defaultJSONStatusIsDeterministicAndSanitized()
    }
    @Test func readyJSONStatusIncludesOnlyApprovedFields() throws {
        try HITWControlIntegrationTestSupport.readyJSONStatusIncludesOnlyApprovedFields()
    }
    @Test func disableSoftPausesAndRetainsLedger() throws {
        try HITWControlIntegrationTestSupport.disableSoftPausesAndRetainsLedger()
    }
    @Test func disabledRefreshFailsWithoutMutatingState() throws {
        try HITWControlIntegrationTestSupport.disabledRefreshFailsWithoutMutatingState()
    }
    @Test func resetDemoRequiresLiteralYes() throws {
        try HITWControlIntegrationTestSupport.resetDemoRequiresLiteralYes()
    }
    @Test func installAndUninstallUseOnlyExplicitFixturePaths() throws {
        try HITWControlIntegrationTestSupport.installAndUninstallUseOnlyExplicitFixturePaths()
    }
    @Test func crossProcessHookWritersPreserveBothMutations() throws {
        try HITWControlIntegrationTestSupport.crossProcessHookWritersPreserveBothMutations()
    }
    @Test func deleteLocalDataRequiresYesAndLogicallyResetsEveryConnection() throws {
        try HITWControlIntegrationTestSupport.deleteLocalDataRequiresYesAndLogicallyResetsEveryConnection()
    }
    @Test func deleteLocalDataRejectsNonregularAndAncestorSymlinkPaths() throws {
        try HITWControlIntegrationTestSupport.deleteLocalDataRejectsNonregularAndAncestorSymlinkPaths()
    }
    @Test func lexicalTraversalStateRootIsRejectedBeforeEveryMutation() throws {
        try HITWControlIntegrationTestSupport.lexicalTraversalStateRootIsRejectedBeforeEveryMutation()
    }
    @Test func internalCoordinatorRequiresExplicitIsolatedPathsBeforeMutation() throws {
        try HITWControlIntegrationTestSupport.internalCoordinatorRequiresExplicitIsolatedPathsBeforeMutation()
    }
    @Test func internalCoordinatorRejectsEmptyFaultSeamOutsideTestMode() throws {
        try HITWControlIntegrationTestSupport.internalCoordinatorRejectsEmptyFaultSeamOutsideTestMode()
    }
    @Test func internalCoordinatorRejectsSymlinkLeavesBeforeMutation() throws {
        try HITWControlIntegrationTestSupport.internalCoordinatorRejectsSymlinkLeavesBeforeMutation()
    }
    @Test func compensationFailureUsesExplicitSanitizedExit() throws {
        try HITWControlIntegrationTestSupport.compensationFailureUsesExplicitSanitizedExit()
    }
    @Test func localTestToggleRejectsSymlinkDatabaseBeforeMutation() throws {
        try HITWControlIntegrationTestSupport.localTestToggleRejectsSymlinkDatabaseBeforeMutation()
    }
}
#endif
