//
//  HandAnchor+Fingertips.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import ARKit
import simd

extension HandAnchor {
    /// The world positions of this hand's five fingertips, for the guidance
    /// engine's per-hand distance cue. Empty while the hand isn't tracked.
    ///
    /// Every fingertip of a tracked hand counts, whether or not its joint is
    /// individually tracked - the 2024 demo's `fingerPosition`. A hand wrapped
    /// around an object hides its own fingers from the cameras, and filtering
    /// those joints out made the hand vanish at the very moment of the grasp
    /// (seen on device); the skeleton's estimate for a hidden finger is still
    /// on the object.
    var fingertipPositions: [SIMD3<Float>] {
        guard isTracked,
              let handSkeleton
        else {
            return []
        }

        let jointNames: [HandSkeleton.JointName] = [.thumbTip,
                                                    .indexFingerTip,
                                                    .middleFingerTip,
                                                    .ringFingerTip,
                                                    .littleFingerTip]

        return jointNames.map { jointName in
            let fingertipFromOrigin = originFromAnchorTransform * handSkeleton.joint(jointName).anchorFromJointTransform

            return simd_make_float3(fingertipFromOrigin.columns.3)
        }
    }
}
#endif
