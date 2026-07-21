import Foundation
import HumanInTheWhoopCore

public enum PetSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case battery
    case whoopSensorB = "whoop-sensor-b"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .battery: "Battery"
        case .whoopSensorB: "WHOOP Sensor B"
        }
    }

    public var isEnabled: Bool { self != .off }
}

public protocol PetPreferenceStoring: Sendable {
    func load() throws -> PetSelection
    func save(_ selection: PetSelection) throws
}

public final class JSONPetPreferenceStore: PetPreferenceStoring, @unchecked Sendable {
    private struct Document: Codable {
        var schemaVersion: Int
        var selection: PetSelection
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> PetSelection {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return .off }
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1
        else {
            return .off
        }
        return document.selection
    }

    public func save(_ selection: PetSelection) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: 1, selection: selection))
        try data.write(to: fileURL, options: .atomic)
    }
}

public final class VolatilePetPreferenceStore: PetPreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var selection: PetSelection

    public init(selection: PetSelection = .off) {
        self.selection = selection
    }

    public func load() throws -> PetSelection {
        lock.lock()
        defer { lock.unlock() }
        return selection
    }

    public func save(_ selection: PetSelection) throws {
        lock.lock()
        defer { lock.unlock() }
        self.selection = selection
    }
}

public struct PetPresentationSnapshot: Codable, Equatable, Sendable {
    public var available: Bool
    public var enabled: Bool
    public var petEnabled: Bool
    public var petIdentity: String?
    public var charge: Int?
    public var awardSequence: String?
    public var appliedCharge: Int

    public static func make(
        state: PersistentState,
        selection: PetSelection,
        localStateAvailable: Bool
    ) -> PetPresentationSnapshot {
        guard localStateAvailable else { return .unavailable }
        guard state.enabled else {
            return PetPresentationSnapshot(
                available: true,
                enabled: false,
                petEnabled: false,
                petIdentity: nil,
                charge: nil,
                awardSequence: nil,
                appliedCharge: 0
            )
        }
        guard let charge = readyCharge(in: state) else { return .unavailable }

        let award = validLastAward(in: state)
        return PetPresentationSnapshot(
            available: true,
            enabled: true,
            petEnabled: selection.isEnabled,
            petIdentity: selection.isEnabled ? selection.rawValue : nil,
            charge: charge,
            awardSequence: award.map {
                "\($0.cycleID):\($0.workoutID.uuidString):\($0.awardedAt.timeIntervalSinceReferenceDate)"
            },
            appliedCharge: award?.appliedCharge ?? 0
        )
    }

    public static let unavailable = PetPresentationSnapshot(
        available: false,
        enabled: false,
        petEnabled: false,
        petIdentity: nil,
        charge: nil,
        awardSequence: nil,
        appliedCharge: 0
    )

    private static func readyCharge(in state: PersistentState) -> Int? {
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
        return charge
    }

    private static func validLastAward(in state: PersistentState) -> WorkoutChargeAward? {
        guard let recovery = state.recovery,
              let epoch = state.workoutRewards,
              epoch.cycleID == recovery.cycleID,
              let award = epoch.lastAward,
              award.cycleID == recovery.cycleID,
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
        return award
    }
}
