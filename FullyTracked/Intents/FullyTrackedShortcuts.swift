import AppIntents

struct FullyTrackedShortcuts: AppShortcutsProvider {
    // `appShortcuts` is an @AppShortcutsBuilder; list the shortcuts directly, not in an array literal.
    static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: LogDrinkIntent(),
                phrases: [
                    "Log a drink in \(.applicationName)",
                    "Log hydration in \(.applicationName)",
                ],
                shortTitle: "Log a drink",
                systemImageName: "cup.and.saucer"
            )
            AppShortcut(
                intent: LogMoodIntent(),
                phrases: [
                    "Log my mood in \(.applicationName)",
                    "Record my mood in \(.applicationName)",
                ],
                shortTitle: "Log mood",
                systemImageName: "face.smiling"
            )
            AppShortcut(
                intent: LogWaterIntent(),
                phrases: [
                    "Log water in \(.applicationName)",
                    "Log my water in \(.applicationName)",
                ],
                shortTitle: "Log water",
                systemImageName: "drop"
            )
            AppShortcut(
                intent: LogSleepIntent(),
                phrases: [
                    "Log sleep in \(.applicationName)",
                    "Log my sleep in \(.applicationName)",
                ],
                shortTitle: "Log sleep",
                systemImageName: "moon"
            )
            AppShortcut(
                intent: LogDoseIntent(),
                phrases: [
                    "Log a dose in \(.applicationName)",
                    "Log my dose in \(.applicationName)",
                ],
                shortTitle: "Log a dose",
                systemImageName: "pills"
            )
            AppShortcut(
                intent: CheckInLocationIntent(),
                phrases: [
                    "Check in my location in \(.applicationName)",
                    "Log my location in \(.applicationName)",
                ],
                shortTitle: "Check in",
                systemImageName: "mappin.and.ellipse"
            )
            AppShortcut(
                intent: TodaySummaryIntent(),
                phrases: [
                    "Summarize today in \(.applicationName)",
                    "Give today's summary in \(.applicationName)",
                ],
                shortTitle: "Today",
                systemImageName: "list.bullet"
            )
    }
}
