//
//  ObjectTrackingUpdatesApp.swift
//  ObjectTrackingUpdates
//

import SwiftUI

@main
struct ObjectTrackingUpdatesApp: App {
    #if os(visionOS)
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            HomeView(appState: appState)
        }

        ImmersiveSpace(id: AppState.immersiveSpaceIdentifier) {
            ObjectTrackingRealityView(appState: appState)
        }
        .immersionStyle(selection: .constant(.mixed),
                        in: .mixed)
    }
    #else
    var body: some Scene {
        WindowGroup {
            IOSHomeView()
        }
    }
    #endif
}
