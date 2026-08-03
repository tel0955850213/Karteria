import Combine
import Foundation
import RevenueCat

@MainActor
final class EntitlementStore: ObservableObject {
    static let proEntitlementID = "pro"

    @Published private(set) var packages: [Package] = []
    @Published private(set) var isPro = false
    @Published private(set) var isConfigured = false
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var lastError: String?

    private var identifiedUserID: String?

    init(bundle: Bundle = .main) {
        let publicKey = (bundle.object(forInfoDictionaryKey: "REVENUECAT_PUBLIC_SDK_KEY") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard publicKey.hasPrefix("appl_") else { return }
        Purchases.configure(withAPIKey: publicKey)
        isConfigured = true
        Task {
            await refresh()
            await loadPackages()
        }
    }

    var monthly: Package? {
        packages.first { $0.packageType == .monthly }
    }

    var yearly: Package? {
        packages.first { $0.packageType == .annual }
    }

    func canCreateGoal(activeGoalCount: Int) -> Bool {
        isPro || activeGoalCount < 1
    }

    func identify(_ userID: String) async {
        guard isConfigured, identifiedUserID != userID else { return }
        do {
            let result = try await Purchases.shared.logIn(userID)
            identifiedUserID = userID
            apply(result.customerInfo)
            await loadPackages()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadPackages() async {
        guard isConfigured else { return }
        do {
            packages = try await Purchases.shared.offerings().current?.availablePackages ?? []
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard isConfigured else { return }
        do {
            apply(try await Purchases.shared.customerInfo())
        } catch {
            lastError = error.localizedDescription
        }
    }

    func purchase(_ package: Package) async {
        guard isConfigured, purchasingProductID == nil else { return }
        purchasingProductID = package.storeProduct.productIdentifier
        defer { purchasingProductID = nil }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            apply(result.customerInfo)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        guard isConfigured else { return }
        do {
            apply(try await Purchases.shared.restorePurchases())
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ customerInfo: CustomerInfo) {
        isPro = customerInfo.entitlements.active[Self.proEntitlementID]?.isActive == true
    }
}
