//
//  IOSObjectAnchorVisualization.swift
//  ObjectTrackingUpdates
//

#if os(iOS)
import ARKit
import RealityKit
import UIKit

/// Builds the visualization attached to a recognized object on iOS: the
/// training mesh wearing a semitransparent solid-color overlay in the item's
/// color - the same look as visionOS, so tracking quality reads the same on
/// both devices - plus a name label.
enum IOSObjectAnchorVisualization {
    private static let textHeight: Float = 0.004
    private static let overlayOpacity: Float = 0.5

    static func make(for anchor: ARObjectAnchor,
                     item: DemoItem,
                     model: Entity) -> Entity
    {
        let entity = Entity()

        // Unlit, so it needs no environment light in the AR view, and faded
        // with OpacityComponent - the one translucency that renders here (a
        // material's own alpha shows opaque).
        let overlay = model.clone(recursive: true)
        overlay.tintUnlit(UIColor(red: CGFloat(item.color.x),
                                  green: CGFloat(item.color.y),
                                  blue: CGFloat(item.color.z),
                                  alpha: 1))
        overlay.components.set(OpacityComponent(opacity: overlayOpacity))
        entity.addChild(overlay)

        let extent = anchor.referenceObject.extent
        let center = anchor.referenceObject.center
        let label = "\(item.displayName)\n\(item.trainingSummary)"
        let text = textEntity(label)
        text.position = [center.x, center.y + extent.y / 2 + 0.02, center.z]
        entity.addChild(text)

        return entity
    }

    private static func textEntity(_ string: String) -> ModelEntity {
        let font = MeshResource.Font(name: "Helvetica",
                                     size: CGFloat(textHeight))
            ?? .systemFont(ofSize: CGFloat(textHeight))
        let mesh = MeshResource.generateText(string,
                                             extrusionDepth: textHeight * 0.05,
                                             font: font)
        let material = UnlitMaterial(color: .white)

        return ModelEntity(mesh: mesh,
                           materials: [material])
    }
}

private extension Entity {
    /// Replaces every material in the hierarchy with one flat, unlit color.
    func tintUnlit(_ color: UIColor) {
        if var modelComponent = components[ModelComponent.self] {
            modelComponent.materials = [UnlitMaterial(color: color)]
            components.set(modelComponent)
        }

        for child in children {
            child.tintUnlit(color)
        }
    }
}
#endif
