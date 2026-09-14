//
//  DemoProtocol.swift
//  PeerConnection
//
//  Everything the iPhone and the Apple Vision Pro say to each other.
//

import Foundation
import simd

/// The heartbeat cadence, shared here so the two sides can't disagree on it.
/// Each device sends a `heartbeat` this often while connected; a device that
/// hears nothing at all for the timeout counts its peer as gone and drops the
/// connection so it reconnects. The timeout is several intervals, to ride out
/// a missed beat.
public enum DemoHeartbeat {
    public static let interval = Duration.seconds(2)
    public static let livenessTimeout = Duration.seconds(6)
}

/// The demo's messages, one line each:
/// - `hello`: I'm here, and my protocol version (in the envelope) matches yours.
/// - `beaconSample`: where I see the shared calibration object right now, in my own world coordinates. Sent by the iPhone during calibration; the Vision Pro pairs each with its own view of the same object.
/// - `calibrationLock`: the agreed iPhone-world-to-Vision-Pro-world transform; we're synced. Sent by the Vision Pro when the solve settles.
/// - `surfaces`: the horizontal surfaces the Vision Pro sees, in the shared frame. Sent when the frame locks and re-sent as the Vision Pro maps more of the room, so the iPhone's overlays stay current.
/// - `mealSelection`: the 3 items dragged out on the iPhone, in drop order - sent after the third ghost settles. Also the guidance order.
/// - `ghostPlaced`: the ghost target for one item now sits at this pose in the shared frame. Sent once per item.
/// - `phase`: keeps both UIs on the same stage of the demo.
/// - `placementDone`: one item was found and placed correctly. Sent once per item; the demo completes after the third.
/// - `reset`: clear the meal selection and ghosts on both devices and return to the ghost-placing stage so a different 3 can be picked.
/// - `heartbeat`: I'm still here. Both devices send it a few times a second; its only job is liveness, so a peer that goes silent (backgrounded, force-quit, off the network) is noticed in seconds rather than at the QUIC idle timeout.
/// - `trackingActive`: whether the Vision Pro is in its immersive space, tracking. Sent by the Vision Pro on every connect and whenever it starts or stops. Both connected and stopped read as the `connected` phase, so without this the iPhone can't tell "mapping surfaces" from "the wearer tapped Stop Tracking and needs to start again."
public enum DemoMessage: PeerToPeerMessage {
    case hello
    case beaconSample(TransformPayload)
    case calibrationLock(TransformPayload)
    case surfaces([SurfacePlane])
    case mealSelection([String])
    case ghostPlaced(itemID: String, pose: TransformPayload)
    case phase(DemoPhase)
    case placementDone(itemID: String)
    case reset
    case heartbeat
    case trackingActive(Bool)
}

/// The stages both devices move through, in order. The Vision Pro is the
/// authority: it broadcasts every transition, and the iPhone mirrors it.
/// The carousel appears on the iPhone only after calibration locks; audio
/// guidance starts on the Vision Pro only after the ghosts are down; both
/// devices finish together.
public enum DemoPhase: PeerToPeerMessage {
    /// Not connected.
    case idle
    /// Hello exchanged; both devices run the same protocol version.
    case connected
    /// The Vision Pro has real plane coverage of the table; the calibration
    /// window is open - both devices point at the shared calibration object.
    case surfacesReady
    /// The shared frame is locked; the surfaces message follows immediately.
    case calibrated
    /// The iPhone drags 3 of the 6 items' ghosts from the carousel onto a surface.
    case placingGhosts
    /// Audio guidance runs for one item at a time.
    case guiding(itemID: String)
    /// All three items are placed.
    case complete
}

/// A rigid transform on the wire: 16 floats, column-major, exactly the memory
/// layout of `simd_float4x4`.
public struct TransformPayload: PeerToPeerMessage {
    public let columns: [Float]

    public init(_ matrix: simd_float4x4) {
        columns = (0..<4).flatMap { column in
            (0..<4).map { row in matrix[column][row] }
        }
    }

    public var matrix: simd_float4x4 {
        var result = matrix_identity_float4x4
        guard columns.count == 16 else { return result }

        for column in 0..<4 {
            for row in 0..<4 {
                result[column][row] = columns[column * 4 + row]
            }
        }

        return result
    }
}

/// One horizontal surface the Vision Pro has mapped - a table, the floor, a
/// seat (ceilings excluded), shown on the iPhone so a person sees what the
/// Vision Pro knows. `pose` is the plane extent's own frame in the Vision
/// Pro's world (anchor transform × `anchorFromExtentTransform`): the extent
/// rectangle lies in that frame's X-Y plane, `width` along X and `height`
/// along Y, as ARKit defines it and Apple's plane samples render it.
public struct SurfacePlane: PeerToPeerMessage {
    public let pose: TransformPayload
    public let width: Float
    public let height: Float

    public init(pose: TransformPayload,
                width: Float,
                height: Float)
    {
        self.pose = pose
        self.width = width
        self.height = height
    }
}
