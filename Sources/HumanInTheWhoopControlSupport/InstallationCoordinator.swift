import Foundation
import HumanInTheWhoopCore

public enum InstallationCoordinatorFault: String, Sendable {
    case afterSoftOff = "after-disable"
    case afterHookCommit = "after-hook-commit"
    case compensationConflict = "compensation-conflict"
}

public enum InstallationCoordinatorError: LocalizedError, Sendable {
    case injectedFailure(InstallationCoordinatorFault)
    case compensationFailed
    case hookNotRetained
    case softOffNotRetained

    public var errorDescription: String? {
        switch self {
        case .injectedFailure(let fault):
            "Injected local-install failure at \(fault.rawValue)."
        case .compensationFailed:
            "Local installation failed and exact compensation could not be completed."
        case .hookNotRetained:
            "Local installation stopped because Codex hooks changed concurrently."
        case .softOffNotRetained:
            "Local installation stopped because Soft Off changed concurrently."
        }
    }
}

enum InstallationCoordinatorTestPoint: Equatable, Sendable {
    case beforeFinalHookConfirmation
}

struct InstallationCoordinatorTestHooks: Sendable {
    let callback: @Sendable (InstallationCoordinatorTestPoint) throws -> Void

    init(_ callback: @escaping @Sendable (InstallationCoordinatorTestPoint) throws -> Void) {
        self.callback = callback
    }
}

/// Coordinates the only cross-resource installer mutation: exact ledger Soft
/// Off plus the owned hook entry. Success confirms the ledger first and then
/// confirms the committed hook bytes; the final hook confirmation is the
/// reported-success linearization boundary. A later non-cooperating hook edit
/// is outside this operation. This provides reported-error compensation; it
/// does not claim atomicity across SQLite and hooks.json.
public struct InstallationCoordinator: Sendable {
    private let engine: ChargeEngine
    private let installer: HookConfigInstaller
    private let injectedFault: InstallationCoordinatorFault?
    private let testHooks: InstallationCoordinatorTestHooks?

    public init(
        engine: ChargeEngine,
        installer: HookConfigInstaller,
        injectedFault: InstallationCoordinatorFault? = nil
    ) {
        self.engine = engine
        self.installer = installer
        self.injectedFault = injectedFault
        self.testHooks = nil
    }

    init(
        engine: ChargeEngine,
        installer: HookConfigInstaller,
        injectedFault: InstallationCoordinatorFault?,
        testHooks: InstallationCoordinatorTestHooks
    ) {
        self.engine = engine
        self.installer = installer
        self.injectedFault = injectedFault
        self.testHooks = testHooks
    }

    @discardableResult
    public func establishSoftOffAndHook() throws -> HookConfigMutationResult {
        let snapshot = try engine.prepareInstallationSoftOff()
        var hookResult: HookConfigMutationResult?
        var preserveConcurrentHook = false
        var preserveConcurrentLedger = false
        do {
            if injectedFault == .afterSoftOff {
                throw InstallationCoordinatorError.injectedFailure(.afterSoftOff)
            }
            let result = try installer.install()
            hookResult = result
            if injectedFault == .compensationConflict {
                try engine.setEnabled(true)
                throw InstallationCoordinatorError.injectedFailure(.compensationConflict)
            }
            if injectedFault == .afterHookCommit {
                throw InstallationCoordinatorError.injectedFailure(.afterHookCommit)
            }
            guard try engine.confirmInstallationSoftOff(snapshot) else {
                preserveConcurrentLedger = true
                throw InstallationCoordinatorError.softOffNotRetained
            }
            try testHooks?.callback(.beforeFinalHookConfirmation)
            guard try installer.confirmCommitted(result) else {
                preserveConcurrentHook = true
                throw InstallationCoordinatorError.hookNotRetained
            }
            return result
        } catch {
            var compensated = true
            if let hookResult, !preserveConcurrentHook {
                do { try installer.rollback(hookResult) } catch { compensated = false }
            }
            if !preserveConcurrentLedger {
                do {
                    if preserveConcurrentHook {
                        _ = try engine.restoreInstallationStateIfCurrent(snapshot)
                    } else {
                        try engine.restoreInstallationState(snapshot)
                    }
                } catch {
                    compensated = false
                }
            }
            guard compensated else { throw InstallationCoordinatorError.compensationFailed }
            throw error
        }
    }
}
