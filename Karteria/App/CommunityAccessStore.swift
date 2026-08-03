import AuthenticationServices
import CloudKit
import Combine
import Foundation

@MainActor
final class CommunityAccessStore: ObservableObject {
    enum ICloudState: Equatable {
        case checking
        case available
        case unavailable

        var label: String {
            switch self {
            case .checking: return "Checking iCloud"
            case .available: return "iCloud available"
            case .unavailable: return "iCloud unavailable"
            }
        }
    }

    @Published private(set) var iCloudState: ICloudState = .checking
    @Published private(set) var appleUserID: String?
    @Published private(set) var identityToken: String?
    @Published private(set) var lastError: String?
    @Published private(set) var birthDate: Date?

    static let appleUserDefaultsKey = "Karteria.appleUserID"

    private let container: CKContainer
    private let isDemoMode: Bool

    init(container: CKContainer = CKContainer(identifier: "iCloud.com.donaldlin.karteria")) {
        self.container = container
        self.isDemoMode = ProcessInfo.processInfo.arguments.contains("-demo")
        self.appleUserID = UserDefaults.standard.string(forKey: Self.appleUserDefaultsKey)
        if isDemoMode {
            appleUserID = "demo-karteria-member"
            identityToken = "demo-token"
            iCloudState = .available
            birthDate = Calendar.current.date(byAdding: .year, value: -22, to: .now)
        }
    }

    var isSignedInWithApple: Bool { appleUserID != nil }
    var allowsLocalDemo: Bool { isDemoMode }

    var age: Int? {
        guard let birthDate else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: .now).year
    }

    var birthDateISO8601: String? {
        guard let birthDate else { return nil }
        return Self.birthDateFormatter.string(from: birthDate)
    }

    var isAdult: Bool { (age ?? 0) >= 18 }

    var canUseAnonymousExchange: Bool {
        iCloudState == .available && isSignedInWithApple && isAdult
    }

    var canUseTrustedReview: Bool {
        iCloudState == .available && (age ?? 0) >= 13
    }

    var canSubmitCheckpoint: Bool {
        canUseAnonymousExchange || canUseTrustedReview
    }

    var accessRequirement: String? {
        if iCloudState != .available { return "Sign in to iCloud to use anonymous exchange." }
        if !isSignedInWithApple { return "Sign in with Apple to protect anonymous exchange." }
        if !isAdult { return "Anonymous exchange is available to members 18 and older." }
        if identityToken == nil && !isDemoMode { return "Sign in again with Apple before a protected exchange request." }
        return nil
    }

    var trustedReviewRequirement: String? {
        if iCloudState != .available { return "Sign in to iCloud to invite a trusted reviewer." }
        if (age ?? 0) < 13 { return "Trusted review is available from age 13." }
        return nil
    }

    func refreshICloudStatus() async {
        guard !isDemoMode else { return }
        iCloudState = .checking
        do {
            let status = try await container.accountStatus()
            iCloudState = status == .available ? .available : .unavailable
        } catch {
            iCloudState = .unavailable
            lastError = error.localizedDescription
        }
    }

    func apply(profile: ProfileRecord) {
        if let profileBirthDate = profile.birthDate {
            birthDate = profileBirthDate
        }
        if appleUserID == nil, let persistedAppleID = profile.appleUserID {
            appleUserID = persistedAppleID
        }
    }

    func updateBirthDate(_ value: Date?) {
        birthDate = value
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                lastError = "Apple did not return a Sign in with Apple credential."
                return
            }
            appleUserID = credential.user
            identityToken = credential.identityToken.flatMap { String(data: $0, encoding: .utf8) }
            UserDefaults.standard.set(credential.user, forKey: Self.appleUserDefaultsKey)
            lastError = identityToken == nil
                ? "Apple identity was saved. Sign in again before a protected exchange request."
                : nil
        }
    }

    func signOutLocally() {
        appleUserID = nil
        identityToken = nil
        UserDefaults.standard.removeObject(forKey: Self.appleUserDefaultsKey)
    }

    private static let birthDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
