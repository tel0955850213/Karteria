import SwiftData
import SwiftUI

@main
struct KarteriaApp: App {
    @UIApplicationDelegateAdaptor(KarteriaAppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([
            ProfileRecord.self,
            GoalRecord.self,
            LevelRecord.self,
            PracticeRepRecord.self,
            EvidenceRecord.self,
        ])
        let useInMemoryStore = ProcessInfo.processInfo.arguments.contains("-uiTesting")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let configuration = ModelConfiguration(
            "Karteria",
            schema: schema,
            isStoredInMemoryOnly: useInMemoryStore,
            cloudKitDatabase: useInMemoryStore
                ? .none
                : .private("iCloud.com.donaldlin.karteria")
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let localConfiguration = ModelConfiguration(
                "Karteria",
                schema: schema,
                isStoredInMemoryOnly: useInMemoryStore,
                cloudKitDatabase: .none
            )
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [localConfiguration])
            } catch {
                fatalError("Karteria could not initialize private storage: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            KarteriaRootView()
                .modelContainer(modelContainer)
        }
    }
}
