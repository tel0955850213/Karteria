import SwiftData
import SwiftUI

enum KarteriaTab: Hashable {
    case exchange
    case practice
    case journey
}

@MainActor
final class KarteriaNavigation: ObservableObject {
    @Published var selectedTab: KarteriaTab = .exchange
    @Published var isPresentingGoalCreation = false
}

struct KarteriaRootView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var navigation = KarteriaNavigation()
    @StateObject private var communityAccess = CommunityAccessStore()
    @StateObject private var entitlements = EntitlementStore()
    @State private var didBootstrap = false

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            ExchangeView()
            .tag(KarteriaTab.exchange)
            .tabItem { Label("Exchange", systemImage: "arrow.left.arrow.right") }

            PracticeView()
            .tag(KarteriaTab.practice)
            .tabItem { Label("Practice", systemImage: "checklist") }

            JourneyView()
            .tag(KarteriaTab.journey)
            .tabItem { Label("Journey", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
        }
        .environmentObject(navigation)
        .environmentObject(communityAccess)
        .environmentObject(entitlements)
        .tint(.karteriaCobalt)
        .preferredColorScheme(.light)
        .karteriaPage()
        .sheet(isPresented: $navigation.isPresentingGoalCreation) {
            GoalCreationSheet()
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            let repository = PrivateJourneyRepository(modelContext: modelContext)
            repository.bootstrap(
                seedDemo: ProcessInfo.processInfo.arguments.contains("-demo")
            )
            communityAccess.apply(profile: repository.primaryProfile())
            await communityAccess.refreshICloudStatus()
            if let appleUserID = communityAccess.appleUserID {
                await entitlements.identify(appleUserID)
            }
        }
    }
}
