//
//  InfoLabel.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import SwiftUI

/// Explains why the demo isn't running.
struct InfoLabel: View {
    let appState: AppState

    var body: some View {
        if !appState.allRequiredProvidersAreSupported {
            ContentUnavailableView {
                Label("Object Tracking Unavailable", systemImage: "arkit.badge.xmark")
            } description: {
                Text("Object tracking isn't supported in Simulator. Run this demo on Apple Vision Pro.")
            }
        } else if !appState.allRequiredAuthorizationsAreGranted {
            ContentUnavailableView {
                Label("Allow World Sensing and Hand Tracking", systemImage: "hand.raised")
            } description: {
                Text("This demo tracks objects and table surfaces with World Sensing, and drives the audio guidance with Hand Tracking. Grant both in Settings → Privacy & Security.")
            }
        }
    }
}

#Preview {
    @Previewable @State var appState = AppState()

    InfoLabel(appState: appState)
}
#endif
