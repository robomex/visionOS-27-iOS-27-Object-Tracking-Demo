//
//  HomeView.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import OSLog
import PeerConnection
import SwiftUI

/// The main window. Two areas behind the visionOS tab ornament: Status (the
/// connection, the demo stage, and the recording toggle, the things a person
/// watches and touches) and Objects (the eight-item load list). The
/// enter/leave controls sit in the window's bottom ornament so they show on
/// both tabs. The section views live in `HomeSections.swift`.
struct HomeView: View {
    @Bindable var appState: AppState

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase

    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "HomeView")

    var body: some View {
        content
            .frame(minWidth: 600, minHeight: 520)
            .toolbar {
                ToolbarItem(placement: .bottomOrnament) {
                    if appState.canEnterImmersiveSpace {
                        TrackingToolbar(appState: appState,
                                        openImmersiveSpace: enterImmersiveSpace,
                                        dismissImmersiveSpace: leaveImmersiveSpace)
                    }
                }
            }
            .onChange(of: appState.demoSession.connection.connectionState) {
                appState.demoSession.connectionStateDidChange()
            }
            .onChange(of: scenePhase,
                      initial: true) {
                handleScenePhase()
            }
            .onChange(of: appState.providersStoppedWithError) { _, stoppedWithError in
                guard stoppedWithError else { return }

                if appState.isImmersiveSpaceOpened {
                    Task { await leaveImmersiveSpace() }
                }
                appState.providersStoppedWithError = false
            }
            .onChange(of: appState.allRequiredAuthorizationsAreGranted) { _, granted in
                // If a person revokes an authorization in Settings while the
                // immersive space is open, dismiss it on their behalf; the
                // toolbar that would let them stop is hidden without it.
                if !granted && appState.isImmersiveSpaceOpened {
                    Task { await leaveImmersiveSpace() }
                }
            }
            .task {
                await runLaunchFlow()
            }
            .task {
                await appState.monitorSessionEvents()
            }
    }

    @ViewBuilder
    private var content: some View {
        if appState.canEnterImmersiveSpace {
            TabView {
                Tab("Status", systemImage: "dot.radiowaves.left.and.right") {
                    StatusTab(appState: appState)
                }
                Tab("Objects", systemImage: "cube") {
                    ObjectsTab(loader: appState.referenceObjectLoader)
                }
            }
        } else {
            InfoLabel(appState: appState)
        }
    }

    // MARK: - Launch and lifecycle

    /// One straight line: ask for the authorizations, load the reference
    /// objects, enter the immersive space. No button. A person who exits
    /// with the Digital Crown stays out; the toolbar button is the way back.
    private func runLaunchFlow() async {
        guard appState.allRequiredProvidersAreSupported else { return }

        await appState.requestAuthorizations()

        guard appState.canEnterImmersiveSpace else { return }

        await appState.referenceObjectLoader.loadBuiltInReferenceObjects()

        // Nothing to track yet: every file is still pending training.
        guard !appState.referenceObjectLoader.loadedItems.isEmpty else { return }

        await enterImmersiveSpace()
    }

    private func handleScenePhase() {
        if scenePhase == .active {
            // Connect while active; the controller's loop reconnects after any
            // drop. Runs at launch and on every return from the background.
            appState.demoSession.startConnecting()

            Task {
                // Returning from the background: authorization may have changed.
                await appState.queryAuthorizations()
            }
        } else {
            // No longer active: leave the immersive space so a person isn't
            // stuck in it without the window's controls.
            if appState.isImmersiveSpaceOpened {
                Task { await leaveImmersiveSpace() }
            }

            // Fully backgrounded: drop the connection cleanly so the iPhone
            // knows at once, and don't browse while suspended.
            if scenePhase == .background {
                appState.demoSession.stopConnecting()
            }
        }
    }

    private func enterImmersiveSpace() async {
        switch await openImmersiveSpace(id: AppState.immersiveSpaceIdentifier) {
        case .opened, .userCancelled:
            break
        case .error:
            logger.error("Could not open the immersive space.")
        @unknown default:
            break
        }
    }

    /// Only dismisses. The immersive view's `onDisappear` records the exit,
    /// as the 2024 demo's did: there are several ways out of the space (this
    /// button, the Digital Crown, a lost authorization, a provider error) and
    /// one bookkeeper, so nothing is torn down twice.
    private func leaveImmersiveSpace() async {
        await dismissImmersiveSpace()
    }
}

#Preview {
    @Previewable @State var appState = AppState()

    HomeView(appState: appState)
}
#endif
