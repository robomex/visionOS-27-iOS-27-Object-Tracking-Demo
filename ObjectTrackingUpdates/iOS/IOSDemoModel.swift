//
//  IOSDemoModel.swift
//  ObjectTrackingUpdates
//

#if os(iOS)
import ARKit
import Foundation
import OSLog
import PeerConnection
import RealityKit
import simd
import SwiftUI

/// The iPhone's side of the cross-device demo: reference-object loading, the
/// listener the Vision Pro connects to, the mirrored phase, the meal
/// selection, and the ghost drop. The Vision Pro is the phase authority;
/// this device mirrors every transition it broadcasts.
@Observable
final class IOSDemoModel {
    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "IOSDemoModel")

    enum ItemStatus: Equatable {
        case pendingTraining
        case failed(String)
        case loaded
        case tracked
    }

    /// Handed the live `RealityView` content and scene root by the view, so
    /// the tracking coordinator can add anchors and the model can raycast
    /// screen points and manage ghosts.
    final class SceneProxy {
        var content: RealityViewCameraContent?
        let root = Entity()
    }

    let connection = PeerMessagingController<Server<DemoMessage>>()
    let sceneProxy = SceneProxy()

    /// The tracking coordinator, once the camera view creates it: the
    /// placement raycasts and the tracking reset go through it.
    @ObservationIgnored weak var trackingCoordinator: IOSTrackingCoordinator?

    private(set) var phase = DemoPhase.idle

    /// Whether the Vision Pro is in its immersive space and tracking. A
    /// stopped Vision Pro and one mapping surfaces are both the `.connected`
    /// phase, so the stage capsule reads this to tell them apart.
    private(set) var visionProIsTracking = true

    /// Set when the device or its authorizations can't run the session.
    private(set) var sessionUnavailableReason: String?

    private(set) var statusByItemID: [String: ItemStatus] = [:]
    private(set) var referenceObjectsByItemID: [String: ARReferenceObject] = [:]

    /// The USDZ embedded in each item's reference object - the mesh Create ML
    /// trained on: the tinted overlay on the tracked object, and for meal
    /// items also the ghost and the carousel's rotating preview.
    private(set) var modelsByItemID: [String: Entity] = [:]

    private(set) var visionFromPhone: simd_float4x4?
    private(set) var surfacePlanes: [SurfacePlane] = []

    /// The items whose ghosts were dragged out, in drop order. Dragging IS
    /// choosing the meal, and this order becomes the guidance order.
    private(set) var mealItemIDsInDropOrder: [String] = []

    /// Where each settled ghost sits in this device's world. A settled item
    /// can't be dropped again; this is what says so.
    private(set) var ghostPosesByItemID: [String: simd_float4x4] = [:]
    private(set) var placedItemIDs: Set<String> = []

    private var surfaceOverlayEntities: [Entity] = []
    private var ghostEntitiesByItemID: [String: Entity] = [:]
    /// Ghosts mid fade-out. Kept here so a reset during the fade can still
    /// remove them from the scene.
    private var exitingGhostsByItemID: [String: Entity] = [:]
    /// The ghost mid-drag: real-scale, following the finger across real
    /// surfaces by raycast until it is dropped or the drag ends.
    private var draggingGhost: DraggingGhost?
    private var ghostExitSubscriptionsByItemID: [String: EventSubscription] = [:]
    private var receiveTask: Task<Void, Never>?

    private var lastBeaconSendInstant: ContinuousClock.Instant?
    /// When the last message of any kind arrived from the Vision Pro.
    private var lastReceivedInstant: ContinuousClock.Instant?
    private var heartbeatTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    var phoneFromVision: simd_float4x4? {
        visionFromPhone?.inverse
    }

    /// The item whose ghost is mid-drag, so its tile can show it.
    var draggingItemID: String? {
        draggingGhost?.itemID
    }

    init() {
        receiveTask = Task { [weak self] in
            guard let stream = self?.connection.incomingMessages else { return }

            for await message in stream {
                self?.receive(message)
            }
        }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: DemoHeartbeat.interval)
                self?.pulse()
            }
        }
    }

    isolated deinit {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
    }

    // MARK: - Asset loading

    /// Called exactly once, from the session coordinator's start - the view
    /// task that creates the coordinator is the app's one idempotency point.
    func loadAssets() async {
        // Every file at once, as the visionOS loader does. The model loads
        // are asynchronous and overlap; the archive reads are synchronous
        // and take their turn on the main actor.
        await withTaskGroup(of: Void.self) { group in
            for item in DemoItemCatalog.items {
                guard let url = Bundle.main.url(forResource: item.fileName,
                                                withExtension: "referenceobject")
                else {
                    statusByItemID[item.id] = .pendingTraining
                    continue
                }

                group.addTask {
                    await self.loadAsset(for: item, at: url)
                }
            }
        }
    }

    private func loadAsset(for item: DemoItem,
                           at url: URL) async
    {
        let referenceObject: ARReferenceObject
        do {
            referenceObject = try ARReferenceObject(archiveURL: url)
        } catch {
            logger.error("Failed to load the reference object for \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
            statusByItemID[item.id] = .failed(error.localizedDescription)

            return
        }

        referenceObjectsByItemID[item.id] = referenceObject
        statusByItemID[item.id] = .loaded

        // Every item's mesh: the USDZ the object was trained on, embedded
        // in the reference object file and read through iOS 27's
        // `ARReferenceObject.usdzFile`. Nothing separate ships alongside.
        guard let modelURL = referenceObject.usdzFile else {
            logger.error("The reference object for \(item.id, privacy: .public) embeds no USDZ; it tracks with no overlay and its tile can't be dragged.")

            return
        }

        do {
            modelsByItemID[item.id] = try await Entity(contentsOf: modelURL)
            logger.log("Loaded the model for \(item.id, privacy: .public).")
        } catch {
            logger.error("Failed to load the model for \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The load-time lever on iOS: assigning a reference object to
    /// `trackingObjects` tracks it at the full frame rate of the session's
    /// `videoFormat` - the iOS equivalent of `highFrameRateTrackingEnabled`
    /// on visionOS. `detectionObjects` is the low-rate path.
    var trackingObjects: Set<ARReferenceObject> {
        objects(matching: { $0.usesHighFrameRateTracking })
    }

    var detectionObjects: Set<ARReferenceObject> {
        objects(matching: { !$0.usesHighFrameRateTracking })
    }

    private func objects(matching predicate: (DemoItem) -> Bool) -> Set<ARReferenceObject> {
        var objects = Set<ARReferenceObject>()
        for item in DemoItemCatalog.items where predicate(item) {
            if let object = referenceObjectsByItemID[item.id] {
                objects.insert(object)
            }
        }

        return objects
    }

    func item(for referenceObject: ARReferenceObject) -> DemoItem? {
        // Match by instance first; fall back to the archive's name in case
        // ARKit hands back a copy of the loaded object. Two unnamed archives
        // must not match each other.
        let itemID = referenceObjectsByItemID.first { $0.value === referenceObject }?.key
            ?? referenceObject.name.flatMap { name in
                referenceObjectsByItemID.first { $0.value.name == name }?.key
            }

        guard let itemID else { return nil }

        return DemoItemCatalog.item(id: itemID)
    }

    /// Called from every anchor update - per frame for full-rate objects -
    /// so only write when the status actually changes; every write to an
    /// observed property re-renders the status UI.
    func setTracked(_ isTracked: Bool,
                    for item: DemoItem)
    {
        let status: ItemStatus = isTracked ? .tracked : .loaded

        guard statusByItemID[item.id] != status else { return }

        statusByItemID[item.id] = status
    }

    func reportSessionUnavailable(_ reason: String) {
        sessionUnavailableReason = reason
    }

    /// The meal's items go by course; the drop order names them.
    func courseDescription(for itemID: String) -> String {
        MealCourse.description(for: itemID,
                               in: mealItemIDsInDropOrder)
    }

    // MARK: - Connection lifecycle

    /// Starts advertising for the Vision Pro. Nobody taps anything: this runs
    /// whenever the app becomes active, and the controller's own loop keeps
    /// the listener up so the Vision Pro can reconnect after any drop while it
    /// stays active.
    func startConnecting() {
        connection.start(with: NetworkServiceConstants.fixedPairingID)
    }

    /// Stops advertising and drops the connection. Called when the app goes to
    /// the background, so the Vision Pro sees a clean drop rather than a
    /// zombie connection, and this side doesn't listen while suspended.
    func stopConnecting() {
        connection.stop()
    }

    /// Called by the main view's `onChange`, which fires once per actual
    /// state change for as long as that view is on screen.
    func connectionStateDidChange() {
        switch connection.connectionState {
        case .connected:
            lastReceivedInstant = clock.now
            send(.hello)
        case .waitingForConnection, .stopped, .tlsFailed:
            // The Vision Pro's connection dropped or never formed. The
            // listener stays up under the controller's loop, so this side
            // only voids the stale demo state and waits for it to reconnect.
            resetToDisconnected()
        case .connecting:
            break
        }
    }

    // MARK: - Meal selection

    /// An item's tile is usable only when it fully loaded: its reference
    /// object tracks, and its bundled USDZ exists for the ghost.
    /// Every tracked item back to merely loaded: after a tracking reset the
    /// anchors are gone, and nothing reports them untracked.
    func markAllUntracked() {
        for (itemID, status) in statusByItemID where status == .tracked {
            statusByItemID[itemID] = .loaded
        }
    }

    func isSelectable(_ item: DemoItem) -> Bool {
        let loaded = statusByItemID[item.id] == .loaded || statusByItemID[item.id] == .tracked

        return loaded && modelsByItemID[item.id] != nil
    }

    /// Clears the meal and ghosts on both devices and returns to the
    /// ghost-placing stage, so a different 3 can be dragged.
    func sendReset() {
        send(.reset)
        clearMealAndGhosts()
    }

    /// Forgets the Vision Pro's certificate and advertises again. The repair
    /// for a TLS failure after either app was reinstalled; run it on both
    /// devices.
    func forgetPairedDevice() {
        CertificateTrustManager.forgetPairedDevice()
        // Drop the live connection; the `.stopped` reaction resets the demo
        // and reconnects, this time re-trusting the peer's certificate.
        connection.disconnect()
    }

    /// The heartbeat: sent on a timer while connected, and the moment to
    /// check that the Vision Pro is still sending its own. A silent peer is a
    /// dead peer, so drop the connection and let the reconnect path find it.
    private func pulse() {
        guard connection.connectionState == .connected else { return }

        if let lastReceivedInstant,
           clock.now - lastReceivedInstant > DemoHeartbeat.livenessTimeout {
            logger.log("No message from the Vision Pro in the liveness window; dropping to reconnect.")
            connection.disconnect()

            return
        }

        send(.heartbeat)
    }

    // MARK: - Calibration

    /// Called by the session coordinator on every tracked update of the
    /// calibration object. Sends at most thirty samples a second while the
    /// calibration window is open.
    func reportBeaconSample(_ pose: simd_float4x4) {
        guard phase == .surfacesReady else { return }

        // ~30 Hz, whatever the frame rate.
        let now = clock.now
        if let lastBeaconSendInstant,
           now - lastBeaconSendInstant < .milliseconds(33) {
            return
        }
        lastBeaconSendInstant = now

        send(.beaconSample(TransformPayload(pose)))
    }

    // MARK: - Ghost drop

    /// Whether this item's tile can be dragged out of the carousel right
    /// now. Dragging IS choosing: any loaded meal item is draggable until
    /// three ghosts are down.
    func canDropGhost(for itemID: String) -> Bool {
        phase == .placingGhosts
            && ghostPosesByItemID[itemID] == nil
            && modelsByItemID[itemID] != nil
            && mealItemIDsInDropOrder.count < 3
            && DemoItemCatalog.item(id: itemID)?.isMealItem == true
    }

    // MARK: - Ghost placement

    /// A tile lifted from the carousel: a real-scale ghost of the item enters
    /// the scene, hidden until it first lands on a surface.
    func beginGhostDrag(itemID: String) {
        guard canDropGhost(for: itemID),
              let model = modelsByItemID[itemID]
        else {
            logger.log("Drag ignored for \(itemID, privacy: .public): not droppable now (phase \(String(describing: self.phase), privacy: .public), has model \(self.modelsByItemID[itemID] != nil, privacy: .public), placed \(self.mealItemIDsInDropOrder.count, privacy: .public)).")

            return
        }

        cancelGhostDrag()

        let ghost = Self.makeGhost(from: model)
        ghost.isEnabled = false
        sceneProxy.root.addChild(ghost)
        draggingGhost = DraggingGhost(itemID: itemID,
                                      entity: ghost)
        logger.log("Drag began for \(itemID, privacy: .public).")
    }

    /// Moves the dragged ghost to where the finger's ray meets a real
    /// horizontal surface - Apple's placement pattern: one raycast per move,
    /// the object set to the hit's world transform. Off any surface the ghost
    /// hides rather than float. Returns whether it is on a surface, which is
    /// whether a drop here would place it.
    @discardableResult
    func moveGhostDrag(to point: CGPoint) -> Bool {
        guard var dragging = draggingGhost else { return false }

        guard let hit = raycastToSurface(through: point) else {
            dragging.entity.isEnabled = false
            dragging.lastHit = nil
            draggingGhost = dragging

            return false
        }

        dragging.entity.setTransformMatrix(hit.worldTransform, relativeTo: nil)
        dragging.entity.isEnabled = true
        dragging.lastHit = hit.worldTransform
        draggingGhost = dragging

        return true
    }

    /// The finger left the camera view mid-drag; the ghost waits, hidden, in
    /// case it comes back.
    func hideGhostDrag() {
        draggingGhost?.entity.isEnabled = false
    }

    /// The drag ended without a drop on the camera view.
    func cancelGhostDrag() {
        guard let dragging = draggingGhost else { return }

        dragging.entity.removeFromParent()
        draggingGhost = nil
        logger.log("Drag for \(dragging.itemID, privacy: .public) ended without a placement.")
    }

    /// Places the ghost where the drop point's ray meets a real horizontal
    /// surface, and the meal's drop order grows by one. Works with or without
    /// a drag in flight (the drag session can report its end before the drop
    /// lands here), and a drop off any surface places nothing.
    func dropGhost(itemID: String,
                   at point: CGPoint)
    {
        guard canDropGhost(for: itemID),
              let model = modelsByItemID[itemID]
        else {
            logger.log("Drop ignored for \(itemID, privacy: .public): not droppable now (phase \(String(describing: self.phase), privacy: .public), has model \(self.modelsByItemID[itemID] != nil, privacy: .public), placed \(self.mealItemIDsInDropOrder.count, privacy: .public)).")
            cancelGhostDrag()

            return
        }

        let inFlight = draggingGhost.flatMap { $0.itemID == itemID ? $0 : nil }
        guard let worldTransform = raycastToSurface(through: point)?.worldTransform ?? inFlight?.lastHit
        else {
            logger.log("Drop for \(itemID, privacy: .public): no real surface under the drop point.")
            cancelGhostDrag()

            return
        }

        // Ghosts can only be dropped after calibration, so the transform is
        // always here; nothing is placed if it somehow is not.
        guard let visionFromPhone
        else {
            logger.fault("A ghost was dropped without a calibration.")
            cancelGhostDrag()

            return
        }

        let ghost: Entity
        if let inFlight {
            ghost = inFlight.entity
            draggingGhost = nil
        } else {
            cancelGhostDrag()
            ghost = Self.makeGhost(from: model)
            sceneProxy.root.addChild(ghost)
        }
        ghost.setTransformMatrix(worldTransform, relativeTo: nil)
        ghost.isEnabled = true
        ghostEntitiesByItemID[itemID] = ghost

        let pose = ghost.transformMatrix(relativeTo: nil)
        ghostPosesByItemID[itemID] = pose
        mealItemIDsInDropOrder.append(itemID)
        logger.log("Placed the ghost for \(itemID, privacy: .public): \(self.mealItemIDsInDropOrder.count, privacy: .public) of 3.")

        send(.ghostPlaced(itemID: itemID,
                          pose: TransformPayload(visionFromPhone * pose)))

        // The third ghost is down: the drop order IS the meal. Sending it
        // confirms the selection and starts the guidance on the Vision Pro.
        if mealItemIDsInDropOrder.count == 3 {
            send(.mealSelection(mealItemIDsInDropOrder))
        }
    }

    /// A ghost of the real item, at its real size: the model's own albedo
    /// texture, unlit (so it needs no environment probe to render) and
    /// translucent. A person sees exactly what will land there.
    private static func makeGhost(from model: Entity) -> Entity {
        let ghost = model.clone(recursive: true)
        ghost.convertMaterialsToUnlitPreservingTextures()
        ghost.components.set(OpacityComponent(opacity: 0.4))

        return ghost
    }

    /// The real horizontal surface under a point in the camera view, if any:
    /// the view's ray through that point - ARKit world space, since the
    /// camera is spatially tracked - cast by the tracking session against an
    /// estimated plane, which hits a detected plane when there is one and a
    /// feature-point estimate otherwise.
    private func raycastToSurface(through point: CGPoint) -> ARRaycastResult? {
        guard let content = sceneProxy.content,
              let ray = content.ray(through: point,
                                    in: .local,
                                    to: .scene)
        else {
            return nil
        }

        return trackingCoordinator?.raycastToHorizontalSurface(origin: ray.origin,
                                                               direction: ray.direction)
    }

    // MARK: - Incoming messages

    private func receive(_ message: DemoMessage) {
        // Any message, even a heartbeat, proves the Vision Pro is alive.
        lastReceivedInstant = clock.now

        switch message {
        case .hello:
            // Answer every hello with a hello. The Vision Pro drives the
            // phases, and it leaves its idle phase only when it receives
            // this. Because a reconnect can adopt a replacement connection
            // without the connection state changing, the greeting cannot
            // ride only on that state's edge - so it rides on the message
            // instead, and the handshake heals itself on every reconnect.
            // The Vision Pro acts on a hello only while idle, so this never
            // ping-pongs.
            send(.hello)
        case .phase(let newPhase):
            apply(newPhase)
        case .calibrationLock(let payload):
            visionFromPhone = payload.matrix
        case .surfaces(let planes):
            surfacePlanes = planes
            rebuildSurfaceOverlays()
        case .placementDone(let itemID):
            placedItemIDs.insert(itemID)
            // The real item sits there now - the ghost animates away.
            animateGhostExit(itemID: itemID)
        case .trackingActive(let active):
            visionProIsTracking = active
        case .heartbeat:
            break
        case .beaconSample, .mealSelection, .ghostPlaced, .reset:
            // The iPhone is the sender of these; arriving here means the
            // other device is misbehaving.
            logger.error("Ignoring a message the Vision Pro should never send: \(String(describing: message), privacy: .private)")
        }
    }

    private func apply(_ newPhase: DemoPhase) {
        // Any step back to a pre-calibration phase voids the shared frame and
        // everything placed in it: the Vision Pro drops to .connected when it
        // stops tracking, and to .surfacesReady on a recalibrate. In both the
        // transform, the meal, the ghosts, and the surfaces (placed through
        // the old transform) are stale; the fresh ones arrive after the next
        // calibration.
        if newPhase == .connected || newPhase == .surfacesReady {
            visionFromPhone = nil
            clearMealAndGhosts()
            surfacePlanes.removeAll()
            rebuildSurfaceOverlays()

            // A redo redoes BOTH sides. The Vision Pro's world is fresh (it
            // stopped tracking) or its lock is distrusted (recalibrate); this
            // device's tracking may have drifted or lost objects meanwhile,
            // so it restarts from scratch too, and every object has to be
            // re-detected before it can count again.
            if phase.isPastConnected {
                trackingCoordinator?.resetTracking()
                markAllUntracked()
            }
        }

        phase = newPhase
    }

    // MARK: - State management

    /// Queues a message for the Vision Pro. The controller sends in order,
    /// which the third ghost's `ghostPlaced` followed by `mealSelection`
    /// depends on.
    private func send(_ message: DemoMessage) {
        connection.send(message)
    }

    /// Fades a placed ghost out: an ease-in scale-down, with the entity
    /// removed when the animation reports completion.
    private func animateGhostExit(itemID: String) {
        guard let ghost = ghostEntitiesByItemID.removeValue(forKey: itemID),
              let content = sceneProxy.content
        else {
            return
        }

        exitingGhostsByItemID[itemID] = ghost

        var vanished = ghost.transform
        vanished.scale = SIMD3<Float>(repeating: 0.001)

        ghostExitSubscriptionsByItemID[itemID] = content.subscribe(to: AnimationEvents.PlaybackCompleted.self,
                                                                   on: ghost) { [weak self] _ in
            ghost.removeFromParent()
            self?.exitingGhostsByItemID.removeValue(forKey: itemID)
            self?.ghostExitSubscriptionsByItemID.removeValue(forKey: itemID)?.cancel()
        }

        ghost.move(to: vanished,
                   relativeTo: ghost.parent,
                   duration: 0.3,
                   timingFunction: .easeIn)
    }

    private func rebuildSurfaceOverlays() {
        for entity in surfaceOverlayEntities {
            entity.removeFromParent()
        }
        surfaceOverlayEntities.removeAll()

        guard let phoneFromVision else { return }

        for plane in surfacePlanes {
            // A faint tint showing what the Vision Pro has mapped, without
            // hiding the table under it. Display only - ghosts are placed by
            // this device's own raycasts. A material's own alpha does not
            // blend here (it renders opaque); OpacityComponent (set below) is
            // the reliable fade. An X-Y rectangle in the extent's own frame:
            // that frame's transform lays it flat and turns it to fit the
            // plane, exactly as the Vision Pro sees it.
            let overlay = ModelEntity(mesh: .generatePlane(width: plane.width,
                                                           height: plane.height),
                                      materials: [UnlitMaterial(color: UIColor.systemCyan)])
            overlay.components.set(OpacityComponent(opacity: 0.15))
            overlay.transform = Transform(matrix: phoneFromVision * plane.pose.matrix)
            sceneProxy.root.addChild(overlay)
            surfaceOverlayEntities.append(overlay)
        }
    }

    /// Removes every ghost, settling or fading, and forgets the meal.
    private func clearMealAndGhosts() {
        for entity in ghostEntitiesByItemID.values {
            entity.removeFromParent()
        }
        ghostEntitiesByItemID.removeAll()
        for entity in exitingGhostsByItemID.values {
            entity.removeFromParent()
        }
        exitingGhostsByItemID.removeAll()
        ghostPosesByItemID.removeAll()
        mealItemIDsInDropOrder.removeAll()
        cancelGhostDrag()
        for subscription in ghostExitSubscriptionsByItemID.values {
            subscription.cancel()
        }
        ghostExitSubscriptionsByItemID.removeAll()
        placedItemIDs.removeAll()
    }

    private func resetToDisconnected() {
        clearMealAndGhosts()
        visionFromPhone = nil
        surfacePlanes.removeAll()
        rebuildSurfaceOverlays()
        // Assume the Vision Pro is tracking until it says otherwise, so the
        // next connection doesn't briefly read as stopped.
        visionProIsTracking = true
        phase = .idle
    }

    private struct DraggingGhost {
        let itemID: String
        let entity: Entity
        /// The last surface the ghost sat on, so a drop that lands a hair off
        /// the surface still places it where it was just shown.
        var lastHit: simd_float4x4?
    }
}

private extension DemoPhase {
    /// The phases in which this device holds spatial state tied to the Vision
    /// Pro's current world: the calibration window and everything after it.
    var isPastConnected: Bool {
        switch self {
        case .idle, .connected:
            return false
        case .surfacesReady, .calibrated, .placingGhosts, .guiding, .complete:
            return true
        }
    }
}

extension Entity {
    /// Converts every `PhysicallyBasedMaterial` in this hierarchy to an
    /// `UnlitMaterial` that keeps the albedo texture. Unlit materials render
    /// without an environment probe, so the entity is safe to draw in any
    /// scene - the AR view's ghosts and the carousel's previews alike.
    func convertMaterialsToUnlitPreservingTextures() {
        if var modelComponent = components[ModelComponent.self] {
            modelComponent.materials = modelComponent.materials.map { material in
                guard let pbr = material as? PhysicallyBasedMaterial else { return material }

                var unlit = UnlitMaterial()
                if let texture = pbr.baseColor.texture {
                    unlit.color = .init(tint: .white,
                                        texture: texture)
                } else {
                    unlit.color = .init(tint: pbr.baseColor.tint)
                }

                return unlit
            }
            components.set(modelComponent)
        }

        for child in children {
            child.convertMaterialsToUnlitPreservingTextures()
        }
    }
}
#endif
