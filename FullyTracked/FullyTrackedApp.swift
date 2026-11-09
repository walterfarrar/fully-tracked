import SwiftData
import SwiftUI
import UIKit

@main
struct FullyTrackedApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer

    init() {
        let schema = Schema([
            JournalEntry.self,
            Drink.self,
            StrengthLevel.self,
            StrengthScaleSetting.self,
            FoodItem.self,
            HydrationAmount.self,
            EventType.self,
            Emotion.self,
            Substance.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("The journal store could not be opened.")
        }
        LocationTracker.shared.attach(container)
        HealthSteps.shared.attach(container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(LocationTracker.shared)
                .environmentObject(HealthSteps.shared)
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Theme.applyChrome()
        LocationTracker.shared.start()
        HealthSteps.shared.start()
        return true
    }
}
