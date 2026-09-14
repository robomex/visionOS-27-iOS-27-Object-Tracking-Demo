//
//  ReferenceObjectLoader.swift
//  ObjectTrackingUpdates
//

#if os(visionOS)
import ARKit
import OSLog
import RealityKit

/// Loads the demo's reference objects from the app bundle, applying each
/// item's frame-rate configuration at load time.
///
/// Apple's object-tracking sample reloads every enabled object at session
/// start because its "High frequency" setting is a user-facing toggle. Here
/// the frame rate is a fixed property of each item, so each file loads
/// exactly once with its item's `ReferenceObject.Configuration`.
@Observable
final class ReferenceObjectLoader {
    private let logger = Logger(subsystem: AppLogging.subsystem,
                                category: "ReferenceObjectLoader")

    /// An item whose reference object loaded successfully.
    struct LoadedItem: Identifiable {
        let item: DemoItem
        let referenceObject: ReferenceObject

        /// The USDZ the object was trained on, embedded in the file.
        /// `nil` when the file omits it.
        let usdzEntity: Entity?

        var id: String { item.id }
    }

    private(set) var loadedItems = [LoadedItem]()

    /// Items whose file exists but failed to load.
    private(set) var failedItems = [(item: DemoItem, errorDescription: String)]()

    private(set) var didFinishLoading = false

    private var loadingTask: Task<Void, Never>?

    func loadedItem(forReferenceObjectID referenceObjectID: UUID) -> LoadedItem? {
        loadedItems.first { $0.referenceObject.id == referenceObjectID }
    }

    func loadedItem(id itemID: String) -> LoadedItem? {
        loadedItems.first { $0.item.id == itemID }
    }

    /// Loads every bundled file once; any caller awaits the same load, so
    /// "the objects are loaded" is a fact a caller can simply await.
    func loadBuiltInReferenceObjects() async {
        if loadingTask == nil {
            loadingTask = Task {
                // Every file at once, as Apple's object-tracking sample and
                // the 2024 demo load them: each decode is its own work, and
                // one after another would add their times up at launch.
                await withTaskGroup(of: Void.self) { group in
                    for item in DemoItemCatalog.items {
                        // A missing file is an item not yet trained; the home
                        // window shows it as pending once loading finishes.
                        guard let url = Bundle.main.url(forResource: item.fileName,
                                                        withExtension: "referenceobject")
                        else {
                            continue
                        }

                        group.addTask {
                            await self.loadReferenceObject(for: item, at: url)
                        }
                    }
                }

                didFinishLoading = true
            }
        }

        await loadingTask?.value
    }

    private func loadReferenceObject(for item: DemoItem,
                                     at url: URL) async
    {
        // The load-time lever: high-frame-rate tracking is a property of the
        // loaded object, not of the trained file, so it applies to any file -
        // including the pre-27 ones.
        var configuration = ReferenceObject.Configuration()
        configuration.highFrameRateTrackingEnabled = item.usesHighFrameRateTracking

        let referenceObject: ReferenceObject
        do {
            // Loading can take a while for larger objects.
            referenceObject = try await ReferenceObject(from: url,
                                                        configuration: configuration)
        } catch {
            logger.error("Failed to load the reference object for \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
            failedItems.append((item: item, errorDescription: error.localizedDescription))

            return
        }

        var usdzEntity: Entity?
        if let usdzURL = referenceObject.usdzFile {
            do {
                // Load the training USDZ as the entity that attaches to the anchor.
                usdzEntity = try await Entity(contentsOf: usdzURL)
            } catch {
                logger.error("Failed to load the model for \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        } else {
            logger.error("The reference object for \(item.id, privacy: .public) embeds no USDZ; it will track with no overlay.")
        }

        loadedItems.append(LoadedItem(item: item,
                                      referenceObject: referenceObject,
                                      usdzEntity: usdzEntity))
    }
}
#endif
