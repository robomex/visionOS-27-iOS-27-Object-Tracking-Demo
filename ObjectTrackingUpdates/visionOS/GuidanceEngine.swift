//
//  GuidanceEngine.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import ARKit
import Foundation
import OSLog
import RealityKit
import simd
import Synchronization

/// Drives the eyes-closed placement, one meal item at a time. Spatial audio
/// IS the left/right cue - sounds play from entities and the ears do the
/// localizing; this engine only decides which sound plays where, and how
/// loud.
///
/// Hands are read the way the 2024 object-tracking demo read them: per hand,
/// the nearest of its five fingertips to the object's bounds, and a grip of
/// none, left, right, or both. Contact is 5 mm, and it is judged only when the
/// cameras deliver a fresh pose of the object, against the latest fingertips,
/// so a hand is never compared to where the object used to be. While carrying,
/// the hands that lifted the object are its carriers until it is set down.
///
/// Both guidance cues are tones synthesized live (`GuidanceTone`): a pulsed
/// tone whose loudness, pulse rate, and pitch all climb as the distance
/// closes. They differ in register, timbre, pulse shape, and pulse range so
/// they read apart with eyes closed: find-me is low, soft, slow, rounded
/// pips; place-here is high, bright, quicker, sharper beeps.
///
/// Every sound plays from an entity the engine owns, parented once at
/// attach, and every player is built ahead of time (`prepareAudio`) at the
/// immersive space's entry, so starting a sound later is a `play()` and
/// nothing stalls when guidance begins.
///
/// 1. Locating: while the cameras see the target object and no hand is on
///    it, the "find me" tone plays from it, driven by the nearer hand's
///    distance. While the cameras can't see it, the tone stops and a
///    once-a-second tick says so instead; the two never play together. A
///    short "got it" sting plays once a hand makes contact, and the tone
///    stops while a hand is on the object.
/// 2. Carrying: once a hand in contact has moved the object from where it
///    rested, the "place here" tone plays from the ghost's position, plainly
///    audible at once, driven by the object's distance to the ghost, and
///    continuous once the object is within the placed distance. If the
///    cameras lose the object on the way, the gripping hand
///    stands in for it; if they lose the hand too, there is nothing to guide
///    by, so the tone stops and the same tick plays until either is seen
///    again. Set down with every hand off it, away from the ghost, it goes
///    back to locating so it can be found again.
/// 3. Placed: the object sat within the placement threshold long enough - a
///    success chime and a spark burst at the ghost, then the next item.
@Observable
final class GuidanceEngine {
    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "GuidanceEngine")

    enum Stage: Equatable {
        case inactive
        case locating
        case carrying
        case celebrating
    }

    /// Which hands are on the object, as the 2024 demo named it.
    enum Grip: Equatable {
        case none
        case left
        case right
        case both
    }

    /// A fingertip this close to the object's bounds: that hand is on it. The
    /// 2024 demo's `minimumFingerDistance`.
    private static let contactDistance: Float = 0.005

    /// A hand in contact stays in contact until its nearest fingertip is this
    /// far off, so jitter at the centimeter doesn't re-fire the sting.
    private static let contactReleaseDistance: Float = 0.05

    /// The object has moved this far from where it rested, with a hand on it:
    /// it is being carried. Well above the jitter of a stationary object.
    private static let liftDistance: Float = 0.05

    /// While carrying, every hand that lifted the object, tracked and this far
    /// off its tracked pose, means it was set down and let go - back to
    /// locating.
    private static let releaseDistance: Float = 0.10

    /// The object's origin must sit within this distance of its ghost's...
    private static let placementDistance: Float = 0.05

    /// ...continuously for this long to count as placed. Position only;
    /// orientation is not checked.
    private static let placementDwell = Duration.seconds(1)

    /// The find-me tone sweeps from this, far away, up to full level at the
    /// object: an object across the room is barely there.
    private static let minimumGain: Double = -40

    /// The place-here tone's far end. The object was just picked up, so the
    /// target has to be plainly audible at once.
    private static let carryingFloorGain: Double = -18
    private static let silentGain: Double = -60

    /// The find-me tone, far from the hand and at it: a low sine, short
    /// rounded pips, pulsing faster and rising as the hand nears. An octave
    /// and more below place-here throughout.
    private static let findMePulsesFar: Double = 1.5
    private static let findMePulsesNear: Double = 6
    private static let findMePitchFar: Double = 262
    private static let findMePitchNear: Double = 523
    private static let findMeDutyCycle = 0.3
    private static let findMeRampSeconds = 0.015

    /// The place-here tone, far from the ghost and at it: a brighter
    /// triangle wave, longer sharper beeps, pulsing faster and rising as the
    /// object nears, continuous once within `placementDistance`.
    private static let placeHerePulsesFar: Double = 2
    private static let placeHerePulsesNear: Double = 10
    private static let placeHerePitchFar: Double = 588
    private static let placeHerePitchNear: Double = 1176
    private static let placeHereDutyCycle = 0.5
    private static let placeHereRampSeconds = 0.005

    private(set) var stage = Stage.inactive
    private(set) var targetItemID: String?
    private(set) var grip = Grip.none

    /// Called when the current item has been placed; the session controller
    /// advances the phase and tells the iPhone.
    var onPlacement: ((String) -> Void)?

    // The one-shots and the tick are files, loaded once at immersive-space
    // entry; the two guidance tones are synthesized.
    private var successResource: AudioFileResource?
    private var notInViewResource: AudioFileResource?
    private var grabbedResource: AudioFileResource?

    // The entities sound plays from, all the engine's own, parented once by
    // `attach(to:)`. The find-me source is kept at the object's tracked
    // pose; the place-here source is put at the ghost's position when an
    // item's guidance begins, and the chime plays from it too. Keeping the
    // sources off the visualizations means their players can be built once
    // and kept. The tick and the sting are non-spatial: they are about the
    // moment, not a place.
    private let findMeSource = Entity()
    private let placeHereSource = Entity()
    private let cueSource = Entity()
    private let stingSource = Entity()
    private var ghostEntity: Entity?
    private let findMeTone = GuidanceTone(waveform: .sine,
                                          dutyCycle: GuidanceEngine.findMeDutyCycle,
                                          rampSeconds: GuidanceEngine.findMeRampSeconds,
                                          pulsesPerSecond: GuidanceEngine.findMePulsesFar,
                                          pitch: GuidanceEngine.findMePitchFar)
    private let placeHereTone = GuidanceTone(waveform: .triangle,
                                             dutyCycle: GuidanceEngine.placeHereDutyCycle,
                                             rampSeconds: GuidanceEngine.placeHereRampSeconds,
                                             pulsesPerSecond: GuidanceEngine.placeHerePulsesFar,
                                             pitch: GuidanceEngine.placeHerePitchFar)

    // The players, built ahead of time: the tones at attach, the tick once
    // its file has loaded and its source is in the scene. The sting and the
    // chime are one-shots, played fresh each time from loaded resources.
    private var findMeGenerator: AudioGeneratorController?
    private var placeHereGenerator: AudioGeneratorController?
    private var notInViewController: AudioPlaybackController?
    private var successController: AudioPlaybackController?
    private var grabbedController: AudioPlaybackController?

    // Live geometry, world space unless noted.
    /// The object's last known pose; kept while it is out of view.
    private var objectTransform: simd_float4x4?
    private var isObjectTracked = false
    private var objectBoundsCenter = SIMD3<Float>.zero
    private var objectBoundsExtent = SIMD3<Float>.zero
    private var ghostPosition: SIMD3<Float>?
    private var fingertipsByHand: [HandAnchor.Chirality: [SIMD3<Float>]] = [:]

    /// The hands currently on the object. A hand enters at `contactDistance`
    /// and leaves at `contactReleaseDistance`, judged only on a fresh object
    /// pose (`updateContact`). Frozen while carrying: these are then the hands
    /// carrying it.
    private var handsInContact: Set<HandAnchor.Chirality> = []

    /// Where the object was last seen with no hand on it; a hand in contact
    /// moving it away from here is what starts carrying.
    private var restPosition: SIMD3<Float>?

    private var dwellStart: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init() {
        findMeSource.components.set(SpatialAudioComponent(gain: Self.minimumGain))
        placeHereSource.components.set(SpatialAudioComponent(gain: Self.silentGain))
        // The tick and the sting play alone, never under a loop, so both at
        // their files' own level.
        cueSource.components.set(ChannelAudioComponent())
        stingSource.components.set(ChannelAudioComponent())
    }

    /// Loads the three audio files. Runs at the immersive space's entry,
    /// alongside the anchor streams, long before any guidance.
    func loadResources() async {
        let looping = AudioFileResource.Configuration(shouldLoop: true)
        do {
            notInViewResource = try await AudioFileResource(named: "NotInView.wav",
                                                            configuration: looping)
            grabbedResource = try await AudioFileResource(named: "Grabbed.wav")
            successResource = try await AudioFileResource(named: "Success.wav")
        } catch {
            // Guidance still advances without audio; it just goes quiet.
            logger.error("Failed to load a guidance audio resource: \(String(describing: error), privacy: .public)")
        }

        prepareTick()
    }

    // MARK: - Session control

    /// Parents the engine's sound sources once, for the life of the scene,
    /// and builds the two tones' players on them, unstarted. Re-adding an
    /// entity that is already a child pulls it out of the scene and back in;
    /// the sources stay put and only their playback changes.
    func attach(to root: Entity) {
        root.addChild(findMeSource)
        root.addChild(placeHereSource)
        root.addChild(cueSource)
        root.addChild(stingSource)

        do {
            findMeGenerator = try findMeTone.prepare(on: findMeSource)
            placeHereGenerator = try placeHereTone.prepare(on: placeHereSource)
        } catch {
            logger.error("Could not prepare a guidance tone: \(String(describing: error), privacy: .public)")
        }

        prepareTick()
    }

    /// Builds the tick's player, unstarted, once its file has loaded and its
    /// source is in the scene. The two arrive in no fixed order (the view's
    /// make closure and its task), so whichever comes second does this.
    private func prepareTick() {
        guard notInViewController == nil,
              cueSource.parent != nil,
              let notInViewResource
        else {
            return
        }

        notInViewController = cueSource.prepareAudio(notInViewResource)
    }

    /// Starts guiding one item.
    func beginGuidance(for itemID: String,
                       ghostEntity: Entity)
    {
        stopAudio()
        targetItemID = itemID
        self.ghostEntity = ghostEntity
        ghostPosition = ghostEntity.position(relativeTo: nil)
        objectTransform = nil
        isObjectTracked = false
        handsInContact = []
        grip = .none
        restPosition = nil
        dwellStart = nil
        findMeSource.spatialAudio?.gain = Self.minimumGain
        placeHereSource.setPosition(ghostEntity.position(relativeTo: nil),
                                    relativeTo: nil)
        placeHereSource.spatialAudio?.gain = Self.silentGain
        stage = .locating
        evaluate(objectSampled: false)
    }

    func stop() {
        stopAudio()
        stage = .inactive
        targetItemID = nil
        ghostEntity = nil
        objectTransform = nil
        isObjectTracked = false
        handsInContact = []
        grip = .none
        restPosition = nil
        dwellStart = nil
    }

    // MARK: - Anchor input

    /// The current target's anchor was removed. High-frame-rate items lose
    /// their anchor the moment they leave view, so this is "out of view", not
    /// "gone": the last pose stands.
    func detachObject(for itemID: String) {
        guard itemID == targetItemID else { return }

        setObjectTracked(false)
        evaluate(objectSampled: false)
    }

    /// Per-update geometry for the current target.
    func updateObject(itemID: String,
                      transform: simd_float4x4,
                      boundsCenter: SIMD3<Float>,
                      boundsExtent: SIMD3<Float>,
                      isTracked: Bool)
    {
        guard itemID == targetItemID else { return }

        objectBoundsCenter = boundsCenter
        objectBoundsExtent = boundsExtent
        if isTracked {
            objectTransform = transform
            findMeSource.setTransformMatrix(transform, relativeTo: nil)
        }
        setObjectTracked(isTracked)
        evaluate(objectSampled: isTracked)
    }

    /// Whether the cameras see the target right now, logged on each change so
    /// a device run shows when the engine learned the object left or
    /// returned - which for a default-rate object is when ARKit says so, not
    /// when the eyes would.
    private func setObjectTracked(_ isTracked: Bool) {
        guard isTracked != isObjectTracked else { return }

        isObjectTracked = isTracked
        logger.log("\(self.targetItemID ?? "", privacy: .public) \(isTracked ? "in" : "out of", privacy: .public) view.")
    }

    /// The latest fingertip positions of each tracked hand, world space.
    func updateHands(_ fingertipsByHand: [HandAnchor.Chirality: [SIMD3<Float>]]) {
        self.fingertipsByHand = fingertipsByHand
        evaluate(objectSampled: false)
    }

    // MARK: - The state machine

    /// - Parameter objectSampled: the cameras just delivered a fresh pose of
    ///   the object, so its bounds and the latest fingertips describe the same
    ///   moment. That is the only time contact is judged; a hand update alone
    ///   moves gains and checks the lift, nothing else.
    private func evaluate(objectSampled: Bool) {
        if objectSampled && stage == .locating {
            updateContact()
        }

        switch stage {
        case .inactive, .celebrating:
            break
        case .locating:
            evaluateLocating()
        case .carrying:
            evaluateCarrying()
        }

        syncCues()
    }

    /// Per hand, in or out of contact with hysteresis, judged against a fresh
    /// object pose; the sting fires when the first hand makes contact and not
    /// again until every hand is off. Runs only while locating: the object
    /// rests there, so its tracked pose is where it is, and a hand that leaves
    /// is seen leaving. While carrying the object moves with the hand and a
    /// tracked pose can trail it by more than the exit distance, so contact is
    /// not re-judged; the hands that lifted it stay its carriers until it is
    /// set down (`evaluateCarrying`).
    private func updateContact() {
        let distances = handDistances()

        // A hand that drops out of tracking mid-grip keeps its contact until
        // a tracked sample says it is off (the 2024 demo's issue #2: hand
        // tracking is lost intermittently).
        for (chirality, distance) in distances {
            if distance < Self.contactDistance {
                handsInContact.insert(chirality)
            } else if distance > Self.contactReleaseDistance {
                handsInContact.remove(chirality)
            }
        }

        let newGrip: Grip
        switch (handsInContact.contains(.left), handsInContact.contains(.right)) {
        case (true, true):
            newGrip = .both
        case (true, false):
            newGrip = .left
        case (false, true):
            newGrip = .right
        case (false, false):
            newGrip = .none
        }

        if grip == .none && newGrip != .none {
            playGotIt()
        }
        grip = newGrip
    }

    private func evaluateLocating() {
        // The nearer hand's distance drives the find-me tone. No tracked hand
        // holds the last values rather than muting.
        if let distance = handDistances().values.min() {
            let closeness = Self.closeness(of: distance,
                                           far: 1.5,
                                           near: 0.1)
            findMeSource.spatialAudio?.gain = Self.minimumGain * (1 - closeness)
            findMeTone.pulsesPerSecond.store(Self.findMePulsesFar + (Self.findMePulsesNear - Self.findMePulsesFar) * closeness,
                                             ordering: .relaxed)
            findMeTone.pitch.store(Self.findMePitchFar + (Self.findMePitchNear - Self.findMePitchFar) * closeness,
                                   ordering: .relaxed)
        }

        guard isObjectTracked,
              let objectTransform
        else {
            return
        }

        let objectPosition = SharedFrameMath.position(of: objectTransform)

        // No hand on it, or never seen before: wherever it sits now is where
        // it rests. Movement with no hand - a tracking jump, someone else's
        // nudge - is not a pickup; the next touch starts from the new spot.
        guard grip != .none,
              let restPosition
        else {
            self.restPosition = objectPosition

            return
        }

        // A hand on it, and it moved from where it rested: carried.
        if length(objectPosition - restPosition) > Self.liftDistance {
            beginCarrying()
        }
    }

    private func evaluateCarrying() {
        // Blind: neither the object nor a carrying hand is seen, so there is
        // no position to guide by. The tone stops and the tick plays
        // (`syncCues`), and the dwell cannot run on a stale position.
        guard let ghostPosition,
              let objectPosition = estimateCarriedPosition()
        else {
            dwellStart = nil

            return
        }

        let distance = length(objectPosition - ghostPosition)
        let closeness = Self.closeness(of: distance,
                                       far: 1.0,
                                       near: 0.05)
        placeHereSource.spatialAudio?.gain = Self.carryingFloorGain * (1 - closeness)
        let isAtTarget = distance < Self.placementDistance
        placeHereTone.pulsesPerSecond.store(isAtTarget ? 0 : Self.placeHerePulsesFar + (Self.placeHerePulsesNear - Self.placeHerePulsesFar) * closeness,
                                            ordering: .relaxed)
        placeHereTone.pitch.store(Self.placeHerePitchFar + (Self.placeHerePitchNear - Self.placeHerePitchFar) * closeness,
                                  ordering: .relaxed)

        guard distance < Self.placementDistance
        else {
            dwellStart = nil

            // Set down away from the ghost and let go: the cameras see the
            // object, and every hand that carried it is tracked and well off
            // it. A carrier the cameras can't see may still be holding it, so
            // it blocks the release (the 2024 demo's issue #2).
            if isObjectTracked,
               let objectTransform {
                let distances = handDistances()
                let carriersAreOff = handsInContact.allSatisfy { chirality in
                    guard let distance = distances[chirality] else { return false }

                    return distance > Self.releaseDistance
                }
                if carriersAreOff {
                    resumeLocating(from: SharedFrameMath.position(of: objectTransform))
                }
            }

            return
        }

        guard let dwellStart
        else {
            dwellStart = clock.now

            return
        }

        if clock.now - dwellStart >= Self.placementDwell {
            celebratePlacement()
        }
    }

    private func beginCarrying() {
        stage = .carrying
        dwellStart = nil
        logger.log("Carrying \(self.targetItemID ?? "", privacy: .public) (\(String(describing: self.grip), privacy: .public) hand).")

        // `syncCues` starts the place-here tone, from its source at the ghost.
        placeHereSource.spatialAudio?.gain = Self.carryingFloorGain
    }

    /// Back from carrying to locating: the hands that carried it have let go,
    /// the object rests where it is now, the ghost's loop stops, and the
    /// object's "find me" loop resumes.
    private func resumeLocating(from objectPosition: SIMD3<Float>) {
        placeHereGenerator?.stop()
        placeHereSource.spatialAudio?.gain = Self.silentGain
        handsInContact = []
        grip = .none
        restPosition = objectPosition
        dwellStart = nil
        stage = .locating
        logger.log("Set down; locating \(self.targetItemID ?? "", privacy: .public) again.")
    }

    private func celebratePlacement() {
        guard let itemID = targetItemID else { return }

        placeHereGenerator?.stop()
        stage = .celebrating

        let sparkEntity = Entity()
        sparkEntity.components.set(ParticleEmitterComponent.Presets.sparks)
        ghostEntity?.addChild(sparkEntity)

        // The chime can still be playing when the space closes or the phase
        // changes; only a placement that is still current advances the demo.
        let finish = { [weak self] in
            sparkEntity.removeFromParent()

            guard let self,
                  self.stage == .celebrating,
                  self.targetItemID == itemID
            else {
                return
            }

            self.successController = nil
            self.onPlacement?(itemID)
        }

        if let successResource {
            placeHereSource.spatialAudio?.gain = 0
            let controller = placeHereSource.playAudio(successResource)
            controller.completionHandler = finish
            successController = controller
        } else {
            // No chime available - advance anyway.
            finish()
        }
    }

    // MARK: - Audio helpers

    /// "Got it": a hand made contact, so pick it up.
    private func playGotIt() {
        guard let grabbedResource else { return }

        grabbedController?.stop()
        grabbedController = stingSource.playAudio(grabbedResource)
    }

    /// The three continuous sounds follow the state, so nothing plays that
    /// the state doesn't call for. Find-me: from the object while the cameras
    /// see it and no hand is on it. Place-here: from the ghost while carrying
    /// with a position to go by, the object's or a carrying hand's. The tick:
    /// whenever the cameras see nothing to guide by - the object while
    /// locating, the object or a carrying hand while carrying. The tick is a
    /// one-second file - a short tone, then silence - looping, so "once a
    /// second" needs no timer.
    private func syncCues() {
        let isLocating = stage == .locating
        let isCarrying = stage == .carrying
        let carriedPosition = isCarrying ? estimateCarriedPosition() : nil

        let wantsFindMe = isLocating && isObjectTracked && grip == .none
        let wantsPlaceHere = isCarrying && carriedPosition != nil
        let wantsTick = (isLocating && !isObjectTracked) || (isCarrying && carriedPosition == nil)

        // The tones: stopped and restarted; each oscillator keeps its place
        // across the gap.
        setPlaying(wantsFindMe, findMeGenerator)
        setPlaying(wantsPlaceHere, placeHereGenerator)

        // The tick: paused and resumed so it never restarts from the top
        // mid-guidance.
        if wantsTick {
            if let notInViewController,
               !notInViewController.isPlaying {
                notInViewController.play()
            }
        } else {
            notInViewController?.pause()
        }
    }

    private func setPlaying(_ playing: Bool,
                            _ generator: AudioGeneratorController?)
    {
        guard let generator else { return }

        if playing {
            if !generator.isPlaying {
                generator.play()
            }
        } else {
            generator.stop()
        }
    }

    /// Silences everything. The prepared players stay, ready for the next
    /// item; the one-shots are dropped.
    private func stopAudio() {
        findMeGenerator?.stop()
        placeHereGenerator?.stop()
        notInViewController?.stop()
        successController?.stop()
        successController = nil
        grabbedController?.stop()
        grabbedController = nil
    }

    /// A distance mapped onto 0 at `far` and beyond, 1 at `near` and closer,
    /// straight-line in between. Every distance-driven cue (gain, speed,
    /// pulse rate, pitch) is a straight line in this.
    private static func closeness(of distance: Float,
                                  far: Float,
                                  near: Float) -> Double
    {
        let clamped = min(max(distance, near), far)

        return Double((far - clamped) / (far - near))
    }

    // MARK: - Geometry helpers

    /// Per tracked hand, the distance from its nearest fingertip to the
    /// object's bounding box, measured in anchor space against the object's
    /// last known pose. Empty with no hands tracked or no object seen yet.
    private func handDistances() -> [HandAnchor.Chirality: Float] {
        guard let objectTransform else { return [:] }

        let anchorFromWorld = objectTransform.inverse
        var distances: [HandAnchor.Chirality: Float] = [:]

        for (chirality, fingertips) in fingertipsByHand {
            let nearest = fingertips.map { worldPosition in
                let homogeneous = anchorFromWorld * SIMD4<Float>(worldPosition, 1)
                let anchorPosition = SIMD3<Float>(homogeneous.x, homogeneous.y, homogeneous.z)

                return SharedFrameMath.distance(from: anchorPosition,
                                                toBoxAt: objectBoundsCenter,
                                                extent: objectBoundsExtent)
            }.min()

            if let nearest {
                distances[chirality] = nearest
            }
        }

        return distances
    }

    /// The object's position while carried: its tracked pose when the
    /// cameras see it, else the fingertips of a hand carrying it. `nil` when
    /// neither is seen: blind, with nothing to guide by.
    private func estimateCarriedPosition() -> SIMD3<Float>? {
        if isObjectTracked,
           let objectTransform {
            return SharedFrameMath.position(of: objectTransform)
        }

        let grippingFingertips = handsInContact.flatMap { fingertipsByHand[$0] ?? [] }
        guard !grippingFingertips.isEmpty else { return nil }

        return grippingFingertips.reduce(.zero, +) / Float(grippingFingertips.count)
    }
}
#endif
