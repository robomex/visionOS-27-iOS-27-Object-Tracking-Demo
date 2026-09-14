//
//  Entity+Materials.swift
//  ObjectTrackingUpdates
//

import RealityKit

extension Entity {
    /// Replaces every material in this entity's hierarchy - how the tint
    /// overlays and ghosts recolor a training mesh.
    func applyMaterialRecursively(_ material: RealityFoundation.Material) {
        if let modelEntity = self as? ModelEntity {
            modelEntity.model?.materials = [material]
        }
        for child in children {
            child.applyMaterialRecursively(material)
        }
    }
}
