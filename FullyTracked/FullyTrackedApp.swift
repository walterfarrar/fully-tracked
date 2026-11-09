import SwiftData
import SwiftUI
import UIKit

@main
struct FullyTrackedApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer

    init() {
        // One store, shared with App Intents. The schema lives in SharedContainer.
        container = SharedContainer.container
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
