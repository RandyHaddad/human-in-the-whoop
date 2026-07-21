import AppKit
import Combine
import SwiftUI
import HumanInTheWhoopAppSupport
import HumanInTheWhoopCore
import HumanInTheWhoopWHOOP

@main
struct HumanInTheWhoopApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = CompanionBootstrap()

    var body: some Scene {
        MenuBarExtra {
            if let model = bootstrap.model {
                MenuBarContentView(model: model)
            } else {
                LaunchFailureContentView()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: bootstrap.batterySystemImage)
                Text(bootstrap.menuBarText)
                    .monospacedDigit()
                if bootstrap.model?.isRefreshing == true {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                if bootstrap.showsUnavailableWarning {
                    let warning = bootstrap.model?.unavailableWarningSystemImage
                        ?? "exclamationmark.triangle.fill"
                    Image(systemName: warning)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Quitting the only local control surface must never strand an enabled hook.
/// macOS routes the explicit button, Command-Q, and the application menu
/// through this synchronous confirmation boundary.
@MainActor
private final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            let paths = AppPaths()
            let store = try SQLiteStateStore(databaseURL: paths.database)
            let engine = ChargeEngine(store: store)
            try CompanionTerminationController(engine: engine).prepareForTermination()
            return .terminateNow
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Human in the Whoop stayed open"
            alert.informativeText = "The feature could not be confirmed Off, so quitting was cancelled. Codex has not been left without its control surface."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
    }
}

/// A launch failure cannot safely create a second ledger. Keep a static
/// unavailable surface alive instead, with no controls that imply persistence
/// or network access. Forwarding model changes keeps the menu-bar label live.
@MainActor
private final class CompanionBootstrap: ObservableObject {
    let model: MenuBarViewModel?
    private var modelChanges: AnyCancellable?

    init() {
        model = try? MenuBarViewModel.live()
        modelChanges = model?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var menuBarText: String {
        model?.menuBarText ?? "Unavailable"
    }

    var batterySystemImage: String {
        model?.batterySystemImage ?? "battery.0"
    }

    var showsUnavailableWarning: Bool {
        model == nil || model?.unavailableWarningSystemImage != nil
    }
}

private struct LaunchFailureContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text("Human in the Whoop could not open its local state. Codex is running normally.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button("Quit Human in the Whoop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 330)
    }
}

private extension MenuBarViewModel {
    /// The only live composition root for the companion. Credential reads are
    /// lazy: constructing the app never embeds or exposes an OAuth secret.
    @MainActor
    static func live() throws -> MenuBarViewModel {
        let paths = AppPaths()
        let store = try SQLiteStateStore(databaseURL: paths.database)
        let engine = ChargeEngine(store: store)
        let petPreferenceStore = JSONPetPreferenceStore(fileURL: paths.petPreferences)
        let credentials = KeychainCredentialStore()
        let api = WhoopAPIClient(credentialStore: credentials)
        let sync = WhoopSyncService(api: api, engine: engine)

        let model = try MenuBarViewModel(
            engine: engine,
            petPreferenceStore: petPreferenceStore
        ) {
            // Durable typed sync state is the presentation boundary. The UI
            // deliberately does not display free-form SyncOutcome payloads.
            _ = await sync.refresh()
        }
        let bridge = PetPresentationBridgeServer(
            snapshotStore: model.petPresentationSnapshotStore
        ) { [weak model] available in
            Task { @MainActor in
                model?.updatePetBridgeAvailability(available)
            }
        }
        model.attachPetPresentationBridge(bridge)
        let pollingController = PollingController { [weak model] in
            await model?.refreshNow()
        }
        model.attachPollingController(pollingController)
        model.startLocalStatePolling()
        return model
    }
}
