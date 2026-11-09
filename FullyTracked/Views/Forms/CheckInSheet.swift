import SwiftUI

struct CheckInSheet: View {
    var kind: CheckInKind
    var openSettings: (SettingsTab) -> Void

    var body: some View {
        switch kind {
        case .meal:
            MealForm(openSettings: openSettings)
        case .hydration:
            HydrationForm(openSettings: openSettings)
        case .bathroom:
            BathroomForm()
        case .lifeEvent:
            LifeEventForm()
        case .mood:
            MoodForm()
        case .sleep:
            SleepForm()
        case .dose:
            DoseForm(openSettings: openSettings)
        }
    }
}
