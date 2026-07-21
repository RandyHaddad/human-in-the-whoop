import Foundation
import Testing
@testable import HumanInTheWhoopAppSupport
@testable import HumanInTheWhoopCore

@Suite struct PetPreferencesTests {
    @Test func missingAndMalformedPreferencesFailClosedToOff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pet-preferences.json")
        let store = JSONPetPreferenceStore(fileURL: url)

        #expect(try store.load() == .off)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        #expect(try store.load() == .off)
    }

    @Test func selectionPersistsAcrossStoreAndModelRestarts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pet-preferences.json")

        let first = JSONPetPreferenceStore(fileURL: url)
        try first.save(.whoopSensorB)

        let restarted = JSONPetPreferenceStore(fileURL: url)
        #expect(try restarted.load() == .whoopSensorB)
        try restarted.save(.off)

        let restartedAgain = JSONPetPreferenceStore(fileURL: url)
        #expect(try restartedAgain.load() == .off)
    }

    @Test @MainActor func modelRestartRestoresSelectionWithoutMutatingChargeLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ChargeEngine(
            store: try SQLiteStateStore(databaseURL: directory.appendingPathComponent("state.sqlite3"))
        )
        let preferenceURL = directory.appendingPathComponent("pet-preferences.json")
        let ledgerBefore = try engine.currentState()

        let first = try MenuBarViewModel(
            engine: engine,
            petPreferenceStore: JSONPetPreferenceStore(fileURL: preferenceURL)
        ) {}
        try first.setPetSelection(.whoopSensorB)
        #expect(try engine.currentState() == ledgerBefore)

        let restarted = try MenuBarViewModel(
            engine: engine,
            petPreferenceStore: JSONPetPreferenceStore(fileURL: preferenceURL)
        ) {}
        #expect(restarted.petSelection == .whoopSensorB)
        #expect(try engine.currentState() == ledgerBefore)
    }

    @Test func snapshotCombinesReadOnlyLedgerWithSeparatePresentationPreference() {
        var state = PersistentState()
        state.enabled = true
        state.chargeRemaining = 72
        state.recovery = RecoverySnapshot(
            cycleID: 100,
            sleepID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            recoveryScore: 72,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            cycleStart: Date(timeIntervalSince1970: 0),
            cycleEnd: nil,
            sleepPerformance: 80,
            cycleStrain: 7,
            recentWorkout: nil,
            secondaryDataComplete: true,
            validatedAt: Date(timeIntervalSince1970: 3)
        )

        let selected = PetPresentationSnapshot.make(
            state: state,
            selection: .battery,
            localStateAvailable: true
        )
        #expect(selected.available)
        #expect(selected.enabled)
        #expect(selected.petEnabled)
        #expect(selected.petIdentity == PetSelection.battery.rawValue)
        #expect(selected.charge == 72)

        let off = PetPresentationSnapshot.make(
            state: state,
            selection: .off,
            localStateAvailable: true
        )
        #expect(off.available)
        #expect(off.enabled)
        #expect(!off.petEnabled)
        #expect(off.petIdentity == nil)
        #expect(off.charge == 72)

        let unavailable = PetPresentationSnapshot.make(
            state: state,
            selection: .battery,
            localStateAvailable: false
        )
        #expect(!unavailable.available)
        #expect(!unavailable.petEnabled)
        #expect(unavailable.charge == nil)
    }
}
