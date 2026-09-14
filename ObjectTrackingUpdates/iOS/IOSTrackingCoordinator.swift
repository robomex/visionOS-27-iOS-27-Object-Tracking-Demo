//
//  IOSTrackingCoordinator.swift
//  ObjectTrackingUpdates
//

#if os(iOS)
import ARKit
import OSLog
import RealityKit
// `RealityViewCameraContent.add` lives in RealityKit's SwiftUI cross-import
// overlay; with member import visibility on, this file must import SwiftUI
// to call it even though no SwiftUI type appears here.
import SwiftUI

/// Runs the AR session behind the iOS `RealityView` and turns its object
/// anchors into scene content.
///
/// The app owns the `ARSession` and its `ARWorldTrackingConfiguration` - the
/// configuration carries `trackingObjects` and `detectionObjects`, which the
/// system-managed session would drop. `SpatialTrackingSession.run(_:session:arConfiguration:)`
/// hands that session to RealityKit; per its documentation, the app manages
/// and runs the `ARSession` itself.
final class IOSTrackingCoordinator: NSObject, ARSessionDelegate {
    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "IOSTrackingCoordinator")

    private let model: IOSDemoModel
    private let session = ARSession()
    private let arConfiguration = ARWorldTrackingConfiguration()
    private let spatialTrackingSession = SpatialTrackingSession()

    private var anchorEntitiesByID: [UUID: AnchorEntity] = [:]

    init(model: IOSDemoModel) {
        self.model = model
    }

    func start() async {
        #if targetEnvironment(simulator)
        // The 27 beta's simulator SDK omits run(_:session:arConfiguration:),
        // and the simulator can't run this session anyway - the home view
        // gates on ARWorldTrackingConfiguration.isSupported before showing
        // the AR view. Nothing to run here.
        model.reportSessionUnavailable("Object tracking isn't supported in Simulator.")
        #else
        await model.loadAssets()

        // Camera feed for the RealityView background, world anchoring for
        // the anchor entities, object tracking for the demo. Of the scene
        // understanding options only shadows: ghosts are placed by raycast,
        // not physics, so collision and physics have nothing to do, and an
        // occlusion mesh would sit on the very surfaces the tinted overlays
        // cover.
        let configuration = SpatialTrackingSession.Configuration(tracking: [.camera, .world, .object],
                                                                 sceneUnderstanding: [.shadow],
                                                                 camera: .back)

        arConfiguration.trackingObjects = model.trackingObjects
        arConfiguration.detectionObjects = model.detectionObjects
        // Real planes for the ghosts to land on: the drop raycasts ask for
        // horizontal surfaces, and detected planes put those hits on the
        // actual table rather than on feature-point estimates alone.
        arConfiguration.planeDetection = [.horizontal]

        session.delegate = self

        if let unavailable = await spatialTrackingSession.run(configuration,
                                                              session: session,
                                                              arConfiguration: arConfiguration)
        {
            if unavailable.anchor.contains(.object) {
                model.reportSessionUnavailable("This device doesn't support object tracking.")

                return
            }

            // Anything else the device declines, such as a scene-understanding
            // capability, is logged rather than fatal: tracking still runs,
            // the ghost drop just has less to land on.
            logger.error("Unavailable tracking capabilities: \(String(describing: unavailable), privacy: .public)")
        }

        // "You manage and run the ARSession for the SpatialTrackingSession."
        // Running the same configuration again is a no-op transition if
        // RealityKit already started it.
        session.run(arConfiguration)
        #endif
    }

    /// Pauses the session. The camera stays off until the view starts a new
    /// coordinator.
    func stop() {
        #if !targetEnvironment(simulator)
        session.pause()
        #endif
    }

    /// Restarts world tracking from scratch - a fresh world origin, every
    /// anchor removed, the objects re-detected. Called when the Vision Pro
    /// steps the demo back to a pre-calibration phase, so a redo redoes both
    /// sides instead of reusing whatever this device still had, drifted or
    /// lost.
    func resetTracking() {
        #if !targetEnvironment(simulator)
        for entity in anchorEntitiesByID.values {
            entity.removeFromParent()
        }
        anchorEntitiesByID.removeAll()
        session.run(arConfiguration,
                    options: [.resetTracking, .removeExistingAnchors])
        #endif
    }

    /// Where a ray meets a real horizontal surface, if it does. Apple's
    /// placement sample's query: an estimated plane, which hits a detected
    /// plane when there is one and a feature-point estimate otherwise, so
    /// placement works before ARKit has fully mapped the table.
    func raycastToHorizontalSurface(origin: SIMD3<Float>,
                                    direction: SIMD3<Float>) -> ARRaycastResult?
    {
        let query = ARRaycastQuery(origin: origin,
                                   direction: direction,
                                   allowing: .estimatedPlane,
                                   alignment: .horizontal)

        return session.raycast(query).first
    }

    // ARSession delivers delegate callbacks on the main run loop when
    // `delegateQueue` is nil (the default), so assuming main-actor
    // isolation here is sound.
    nonisolated func session(_ session: ARSession,
                             didAdd anchors: [ARAnchor])
    {
        MainActor.assumeIsolated {
            for case let anchor as ARObjectAnchor in anchors {
                add(anchor)
            }
        }
    }

    nonisolated func session(_ session: ARSession,
                             didUpdate anchors: [ARAnchor])
    {
        MainActor.assumeIsolated {
            for case let anchor as ARObjectAnchor in anchors {
                // An anchor that arrived before the RealityView content
                // existed was never added; add it now.
                if anchorEntitiesByID[anchor.identifier] == nil {
                    add(anchor)
                }

                // When a tracked object leaves the camera's view, ARKit sets
                // `isTracked` to false. Disabling the entity hides the
                // content without removing it, so it reappears instantly
                // when tracking resumes.
                anchorEntitiesByID[anchor.identifier]?.isEnabled = anchor.isTracked

                guard let item = model.item(for: anchor.referenceObject) else { continue }

                model.setTracked(anchor.isTracked, for: item)
            }
        }
    }

    // The calibration object reports where this device sees it, every frame
    // - not only when ARKit revises its anchor. An object in
    // `detectionObjects` is revised rarely, so with one as the calibration
    // object the samples would trickle in and calibration could take
    // forever; the frame's anchors carry ARKit's current pose every frame.
    // The model's throttle sets the send rate.
    nonisolated func session(_ session: ARSession,
                             didUpdate frame: ARFrame)
    {
        MainActor.assumeIsolated {
            for case let anchor as ARObjectAnchor in frame.anchors
            where anchor.isTracked && model.item(for: anchor.referenceObject)?.id == DemoItemCatalog.calibrationItemID {
                model.reportBeaconSample(anchor.transform)
            }
        }
    }

    // ARKit never calls this automatically for object anchors - they stay in
    // the session until the app removes them - but clean up if it ever does.
    nonisolated func session(_ session: ARSession,
                             didRemove anchors: [ARAnchor])
    {
        MainActor.assumeIsolated {
            for case let anchor as ARObjectAnchor in anchors {
                if let entity = anchorEntitiesByID.removeValue(forKey: anchor.identifier) {
                    entity.removeFromParent()
                }
            }
        }
    }

    private func add(_ anchor: ARObjectAnchor) {
        guard let content = model.sceneProxy.content,
              let item = model.item(for: anchor.referenceObject)
        else {
            return
        }

        guard let itemModel = model.modelsByItemID[item.id]
        else {
            // Logged at load time; nothing to draw for it.
            return
        }

        let entity = AnchorEntity(anchor: anchor)
        entity.addChild(IOSObjectAnchorVisualization.make(for: anchor,
                                                          item: item,
                                                          model: itemModel))
        anchorEntitiesByID[anchor.identifier] = entity
        content.add(entity)

        model.setTracked(anchor.isTracked, for: item)
    }
}
#endif
