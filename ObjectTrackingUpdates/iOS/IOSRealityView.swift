//
//  IOSRealityView.swift
//  ObjectTrackingUpdates
//

#if os(iOS)
import ARKit
import RealityKit
import SwiftUI

/// The iOS camera view: a `RealityView` whose background is the spatial
/// tracking camera feed. Tracked-object overlays, table overlays, and ghosts
/// all hang off the scene this view hands to the model.
struct IOSRealityView: View {
    let model: IOSDemoModel

    @State private var coordinator: IOSTrackingCoordinator?

    var body: some View {
        RealityView { content in
            content.add(model.sceneProxy.root)
            model.sceneProxy.content = content

            // Run our tracking session (our own ARSession, carrying the
            // object-tracking configuration) BEFORE switching the camera to
            // spatial tracking. Setting `.spatialTracking` with no session
            // running makes RealityKit start its own default `ARSession`;
            // ours would then be a second session, and two world-tracking
            // sessions fighting over the device-motion sensor is the ARKit
            // crash (a freed `ARWorldTrackingTechnique` messaged from the
            // sensor queue). Running ours first means there is only ever one.
            let coordinator = IOSTrackingCoordinator(model: model)
            self.coordinator = coordinator
            model.trackingCoordinator = coordinator
            await coordinator.start()

            content.camera = .spatialTracking
        }
        .ignoresSafeArea()
        .onDisappear {
            coordinator?.stop()
        }
    }
}
#endif
