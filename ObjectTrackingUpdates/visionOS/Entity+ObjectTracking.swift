//
//  Entity+ObjectTracking.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import RealityKit
import UIKit

extension Entity {
    /// A white, unlit text mesh: the in-world item labels.
    static func createText(_ string: String,
                           height: Float) -> ModelEntity
    {
        let font = MeshResource.Font(name: "Helvetica",
                                     size: CGFloat(height))
            ?? .systemFont(ofSize: CGFloat(height))
        let mesh = MeshResource.generateText(string,
                                             extrusionDepth: height * 0.05,
                                             font: font)
        let material = UnlitMaterial(color: .white)
        let text = ModelEntity(mesh: mesh,
                               materials: [material])

        return text
    }
}
#endif
