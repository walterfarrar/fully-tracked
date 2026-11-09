import Foundation
import SwiftData

/// The journal store shared by the app and by App Intents.
/// `FullyTrackedApp` should keep this container instead of opening a second one.
enum SharedContainer {
    static let schema = Schema([
        JournalEntry.self,
        Drink.self,
        StrengthLevel.self,
        StrengthScaleSetting.self,
        FoodItem.self,
        HydrationAmount.self,
        EventType.self,
        Emotion.self,
        Substance.self,
        PlaceCacheEntry.self,
        HealthSample.self,
        HealthDailyRollup.self,
        HealthSyncAnchor.self,
    ])

    static let container: ModelContainer = {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("The journal store could not be opened.")
        }
    }()

    @MainActor
    static var context: ModelContext {
        container.mainContext
    }
}
