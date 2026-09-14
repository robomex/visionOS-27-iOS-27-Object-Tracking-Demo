//
//  ImmersiveSceneCoordinator.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import ARKit
import OSLog
import PeerConnection
import RealityKit
import SwiftUI

/// Everything that happens inside the immersive space, kept out of the view:
/// the scene root, the three ARKit anchor streams, one visualization per
/// tracked item, the ghost targets, and the guidance engine's wiring. The
/// view owns one of these per entry into the space and forwards its
/// lifecycle and phase changes here.
@Observable
final class ImmersiveSceneCoordinator {
    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "ImmersiveSceneCoordinator")

    /// The one entity every tracked item and ghost hangs off. A class-owned
    /// entity survives SwiftUI re-creating the view value; a `var` on the
    /// view struct would not.
    let root = Entity()

    private let guidance = GuidanceEngine()

    private var appState: AppState?
    private var objectVisualizations: [UUID: ObjectAnchorVisualization] = [:]
    private var ghostEntitiesByItemID: [String: Entity] = [:]
    private var ghostsAwaitingRemoval: [ObjectIdentifier: Entity] = [:]
    private var animationSubscription: EventSubscription?
    private var fingertipsByHand: [HandAnchor.Chirality: [SIMD3<Float>]] = [:]

    // MARK: - Lifecycle

    /// Called from the `RealityView` make closure: adopts the scene content
    /// and shows any ghosts already placed.
    func attach(appState: AppState,
                to content: RealityViewContent)
    {
        self.appState = appState
        content.add(root)

        // One subscription routes every finished exit animation to its
        // ghost's removal.
        animationSubscription = content.subscribe(to: AnimationEvents.PlaybackCompleted.self) { [weak self] event in
            guard let self,
                  let entity = event.playbackController.entity,
                  self.ghostsAwaitingRemoval.removeValue(forKey: ObjectIdentifier(entity)) != nil
            else {
                return
            }

            entity.removeFromParent()
        }

        guidance.attach(to: root)
        guidance.onPlacement = { [weak self] itemID in
            self?.appState?.demoSession.completePlacement(of: itemID)
        }

        syncGhostEntities()
    }

    /// Runs for the life of the immersive space: starts the providers, then
    /// drives the three anchor streams and loads the guidance audio side by
    /// side until the enclosing task is cancelled. Takes `appState` directly
    /// rather than reading what `attach` stored, because the make closure and
    /// this task fire in no guaranteed order.
    func run(appState: AppState) async {
        self.appState = appState

        guard let providers = await appState.startTracking() else { return }

        await withTaskGroup(of: Void.self) { group in
            // Concurrent with tracking: the audio only has to be ready by the
            // first `.guiding` phase, which is many steps away.
            group.addTask { await self.guidance.loadResources() }
            group.addTask { await self.processObjectAnchorUpdates(providers.objectTracking) }
            group.addTask { await self.processPlaneAnchorUpdates(providers.planeDetection) }
            group.addTask { await self.processHandAnchorUpdates(providers.handTracking) }
        }
    }

    /// The view is leaving the immersive space.
    func tearDown() {
        guidance.stop()
        guidance.onPlacement = nil
        animationSubscription?.cancel()
        animationSubscription = nil

        for visualization in objectVisualizations.values {
            visualization.entity.removeFromParent()
        }
        objectVisualizations.removeAll()

        for ghost in ghostEntitiesByItemID.values {
            ghost.removeFromParent()
        }
        ghostEntitiesByItemID.removeAll()
        ghostsAwaitingRemoval.removeAll()

        appState?.didLeaveImmersiveSpace()
    }

    // MARK: - Phase changes

    func handlePhaseChange(to newPhase: DemoPhase) {
        switch newPhase {
        case .guiding(let itemID):
            beginGuidance(for: itemID)
        case .idle, .connected, .surfacesReady, .calibrated, .placingGhosts, .complete:
            guidance.stop()
        }
    }

    /// The real item sits there now, so its ghost animates away. The success
    /// chime has already played; placement is recorded on its completion.
    func handlePlacedItems(_ placedItemIDs: Set<String>) {
        for itemID in placedItemIDs {
            animateGhostExit(itemID: itemID)
        }
    }

    // MARK: - Anchor streams

    private func processObjectAnchorUpdates(_ objectTracking: ObjectTrackingProvider) async {
        for await anchorUpdate in objectTracking.anchorUpdates {
            let anchor = anchorUpdate.anchor
            let id = anchor.id

            switch anchorUpdate.event {
            case .added:
                guard let loadedItem = appState?.referenceObjectLoader.loadedItem(forReferenceObjectID: anchor.referenceObject.id)
                else {
                    logger.error("No catalog item for reference object \(anchor.referenceObject.name, privacy: .public)")
                    continue
                }

                guard let model = loadedItem.usdzEntity
                else {
                    // Logged at load time; nothing to draw for it.
                    continue
                }

                let visualization = ObjectAnchorVisualization(for: anchor,
                                                              item: loadedItem.item,
                                                              withModel: model)
                objectVisualizations[id] = visualization
                root.addChild(visualization.entity)

                feedGuidanceAndCalibration(with: anchor,
                                           visualization: visualization)
            case .updated:
                guard let visualization = objectVisualizations[id] else { continue }

                visualization.update(with: anchor)
                feedGuidanceAndCalibration(with: anchor,
                                           visualization: visualization)
            case .removed:
                // High-frame-rate items hit this immediately when the object
                // leaves view; default-rate items keep their anchor briefly.
                // Either way, tear the visualization down and tell guidance
                // its target is gone.
                if let visualization = objectVisualizations[id] {
                    if visualization.item.id == DemoItemCatalog.calibrationItemID {
                        appState?.demoSession.updateBeaconPose(nil)
                    }
                    guidance.detachObject(for: visualization.item.id)
                    visualization.entity.removeFromParent()
                }
                objectVisualizations.removeValue(forKey: id)
            }
        }
    }

    private func processPlaneAnchorUpdates(_ planeDetection: PlaneDetectionProvider) async {
        for await anchorUpdate in planeDetection.anchorUpdates {
            switch anchorUpdate.event {
            case .added, .updated:
                appState?.demoSession.updatePlane(anchorUpdate.anchor)
            case .removed:
                appState?.demoSession.removePlane(withID: anchorUpdate.anchor.id)
            }
        }
    }

    private func processHandAnchorUpdates(_ handTracking: HandTrackingProvider) async {
        for await anchorUpdate in handTracking.anchorUpdates {
            let anchor = anchorUpdate.anchor

            switch anchorUpdate.event {
            case .added, .updated:
                fingertipsByHand[anchor.chirality] = anchor.fingertipPositions
            case .removed:
                fingertipsByHand.removeValue(forKey: anchor.chirality)
            }

            guidance.updateHands(fingertipsByHand)
        }
    }

    // MARK: - Guidance wiring

    private func feedGuidanceAndCalibration(with anchor: ObjectAnchor,
                                            visualization: ObjectAnchorVisualization)
    {
        // The calibration object reports where this device sees it.
        if visualization.item.id == DemoItemCatalog.calibrationItemID {
            appState?.demoSession.updateBeaconPose(anchor.isTracked ? anchor.originFromAnchorTransform : nil)
        }

        guard visualization.item.id == guidance.targetItemID else { return }

        guidance.updateObject(itemID: visualization.item.id,
                              transform: anchor.originFromAnchorTransform,
                              boundsCenter: visualization.boundsCenter,
                              boundsExtent: visualization.boundsExtent,
                              isTracked: anchor.isTracked)
    }

    private func beginGuidance(for itemID: String) {
        // Both devices bundle the same models and the iPhone only lets an
        // item with a model be dragged, so a guided item always has a ghost
        // here. If that invariant ever breaks, say so loudly rather than
        // guide toward nothing.
        guard let ghostEntity = ghostEntitiesByItemID[itemID]
        else {
            logger.fault("No ghost entity for \(itemID, privacy: .public); guidance cannot start.")

            return
        }

        guidance.beginGuidance(for: itemID,
                               ghostEntity: ghostEntity)

        // The object may already be tracked - give the engine its current
        // pose now instead of waiting for the next anchor event, which for a
        // default-rate object can be seconds away.
        if let visualization = objectVisualizations.values.first(where: { $0.item.id == itemID }) {
            guidance.updateObject(itemID: itemID,
                                  transform: visualization.entity.transform.matrix,
                                  boundsCenter: visualization.boundsCenter,
                                  boundsExtent: visualization.boundsExtent,
                                  isTracked: visualization.entity.isEnabled)
        }
    }

    // MARK: - Ghosts

    /// Mirrors the session's ghost poses into the scene: a semitransparent
    /// clone of each item's training mesh, sitting where the iPhone dropped
    /// it. Placed items are skipped; their ghosts have animated away.
    func syncGhostEntities() {
        guard let appState else { return }

        let ghostPoses = appState.demoSession.ghostPosesByItemID
        let placedItemIDs = appState.demoSession.placedItemIDs

        for (itemID, entity) in ghostEntitiesByItemID where ghostPoses[itemID] == nil {
            entity.removeFromParent()
            ghostEntitiesByItemID.removeValue(forKey: itemID)
        }

        for (itemID, pose) in ghostPoses
        where ghostEntitiesByItemID[itemID] == nil && !placedItemIDs.contains(itemID) {
            guard let loadedItem = appState.referenceObjectLoader.loadedItem(id: itemID),
                  let model = loadedItem.usdzEntity
            else {
                logger.error("No training mesh for \(itemID, privacy: .public); cannot show its ghost.")
                continue
            }

            // A ghost of the real item: the training model with its own
            // materials, lit by the room like anything else in the space,
            // made translucent. A person sees exactly what goes where. The
            // solid item color is the Part 1 convention for the overlays on
            // tracked objects, not for ghosts.
            let ghost = model.clone(recursive: true)
            ghost.components.set(OpacityComponent(opacity: 0.4))

            // Grow in where it landed rather than popping into existence.
            let restingTransform = Transform(matrix: pose)
            var entrance = restingTransform
            entrance.scale = SIMD3<Float>(repeating: 0.01)
            ghost.transform = entrance
            root.addChild(ghost)
            ghost.move(to: restingTransform,
                       relativeTo: nil,
                       duration: 0.3,
                       timingFunction: .easeOut)
            ghostEntitiesByItemID[itemID] = ghost
        }
    }

    /// Fades a placed ghost out: an ease-in scale-down, with the entity
    /// removed when the animation reports completion.
    private func animateGhostExit(itemID: String) {
        guard let ghost = ghostEntitiesByItemID.removeValue(forKey: itemID) else { return }

        var vanished = ghost.transform
        vanished.scale = SIMD3<Float>(repeating: 0.001)

        ghostsAwaitingRemoval[ObjectIdentifier(ghost)] = ghost
        ghost.move(to: vanished,
                   relativeTo: ghost.parent,
                   duration: 0.3,
                   timingFunction: .easeIn)
    }
}
#endif
