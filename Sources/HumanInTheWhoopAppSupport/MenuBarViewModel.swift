import Combine
import Foundation
import HumanInTheWhoopCore

public enum MenuBarViewModelError: LocalizedError, Equatable, Sendable {
    case resetUnavailable

    public var errorDescription: String? {
        switch self {
        case .resetUnavailable:
            "Demo Reset requires an enabled, ready Recovery."
        }
    }
}

/// Main-actor presentation state for the separate menu-bar companion.
///
/// The model never contacts WHOOP itself. Its injected refresh boundary is the
/// only remote path, while `reloadLocalState` and the one-second observer only
/// read the shared SQLite ledger.
@MainActor
public final class MenuBarViewModel: ObservableObject {
    public typealias RefreshAction = @Sendable () async -> Void

    @Published public private(set) var state: PersistentState
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var petSelection: PetSelection
    @Published public private(set) var petBridgeAvailable = false

    public let petPresentationSnapshotStore: PetPresentationSnapshotStore

    private let engine: ChargeEngine
    private let petPreferenceStore: any PetPreferenceStoring
    private var petPresentationBridge: (any PetPresentationServing)?
    private let refreshAction: RefreshAction
    private let localStateSleeper: any Sleeper
    private var localStateTask: Task<Void, Never>?
    private var pollingController: PollingController?
    private var localStateAvailable = true
    private var featureGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var activeRefreshGeneration: UInt64?
    private var externalEnableTask: Task<Void, Never>?
    private var externalEnableGeneration: UInt64?
    private var externalEnableRefreshGeneration: UInt64?

    private static let unavailableMessage = "Human in the Whoop is unavailable."

    public init(
        engine: ChargeEngine,
        petPreferenceStore: any PetPreferenceStoring = VolatilePetPreferenceStore(),
        petPresentationSnapshotStore: PetPresentationSnapshotStore = PetPresentationSnapshotStore(),
        localStateSleeper: any Sleeper = TaskSleeper(),
        refresh: @escaping RefreshAction
    ) throws {
        self.engine = engine
        self.petPreferenceStore = petPreferenceStore
        self.petPresentationSnapshotStore = petPresentationSnapshotStore
        self.localStateSleeper = localStateSleeper
        self.refreshAction = refresh
        let initialState = try engine.currentState()
        state = initialState
        petSelection = try petPreferenceStore.load()
        statusMessage = Self.statusMessage(for: initialState)
        publishPetPresentationSnapshot()
    }

    /// Changes only presentation preference. It never enters the Charge
    /// engine or WHOOP sync boundary.
    public func setPetSelection(_ selection: PetSelection) throws {
        try petPreferenceStore.save(selection)
        petSelection = selection
        publishPetPresentationSnapshot()
    }

    public var petPresentationSnapshot: PetPresentationSnapshot {
        PetPresentationSnapshot.make(
            state: state,
            selection: petSelection,
            localStateAvailable: localStateAvailable
        )
    }

    public var petBridgeWarningText: String? {
        petBridgeAvailable ? nil : "Codex pet bridge unavailable; stock pet is active."
    }

    public func attachPetPresentationBridge(_ bridge: any PetPresentationServing) {
        petPresentationBridge?.stop()
        petPresentationBridge = nil
        petBridgeAvailable = false
        do {
            try bridge.start()
            petPresentationBridge = bridge
        } catch {
            petBridgeAvailable = false
        }
    }

    public func updatePetBridgeAvailability(_ available: Bool) {
        petBridgeAvailable = available
    }

    public var menuBarText: String {
        guard localStateAvailable else { return "Unavailable" }
        guard state.enabled else { return "Off" }
        guard let charge = readyCharge else { return "Unavailable" }
        return "\(charge)/100"
    }

    /// Validated Charge for rich presentation surfaces. Off, unavailable, and
    /// malformed state deliberately expose no paused or stale ledger value.
    public var currentChargeScore: Int? {
        guard localStateAvailable, state.enabled else { return nil }
        return readyCharge
    }

    public var batterySystemImage: String {
        guard localStateAvailable else { return "battery.0" }
        guard state.enabled, let charge = readyCharge else { return "battery.0" }
        switch charge {
        case 76...100:
            return "battery.100"
        case 51...75:
            return "battery.75"
        case 26...50:
            return "battery.50"
        case 1...25:
            return "battery.25"
        default:
            return "battery.0"
        }
    }

    /// A separate, valid SF Symbol badge distinguishes Unavailable from Off.
    public var unavailableWarningSystemImage: String? {
        guard localStateAvailable else { return "exclamationmark.triangle.fill" }
        guard state.enabled, readyCharge == nil else { return nil }
        return "exclamationmark.triangle.fill"
    }

    /// The only Recovery score presentation seam. Paused, degraded, ended,
    /// malformed, or ledger-corrupt state never exposes a cached health value.
    public var currentRecoveryScore: Int? {
        guard localStateAvailable, state.enabled else { return nil }
        return readyRecoveryAndCharge?.recovery.recoveryScore
    }

    public var lastWorkoutAwardText: String? {
        guard localStateAvailable,
              state.enabled,
              let ready = readyRecoveryAndCharge,
              let epoch = state.workoutRewards,
              epoch.cycleID == ready.recovery.cycleID,
              let award = epoch.lastAward,
              award.cycleID == ready.recovery.cycleID,
              award.strain.isFinite,
              (0...21).contains(award.strain),
              (1...50).contains(award.earnedCharge),
              (0...award.earnedCharge).contains(award.appliedCharge),
              (0...100).contains(award.resultingCharge),
              award.workoutEndedAt.timeIntervalSinceReferenceDate.isFinite,
              award.awardedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }
        if award.appliedCharge == 0 {
            return "Charge already full (+\(award.earnedCharge) earned)"
        }
        if award.appliedCharge < award.earnedCharge {
            return "+\(award.appliedCharge) Charge (+\(award.earnedCharge) earned; capped)"
        }
        return "+\(award.appliedCharge) Charge"
    }

    public var canResetDemo: Bool {
        localStateAvailable && state.enabled && readyRecoveryAndCharge != nil
    }

    public var resetConfirmationText: String? {
        guard canResetDemo,
              let current = state.chargeRemaining,
              let target = state.recovery?.recoveryScore
        else {
            return nil
        }
        return "Reset Charge from \(current) to \(target) across all local Codex windows? This does not change WHOOP data."
    }

    /// Persists Soft Off immediately. A transition from Off to On remains
    /// unavailable until the required refresh has finished successfully.
    public func setEnabled(_ enabled: Bool) async {
        if !enabled {
            // Soft Off revokes every in-memory network path before touching a
            // database that may itself be unavailable.
            featureGeneration &+= 1
            cancelExternalEnable()
            invalidateActiveRefresh()
            pollingController?.setEnabled(false)
            do {
                try engine.setEnabled(false)
                try reloadLocalState(observeExternalTransitions: false)
            } catch {
                markLocalStateUnavailable()
            }
            return
        }

        do {
            try reloadLocalState(observeExternalTransitions: false)
            // A duplicate/reentrant On observes the durable On written by the
            // original operation and leaves its generation untouched.
            guard !state.enabled else { return }

            featureGeneration &+= 1
            let operationGeneration = featureGeneration
            try engine.setEnabled(true)
            try reloadLocalState(observeExternalTransitions: false)
            await refreshNow()
            guard featureGeneration == operationGeneration, state.enabled else { return }
            // Re-enable already performed its required immediate refresh. The
            // scheduler resumes at the next 900-second interval.
            pollingController?.setEnabled(true)
        } catch {
            markLocalStateUnavailable()
        }
    }

    /// Runs one explicit refresh only when the durable feature flag is On.
    public func refreshNow() async {
        do {
            try reloadLocalState(observeExternalTransitions: false)
        } catch {
            markLocalStateUnavailable()
            return
        }
        guard state.enabled, activeRefreshGeneration == nil else { return }

        refreshGeneration &+= 1
        let generation = refreshGeneration
        activeRefreshGeneration = generation
        isRefreshing = true
        await refreshAction()
        completeRefresh(generation: generation)
    }

    public func confirmResetDemo() throws {
        guard canResetDemo else {
            throw MenuBarViewModelError.resetUnavailable
        }
        do {
            _ = try engine.resetDemo()
            try reloadLocalState()
        } catch {
            try? reloadLocalState()
            throw error
        }
    }

    /// Rereads only the shared local SQLite state. This has no WHOOP boundary.
    public func reloadLocalState() throws {
        try reloadLocalState(observeExternalTransitions: true)
    }

    private func reloadLocalState(observeExternalTransitions: Bool) throws {
        let wasEnabled = state.enabled
        let wasRefreshRequired = Self.isRefreshRequired(state)
        let newState: PersistentState
        do {
            newState = try engine.currentState()
        } catch {
            markLocalStateUnavailable()
            throw error
        }
        localStateAvailable = true
        state = newState
        statusMessage = Self.statusMessage(for: newState)
        publishPetPresentationSnapshot()
        guard observeExternalTransitions else { return }

        if wasEnabled, !newState.enabled {
            featureGeneration &+= 1
            cancelExternalEnable()
            invalidateActiveRefresh()
            pollingController?.setEnabled(false)
        } else if !wasRefreshRequired, Self.isRefreshRequired(newState) {
            scheduleExternalEnable()
        }
    }

    /// Composes the model with WHOOP launch/wake/interval scheduling. Attaching
    /// while enabled performs the scheduler-owned launch refresh exactly once.
    public func attachPollingController(_ controller: PollingController) {
        pollingController?.stop()
        pollingController = controller
        controller.start(enabled: state.enabled)
    }

    /// Starts the independent one-second local ledger observation loop.
    public func startLocalStatePolling() {
        guard localStateTask == nil else { return }
        let sleeper = localStateSleeper
        localStateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(seconds: 1)
                    try Task.checkCancellation()
                    guard let self else { return }
                    try self.reloadLocalState()
                } catch is CancellationError {
                    return
                } catch {
                    self?.markLocalStateUnavailable()
                }
            }
        }
    }

    public func stopLocalStatePolling() {
        localStateTask?.cancel()
        localStateTask = nil
    }

    private var readyCharge: Int? {
        readyRecoveryAndCharge?.charge
    }

    private var readyRecoveryAndCharge: (recovery: RecoverySnapshot, charge: Int)? {
        Self.readyRecoveryAndCharge(in: state)
    }

    private static func readyRecoveryAndCharge(
        in state: PersistentState
    ) -> (recovery: RecoverySnapshot, charge: Int)? {
        guard state.degradedReason == nil,
              let recovery = state.recovery,
              recovery.cycleID > 0,
              recovery.sleepID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              (0...100).contains(recovery.recoveryScore),
              recovery.createdAt.timeIntervalSinceReferenceDate.isFinite,
              recovery.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              recovery.cycleStart.timeIntervalSinceReferenceDate.isFinite,
              recovery.validatedAt.timeIntervalSinceReferenceDate.isFinite,
              recovery.cycleEnd == nil,
              let charge = state.chargeRemaining,
              (0...100).contains(charge)
        else {
            return nil
        }
        return (recovery, charge)
    }

    private static func statusMessage(for state: PersistentState) -> String? {
        guard state.enabled else { return nil }
        let typedReason = state.lastSyncError.flatMap(SyncFailureReason.init(rawValue:))
        let ready = readyRecoveryAndCharge(in: state) != nil

        guard ready, state.degradedReason == nil else {
            return typedReason.map(safeStatusMessage(for:)) ?? unavailableMessage
        }
        guard state.lastSyncError != nil else { return nil }
        guard let typedReason else { return unavailableMessage }
        return safeStatusMessage(for: typedReason)
    }

    private static func isRefreshRequired(_ state: PersistentState) -> Bool {
        state.enabled && state.lastSyncError == SyncFailureReason.refreshRequired.rawValue
    }

    private static func safeStatusMessage(for reason: SyncFailureReason) -> String {
        switch reason {
        case .ledgerCorrupt:
            return unavailableMessage
        case .unavailable, .authentication, .rateLimited, .invalidData, .refreshRequired:
            return reason.userMessage
        }
    }

    private func invalidateActiveRefresh() {
        refreshGeneration &+= 1
        activeRefreshGeneration = nil
        isRefreshing = false
    }

    private func markLocalStateUnavailable() {
        localStateAvailable = false
        statusMessage = Self.unavailableMessage
        publishPetPresentationSnapshot()
    }

    private func publishPetPresentationSnapshot() {
        petPresentationSnapshotStore.publish(petPresentationSnapshot)
    }

    private func scheduleExternalEnable() {
        guard externalEnableGeneration == nil else { return }
        pollingController?.setEnabled(false)
        featureGeneration &+= 1
        let featureToken = featureGeneration
        externalEnableGeneration = featureToken

        if activeRefreshGeneration != nil {
            // A refresh that began before durable refreshRequired belongs to
            // the superseded enable epoch and cannot validate this re-enable.
            invalidateActiveRefresh()
        }

        refreshGeneration &+= 1
        let refreshToken = refreshGeneration
        activeRefreshGeneration = refreshToken
        externalEnableRefreshGeneration = refreshToken
        isRefreshing = true
        let refreshAction = refreshAction
        externalEnableTask = Task { @MainActor [weak self, refreshAction] in
            guard !Task.isCancelled else { return }
            await refreshAction()
            self?.completeRefresh(generation: refreshToken)
        }
    }

    private func cancelExternalEnable() {
        externalEnableTask?.cancel()
        externalEnableTask = nil
        externalEnableGeneration = nil
        externalEnableRefreshGeneration = nil
    }

    private func completeRefresh(generation: UInt64) {
        guard activeRefreshGeneration == generation else { return }
        do {
            // A refresh completion must publish state without interpreting its
            // own durable writes as another external transition.
            try reloadLocalState(observeExternalTransitions: false)
        } catch {
            markLocalStateUnavailable()
        }
        guard activeRefreshGeneration == generation else { return }
        activeRefreshGeneration = nil
        isRefreshing = false
        completeExternalEnable(refreshGeneration: generation)
    }

    private func completeExternalEnable(refreshGeneration: UInt64) {
        guard externalEnableRefreshGeneration == refreshGeneration,
              let featureGeneration = externalEnableGeneration
        else {
            return
        }
        externalEnableTask = nil
        externalEnableGeneration = nil
        externalEnableRefreshGeneration = nil
        guard self.featureGeneration == featureGeneration, state.enabled else { return }
        // The external transition's immediate refresh is already done.
        pollingController?.setEnabled(true)
    }
}
