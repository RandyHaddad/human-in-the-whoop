import AppKit
import SwiftUI
import HumanInTheWhoopAppSupport

struct MenuBarContentView: View {
    @ObservedObject var model: MenuBarViewModel

    @State private var isAdvancedExpanded = false
    @State private var isShowingResetConfirmation = false
    @State private var resetFailed = false
    @State private var petSelectionFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChargeBlobView(score: model.currentChargeScore)

            if model.isRefreshing {
                Label("Refreshing WHOOP…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage = model.statusMessage {
                warningLabel(statusMessage, systemImage: "exclamationmark.triangle.fill")
            }

            if let warning = model.petBridgeWarningText {
                warningLabel(warning, systemImage: "pawprint.fill")
            }

            Divider()

            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                advancedContent
                    .padding(.top, 10)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .contentShape(Rectangle())
            }
        }
        .padding(16)
        .frame(width: 360)
        .confirmationDialog(
            "Reset Demo Charge?",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Charge", role: .destructive) {
                do {
                    try model.confirmResetDemo()
                } catch {
                    resetFailed = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.resetConfirmationText ?? "Demo Reset is unavailable.")
        }
        .alert("Demo Reset could not be completed.", isPresented: $resetFailed) {
            Button("OK", role: .cancel) {}
        }
        .alert("Pet selection could not be saved.", isPresented: $petSelectionFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            recoveryDetails

            Divider()

            Button {
                Task { await model.refreshNow() }
            } label: {
                Label("Refresh WHOOP Now", systemImage: "arrow.clockwise")
            }
            .disabled(!model.state.enabled || model.isRefreshing)

            if model.canResetDemo {
                Button {
                    isShowingResetConfirmation = true
                } label: {
                    Label(resetButtonTitle, systemImage: "arrow.counterclockwise")
                }
            }

            Picker("Codex pet", selection: petSelectionBinding) {
                ForEach(PetSelection.allCases) { selection in
                    Text(selection.displayName).tag(selection)
                }
            }

            Toggle(
                "Human in the Whoop",
                isOn: Binding(
                    get: { model.state.enabled },
                    set: { enabled in
                        Task { await model.setEnabled(enabled) }
                    }
                )
            )

            Divider()

            Button("Turn Off and Quit Human in the Whoop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .font(.callout)
    }

    private var recoveryDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("WHOOP Recovery")
                    .foregroundStyle(.secondary)
                Text(recoveryText)
                    .monospacedDigit()
            }
            GridRow {
                Text("Last refresh")
                    .foregroundStyle(.secondary)
                if let lastRefresh = model.state.lastSyncSuccessAt {
                    Text(lastRefresh, format: .dateTime.month(.abbreviated).day().hour().minute())
                } else {
                    Text("Never")
                }
            }
            if let award = model.lastWorkoutAwardText {
                GridRow {
                    Text("Last workout refill")
                        .foregroundStyle(.secondary)
                    Text(award)
                        .monospacedDigit()
                }
            }
        }
    }

    private func warningLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var petSelectionBinding: Binding<PetSelection> {
        Binding(
            get: { model.petSelection },
            set: { selection in
                do {
                    try model.setPetSelection(selection)
                } catch {
                    petSelectionFailed = true
                }
            }
        )
    }

    private var recoveryText: String {
        guard let score = model.currentRecoveryScore else {
            return model.state.enabled ? "Unavailable" : "Paused"
        }
        return "\(score)/100"
    }

    private var resetButtonTitle: String {
        guard let score = model.currentRecoveryScore else {
            return "Reset Charge…"
        }
        return "Reset Charge to \(score)…"
    }
}
