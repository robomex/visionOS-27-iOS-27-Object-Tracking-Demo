//
//  DemoSessionController.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import ARKit
import Foundation
import OSLog
import PeerConnection
import simd

/// The Vision Pro's side of the cross-device demo: the connection to the
/// iPhone, the calibration solve, the table-surface sync, and the phase
/// state machine both devices follow. The Vision Pro is the authority - it
/// broadcasts every phase transition and the iPhone mirrors it.
@Observable
final class DemoSessionController {
    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "DemoSessionController")

    /// How many paired observations the calibration solve uses, after the
    /// warm-up. At the iPhone's ~30 Hz send rate, about a second of pointing
    /// both devices at the calibration object.
    static let requiredCalibrationSamples = 30

    /// Samples discarded each time the object comes into view, while object
    /// tracking settles: it wobbles for a moment when the object first
    /// appears at the edge of a camera's view. About half a second.
    static let warmupSampleCount = 15

    /// Why calibration is still waiting, so it never waits silently.
    enum CalibrationStatus: Equatable {
        /// No sample from the iPhone yet: it doesn't see the object.
        case waitingForIPhone
        /// The iPhone sees the object; this device doesn't.
        case waitingForVisionPro
        /// Both see it; the window is filling.
        case steadying
    }

    /// The surface coverage that opens the calibration window: at least this
    /// much horizontal surface area, so ghosts have somewhere real to land.
    static let requiredSurfaceArea: Float = 0.2

    let connection = PeerMessagingController<Client<DemoMessage>>()

    private(set) var phase = DemoPhase.idle

    /// Whether the immersive space is open and this device is tracking. The
    /// iPhone can't tell that from the phase - a stopped Vision Pro and one
    /// mapping surfaces both read as `.connected` - so this rides its own
    /// message.
    private(set) var isTrackingActive = false

    /// Where the Vision Pro currently sees the calibration object, fed by the
    /// object-anchor loop. `nil` whenever the object isn't tracked.
    private(set) var latestBeaconPose: simd_float4x4?

    /// How full the calibration window is, 0 to 1.
    private(set) var calibrationProgress = 0.0

    /// What calibration is waiting for right now.
    private(set) var calibrationStatus = CalibrationStatus.waitingForIPhone

    private(set) var visionFromPhone: simd_float4x4?

    /// The horizontal surfaces currently known, by plane-anchor ID.
    private(set) var surfacePlanesByAnchorID: [UUID: SurfacePlane] = [:]

    /// The three items dragged out on the iPhone, in drop order, which is
    /// also the guidance order. Arrives in the `mealSelection` message after
    /// the third ghost settles.
    private(set) var mealItemIDs: [String] = []

    /// Ghost poses in the shared frame, per item.
    private(set) var ghostPosesByItemID: [String: simd_float4x4] = [:]

    private(set) var placedItemIDs: Set<String> = []

    private var calibrationPairs: [SharedFrameMath.SamplePair] = []
    private var warmupSamplesRemaining = DemoSessionController.warmupSampleCount

    /// When the iPhone's last calibration sample arrived. The iPhone sends
    /// only while it sees the object, so a pause in the stream is the iPhone
    /// losing it.
    private var lastBeaconSampleInstant: ContinuousClock.Instant?

    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// When the last message of any kind arrived from the iPhone. The
    /// liveness check measures silence against it.
    private var lastReceivedInstant: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// When the surface set was last sent to the iPhone. Plane updates arrive
    /// faster than the overlays need to change, so broadcasts are throttled.
    private var lastSurfaceBroadcast: ContinuousClock.Instant?
    private let surfaceBroadcastInterval = Duration.milliseconds(300)

    /// A plane change landed inside the throttle window and was not sent. If
    /// nothing follows it, the heartbeat sends it.
    private var surfacesChangedSinceBroadcast = false

    var guidedItemID: String? {
        guard case .guiding(let itemID) = phase else { return nil }

        return itemID
    }

    var hasSurfaceCoverage: Bool {
        surfacePlanesByAnchorID.values.reduce(Float(0)) { $0 + $1.width * $1.height } >= Self.requiredSurfaceArea
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

    // MARK: - Connection lifecycle

    /// Starts looking for the iPhone. Nobody taps anything: this runs whenever
    /// the app becomes active, and the controller's own loop reconnects after
    /// any drop while it stays active.
    func startConnecting() {
        connection.start(with: NetworkServiceConstants.fixedPairingID)
    }

    /// Stops looking for the iPhone and drops the connection. Called when the
    /// app goes to the background, so the iPhone sees a clean drop and this
    /// side doesn't browse while suspended.
    func stopConnecting() {
        connection.stop()
    }

    /// Called by the main window's `onChange`, which fires once per actual
    /// state change for as long as that window is open.
    func connectionStateDidChange() {
        switch connection.connectionState {
        case .connected:
            // The stream is up; say hello. The demo is connected once the
            // iPhone's hello arrives with a matching version. Start the
            // liveness clock so a peer that connects then dies is still
            // caught.
            lastReceivedInstant = clock.now
            send(.hello)
            // A fresh connection doesn't know this device's tracking state;
            // send it so the iPhone shows the right thing right away.
            send(.trackingActive(isTrackingActive))
        case .waitingForConnection, .stopped, .tlsFailed:
            // The connection dropped or never formed. The controller's loop
            // keeps looking, so this side only voids the stale demo state -
            // the calibration and everything placed in it belonged to the
            // session that just ended.
            resetToDisconnected()
        case .connecting:
            break
        }
    }

    /// Forgets the iPhone's certificate and looks for it again. The repair
    /// for a TLS failure after either app was reinstalled; run it on both
    /// devices.
    func forgetPairedDevice() {
        CertificateTrustManager.forgetPairedDevice()
        // Drop the live connection; the `.stopped` reaction resets the demo
        // and reconnects, this time re-trusting the peer's certificate.
        connection.disconnect()
    }

    /// The heartbeat: sent on a timer while connected, and the moment to
    /// check that the iPhone is still sending its own. A silent peer is a
    /// dead peer, so drop the connection and let the reconnect path find it.
    private func pulse() {
        guard connection.connectionState == .connected else { return }

        if let lastReceivedInstant,
           clock.now - lastReceivedInstant > DemoHeartbeat.livenessTimeout {
            logger.log("No message from the iPhone in the liveness window; dropping to reconnect.")
            connection.disconnect()

            return
        }

        send(.heartbeat)

        // Calibration: a heartbeat interval with no sample means the iPhone
        // lost the object. Say so, rather than leave the last reason standing.
        if phase == .surfacesReady,
           let lastBeaconSampleInstant,
           clock.now - lastBeaconSampleInstant > DemoHeartbeat.interval {
            calibrationStatus = .waitingForIPhone
        }

        // Surfaces: a change skipped by the throttle, with nothing after it.
        if surfacesChangedSinceBroadcast {
            broadcastSurfaces(force: true)
        }
    }

    // MARK: - Escape hatches

    /// The immersive space opened, so this device is tracking again. Tells the
    /// iPhone, which otherwise can't tell a mapping Vision Pro from a stopped
    /// one, both being the `.connected` phase.
    func trackingDidStart() {
        setTrackingActive(true)
    }

    /// Tracking stopped, because the immersive space closed - Stop Tracking,
    /// the app backgrounding, an authorization revoked, or a provider error.
    /// The Vision Pro's world frame is torn down; re-entering brings up a
    /// fresh one, so the calibration and everything placed in it are void and
    /// the surfaces belong to the old frame. Return to the connected but
    /// uncalibrated phase and tell the iPhone to do the same, so re-entry
    /// recalibrates from scratch. A dropped network resets on its own.
    func resetForStoppedTracking() {
        // Tracking stopped, whatever the phase, so the iPhone must hear it -
        // even from `.connected`, where the phase itself doesn't change.
        setTrackingActive(false)

        // The world frame went with the immersive space, and the anchor
        // streams simply end - no `.removed` events - so what they delivered
        // would otherwise linger: the last object pose would match against
        // fresh iPhone samples on re-entry, locking a garbage frame the
        // instant the object reappeared, and the planes would count toward
        // the next run's surface coverage and go out in its first surfaces
        // message, all at poses from a world that no longer exists. Whatever
        // the phase, both go.
        latestBeaconPose = nil
        surfacePlanesByAnchorID.removeAll()

        switch phase {
        case .idle, .connected:
            return
        case .surfacesReady, .calibrated, .placingGhosts, .guiding, .complete:
            clearCalibration()
            clearGhosts()
            clearMealSelection()
            transition(to: .connected)
        }
    }

    /// Redoes the frame sync without restarting the demo: back to the
    /// calibration window, reusing the same messages. Ghosts and the meal
    /// clear: the ghosts were placed through the old, distrusted transform,
    /// and the meal is just the drop order, so the items are dragged again
    /// after the new lock.
    func recalibrate() {
        guard visionFromPhone != nil else { return }

        clearCalibration()
        // Fresh observations on this side too; the iPhone resets its own
        // tracking on the phase step, so both sides start over.
        latestBeaconPose = nil
        clearMealSelection()
        clearGhosts()
        transition(to: .surfacesReady)
    }

    // MARK: - Anchor input

    /// Where this device currently sees the calibration object, or `nil` when
    /// it left view. Leaving view restarts the warm-up: tracking settles
    /// again when it comes back.
    func updateBeaconPose(_ pose: simd_float4x4?) {
        if pose == nil && latestBeaconPose != nil {
            warmupSamplesRemaining = Self.warmupSampleCount
        }
        latestBeaconPose = pose
    }

    func updatePlane(_ anchor: PlaneAnchor) {
        // The provider only delivers horizontal planes; any of them works as
        // a drop surface - a table, the floor, a seat - except a ceiling.
        // Anyone trying this demo should be able to play it on whatever
        // horizontal surface they have.
        guard anchor.surfaceClassification != .ceiling else { return }

        let extent = anchor.geometry.extent
        // The extent rectangle sits in its own frame inside the anchor:
        // `anchorFromExtentTransform` carries its in-plane yaw and center
        // offset (ARKit fits the rectangle to the plane's polygon, so both
        // are arbitrary per plane) plus the rotation that lays the extent's
        // X-Y rectangle flat. Sending the anchor transform alone dropped the
        // yaw and offset, and every overlay showed up spun by its own random
        // angle. Send the full extent frame; the iPhone draws an X-Y
        // rectangle in it, as Apple's plane samples do.
        let pose = anchor.originFromAnchorTransform * extent.anchorFromExtentTransform
        surfacePlanesByAnchorID[anchor.id] = SurfacePlane(pose: TransformPayload(pose),
                                                          width: extent.width,
                                                          height: extent.height)

        // Enough surface is mapped - open the calibration window.
        if phase == .connected && hasSurfaceCoverage {
            transition(to: .surfacesReady)
        }

        // Keep the iPhone's overlays current as the Vision Pro maps more of
        // the room. No-op until the frame is agreed (nothing to render yet).
        broadcastSurfaces()
    }

    func removePlane(withID anchorID: UUID) {
        guard surfacePlanesByAnchorID.removeValue(forKey: anchorID) != nil else { return }

        broadcastSurfaces()
    }

    /// Sends the current surface set to the iPhone. Only meaningful once the
    /// frame is agreed - before that the iPhone has no transform to place them
    /// with. Throttled unless `force`d (the first send, right after the lock).
    private func broadcastSurfaces(force: Bool = false) {
        guard visionFromPhone != nil
        else {
            // Nothing to render yet; the lock's own send carries whatever
            // mapped meanwhile.
            surfacesChangedSinceBroadcast = false

            return
        }

        if !force,
           let lastSurfaceBroadcast,
           clock.now - lastSurfaceBroadcast < surfaceBroadcastInterval {
            // Inside the window: skipped here, sent by the heartbeat if no
            // later change sends it first.
            surfacesChangedSinceBroadcast = true

            return
        }

        surfacesChangedSinceBroadcast = false
        lastSurfaceBroadcast = clock.now
        send(.surfaces(Array(surfacePlanesByAnchorID.values)))
    }

    // MARK: - Guidance callbacks

    /// Called by the guidance engine when the current item has sat within the
    /// placement threshold long enough.
    func completePlacement(of itemID: String) {
        guard guidedItemID == itemID else { return }

        placedItemIDs.insert(itemID)
        send(.placementDone(itemID: itemID))

        if let nextItemID = mealItemIDs.first(where: { !placedItemIDs.contains($0) }) {
            transition(to: .guiding(itemID: nextItemID))
        } else {
            transition(to: .complete)
        }
    }

    // MARK: - Incoming messages

    private func receive(_ message: DemoMessage) {
        // Any message, even a heartbeat, proves the iPhone is alive.
        lastReceivedInstant = clock.now

        switch message {
        case .hello:
            guard phase == .idle else { break }

            transition(to: .connected)
            // The surfaces may already be mapped from an earlier run.
            if hasSurfaceCoverage {
                transition(to: .surfacesReady)
            }
        case .beaconSample(let payload):
            recordBeaconSample(payload)
        case .mealSelection(let itemIDs):
            recordMealSelection(itemIDs)
        case .ghostPlaced(let itemID, let pose):
            recordGhost(itemID: itemID, pose: pose)
        case .heartbeat:
            break
        case .reset:
            switch phase {
            case .placingGhosts, .guiding, .complete:
                clearMealSelection()
                clearGhosts()
                transition(to: .placingGhosts)
            case .idle, .connected, .surfacesReady, .calibrated:
                // A reset that crossed a tracking stop on the wire: there is
                // no calibration to place ghosts in, and reopening placing
                // here would leave both devices there with no way forward.
                logger.log("Ignoring a reset in the \(String(describing: self.phase), privacy: .public) phase; nothing is placed.")
            }
        case .calibrationLock, .surfaces, .phase, .placementDone, .trackingActive:
            // The Vision Pro is the sender of these; arriving here means the
            // other device is misbehaving.
            logger.error("Ignoring a message the iPhone should never send: \(String(describing: message), privacy: .private)")
        }
    }

    private func recordBeaconSample(_ payload: TransformPayload) {
        // Samples only count while the calibration window is open and this
        // device also sees the object right now.
        guard phase == .surfacesReady else { return }

        // A pause in the stream means the iPhone lost the object and found it
        // again, and its tracking settles again too: restart the warm-up, as
        // this device does when its own view of the object comes back.
        let now = clock.now
        if let lastBeaconSampleInstant,
           now - lastBeaconSampleInstant > DemoHeartbeat.interval {
            warmupSamplesRemaining = Self.warmupSampleCount
        }
        lastBeaconSampleInstant = now

        guard let localPose = latestBeaconPose
        else {
            calibrationStatus = .waitingForVisionPro

            return
        }
        calibrationStatus = .steadying

        guard warmupSamplesRemaining == 0
        else {
            warmupSamplesRemaining -= 1

            return
        }

        calibrationPairs.append(SharedFrameMath.SamplePair(phonePose: payload.matrix,
                                                           visionPose: localPose))
        calibrationProgress = Double(calibrationPairs.count) / Double(Self.requiredCalibrationSamples)

        guard calibrationPairs.count >= Self.requiredCalibrationSamples else { return }

        guard let solved = SharedFrameMath.solveVisionFromPhone(calibrationPairs)
        else {
            clearCalibration()

            return
        }

        logger.log("Calibration locked on \(Self.requiredCalibrationSamples, privacy: .public) samples.")
        visionFromPhone = solved
        calibrationPairs.removeAll()
        calibrationProgress = 0
        send(.calibrationLock(TransformPayload(solved)))
        transition(to: .calibrated)

        // The frame is agreed; send the surfaces in it now, then keep them
        // current as the Vision Pro maps more of the room (updatePlane).
        broadcastSurfaces(force: true)
        transition(to: .placingGhosts)
    }

    /// The confirmation that all three ghosts are down, carrying the drop
    /// order. Guidance starts here.
    private func recordMealSelection(_ itemIDs: [String]) {
        guard phase == .placingGhosts,
              itemIDs.count == 3,
              itemIDs.allSatisfy({ DemoItemCatalog.item(id: $0)?.isMealItem == true }),
              itemIDs.allSatisfy({ ghostPosesByItemID[$0] != nil })
        else {
            logger.error("Ignoring an invalid meal selection: \(itemIDs, privacy: .public)")

            return
        }

        mealItemIDs = itemIDs

        if let firstItemID = itemIDs.first {
            transition(to: .guiding(itemID: firstItemID))
        }
    }

    private func recordGhost(itemID: String,
                             pose: TransformPayload)
    {
        // Dragging IS choosing: any meal item's ghost is welcome until three
        // are down. The meal-selection message follows the third.
        guard phase == .placingGhosts,
              DemoItemCatalog.item(id: itemID)?.isMealItem == true,
              ghostPosesByItemID[itemID] == nil,
              ghostPosesByItemID.count < 3
        else {
            logger.error("Ignoring a ghost for \(itemID, privacy: .public) outside the placing stage.")

            return
        }

        ghostPosesByItemID[itemID] = pose.matrix
    }

    // MARK: - State management

    private func transition(to newPhase: DemoPhase) {
        phase = newPhase
        send(.phase(newPhase))
    }

    /// Queues a message for the iPhone. The controller sends in order.
    private func send(_ message: DemoMessage) {
        connection.send(message)
    }

    /// Records this device's tracking state and tells the iPhone.
    private func setTrackingActive(_ active: Bool) {
        isTrackingActive = active
        send(.trackingActive(active))
    }

    private func clearCalibration() {
        calibrationPairs.removeAll()
        warmupSamplesRemaining = Self.warmupSampleCount
        lastBeaconSampleInstant = nil
        calibrationProgress = 0
        calibrationStatus = .waitingForIPhone
        visionFromPhone = nil
    }

    private func clearGhosts() {
        ghostPosesByItemID.removeAll()
        placedItemIDs.removeAll()
    }

    private func clearMealSelection() {
        mealItemIDs.removeAll()
    }

    private func resetToDisconnected() {
        clearCalibration()
        clearGhosts()
        clearMealSelection()
        // The surface planes survive - they're this device's own observation.
        phase = .idle
    }
}
#endif
