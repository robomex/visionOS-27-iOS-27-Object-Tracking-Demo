//
//  HomeSections.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import PeerConnection
import SwiftUI

// MARK: - Status tab

/// The connection, the demo stage, and the recording toggle: what a person
/// watches and touches. A `Form`, so each caption is a section footer rather
/// than its own row.
struct StatusTab: View {
    let appState: AppState

    var body: some View {
        Form {
            ConnectionSection(session: appState.demoSession)
            DemoSection(session: appState.demoSession)
            RecordingSection(showsPersonaCam: Binding(get: { appState.showsPersonaCam },
                                                      set: { appState.showsPersonaCam = $0 }))
        }
        // Breathing room so the first section doesn't sit flush against the
        // top edge of the window.
        .contentMargins(.top, 28, for: .scrollContent)
    }
}

/// The link to the iPhone, and the one repair a person may need.
struct ConnectionSection: View {
    let session: DemoSessionController

    var body: some View {
        Section {
            if session.connection.connectionState == .connected {
                Label("Connected", systemImage: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Looking for the iPhone…")
                    }
                    Text("Open the project on a nearby iPhone, with Wi-Fi enabled on both devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let errorMessage = session.connection.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Button("Forget Paired Device") {
                session.forgetPairedDevice()
            }
        } header: {
            Text("iPhone connection")
        } footer: {
            Text("Each device remembers the other's certificate after the first connection. Reinstalling the app on either device changes its certificate, so tap this on both devices, then reconnect.")
        }
    }
}

/// The demo's stage, the calibration progress, and the recalibrate escape.
struct DemoSection: View {
    let session: DemoSessionController

    var body: some View {
        Section("Demo") {
            LabeledContent("Stage",
                           value: stageDescription)

            if session.phase == .surfacesReady {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: session.calibrationProgress)
                    Text("Point both devices at the \(DemoItemCatalog.calibrationItemName) and hold steady.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(statusMessage(for: session.calibrationStatus))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if session.visionFromPhone != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Recalibrate") {
                        session.recalibrate()
                    }
                    Text("Redoes the frame sync. Ghosts and the meal clear; drag the items again on the iPhone after the new lock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stageDescription: String {
        switch session.phase {
        case .idle:
            return "Not connected"
        case .connected:
            if !session.isTrackingActive {
                return "Connected · start tracking to continue"
            }

            return session.hasSurfaceCoverage ? "Connected" : "Connected · mapping surfaces"
        case .surfacesReady:
            return "Calibrating"
        case .calibrated:
            return "Calibrated"
        case .placingGhosts:
            return "The iPhone places the ghost targets"
        case .guiding(let itemID):
            return "Guiding · \(MealCourse.description(for: itemID, in: session.mealItemIDs))"
        case .complete:
            return "Meal complete"
        }
    }

    /// What calibration is waiting for, in the person's terms.
    private func statusMessage(for status: DemoSessionController.CalibrationStatus) -> String {
        switch status {
        case .waitingForIPhone:
            return "The iPhone doesn't see the \(DemoItemCatalog.calibrationItemName) yet."
        case .waitingForVisionPro:
            return "This Vision Pro doesn't see the \(DemoItemCatalog.calibrationItemName) yet."
        case .steadying:
            return "Steadying…"
        }
    }
}

/// The PersonaCam facecam toggle.
struct RecordingSection: View {
    @Binding var showsPersonaCam: Bool

    var body: some View {
        Section {
            Toggle("Show PersonaCam facecam",
                   isOn: $showsPersonaCam)
        } header: {
            Text("Recording")
        } footer: {
            Text("Floats your Persona in the lower right as proof your eyes are closed. Takes effect the next time tracking starts.")
        }
    }
}

// MARK: - Objects tab

/// The eight-object load list, on its own tab so it isn't the first thing a
/// person sees.
struct ObjectsTab: View {
    let loader: ReferenceObjectLoader

    var body: some View {
        List {
            Section {
                ForEach(DemoItemCatalog.items) { item in
                    ItemRowView(item: item,
                                loader: loader)
                }
            } footer: {
                Text("Each object's training and load-time settings, and whether its reference object is bundled yet.")
            }
        }
        .contentMargins(.top, 28, for: .scrollContent)
    }
}

/// One row of the object list: the item's levers and its load status.
private struct ItemRowView: View {
    let item: DemoItem
    let loader: ReferenceObjectLoader

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.displayName)
                    .font(.headline)
                Text(item.trainingSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(roleDescription)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            statusLabel
        }
    }

    private var roleDescription: String {
        let role: String
        switch item.role {
        case .carton:
            role = "Part 1 comparison"
        case .mealItem(let category):
            role = "Meal item · \(category.rawValue)"
        }

        return item.id == DemoItemCatalog.calibrationItemID ? "\(role) · calibration object" : role
    }

    @ViewBuilder
    private var statusLabel: some View {
        if loader.loadedItems.contains(where: { $0.item.id == item.id }) {
            Label("Loaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.iconOnly)
        } else if let failure = loader.failedItems.first(where: { $0.item.id == item.id }) {
            Label(failure.errorDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .labelStyle(.iconOnly)
                .help(failure.errorDescription)
        } else if loader.didFinishLoading {
            Text("Pending training")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

// MARK: - Toolbar

/// The immersive-space controls in the window's bottom ornament: enter,
/// leave, and the starting-up state.
struct TrackingToolbar: View {
    let appState: AppState
    let openImmersiveSpace: () async -> Void
    let dismissImmersiveSpace: () async -> Void

    var body: some View {
        VStack {
            if !appState.isImmersiveSpaceOpened {
                let loadedCount = appState.referenceObjectLoader.loadedItems.count

                Button(startTitle(count: loadedCount)) {
                    Task { await openImmersiveSpace() }
                }
                .disabled(loadedCount == 0 || !appState.referenceObjectLoader.didFinishLoading)
            } else {
                Button("Stop Tracking") {
                    Task { await dismissImmersiveSpace() }
                }

                if !appState.objectTrackingStartedRunning {
                    HStack {
                        ProgressView()
                        Text("Starting object tracking…")
                    }
                }
            }

            Text(hint)
                .foregroundStyle(.secondary)
                .font(.footnote)
                .padding(.horizontal)
        }
    }

    private func startTitle(count: Int) -> String {
        count == 1 ? "Start Tracking 1 Object" : "Start Tracking \(count) Objects"
    }

    private var hint: String {
        if appState.isImmersiveSpaceOpened {
            return "This leaves the immersive space."
        }
        if !appState.referenceObjectLoader.didFinishLoading {
            return "Loading reference objects…"
        }
        if appState.referenceObjectLoader.loadedItems.isEmpty {
            return "No reference objects are available yet."
        }

        return "This enters an immersive space, hiding all other apps."
    }
}
#endif
