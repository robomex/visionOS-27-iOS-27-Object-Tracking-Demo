//
//  AppState.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import ARKit
import OSLog

/// The app's overall state on visionOS: authorization, session lifecycle, and
/// the three providers the demo runs together - object tracking for every
/// loaded item, plane detection for the table, and hand tracking for the
/// audio-guidance distance cues.
@Observable
final class AppState {
    static let immersiveSpaceIdentifier = "ObjectTracking"

    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "AppState")

    var isImmersiveSpaceOpened = false
    var providersStoppedWithError = false

    /// Whether PersonaCam floats the wearer's Persona in the field of view,
    /// so a recording shows their eyes are closed during placement. On by
    /// default; the toggle in the main window switches it off. Takes effect
    /// the next time tracking starts.
    var showsPersonaCam = true

    let referenceObjectLoader = ReferenceObjectLoader()
    let demoSession = DemoSessionController()

    private let arkitSession = ARKitSession()
    private var objectTracking: ObjectTrackingProvider?

    private(set) var objectTrackingStartedRunning = false
    private(set) var worldSensingAuthorizationStatus = ARKitSession.AuthorizationStatus.notDetermined
    private(set) var handTrackingAuthorizationStatus = ARKitSession.AuthorizationStatus.notDetermined

    var allRequiredAuthorizationsAreGranted: Bool {
        worldSensingAuthorizationStatus == .allowed && handTrackingAuthorizationStatus == .allowed
    }

    var allRequiredProvidersAreSupported: Bool {
        ObjectTrackingProvider.isSupported && PlaneDetectionProvider.isSupported && HandTrackingProvider.isSupported
    }

    var canEnterImmersiveSpace: Bool {
        allRequiredAuthorizationsAreGranted && allRequiredProvidersAreSupported
    }

    func didEnterImmersiveSpace() {
        isImmersiveSpaceOpened = true

        // The Vision Pro is tracking again; tell the iPhone so it stops
        // showing the stopped state.
        demoSession.trackingDidStart()
    }

    func didLeaveImmersiveSpace() {
        // Stop the session; the providers that just ran in the immersive
        // space are in a paused state and aren't needed anymore. When a
        // person reenters the immersive space, run new providers. The
        // running flag resets here as well as on the session's own stopped
        // event, so re-entry never reads a stale "starting" state.
        arkitSession.stop()
        objectTracking = nil
        objectTrackingStartedRunning = false
        isImmersiveSpaceOpened = false

        // The world frame is gone with the session, so the shared calibration
        // and everything placed in it are stale. Reset to recalibrate on the
        // next entry, and tell the iPhone.
        demoSession.resetForStoppedTracking()
    }

    /// Runs the three providers in one session: a single object-tracking
    /// provider covering every loaded item (eight objects fit the
    /// 10-per-session cap), horizontal plane detection for the table, and
    /// hand tracking for the fingertip distance cues.
    func startTracking() async -> (objectTracking: ObjectTrackingProvider,
                                   planeDetection: PlaneDetectionProvider,
                                   handTracking: HandTrackingProvider)?
    {
        let referenceObjects = referenceObjectLoader.loadedItems.map(\.referenceObject)

        guard !referenceObjects.isEmpty else { return nil }

        // Run new providers every time when entering the immersive space.
        let objectTracking = ObjectTrackingProvider(referenceObjects: referenceObjects)
        let planeDetection = PlaneDetectionProvider(alignments: [.horizontal])
        let handTracking = HandTrackingProvider()
        do {
            try await arkitSession.run([objectTracking, planeDetection, handTracking])
        } catch {
            logger.error("Error running the ARKit session: \(String(describing: error), privacy: .public)")

            return nil
        }
        self.objectTracking = objectTracking

        return (objectTracking, planeDetection, handTracking)
    }

    func requestAuthorizations() async {
        let authorizationResult = await arkitSession.requestAuthorization(for: [.worldSensing, .handTracking])
        worldSensingAuthorizationStatus = authorizationResult[.worldSensing] ?? .notDetermined
        handTrackingAuthorizationStatus = authorizationResult[.handTracking] ?? .notDetermined
    }

    func queryAuthorizations() async {
        let authorizationResult = await arkitSession.queryAuthorization(for: [.worldSensing, .handTracking])
        worldSensingAuthorizationStatus = authorizationResult[.worldSensing] ?? .notDetermined
        handTrackingAuthorizationStatus = authorizationResult[.handTracking] ?? .notDetermined
    }

    func monitorSessionEvents() async {
        for await event in arkitSession.events {
            switch event {
            case .dataProviderStateChanged(let providers, let newState, let error):
                switch newState {
                case .initialized, .paused:
                    break
                case .running:
                    guard objectTrackingStartedRunning == false,
                          let objectTracking,
                          providers.contains(where: { $0 === objectTracking })
                    else {
                        continue
                    }

                    objectTrackingStartedRunning = true
                case .stopped:
                    guard objectTrackingStartedRunning == true,
                          let objectTracking,
                          providers.contains(where: { $0 === objectTracking })
                    else {
                        continue
                    }

                    objectTrackingStartedRunning = false
                    if let error {
                        logger.error("An ARKit session error occurred: \(String(describing: error), privacy: .public)")
                        providersStoppedWithError = true
                    }
                @unknown default:
                    break
                }
            case .authorizationChanged(let type, let status):
                switch type {
                case .worldSensing:
                    worldSensingAuthorizationStatus = status
                case .handTracking:
                    handTrackingAuthorizationStatus = status
                default:
                    break
                }
            default:
                logger.debug("An unhandled ARKit session event occurred: \(String(describing: event), privacy: .public)")
            }
        }
    }
}
#endif
