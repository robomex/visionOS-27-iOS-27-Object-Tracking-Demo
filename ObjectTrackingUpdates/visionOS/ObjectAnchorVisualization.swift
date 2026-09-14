//
//  ObjectAnchorVisualization.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import ARKit
import RealityKit
import UIKit

/// The in-world visualization of one tracked item: the training USDZ wearing
/// a semitransparent solid-color overlay in the item's color, plus a name
/// label.
final class ObjectAnchorVisualization {
    /// Glyph height of the label.
    private let labelHeight: Float = 0.004
    /// How far above the object's box the label floats, as on iOS.
    private let labelClearance: Float = 0.02
    private let overlayOpacity: Float = 0.5

    let item: DemoItem
    var entity: Entity

    /// The anchor's latest bounding box, anchor space - the guidance engine
    /// measures fingertip distances against it.
    private(set) var boundsCenter: SIMD3<Float>
    private(set) var boundsExtent: SIMD3<Float>

    /// - Parameter model: the item's training mesh, cloned here so two
    ///   anchors for the same reference object (two physical copies of one
    ///   item, which ARKit allows) never fight over one entity.
    init(for anchor: ObjectAnchor,
         item: DemoItem,
         withModel model: Entity)
    {
        self.item = item

        let entity = Entity()

        let overlay = model.clone(recursive: true)

        // The semitransparent solid-color overlay that makes tracking
        // quality read on camera: the training mesh, tinted in the item's
        // color.
        var overlayMaterial = PhysicallyBasedMaterial()
        overlayMaterial.baseColor = .init(tint: UIColor(red: CGFloat(item.color.x),
                                                        green: CGFloat(item.color.y),
                                                        blue: CGFloat(item.color.z),
                                                        alpha: 1))
        overlayMaterial.blending = .transparent(opacity: .init(floatLiteral: overlayOpacity))
        overlayMaterial.faceCulling = .back

        overlay.applyMaterialRecursively(overlayMaterial)
        entity.addChild(overlay)

        entity.transform = Transform(matrix: anchor.originFromAnchorTransform)
        entity.isEnabled = anchor.isTracked

        let label = "\(item.displayName)\n\(item.trainingSummary)"
        let descriptionEntity = Entity.createText(label,
                                                  height: labelHeight)
        let boundingBox = anchor.boundingBox
        descriptionEntity.position = [boundingBox.center.x,
                                      boundingBox.center.y + boundingBox.extent.y / 2 + labelClearance,
                                      boundingBox.center.z]
        entity.addChild(descriptionEntity)

        self.entity = entity
        boundsCenter = anchor.boundingBox.center
        boundsExtent = anchor.boundingBox.extent
    }

    func update(with anchor: ObjectAnchor) {
        entity.isEnabled = anchor.isTracked

        guard anchor.isTracked else { return }

        entity.transform = Transform(matrix: anchor.originFromAnchorTransform)
        boundsCenter = anchor.boundingBox.center
        boundsExtent = anchor.boundingBox.extent
    }
}
#endif
