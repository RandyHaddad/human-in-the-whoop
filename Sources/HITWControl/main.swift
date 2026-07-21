import Darwin
import Foundation
import HumanInTheWhoopControlSupport
import HumanInTheWhoopCore
import HumanInTheWhoopWHOOP

private enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    case compensationIncomplete = 3
}

private enum ControlError: LocalizedError {
    case usage(String)
    case featureOff
    case unsafeStatePath
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        case .featureOff: "Human in the Whoop is off. Enable it before refreshing WHOOP."
        case .unsafeStatePath: "Refusing unsafe local-state path."
        case .operationFailed(let message): message
        }
    }
}

private struct StatusOutput: Encodable {
    let feature: String
    let charge: Int?
    let recoveryScore: Int?
    let recoveryCycleID: Int64?
    let lastSuccessfulRefresh: String?

    enum CodingKeys: String, CodingKey {
        case feature
        case charge
        case recoveryScore = "recovery_score"
        case recoveryCycleID = "recovery_cycle_id"
        case lastSuccessfulRefresh = "last_successful_refresh"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(feature, forKey: .feature)
        if let charge {
            try container.encode(charge, forKey: .charge)
        } else {
            try container.encodeNil(forKey: .charge)
        }
        if let recoveryScore {
            try container.encode(recoveryScore, forKey: .recoveryScore)
        } else {
            try container.encodeNil(forKey: .recoveryScore)
        }
        if let recoveryCycleID {
            try container.encode(recoveryCycleID, forKey: .recoveryCycleID)
        } else {
            try container.encodeNil(forKey: .recoveryCycleID)
        }
        if let lastSuccessfulRefresh {
            try container.encode(lastSuccessfulRefresh, forKey: .lastSuccessfulRefresh)
        } else {
            try container.encodeNil(forKey: .lastSuccessfulRefresh)
        }
    }
}

private enum PresentationState {
    case off
    case ready(recovery: RecoverySnapshot, charge: Int)
    case unavailable
}

private struct HookArguments {
    let hooksFile: URL
    let hookBinary: URL
    let rawHooksFile: String
    let rawHookBinary: String
}

private let usage = """
Usage:
  hitwctl status [--json]
  hitwctl enable
  hitwctl disable
  hitwctl refresh [--json]
  hitwctl reset-demo --yes
  hitwctl install-hook [--hooks-file PATH] [--hook-binary PATH]
  hitwctl uninstall-hook [--hooks-file PATH] [--hook-binary PATH]
  hitwctl delete-local-data --yes
"""

private func writeStandardOutput(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

private func writeStandardError(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
}

private func validatedPresentation(_ state: PersistentState) -> PresentationState {
    guard state.enabled else { return .off }
    guard state.degradedReason == nil,
          let recovery = state.recovery,
          let charge = state.chargeRemaining,
          (0...100).contains(recovery.recoveryScore),
          (0...100).contains(charge),
          recovery.cycleID > 0,
          recovery.sleepID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
          recovery.cycleEnd == nil,
          recovery.createdAt.timeIntervalSinceReferenceDate.isFinite,
          recovery.updatedAt.timeIntervalSinceReferenceDate.isFinite,
          recovery.cycleStart.timeIntervalSinceReferenceDate.isFinite,
          recovery.validatedAt.timeIntervalSinceReferenceDate.isFinite
    else { return .unavailable }
    return .ready(recovery: recovery, charge: charge)
}

private func statusOutput(for state: PersistentState) -> StatusOutput {
    let lastRefresh = state.lastSyncSuccessAt.flatMap(formatDate)
    switch validatedPresentation(state) {
    case .off:
        return StatusOutput(
            feature: "off",
            charge: nil,
            recoveryScore: nil,
            recoveryCycleID: nil,
            lastSuccessfulRefresh: lastRefresh
        )
    case .unavailable:
        return StatusOutput(
            feature: "unavailable",
            charge: nil,
            recoveryScore: nil,
            recoveryCycleID: nil,
            lastSuccessfulRefresh: lastRefresh
        )
    case .ready(let recovery, let charge):
        return StatusOutput(
            feature: "ready",
            charge: charge,
            recoveryScore: recovery.recoveryScore,
            recoveryCycleID: recovery.cycleID,
            lastSuccessfulRefresh: lastRefresh
        )
    }
}

private func formatDate(_ date: Date) -> String? {
    guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func printStatus(_ state: PersistentState, json: Bool) throws {
    let output = statusOutput(for: state)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ControlError.operationFailed("Could not encode status.")
        }
        writeStandardOutput(string)
        return
    }

    switch output.feature {
    case "off":
        writeStandardOutput("Feature: Off")
        writeStandardOutput("Charge: Paused")
        writeStandardOutput("WHOOP Recovery: Paused")
    case "ready":
        writeStandardOutput("Feature: Ready")
        writeStandardOutput("Charge: \(output.charge ?? 0)/100")
        writeStandardOutput(
            "WHOOP Recovery: \(output.recoveryScore ?? 0)/100 (cycle \(output.recoveryCycleID ?? 0))"
        )
    default:
        writeStandardOutput("Feature: Unavailable")
        writeStandardOutput("Charge: Unavailable")
        writeStandardOutput("WHOOP Recovery: Unavailable")
    }
    writeStandardOutput("Last successful refresh: \(output.lastSuccessfulRefresh ?? "Never")")
}

private func makeEngine() throws -> ChargeEngine {
    try makeEngine(stateRoot: validatedStateRoot())
}

private func makeEngine(stateRoot: URL) throws -> ChargeEngine {
    let paths = AppPaths(rootOverride: stateRoot)
    let store = try SQLiteStateStore(databaseURL: paths.database)
    return ChargeEngine(store: store)
}

private func refresh(_ engine: ChargeEngine) async -> SyncOutcome {
    let api = WhoopAPIClient(credentialStore: KeychainCredentialStore())
    let service = WhoopSyncService(api: api, engine: engine)
    return await service.refresh()
}

private func parseJSONFlag(_ arguments: ArraySlice<String>) throws -> Bool {
    if arguments.isEmpty { return false }
    guard Array(arguments) == ["--json"] else {
        throw ControlError.usage(usage)
    }
    return true
}

private func parseHookArguments(
    _ arguments: ArraySlice<String>,
    requireExplicit: Bool = false
) throws -> HookArguments {
    var rawHooksFile: String?
    var rawHookBinary: String?
    if !requireExplicit {
        rawHooksFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
            .path
        rawHookBinary = AppPaths().hookBinary.path
    }
    var sawHooksFile = false
    var sawHookBinary = false
    var index = arguments.startIndex

    while index < arguments.endIndex {
        let option = arguments[index]
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw ControlError.usage(usage)
        }
        let value = arguments[valueIndex]
        switch option {
        case "--hooks-file" where !sawHooksFile:
            rawHooksFile = value
            sawHooksFile = true
        case "--hook-binary" where !sawHookBinary:
            rawHookBinary = value
            sawHookBinary = true
        default:
            throw ControlError.usage(usage)
        }
        index = arguments.index(after: valueIndex)
    }
    guard let rawHooksFile, let rawHookBinary else {
        throw ControlError.usage(
            "Internal installer command requires explicit --hooks-file and --hook-binary paths."
        )
    }
    return HookArguments(
        hooksFile: URL(fileURLWithPath: rawHooksFile),
        hookBinary: URL(fileURLWithPath: rawHookBinary),
        rawHooksFile: rawHooksFile,
        rawHookBinary: rawHookBinary
    )
}

private func deleteLocalData() throws {
    let root = try validatedStateRoot()
    let paths = AppPaths(rootOverride: root)
    let database = paths.database
    guard database.lastPathComponent == "state.sqlite3",
          database.deletingLastPathComponent().path == root.path
    else { throw ControlError.unsafeStatePath }

    guard pathExists(database.path) else { return }
    for path in [database.path, database.path + "-wal", database.path + "-shm"] where pathExists(path) {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG
        else { throw ControlError.unsafeStatePath }
    }
    let store = try SQLiteStateStore(databaseURL: database)
    try ChargeEngine(store: store).deleteLocalData()
}

private func validatedStateRoot() throws -> URL {
    let rawPath: String
    if let override = ProcessInfo.processInfo.environment["HITW_STATE_ROOT"], !override.isEmpty {
        rawPath = override
    } else {
        rawPath = AppPaths().root.path
    }
    let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
    let hasControlCharacter = rawPath.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0)
    }
    let unsafeRoots: Set<String> = [
        "/", "/Users", "/Library", "/System", "/Applications", "/tmp",
        "/private", "/private/tmp",
        FileManager.default.homeDirectoryForCurrentUser.path,
    ]
    guard rawPath.hasPrefix("/"),
          !rawPath.hasSuffix("/"),
          !rawPath.contains("//"),
          !hasControlCharacter,
          components.first == "",
          components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          !unsafeRoots.contains(rawPath),
          !hasExistingSymbolicLinkComponent(rawPath)
    else { throw ControlError.unsafeStatePath }

    let root = URL(fileURLWithPath: rawPath, isDirectory: true)
    guard root.path == rawPath else { throw ControlError.unsafeStatePath }
    return root
}

private func validatedTemporaryTestStateRoot() throws -> URL {
    let root = try validatedStateRoot()
    guard root.path.hasPrefix("/private/tmp/") else {
        throw ControlError.unsafeStatePath
    }
    return root
}

private func validatedTemporaryTestURL(rawPath: String) throws -> URL {
    let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
    let hasControlCharacter = rawPath.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0)
    }
    guard rawPath.hasPrefix("/private/tmp/"),
          !rawPath.hasSuffix("/"),
          !rawPath.contains("//"),
          !hasControlCharacter,
          components.first == "",
          components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          !hasExistingSymbolicLinkComponent(rawPath)
    else { throw ControlError.unsafeStatePath }
    let url = URL(fileURLWithPath: rawPath)
    guard url.path == rawPath else { throw ControlError.unsafeStatePath }
    return url
}

private func requireCanonicalDirectory(_ url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          canonicalPhysicalPath(url.path) == url.path
    else { throw ControlError.unsafeStatePath }
}

private func requireRegularFile(_ url: URL, allowMissing: Bool) throws {
    var status = stat()
    if lstat(url.path, &status) != 0 {
        if allowMissing, errno == ENOENT { return }
        throw ControlError.unsafeStatePath
    }
    guard status.st_mode & S_IFMT == S_IFREG,
          canonicalPhysicalPath(url.path) == url.path
    else { throw ControlError.unsafeStatePath }
}

private func canonicalPhysicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func validateInternalCoordinatorTestPaths(_ options: HookArguments) throws -> URL {
    let stateRoot = try validateStrictTemporaryStatePaths()

    let hooksFile = try validatedTemporaryTestURL(rawPath: options.rawHooksFile)
    let hooksParent = hooksFile.deletingLastPathComponent()
    _ = try validatedTemporaryTestURL(rawPath: hooksParent.path)
    try requireCanonicalDirectory(hooksParent)
    try requireRegularFile(hooksFile, allowMissing: true)

    let hookBinary = try validatedTemporaryTestURL(rawPath: options.rawHookBinary)
    try requireRegularFile(hookBinary, allowMissing: false)
    return stateRoot
}

@discardableResult
private func validateStrictTemporaryStatePaths() throws -> URL {
    let stateRoot = try validatedTemporaryTestStateRoot()
    _ = try validatedTemporaryTestURL(rawPath: stateRoot.path)
    try requireCanonicalDirectory(stateRoot)
    for leaf in ["state.sqlite3", "state.sqlite3-wal", "state.sqlite3-shm"] {
        try requireRegularFile(stateRoot.appendingPathComponent(leaf), allowMissing: true)
    }
    return stateRoot
}

private func pathExists(_ path: String) -> Bool {
    var status = stat()
    return lstat(path, &status) == 0
}

private func hasExistingSymbolicLinkComponent(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return true }
    var current = ""
    for component in path.split(separator: "/") {
        current += "/\(component)"
        var status = stat()
        if lstat(current, &status) != 0 {
            if errno == ENOENT { return false }
            return true
        }
        if status.st_mode & S_IFMT == S_IFLNK { return true }
        if current != path, status.st_mode & S_IFMT != S_IFDIR { return true }
    }
    return false
}

private func run() async -> ExitCode {
    let arguments = CommandLine.arguments.dropFirst()
    guard let command = arguments.first else {
        writeStandardError(usage)
        return .usage
    }
    let remainder = arguments.dropFirst()

    do {
        switch command {
        case "status":
            let json = try parseJSONFlag(remainder)
            let state = try makeEngine().currentState()
            try printStatus(state, json: json)

        case "enable":
            guard remainder.isEmpty else { throw ControlError.usage(usage) }
            let engine = try makeEngine()
            try engine.setEnabled(true)
            let outcome = await refresh(engine)
            try printStatus(try engine.currentState(), json: false)
            if case .degraded = outcome { return .failure }

        case "disable":
            guard remainder.isEmpty else { throw ControlError.usage(usage) }
            let engine = try makeEngine()
            try engine.setEnabled(false)
            writeStandardOutput("Human in the Whoop is Off. Charge is paused.")

        case "_test-set-enabled-local":
            guard ProcessInfo.processInfo.environment["HITW_INSTALL_TEST_MODE"] == "1",
                  remainder.count == 3,
                  Array(remainder.prefix(2)) == ["--yes", "--value"],
                  let value = remainder.last,
                  value == "on" || value == "off"
            else { throw ControlError.usage(usage) }
            let stateRoot = try validateStrictTemporaryStatePaths()
            try makeEngine(stateRoot: stateRoot).setEnabled(value == "on")
            writeStandardOutput("Local feature state changed without WHOOP refresh.")

        case "refresh":
            let json = try parseJSONFlag(remainder)
            let engine = try makeEngine()
            guard try engine.currentState().enabled else { throw ControlError.featureOff }
            let outcome = await refresh(engine)
            try printStatus(try engine.currentState(), json: json)
            if case .degraded = outcome { return .failure }

        case "reset-demo":
            guard Array(remainder) == ["--yes"] else { throw ControlError.usage(usage) }
            let charge = try makeEngine().resetDemo()
            writeStandardOutput("Demo Charge reset to \(charge)/100. WHOOP data was not changed.")

        case "install-hook", "uninstall-hook":
            let options = try parseHookArguments(remainder)
            let installer = try HookConfigInstaller(
                hooksFile: options.hooksFile,
                hookBinary: options.hookBinary
            )
            let result = try command == "install-hook"
                ? installer.install()
                : installer.uninstall()
            if command == "install-hook" {
                writeStandardOutput(result.changed ? "Human in the Whoop hook installed." : "Human in the Whoop hook is already installed.")
            } else {
                writeStandardOutput(result.changed ? "Human in the Whoop hook removed." : "Human in the Whoop hook was not installed.")
            }
            if let backup = result.backup {
                writeStandardOutput("Backup: \(backup.path)")
            }
            if !result.durabilityConfirmed {
                writeStandardError("Hook update committed, but crash-durability could not be confirmed.")
            }

        case "install-soft-off-hook":
            let options = try parseHookArguments(remainder, requireExplicit: true)
            let environment = ProcessInfo.processInfo.environment
            let testMode = environment["HITW_INSTALL_TEST_MODE"] ?? "0"
            guard testMode == "0" || testMode == "1" else {
                throw ControlError.operationFailed("Invalid internal installer test mode.")
            }
            let injectedFault: InstallationCoordinatorFault?
            if let value = environment["HITW_INSTALL_TEST_FAIL_AT"] {
                guard testMode == "1", !value.isEmpty,
                      let fault = InstallationCoordinatorFault(rawValue: value)
                else {
                    throw ControlError.operationFailed("Unknown local-install fault injection.")
                }
                injectedFault = fault
            } else {
                injectedFault = nil
            }
            let engine: ChargeEngine
            if testMode == "1" {
                let stateRoot = try validateInternalCoordinatorTestPaths(options)
                engine = try makeEngine(stateRoot: stateRoot)
            } else {
                engine = try makeEngine()
            }
            let installer = try HookConfigInstaller(
                hooksFile: options.hooksFile,
                hookBinary: options.hookBinary
            )
            let result = try InstallationCoordinator(
                engine: engine,
                installer: installer,
                injectedFault: injectedFault
            ).establishSoftOffAndHook()
            writeStandardOutput(
                result.changed
                    ? "Human in the Whoop entered Soft Off and installed its hook."
                    : "Human in the Whoop entered Soft Off; its hook was already installed."
            )
            if let backup = result.backup { writeStandardOutput("Backup: \(backup.path)") }
            if !result.durabilityConfirmed {
                writeStandardError("Hook update committed, but crash-durability could not be confirmed.")
            }

        case "delete-local-data":
            guard Array(remainder) == ["--yes"] else { throw ControlError.usage(usage) }
            try deleteLocalData()
            writeStandardOutput("Local Charge and WHOOP cache data deleted. Keychain credentials were preserved.")

        default:
            throw ControlError.usage(usage)
        }
        return .success
    } catch let error as ControlError {
        writeStandardError(error.localizedDescription)
        if case .usage = error { return .usage }
        return .failure
    } catch let error as HookConfigInstallerError {
        writeStandardError(error.localizedDescription)
        return .failure
    } catch let error as InstallationCoordinatorError {
        if case .compensationFailed = error {
            writeStandardError(
                "Installation compensation is incomplete. Do not assume Soft Off or hook restoration succeeded."
            )
            return .compensationIncomplete
        }
        writeStandardError(error.localizedDescription)
        return .failure
    } catch {
        writeStandardError("Human in the Whoop operation failed safely.")
        return .failure
    }
}

private let exitCode = await run()
exit(exitCode.rawValue)
