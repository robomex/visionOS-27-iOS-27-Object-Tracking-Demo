//
//  DemoItem.swift
//  ObjectTrackingUpdates
//

import Foundation
import simd

/// One physical object the demo tracks.
///
/// Two levers decide how an object tracks in the 27 releases:
///
/// 1. Training - which trainer generation produced the `.referenceobject`
///    file (pre-27 vs 27 Create ML) and, for the 27 trainer, standard vs
///    extended mode. Baked into the file.
/// 2. Frame rate - default vs high-frame-rate tracking, chosen at load time.
///    Works on any file, including pre-27 ones. On visionOS this is
///    `ReferenceObject.Configuration.highFrameRateTrackingEnabled`; on iOS it
///    decides `trackingObjects` (full frame rate) vs `detectionObjects`.
struct DemoItem: Identifiable, Hashable {
    enum TrainerGeneration: String {
        case pre27 = "Pre-27"
        case gen27 = "27"
    }

    enum TrainingMode: String {
        case standard = "Standard"
        case extended = "Extended"
    }

    enum Role: Hashable {
        /// A Fairlife carton: the part-1 worst-vs-best comparison pair.
        case carton
        /// One of the six items the meal is built from.
        case mealItem(MealCategory)
    }

    enum MealCategory: String {
        case healthy = "Healthy"
        case indulgent = "Indulgent"
    }

    let id: String
    let displayName: String

    /// Base name of the item's `.referenceobject` file in the app bundle,
    /// without the file extension. The 3D model for the ghost and the overlay
    /// is the USDZ embedded in that same file, so nothing else keys off this.
    let fileName: String

    let trainerGeneration: TrainerGeneration
    let trainingMode: TrainingMode

    /// Whether the file loads with high-frame-rate tracking.
    let usesHighFrameRateTracking: Bool

    let role: Role

    /// The item's overlay and ghost color, sRGB components in 0...1.
    let color: SIMD3<Float>

    var trainingSummary: String {
        "\(trainerGeneration.rawValue) · \(trainingMode.rawValue) · \(usesHighFrameRateTracking ? "High frame rate" : "Default rate")"
    }

    var isMealItem: Bool {
        if case .mealItem = role { return true }

        return false
    }
}

/// The demo's eight objects: the two part-1 cartons and the six part-2 meal
/// items. All eight are trained; the app still treats a missing file as
/// "pending training" rather than an error, so it runs with whatever subset
/// is bundled.
///
/// Two objects are pre-27 files carried over unchanged from the 2024
/// visionOS 2 demo - the blue carton and Cap'n Crunch. The blue carton is
/// part 1's deliberate worst case against the red carton, and Cap'n Crunch
/// puts an old-generation file in the meal set beside 27-trained ones.
///
/// The meal items are ordered as near-pairs, indulgent first: cereal, then
/// dessert, then fruit snack. Three healthy, three indulgent. Six objects
/// load with high-frame-rate tracking, the red carton and every meal item
/// but apple sauce: six is the most that tracked at high frame rate at once
/// on device (Apple documents only the ten-per-session cap). Only a
/// high-frame-rate anchor reports the object leaving the cameras' view, which
/// the guidance's not-in-view cue depends on. Part 1's cartons carry the rate
/// comparison.
enum DemoItemCatalog {
    /// The item both devices track during calibration: the red carton, the
    /// best tracker here (27 trainer, extended, high frame rate). It has to
    /// be a high-frame-rate item: a default-rate anchor holds its first pose
    /// estimate, so the solve would see one frozen heading instead of thirty
    /// fresh ones.
    static let calibrationItemID = "red-carton"

    static let items: [DemoItem] = [
        DemoItem(id: "blue-carton",
                 displayName: "Blue Fairlife carton",
                 fileName: "Fairlife2Percent",
                 trainerGeneration: .pre27,
                 trainingMode: .standard,
                 usesHighFrameRateTracking: false,
                 role: .carton,
                 color: SIMD3<Float>(0.16, 0.44, 1.0)),
        DemoItem(id: "red-carton",
                 displayName: "Red Fairlife carton",
                 fileName: "FairlifeWholeMilk",
                 trainerGeneration: .gen27,
                 trainingMode: .extended,
                 usesHighFrameRateTracking: true,
                 role: .carton,
                 color: SIMD3<Float>(1.0, 0.23, 0.19)),
        DemoItem(id: "capn-crunch",
                 displayName: "Cap'n Crunch",
                 fileName: "CapnCrunch",
                 trainerGeneration: .pre27,
                 trainingMode: .standard,
                 usesHighFrameRateTracking: true,
                 role: .mealItem(.indulgent),
                 color: SIMD3<Float>(1.0, 0.62, 0.04)),
        DemoItem(id: "quaker-granola",
                 displayName: "Quaker protein granola",
                 fileName: "QuakerProteinGranola",
                 trainerGeneration: .gen27,
                 trainingMode: .extended,
                 usesHighFrameRateTracking: true,
                 role: .mealItem(.healthy),
                 color: SIMD3<Float>(0.20, 0.78, 0.35)),
        DemoItem(id: "oreo-bars",
                 displayName: "Oreo bars",
                 fileName: "OreoBars",
                 trainerGeneration: .gen27,
                 trainingMode: .standard,
                 usesHighFrameRateTracking: true,
                 role: .mealItem(.indulgent),
                 color: SIMD3<Float>(0.86, 0.44, 0.84)),
        DemoItem(id: "chobani-yogurt",
                 displayName: "Chobani Greek yogurt",
                 fileName: "ChobaniGreekYogurt",
                 trainerGeneration: .gen27,
                 trainingMode: .standard,
                 usesHighFrameRateTracking: true,
                 role: .mealItem(.healthy),
                 color: SIMD3<Float>(0.35, 0.68, 0.90)),
        DemoItem(id: "fruit-roll-ups",
                 displayName: "Fruit Roll-Ups",
                 fileName: "FruitRollUps",
                 trainerGeneration: .gen27,
                 trainingMode: .standard,
                 usesHighFrameRateTracking: true,
                 role: .mealItem(.indulgent),
                 color: SIMD3<Float>(1.0, 0.27, 0.53)),
        DemoItem(id: "apple-sauce",
                 displayName: "Apple sauce",
                 fileName: "AppleSauce",
                 trainerGeneration: .gen27,
                 trainingMode: .standard,
                 usesHighFrameRateTracking: false,
                 role: .mealItem(.healthy),
                 color: SIMD3<Float>(0.55, 0.83, 0.28))
    ]

    static var mealItems: [DemoItem] {
        items.filter(\.isMealItem)
    }

    /// The calibration object's name, for the instructions on both devices.
    static var calibrationItemName: String {
        item(id: calibrationItemID)?.displayName ?? "calibration object"
    }

    static func item(id: String) -> DemoItem? {
        items.first { $0.id == id }
    }
}

/// The meal is served in the order its ghosts were dropped. This turns an item
/// into its course label given that order, so the iPhone's carousel and the
/// Vision Pro's stage read the same words.
enum MealCourse {
    static let names = ["First course", "Second course", "Third course"]

    /// The course label for an item, or the item's display name if it isn't
    /// one of the meal's (up to three) items.
    static func description(for itemID: String,
                            in dropOrder: [String]) -> String
    {
        guard let index = dropOrder.firstIndex(of: itemID),
              index < names.count
        else {
            return DemoItemCatalog.item(id: itemID)?.displayName ?? itemID
        }

        return names[index]
    }
}
