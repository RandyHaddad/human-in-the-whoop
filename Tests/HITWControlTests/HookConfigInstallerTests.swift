import Darwin
import Foundation
@testable import HumanInTheWhoopControlSupport

private enum HookConfigInstallerTestSupport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Fixture {
        let directory: URL
        let hooksFile: URL
        let hookBinary: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static let expectedStatus = "Checking Human in the Whoop Charge"

    static func makeFixture() throws -> Fixture {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let physicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        let directory = URL(fileURLWithPath: physicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("hitw-hook-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateRoot = directory
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Human in the Whoop", isDirectory: true)
        let hookBinary = stateRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("hitw-hook")
        try FileManager.default.createDirectory(
            at: hookBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture hook".utf8).write(to: hookBinary)
        return Fixture(
            directory: directory,
            hooksFile: directory
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("hooks.json"),
            hookBinary: hookBinary
        )
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    static func readRoot(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "hooks root was not an object")
        }
        return root
    }

    static func promptGroups(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["UserPromptSubmit"] as? [[String: Any]]
        else {
            throw Failure(description: "UserPromptSubmit groups were missing")
        }
        return groups
    }

    static func handlers(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    static func installedHandlers(_ groups: [[String: Any]], binary: URL) -> [[String: Any]] {
        let command = "\"\(binary.path)\""
        return handlers(groups).filter { ($0["command"] as? String) == command }
    }

    static func installCreatesDirectPromptHook() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let result = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary
        ).install()

        try expect(result.changed, "new install did not report a change")
        try expect(result.backup == nil, "new install unexpectedly created a backup")
        let groups = try promptGroups(readRoot(fixture.hooksFile))
        try expect(groups.count == 1, "new install did not create exactly one matcher group")
        try expect(groups[0]["matcher"] == nil, "installed group unexpectedly had a matcher")
        let installed = installedHandlers(groups, binary: fixture.hookBinary)
        try expect(installed.count == 1, "installed handler was missing or duplicated")
        try expect(installed[0]["type"] as? String == "command", "handler type changed")
        try expect((installed[0]["timeout"] as? NSNumber)?.intValue == 2, "timeout changed")
        try expect(installed[0]["statusMessage"] as? String == expectedStatus, "status changed")
    }

    static func installPreservesExistingEventsHooksAndUnknownFields() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let existingPreTool: [String: Any] = [
            "matcher": "Shell",
            "hooks": [["type": "command", "command": "/tmp/pre-tool", "timeout": 9]],
            "futureGroupField": ["kept": true],
        ]
        let existingPrompt: [String: Any] = [
            "matcher": "important",
            "hooks": [[
                "type": "command",
                "command": "/tmp/existing-prompt",
                "statusMessage": "Existing",
                "futureHandlerField": 42,
            ]],
        ]
        try writeJSON([
            "schemaVersion": 7,
            "futureTopLevel": ["alpha", "beta"],
            "hooks": [
                "PreToolUse": [existingPreTool],
                "UserPromptSubmit": [existingPrompt],
            ],
        ], to: fixture.hooksFile)

        _ = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary
        ).install()

        let root = try readRoot(fixture.hooksFile)
        try expect((root["schemaVersion"] as? NSNumber)?.intValue == 7, "top-level number changed")
        try expect(root["futureTopLevel"] as? [String] == ["alpha", "beta"], "unknown top-level field changed")
        guard let hooks = root["hooks"] as? [String: Any],
              let preTool = hooks["PreToolUse"] as? [[String: Any]],
              let prompt = hooks["UserPromptSubmit"] as? [[String: Any]]
        else { throw Failure(description: "preserved hook events became malformed") }
        try expect(NSDictionary(dictionary: preTool[0]).isEqual(to: existingPreTool), "PreToolUse changed")
        try expect(NSDictionary(dictionary: prompt[0]).isEqual(to: existingPrompt), "existing prompt hook changed")
        try expect(installedHandlers(prompt, binary: fixture.hookBinary).count == 1, "our handler count changed")
    }

    static func repeatedInstallIsIdempotentAndDoesNotCreateAnotherBackup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try writeJSON(["hooks": ["PreToolUse": []], "unknown": true], to: fixture.hooksFile)
        let installer = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary
        )

        let first = try installer.install()
        let firstData = try Data(contentsOf: fixture.hooksFile)
        let backupsAfterFirst = try backupFiles(for: fixture.hooksFile)
        let second = try installer.install()
        let secondData = try Data(contentsOf: fixture.hooksFile)
        let backupsAfterSecond = try backupFiles(for: fixture.hooksFile)

        try expect(first.changed, "first install did not change the fixture")
        try expect(first.backup != nil, "first install did not back up existing JSON")
        try expect(!second.changed, "second install was not idempotent")
        try expect(second.backup == nil, "idempotent install created a backup")
        try expect(firstData == secondData, "idempotent install rewrote JSON")
        try expect(backupsAfterFirst == backupsAfterSecond, "idempotent install created another backup")
    }

    static func committedConfirmationIsReadOnlyForChangedAndNoopInstalls() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try writeJSON(["hooks": [:], "generation": 1], to: fixture.hooksFile)
        let installer = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary
        )

        let changed = try installer.install()
        let committedData = try Data(contentsOf: fixture.hooksFile)
        try expect(try installer.confirmCommitted(changed), "changed install could not be confirmed")
        try expect(try Data(contentsOf: fixture.hooksFile) == committedData, "confirmation rewrote committed hooks")

        let noop = try installer.install()
        try expect(!noop.changed, "confirmation fixture did not produce an idempotent install")
        try expect(try installer.confirmCommitted(noop), "no-op install did not retain a confirmation token")

        let outsiderData = Data("{\"hooks\":{},\"generation\":2}\n".utf8)
        try outsiderData.write(to: fixture.hooksFile, options: .atomic)
        try expect(!installer.confirmCommitted(noop), "confirmation accepted outsider hook bytes")
        try expect(try Data(contentsOf: fixture.hooksFile) == outsiderData, "confirmation overwrote outsider hook bytes")
    }

    static func uninstallRemovesOnlyOurHandlerAndPrunesOnlyEmptyContainers() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let nearMatch = "\"\(fixture.hookBinary.path)\" --unexpected-argument"
        let unrelated = ["type": "command", "command": "/tmp/unrelated"]
        try writeJSON([
            "unknown": "keep",
            "hooks": [
                "PreToolUse": [["hooks": [unrelated]]],
                "UserPromptSubmit": [
                    ["matcher": "other", "hooks": [unrelated]],
                    ["hooks": [[
                        "type": "command",
                        "command": "\"\(fixture.hookBinary.path)\"",
                        "timeout": 2,
                        "statusMessage": expectedStatus,
                    ], [
                        "type": "command",
                        "command": nearMatch,
                    ]]],
                ],
            ],
        ], to: fixture.hooksFile)

        let result = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary
        ).uninstall()

        try expect(result.changed, "uninstall did not report a change")
        try expect(result.backup != nil, "uninstall did not back up existing JSON")
        let root = try readRoot(fixture.hooksFile)
        try expect(root["unknown"] as? String == "keep", "uninstall changed top-level data")
        guard let hooks = root["hooks"] as? [String: Any],
              let preTool = hooks["PreToolUse"] as? [[String: Any]],
              let prompt = hooks["UserPromptSubmit"] as? [[String: Any]]
        else { throw Failure(description: "uninstall removed unrelated events") }
        try expect(preTool.count == 1, "uninstall changed PreToolUse")
        try expect(prompt.count == 2, "uninstall pruned a nonempty matcher group")
        try expect(installedHandlers(prompt, binary: fixture.hookBinary).isEmpty, "our handler survived uninstall")
        try expect(handlers(prompt).contains { $0["command"] as? String == nearMatch }, "near match was removed")
    }

    static func malformedExistingJSONAbortsWithoutOverwritingOrBackup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let malformed = Data("{ not-json".utf8)
        try malformed.write(to: fixture.hooksFile)

        do {
            _ = try HookConfigInstaller(
                hooksFile: fixture.hooksFile,
                hookBinary: fixture.hookBinary
            ).install()
            throw Failure(description: "malformed JSON unexpectedly installed")
        } catch is Failure {
            throw Failure(description: "malformed JSON unexpectedly installed")
        } catch {
            // Expected.
        }

        try expect(try Data(contentsOf: fixture.hooksFile) == malformed, "malformed file was overwritten")
        try expect(try backupFiles(for: fixture.hooksFile).isEmpty, "malformed file was backed up")
    }

    static func installWritesExactBackupBeforeReplacingExistingFile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let original = Data("{\"hooks\":{},\"preserve\":\"exact bytes\"}\n".utf8)
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: fixture.hooksFile)

        let result = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary
        ).install()

        guard let backup = result.backup else {
            throw Failure(description: "existing file was not backed up")
        }
        try expect(try Data(contentsOf: backup) == original, "backup was not byte-exact")
        try expect(try Data(contentsOf: fixture.hooksFile) != original, "target was not replaced")
    }

    static func rejectsSymlinkTargetWithoutTouchingReferent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let referent = fixture.directory.appendingPathComponent("referent.json")
        let original = Data("{\"hooks\":{},\"safe\":true}".utf8)
        try original.write(to: referent)
        try FileManager.default.createDirectory(
            at: fixture.hooksFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.hooksFile,
            withDestinationURL: referent
        )

        do {
            _ = try HookConfigInstaller(
                hooksFile: fixture.hooksFile,
                hookBinary: fixture.hookBinary
            ).install()
            throw Failure(description: "symlink target unexpectedly installed")
        } catch is Failure {
            throw Failure(description: "symlink target unexpectedly installed")
        } catch {
            // Expected.
        }

        try expect(try Data(contentsOf: referent) == original, "symlink referent was modified")
        try expect(try backupFiles(for: fixture.hooksFile).isEmpty, "symlink target was backed up")
    }

    static func uninstallWithoutOwnedHandlerIsAnExactNoop() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let original: [String: Any] = [
            "future": "keep",
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": []],
                    ["matcher": "other", "hooks": [[
                        "type": "command",
                        "command": "/tmp/unrelated",
                    ]]],
                ],
            ],
        ]
        try writeJSON(original, to: fixture.hooksFile)
        let before = try Data(contentsOf: fixture.hooksFile)

        let result = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary
        ).uninstall()

        try expect(!result.changed, "uninstall changed a config without our handler")
        try expect(result.backup == nil, "no-op uninstall created a backup")
        try expect(try Data(contentsOf: fixture.hooksFile) == before, "no-op uninstall rewrote JSON")
    }

    static func ownedHandlerIdentityDependsOnlyOnNormalizedCommandPath() throws {
        let variants: [[String: Any]] = [
            ["command": "\"PLACEHOLDER\""],
            ["type": "wrong", "command": "PLACEHOLDER"],
            ["type": NSNull(), "command": "  'PLACEHOLDER'  "],
        ]

        for variant in variants {
            let fixture = try makeFixture()
            defer { fixture.cleanUp() }
            var owned = variant
            owned["command"] = (owned["command"] as! String)
                .replacingOccurrences(of: "PLACEHOLDER", with: fixture.hookBinary.path)
            try writeJSON([
                "hooks": ["UserPromptSubmit": [["hooks": [
                    owned,
                    ["type": "command", "command": "\"\(fixture.hookBinary.path)\" --near"],
                ]]]],
            ], to: fixture.hooksFile)

            let installer = try HookConfigInstaller(
                hooksFile: fixture.hooksFile,
                hookBinary: fixture.hookBinary
            )
            _ = try installer.install()
            var groups = try promptGroups(readRoot(fixture.hooksFile))
            let exact = handlers(groups).filter {
                ($0["command"] as? String) == "\"\(fixture.hookBinary.path)\""
            }
            try expect(exact.count == 1, "install did not canonicalize owned variant")
            try expect(exact[0]["type"] as? String == "command", "install did not repair type")

            _ = try installer.uninstall()
            groups = try promptGroupsOrEmpty(readRoot(fixture.hooksFile))
            try expect(
                handlers(groups).contains { ($0["command"] as? String)?.hasSuffix(" --near") == true },
                "uninstall removed a near match"
            )
            try expect(
                !handlers(groups).contains { ($0["command"] as? String) == "\"\(fixture.hookBinary.path)\"" },
                "uninstall retained an exact owned command"
            )
        }
    }

    static func promptGroupsOrEmpty(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        guard let value = hooks["UserPromptSubmit"] else { return [] }
        guard let groups = value as? [[String: Any]] else {
            throw Failure(description: "UserPromptSubmit became malformed")
        }
        return groups
    }

    static func concurrentExternalMutationFailsCompareAndSwap() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try writeJSON(["hooks": [:], "generation": 1], to: fixture.hooksFile)
        let external = try JSONSerialization.data(
            withJSONObject: ["hooks": [:], "generation": 2],
            options: [.sortedKeys]
        )
        let hooks = HookConfigInstallerTestHooks { point in
            if point == .beforeCompareAndSwap {
                try external.write(to: fixture.hooksFile, options: .atomic)
            }
        }
        let installer = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary,
            testHooks: hooks
        )

        do {
            _ = try installer.install()
            throw Failure(description: "compare-and-swap accepted concurrent mutation")
        } catch is Failure {
            throw Failure(description: "compare-and-swap accepted concurrent mutation")
        } catch {
            // Expected.
        }
        let root = try readRoot(fixture.hooksFile)
        try expect((root["generation"] as? NSNumber)?.intValue == 2, "external mutation was overwritten")
    }

    static func mutationInFinalPreRenameWindowFailsCompareAndSwap() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try writeJSON(["hooks": [:], "generation": 1], to: fixture.hooksFile)
        let external = try JSONSerialization.data(
            withJSONObject: ["hooks": [:], "generation": 2],
            options: [.sortedKeys]
        )
        let installer = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary,
            testHooks: HookConfigInstallerTestHooks { point in
                if point == .beforeRename {
                    try external.write(to: fixture.hooksFile, options: .atomic)
                }
            }
        )

        do {
            _ = try installer.install()
            throw Failure(description: "final pre-rename mutation was overwritten")
        } catch is Failure {
            throw Failure(description: "final pre-rename mutation was overwritten")
        } catch {
            // Expected.
        }
        let root = try readRoot(fixture.hooksFile)
        try expect((root["generation"] as? NSNumber)?.intValue == 2, "final external mutation was not preserved")
    }

    static func preRenameFailureIsUncommittedButPostRenameFailureReportsCommitted() throws {
        let pre = try makeFixture()
        defer { pre.cleanUp() }
        try writeJSON(["hooks": [:], "generation": 1], to: pre.hooksFile)
        let before = try Data(contentsOf: pre.hooksFile)
        let preInstaller = try HookConfigInstaller(
            hooksFile: pre.hooksFile,
            hookBinary: pre.hookBinary,
            testHooks: HookConfigInstallerTestHooks { point in
                if point == .beforeRename { throw Failure(description: "injected pre-rename") }
            }
        )
        do {
            _ = try preInstaller.install()
            throw Failure(description: "pre-rename failure unexpectedly succeeded")
        } catch let error as Failure where error.description == "pre-rename failure unexpectedly succeeded" {
            throw error
        } catch {
            // Expected.
        }
        try expect(try Data(contentsOf: pre.hooksFile) == before, "pre-rename failure changed target")

        let post = try makeFixture()
        defer { post.cleanUp() }
        try writeJSON(["hooks": [:], "generation": 1], to: post.hooksFile)
        let postInstaller = try HookConfigInstaller(
            hooksFile: post.hooksFile,
            hookBinary: post.hookBinary,
            testHooks: HookConfigInstallerTestHooks { point in
                if point == .afterRenameBeforeDirectorySync {
                    throw Failure(description: "injected post-rename sync failure")
                }
            }
        )
        let result = try postInstaller.install()
        try expect(result.changed, "post-rename result did not report committed change")
        try expect(!result.durabilityConfirmed, "post-rename sync failure claimed durable success")
        try expect(
            installedHandlers(try promptGroups(readRoot(post.hooksFile)), binary: post.hookBinary).count == 1,
            "post-rename committed target is missing"
        )
    }

    static func nestedAncestorSymlinkAndSwapAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let outside = fixture.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedParent = fixture.directory.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        let linkedHooks = linkedParent.appendingPathComponent("nested/hooks.json")
        do {
            _ = try HookConfigInstaller(hooksFile: linkedHooks, hookBinary: fixture.hookBinary).install()
            throw Failure(description: "nested ancestor symlink was accepted")
        } catch is Failure {
            throw Failure(description: "nested ancestor symlink was accepted")
        } catch {
            // Expected.
        }
        try expect(
            !FileManager.default.fileExists(atPath: outside.appendingPathComponent("nested/hooks.json").path),
            "installer wrote through nested symlink"
        )

        try writeJSON(["hooks": [:], "generation": 1], to: fixture.hooksFile)
        let originalParent = fixture.hooksFile.deletingLastPathComponent()
        let movedParent = fixture.directory.appendingPathComponent("original-codex")
        let swapOutside = fixture.directory.appendingPathComponent("swap-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: swapOutside, withIntermediateDirectories: true)
        let installer = try HookConfigInstaller(
            hooksFile: fixture.hooksFile,
            hookBinary: fixture.hookBinary,
            testHooks: HookConfigInstallerTestHooks { point in
                guard point == .beforeCompareAndSwap else { return }
                try FileManager.default.moveItem(at: originalParent, to: movedParent)
                try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: swapOutside)
            }
        )
        do {
            _ = try installer.install()
            throw Failure(description: "ancestor swap unexpectedly committed")
        } catch is Failure {
            throw Failure(description: "ancestor swap unexpectedly committed")
        } catch {
            // Expected.
        }
        try expect(
            !FileManager.default.fileExists(atPath: swapOutside.appendingPathComponent("hooks.json").path),
            "installer wrote out of scope after ancestor swap"
        )
    }

    static func lockSymlinkAndNonregularFilesAreRejected() throws {
        for kind in ["symlink", "fifo", "directory"] {
            let fixture = try makeFixture()
            defer { fixture.cleanUp() }
            let parent = fixture.hooksFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let lock = parent.appendingPathComponent(".hooks.json.human-in-the-whoop.lock")
            switch kind {
            case "symlink":
                let outside = fixture.directory.appendingPathComponent("outside-lock")
                try Data("outside".utf8).write(to: outside)
                try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
            case "fifo":
                guard mkfifo(lock.path, 0o600) == 0 else {
                    throw Failure(description: "could not create lock FIFO")
                }
            default:
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            }
            do {
                _ = try HookConfigInstaller(
                    hooksFile: fixture.hooksFile,
                    hookBinary: fixture.hookBinary
                ).install()
                throw Failure(description: "installer accepted \(kind) lock")
            } catch is Failure {
                throw Failure(description: "installer accepted \(kind) lock")
            } catch {
                // Expected.
            }
            try expect(!FileManager.default.fileExists(atPath: fixture.hooksFile.path), "unsafe lock allowed target write")
        }
    }

    static func backupFiles(for hooksFile: URL) throws -> [String] {
        let parent = hooksFile.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix("\(hooksFile.lastPathComponent).backup.") }
            .sorted()
    }
}

#if canImport(XCTest)
import XCTest

final class HookConfigInstallerTests: XCTestCase {
    func testInstallCreatesUserPromptSubmitHookWithoutMatcher() throws {
        try HookConfigInstallerTestSupport.installCreatesDirectPromptHook()
    }

    func testInstallPreservesExistingPreToolAndUserPromptHooks() throws {
        try HookConfigInstallerTestSupport.installPreservesExistingEventsHooksAndUnknownFields()
    }

    func testRepeatedInstallIsIdempotent() throws {
        try HookConfigInstallerTestSupport.repeatedInstallIsIdempotentAndDoesNotCreateAnotherBackup()
    }
    func testCommittedConfirmationIsReadOnlyForChangedAndNoopInstalls() throws {
        try HookConfigInstallerTestSupport.committedConfirmationIsReadOnlyForChangedAndNoopInstalls()
    }

    func testUninstallRemovesOnlyHumanInTheWhoopHandler() throws {
        try HookConfigInstallerTestSupport.uninstallRemovesOnlyOurHandlerAndPrunesOnlyEmptyContainers()
    }

    func testMalformedExistingJSONAbortsWithoutOverwriting() throws {
        try HookConfigInstallerTestSupport.malformedExistingJSONAbortsWithoutOverwritingOrBackup()
    }

    func testInstallWritesBackupBeforeReplacingExistingFile() throws {
        try HookConfigInstallerTestSupport.installWritesExactBackupBeforeReplacingExistingFile()
    }

    func testSymlinkTargetIsRejectedWithoutTouchingReferent() throws {
        try HookConfigInstallerTestSupport.rejectsSymlinkTargetWithoutTouchingReferent()
    }

    func testUninstallWithoutOwnedHandlerIsAnExactNoop() throws {
        try HookConfigInstallerTestSupport.uninstallWithoutOwnedHandlerIsAnExactNoop()
    }
    func testOwnedHandlerIdentityDependsOnlyOnNormalizedCommandPath() throws {
        try HookConfigInstallerTestSupport.ownedHandlerIdentityDependsOnlyOnNormalizedCommandPath()
    }
    func testConcurrentExternalMutationFailsCompareAndSwap() throws {
        try HookConfigInstallerTestSupport.concurrentExternalMutationFailsCompareAndSwap()
    }
    func testMutationInFinalPreRenameWindowFailsCompareAndSwap() throws {
        try HookConfigInstallerTestSupport.mutationInFinalPreRenameWindowFailsCompareAndSwap()
    }
    func testPreAndPostRenameFailureSemantics() throws {
        try HookConfigInstallerTestSupport.preRenameFailureIsUncommittedButPostRenameFailureReportsCommitted()
    }
    func testNestedAncestorSymlinkAndSwapAreRejected() throws {
        try HookConfigInstallerTestSupport.nestedAncestorSymlinkAndSwapAreRejected()
    }
    func testLockSymlinkAndNonregularFilesAreRejected() throws {
        try HookConfigInstallerTestSupport.lockSymlinkAndNonregularFilesAreRejected()
    }
}
#else
import Testing

@Suite struct HookConfigInstallerTests {
    @Test func installCreatesUserPromptSubmitHookWithoutMatcher() throws {
        try HookConfigInstallerTestSupport.installCreatesDirectPromptHook()
    }

    @Test func installPreservesExistingPreToolAndUserPromptHooks() throws {
        try HookConfigInstallerTestSupport.installPreservesExistingEventsHooksAndUnknownFields()
    }

    @Test func repeatedInstallIsIdempotent() throws {
        try HookConfigInstallerTestSupport.repeatedInstallIsIdempotentAndDoesNotCreateAnotherBackup()
    }
    @Test func committedConfirmationIsReadOnlyForChangedAndNoopInstalls() throws {
        try HookConfigInstallerTestSupport.committedConfirmationIsReadOnlyForChangedAndNoopInstalls()
    }

    @Test func uninstallRemovesOnlyHumanInTheWhoopHandler() throws {
        try HookConfigInstallerTestSupport.uninstallRemovesOnlyOurHandlerAndPrunesOnlyEmptyContainers()
    }

    @Test func malformedExistingJSONAbortsWithoutOverwriting() throws {
        try HookConfigInstallerTestSupport.malformedExistingJSONAbortsWithoutOverwritingOrBackup()
    }

    @Test func installWritesBackupBeforeReplacingExistingFile() throws {
        try HookConfigInstallerTestSupport.installWritesExactBackupBeforeReplacingExistingFile()
    }

    @Test func symlinkTargetIsRejectedWithoutTouchingReferent() throws {
        try HookConfigInstallerTestSupport.rejectsSymlinkTargetWithoutTouchingReferent()
    }

    @Test func uninstallWithoutOwnedHandlerIsAnExactNoop() throws {
        try HookConfigInstallerTestSupport.uninstallWithoutOwnedHandlerIsAnExactNoop()
    }
    @Test func ownedHandlerIdentityDependsOnlyOnNormalizedCommandPath() throws {
        try HookConfigInstallerTestSupport.ownedHandlerIdentityDependsOnlyOnNormalizedCommandPath()
    }
    @Test func concurrentExternalMutationFailsCompareAndSwap() throws {
        try HookConfigInstallerTestSupport.concurrentExternalMutationFailsCompareAndSwap()
    }
    @Test func mutationInFinalPreRenameWindowFailsCompareAndSwap() throws {
        try HookConfigInstallerTestSupport.mutationInFinalPreRenameWindowFailsCompareAndSwap()
    }
    @Test func preAndPostRenameFailureSemantics() throws {
        try HookConfigInstallerTestSupport.preRenameFailureIsUncommittedButPostRenameFailureReportsCommitted()
    }
    @Test func nestedAncestorSymlinkAndSwapAreRejected() throws {
        try HookConfigInstallerTestSupport.nestedAncestorSymlinkAndSwapAreRejected()
    }
    @Test func lockSymlinkAndNonregularFilesAreRejected() throws {
        try HookConfigInstallerTestSupport.lockSymlinkAndNonregularFilesAreRejected()
    }
}
#endif
