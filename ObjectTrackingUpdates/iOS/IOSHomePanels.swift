//
//  IOSHomePanels.swift
//  ObjectTrackingUpdates
//

#if os(iOS)
import PeerConnection
import RealityKit
import SwiftUI

// MARK: - Status bar

/// The stage capsule and any warnings, over the top of the camera view.
struct IOSStatusBar: View {
    let model: IOSDemoModel

    var body: some View {
        VStack(spacing: 6) {
            // Before the demo connects, the bottom panel carries the state;
            // a stage capsule up top would just repeat it.
            if model.phase != .idle {
                Text(stageDescription)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
            }

            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.8), in: .capsule)
            }
        }
        .padding(.top, 8)
        .animation(.default, value: stageDescription)
    }

    private var stageDescription: String {
        switch model.phase {
        case .idle:
            // Not shown: the capsule hides at idle and the bottom panel
            // carries this state.
            return "Not connected"
        case .connected:
            return model.visionProIsTracking
                ? "Connected: The Vision Pro is mapping nearby surfaces"
                : "Connected: Waiting for the Vision Pro to start tracking"
        case .surfacesReady:
            return "Calibrating: Point at the \(DemoItemCatalog.calibrationItemName)"
        case .calibrated:
            return "Synced"
        case .placingGhosts:
            return "Drag 3 items onto the table"
        case .guiding(let itemID):
            return "Guiding: \(model.courseDescription(for: itemID))"
        case .complete:
            return "Meal complete"
        }
    }

    private var warnings: [String] {
        var warnings: [String] = []
        if let reason = model.sessionUnavailableReason {
            warnings.append(reason)
        }

        return warnings
    }
}

// MARK: - Bottom panel

/// The stage-driven panel at the bottom: connection, calibration, the item
/// carousel, guidance progress, or completion.
struct IOSBottomPanel: View {
    let model: IOSDemoModel

    var body: some View {
        VStack(spacing: 12) {
            switch model.phase {
            case .idle:
                IOSConnectionPanel(model: model)
                    .padding(.horizontal)
            case .connected, .calibrated:
                EmptyView()
            case .surfacesReady:
                IOSCalibrationPanel(model: model)
                    .padding(.horizontal)
            case .placingGhosts:
                // Full width: the carousel runs to the screen edges so it can
                // show as many items as fit; its own scroll content is inset.
                IOSCarouselPanel(model: model)
            case .guiding:
                IOSGuidancePanel(model: model)
                    .padding(.horizontal)
            case .complete:
                IOSCompletePanel(model: model)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
        .animation(.default, value: model.phase)
    }
}

struct IOSConnectionPanel: View {
    let model: IOSDemoModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ProgressView()
                Text("Looking for a Vision Pro…")
            }
            Text("Open the project on a nearby Vision Pro, with Wi-Fi enabled on both devices")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let errorMessage = model.connection.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button("Forget Paired Device") {
                model.forgetPairedDevice()
            }
            .font(.footnote)
            Text("Use on both devices after reinstalling the app on either one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }
}

struct IOSCalibrationPanel: View {
    let model: IOSDemoModel

    var body: some View {
        VStack(spacing: 6) {
            Label("Keep the \(DemoItemCatalog.calibrationItemName) in view on both devices",
                  systemImage: beaconIsTracked ? "viewfinder.circle.fill" : "viewfinder.circle")
                .foregroundStyle(beaconIsTracked ? .green : .primary)
            Text(beaconIsTracked ? "Tracking it. Hold steady for a moment." : "Not tracking it yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }

    private var beaconIsTracked: Bool {
        model.statusByItemID[DemoItemCatalog.calibrationItemID] == .tracked
    }
}

/// The carousel: all six meal items, horizontally scrollable. Dragging a
/// tile out into the camera view IS choosing that item for the meal; the
/// first three dragged become the meal, in drop order.
struct IOSCarouselPanel: View {
    let model: IOSDemoModel

    var body: some View {
        VStack(spacing: 10) {
            Text("\(model.mealItemIDsInDropOrder.count) of 3 placed")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            // The scroll view spans the full width of the card; only its
            // content is inset, so the tiles start and end with a margin but
            // scroll all the way to the card's edges instead of sitting in a
            // doubly-padded box.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(DemoItemCatalog.mealItems) { item in
                        ItemTile(item: item,
                                 ghostModel: model.modelsByItemID[item.id],
                                 dropIndex: model.mealItemIDsInDropOrder.firstIndex(of: item.id),
                                 status: model.statusByItemID[item.id],
                                 isAvailable: model.isSelectable(item),
                                 isDragging: model.draggingItemID == item.id)
                            // The system drag: press and hold lifts the tile,
                            // a swipe still scrolls. The lift preview is
                            // invisible on purpose - the preview is the
                            // real-scale ghost in the camera view, not a copy
                            // of the tile under the finger.
                            .draggable(item.id) {
                                Color.clear
                                    .frame(width: 1, height: 1)
                            }
                            .onDragSessionUpdated { session in
                                switch session.phase {
                                case .initial, .active:
                                    if model.draggingItemID != item.id {
                                        model.beginGhostDrag(itemID: item.id)
                                    }
                                case .ended, .dataTransferCompleted:
                                    // A drop on the camera view has already
                                    // placed the ghost and cleared this; any
                                    // other end is a cancel.
                                    model.cancelGhostDrag()
                                case .ending:
                                    break
                                @unknown default:
                                    break
                                }
                            }
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()

            if !model.mealItemIDsInDropOrder.isEmpty {
                IOSResetButton(model: model)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .animation(.default, value: model.mealItemIDsInDropOrder)
    }

}

struct IOSGuidancePanel: View {
    let model: IOSDemoModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.mealItemIDsInDropOrder, id: \.self) { itemID in
                if let item = DemoItemCatalog.item(id: itemID) {
                    HStack {
                        Image(systemName: icon(for: itemID))
                            .foregroundStyle(model.placedItemIDs.contains(itemID) ? .green : .primary)
                        Text("\(model.courseDescription(for: itemID)): \(item.displayName)")
                            .fontWeight(model.phase == .guiding(itemID: itemID) ? .bold : .regular)
                        Spacer()
                    }
                }
            }

            IOSResetButton(model: model)
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .animation(.default, value: model.placedItemIDs)
    }

    private func icon(for itemID: String) -> String {
        if model.placedItemIDs.contains(itemID) {
            return "checkmark.circle.fill"
        }
        if model.phase == .guiding(itemID: itemID) {
            return "speaker.wave.3.fill"
        }

        return "circle"
    }
}

struct IOSCompletePanel: View {
    let model: IOSDemoModel

    var body: some View {
        VStack(spacing: 10) {
            Label("All three items placed", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            IOSResetButton(model: model)
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }
}

struct IOSResetButton: View {
    let model: IOSDemoModel

    var body: some View {
        Button("Reset meal", role: .destructive) {
            model.sendReset()
        }
        .font(.footnote)
    }
}

// MARK: - Rotating 3D preview

/// Marks an entity that turns about vertical, for `SpinSystem`.
struct SpinComponent: Component {
    var radiansPerSecond: Float
}

/// Turns every `SpinComponent` entity each frame.
struct SpinSystem: System {
    private static let query = EntityQuery(where: .has(SpinComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query,
                                       updatingSystemWhen: .rendering)
        {
            guard let spin = entity.components[SpinComponent.self] else { continue }

            let step = simd_quatf(angle: spin.radiansPerSecond * Float(context.deltaTime),
                                  axis: SIMD3<Float>(0, 1, 0))
            entity.orientation = step * entity.orientation
        }
    }
}

/// A meal item's model, slowly rotating - the actual object, not a flat
/// swatch. The clone renders unlit with its own texture, so it needs no
/// image-based light (a PBR model in a bare RealityView has nothing to light
/// it and fails in the renderer); `SpinSystem` turns it each frame.
struct RotatingModelView: View {
    let model: Entity

    var body: some View {
        RealityView { content in
            _ = Self.spinSystemRegistration

            let preview = model.clone(recursive: true)
            preview.convertMaterialsToUnlitPreservingTextures()

            // Center the model on the spinner's origin and normalize it to
            // unit radius, so one camera distance frames every item and the
            // spin is about the model's own middle.
            let spinner = Entity()
            spinner.addChild(preview)
            let bounds = preview.visualBounds(relativeTo: spinner)
            preview.position -= bounds.center
            spinner.scale = SIMD3<Float>(repeating: 1 / max(length(bounds.extents) / 2, 0.01))
            spinner.components.set(SpinComponent(radiansPerSecond: .pi / 4))
            content.add(spinner)

            // RealityKit's camera looks down -Z, so +Z faces the model.
            let camera = PerspectiveCamera()
            camera.position = SIMD3<Float>(0, 0, 3)
            content.add(camera)
        }
    }

    /// Registers the spin component and system once, before the first
    /// preview needs them.
    private static let spinSystemRegistration: Void = {
        SpinComponent.registerComponent()
        SpinSystem.registerSystem()
    }()
}

// MARK: - Item tile

/// One meal item in the carousel. Drag it out into the camera view to place
/// its ghost.
private struct ItemTile: View {
    let item: DemoItem
    let ghostModel: Entity?
    let dropIndex: Int?
    let status: IOSDemoModel.ItemStatus?
    let isAvailable: Bool
    let isDragging: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tileColor.opacity(0.18))
                    .frame(width: 76, height: 76)

                modelPreview
                    .frame(width: 62, height: 62)
                    // Dimmed while unavailable, and while its ghost is out
                    // in the camera view.
                    .opacity(isAvailable && !isDragging ? 1 : 0.3)

                // A placed item is dimmed and marked with its course number.
                if let dropIndex {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.4))
                        .frame(width: 76, height: 76)
                    Label("\(dropIndex + 1)", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
            }

            Text(item.displayName)
                .font(.caption2)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(subtitleIsFailure ? .red : .secondary)
        }
        .frame(width: 92)
        .animation(.default, value: dropIndex)
    }

    /// The item's actual 3D model, slowly rotating, so it reads as the object
    /// it is rather than a flat swatch.
    @ViewBuilder
    private var modelPreview: some View {
        if let ghostModel {
            RotatingModelView(model: ghostModel)
        } else {
            Image(systemName: "cube.transparent")
                .font(.title)
                .foregroundStyle(tileColor)
        }
    }

    private var tileColor: Color {
        Color(red: Double(item.color.x),
              green: Double(item.color.y),
              blue: Double(item.color.z))
    }

    private var subtitle: String {
        if isAvailable { return categoryName }
        if case .failed = status { return "Failed to load" }

        return "Pending training"
    }

    private var subtitleIsFailure: Bool {
        if case .failed = status { return true }

        return false
    }

    private var categoryName: String {
        if case .mealItem(let category) = item.role {
            return category.rawValue
        }

        return ""
    }
}
#endif
