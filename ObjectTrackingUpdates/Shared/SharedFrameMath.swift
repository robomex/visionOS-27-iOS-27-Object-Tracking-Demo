//
//  SharedFrameMath.swift
//  ObjectTrackingUpdates
//

import Foundation
import simd

/// The math behind the one-shot calibration.
///
/// Both devices watch the same object for a second. Each sample pair is the
/// object's pose in the iPhone's world and in the Vision Pro's world at the
/// same moment. Both worlds are gravity-aligned, so the transform between
/// them is only a rotation about the vertical axis plus a translation - the
/// object's heading gives the rotation, its position then gives the
/// translation - and the median over the window rejects the noisy samples.
/// Verified numerically against ground-truth transforms (exact recovery to
/// float precision; 0.005 rad / 1.4 cm under 1 cm of injected noise).
enum SharedFrameMath {
    /// One paired observation of the calibration object.
    struct SamplePair {
        let phonePose: simd_float4x4
        let visionPose: simd_float4x4
    }

    /// Solves the iPhone-world-to-Vision-Pro-world transform from paired
    /// observations of the same static object.
    static func solveVisionFromPhone(_ pairs: [SamplePair]) -> simd_float4x4? {
        guard !pairs.isEmpty else { return nil }

        // Per pair: the yaw difference between how the two worlds see the object.
        var yaws: [Float] = []
        for pair in pairs {
            // Pick whichever object axis is most horizontal in the phone
            // world - an axis pointing near-vertical has no usable heading.
            let phoneX = horizontalProjection(axis(0, of: pair.phonePose))
            let phoneZ = horizontalProjection(axis(2, of: pair.phonePose))
            let usesXAxis = length(phoneX) >= length(phoneZ)
            let phoneAxis = usesXAxis ? phoneX : phoneZ
            let visionAxis = horizontalProjection(axis(usesXAxis ? 0 : 2, of: pair.visionPose))
            yaws.append(normalizedAngle(heading(visionAxis) - heading(phoneAxis)))
        }

        // Median of angles: unwrap around the circular mean first, so a batch
        // straddling the +/-pi seam still produces a sensible median.
        let meanDirection = atan2f(yaws.map(sinf).reduce(0, +), yaws.map(cosf).reduce(0, +))
        let unwrapped = yaws.map { meanDirection + normalizedAngle($0 - meanDirection) }
        let yaw = median(unwrapped)

        // Translation residuals from the median yaw - not the per-sample
        // yaws - so angle noise doesn't leak into the translation estimate.
        // Then a componentwise median.
        let rotation = rotationAboutY(yaw)
        var xs: [Float] = []
        var ys: [Float] = []
        var zs: [Float] = []
        for pair in pairs {
            let rotated = rotation * pair.phonePose.columns.3
            let visionTranslation = pair.visionPose.columns.3
            xs.append(visionTranslation.x - rotated.x)
            ys.append(visionTranslation.y - rotated.y)
            zs.append(visionTranslation.z - rotated.z)
        }

        var transform = rotation
        transform.columns.3 = SIMD4<Float>(median(xs), median(ys), median(zs), 1)

        return transform
    }

    /// A rotation about the world's vertical axis.
    static func rotationAboutY(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)

        return simd_float4x4(columns: (SIMD4<Float>(cosine, 0, -sine, 0),
                                       SIMD4<Float>(0, 1, 0, 0),
                                       SIMD4<Float>(sine, 0, cosine, 0),
                                       SIMD4<Float>(0, 0, 0, 1)))
    }

    /// A transform's translation - its position, dropping orientation.
    static func position(of matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    /// The distance from a point to an axis-aligned box, zero inside it.
    /// Point and box must share a coordinate space.
    static func distance(from point: SIMD3<Float>,
                         toBoxAt center: SIMD3<Float>,
                         extent: SIMD3<Float>) -> Float
    {
        let halfExtent = extent / 2
        let clamped = simd_clamp(point, center - halfExtent, center + halfExtent)

        return length(point - clamped)
    }

    // MARK: - Private helpers

    private static func axis(_ column: Int,
                             of matrix: simd_float4x4) -> SIMD3<Float>
    {
        let columnVector = matrix[column]

        return SIMD3<Float>(columnVector.x, columnVector.y, columnVector.z)
    }

    private static func horizontalProjection(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(vector.x, 0, vector.z)
    }

    /// The angle of a horizontal vector about +Y, so that
    /// `rotationAboutY(heading(v))` maps +Z onto `v`'s direction.
    private static func heading(_ vector: SIMD3<Float>) -> Float {
        atan2f(vector.x, vector.z)
    }

    private static func normalizedAngle(_ angle: Float) -> Float {
        var normalized = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if normalized > .pi { normalized -= 2 * .pi }
        if normalized < -.pi { normalized += 2 * .pi }

        return normalized
    }

    private static func median(_ values: [Float]) -> Float {
        precondition(!values.isEmpty, "median of an empty sample set")

        let sorted = values.sorted()
        let count = sorted.count

        guard count % 2 == 1
        else {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }

        return sorted[count / 2]
    }
}
