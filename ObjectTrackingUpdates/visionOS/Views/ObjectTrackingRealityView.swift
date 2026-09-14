//
//  ObjectTrackingRealityView.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import PersonaCam
import RealityKit
import SwiftUI

/// The immersive space. The scene itself, the anchor streams, and the
/// guidance wiring live in `ImmersiveSceneCoordinator`; this view hands the
/// coordinator its content and lifecycle, and forwards the session's phase
/// and placement changes.
struct ObjectTrackingRealityView: View {
    var appState: AppState

    @State private var coordinator = ImmersiveSceneCoordinator()

    var body: some View {
        RealityView { content, attachments in
            coordinator.attach(appState: appState,
                               to: content)

            // The wearer's Persona floats in view so a recording shows their
            // eyes are closed during placement. On by default; the toggle in
            // the main window switches it off. Bottom right keeps it clear
            // of the centered guidance and the placed items.
            if appState.showsPersonaCam {
                content.addPersonaCam(position: .topRight,
                                      in: attachments)
            }
        } attachments: {
            PersonaCamAttachment(size: .regular)
        }
        .task {
            await coordinator.run(appState: appState)
        }
        .onChange(of: appState.demoSession.ghostPosesByItemID) {
            coordinator.syncGhostEntities()
        }
        .onChange(of: appState.demoSession.placedItemIDs) { previouslyPlaced, nowPlaced in
            coordinator.handlePlacedItems(nowPlaced.subtracting(previouslyPlaced))
        }
        .onChange(of: appState.demoSession.phase) { _, newPhase in
            coordinator.handlePhaseChange(to: newPhase)
        }
        .onAppear {
            appState.didEnterImmersiveSpace()
        }
        .onDisappear {
            coordinator.tearDown()
        }
    }
}
#endif
