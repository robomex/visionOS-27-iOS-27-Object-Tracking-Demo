//
//  IOSHomeView.swift
//  ObjectTrackingUpdates
//

#if os(iOS)
import ARKit
import PeerConnection
import SwiftUI

/// The iOS main view: the camera feed with tracked-object overlays, a stage
/// capsule up top, and the stage-driven panel at the bottom. The panels live
/// in `IOSHomePanels.swift`.
struct IOSHomeView: View {
    @State private var model = IOSDemoModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if ARWorldTrackingConfiguration.isSupported {
                arExperience
            } else {
                ContentUnavailableView {
                    Label("Object Tracking Unavailable", systemImage: "arkit.badge.xmark")
                } description: {
                    Text("World tracking isn't supported on this device.")
                }
            }
        }
        // Drive the connection at the model level, not inside the camera
        // view: the iPhone is the server and should advertise whether or not
        // object tracking is up - but only while the app is active. A
        // backgrounded iPhone drops the connection cleanly so the Vision Pro
        // knows at once, rather than leaving a zombie it has to time out.
        .onChange(of: model.connection.connectionState) {
            model.connectionStateDidChange()
        }
        .onChange(of: scenePhase,
                  initial: true) {
            switch scenePhase {
            case .active:
                model.startConnecting()
            case .background:
                model.stopConnecting()
            default:
                break
            }
        }
    }

    private var arExperience: some View {
        IOSRealityView(model: model)
            // The camera view is the drop destination for the carousel's
            // tiles. While a lifted tile is over it, the configuration
            // closure runs on every move with the finger's location in this
            // view's space; that drives the real-scale ghost across the real
            // surfaces, and the drop places it. Off any surface the drop is
            // refused, so letting go there places nothing.
            .dropDestination(for: String.self) { itemIDs, session in
                guard let itemID = itemIDs.first else { return }

                model.dropGhost(itemID: itemID,
                                at: session.location)
            }
            .dropConfiguration { session in
                switch session.phase {
                case .entering, .active:
                    let onSurface = model.moveGhostDrag(to: session.location)

                    return DropConfiguration(operation: onSurface ? .copy : .cancel)
                case .exiting:
                    model.hideGhostDrag()
                case .ended, .dataTransferCompleted:
                    break
                @unknown default:
                    break
                }

                return DropConfiguration(operation: .cancel)
            }
            .overlay(alignment: .top) {
                IOSStatusBar(model: model)
            }
            .overlay(alignment: .bottom) {
                IOSBottomPanel(model: model)
            }
    }
}

#Preview {
    IOSHomeView()
}
#endif
