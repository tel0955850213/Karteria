import AuthenticationServices
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var communityAccess: CommunityAccessStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @Query private var profiles: [ProfileRecord]
    @Query private var goals: [GoalRecord]
    @Query private var levels: [LevelRecord]

    @State private var isPresentingAccess = false
    @State private var isPresentingPaywall = false
    @State private var preparedExportURL: URL?
    @State private var isConfirmingPrivateDataDeletion = false
    @State private var isDeletingPrivateData = false
    @State private var dataMessage: String?

    private var profile: ProfileRecord? { profiles.sorted { $0.createdAt < $1.createdAt }.first }
    private var activeGoalCount: Int { goals.filter { $0.status == .active }.count }

    var body: some View {
        NavigationStack {
            List {
                Section("Exchange access") {
                    LabeledContent("iCloud", value: communityAccess.iCloudState.label)
                    LabeledContent("Sign in with Apple", value: communityAccess.isSignedInWithApple ? "Connected" : "Not connected")
                    LabeledContent("Anonymous queue", value: communityAccess.canUseAnonymousExchange ? "Eligible" : "Private only")
                    Button("Manage access") { isPresentingAccess = true }
                }

                Section("Review standing") {
                    LabeledContent("Review credits", value: "\(profile?.reviewCredits ?? CreditBalance.initialCredits)")
                    LabeledContent("Calibration", value: "\(profile?.calibrationCorrect ?? 0)/\(profile?.calibrationCompleted ?? 0) correct")
                    Text("Every qualified vote has equal weight. Reliability concerns send a reviewer back through calibration rather than changing vote weight.")
                        .font(.caption)
                        .foregroundStyle(Color.karteriaMuted)
                }

                Section("Karteria Pro") {
                    LabeledContent("Plan", value: entitlements.isPro ? "Pro" : "Free")
                    LabeledContent("Active goals", value: "\(activeGoalCount)/\(entitlements.isPro ? "Unlimited" : "1")")
                    Button("View Pro") { isPresentingPaywall = true }
                }

                Section("Privacy and safety") {
                    Text("Private practice stays in your private journey. Public review copies are scheduled for deletion 30 days after settlement.")
                    Text("You can only send evidence to anonymous review after iCloud, Sign in with Apple, and the 18+ gate are complete.")
                }

                Section("Your data") {
                    Button("Prepare private data export") { prepareExport() }
                    if let preparedExportURL {
                        ShareLink(item: preparedExportURL) {
                            Label("Share private data export", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        isConfirmingPrivateDataDeletion = true
                    } label: {
                        Text(isDeletingPrivateData ? "Removing private data" : "Delete private practice data")
                    }
                    .disabled(isDeletingPrivateData)
                }

                Section("Support") {
                    if let supportEmail {
                        Link("Contact support", destination: URL(string: "mailto:\(supportEmail)")!)
                    } else {
                        Text("A public support contact must be configured before this build can be released.")
                            .font(.caption)
                            .foregroundStyle(Color.karteriaCoral)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.karteriaPaper)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isPresentingAccess) {
                CommunityAccessSheet()
            }
            .sheet(isPresented: $isPresentingPaywall) {
                PaywallView()
            }
            .confirmationDialog(
                "Delete private practice data?",
                isPresented: $isConfirmingPrivateDataDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete private data", role: .destructive) { deletePrivateJourney() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Karteria first removes any remaining public evidence and trusted iCloud shares, then removes goals, practice reps, private evidence, and local sign-in state. Settled verification outcomes are never fabricated or altered.")
            }
            .alert("Your data", isPresented: Binding(
                get: { dataMessage != nil },
                set: { if !$0 { dataMessage = nil } }
            )) {
                Button("OK", role: .cancel) { dataMessage = nil }
            } message: {
                Text(dataMessage ?? "")
            }
        }
    }

    private var supportEmail: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "KARTERIA_SUPPORT_EMAIL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("@") ? value : nil
    }

    private func prepareExport() {
        do {
            preparedExportURL = try PrivateDataExportService.prepareArchive(modelContext: modelContext)
            dataMessage = "Your private Journey export is ready to share."
        } catch {
            dataMessage = "Karteria could not prepare the export: \(error.localizedDescription)"
        }
    }

    private func deletePrivateJourney() {
        guard !isDeletingPrivateData else { return }
        isDeletingPrivateData = true
        let levelsToDelete = levels
        Task {
            defer { isDeletingPrivateData = false }
            do {
                try await RemoteEvidenceDeletionService.removeRemoteCopies(
                    for: levelsToDelete,
                    communityAccess: communityAccess
                )
                try PrivateDataExportService.erasePrivateJourney(modelContext: modelContext)
                communityAccess.signOutLocally()
                preparedExportURL = nil
                dataMessage = "Private practice data and any remaining evidence copies were deleted."
            } catch {
                dataMessage = "Karteria stopped before deleting local data: \(error.localizedDescription)"
            }
        }
    }
}

struct CommunityAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var communityAccess: CommunityAccessStore
    @EnvironmentObject private var entitlements: EntitlementStore

    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -18, to: .now) ?? .now

    private var minimumAllowedDate: Date {
        Calendar.current.date(byAdding: .year, value: -13, to: .now) ?? .now
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    KarteriaSectionHeading(
                        "Community access",
                        title: "Practice stays available without an account.",
                        detail: "Anonymous exchange needs iCloud, Sign in with Apple, and an 18+ age gate. Members 13 to 17 use private practice and invite-only trusted review."
                    )

                    KarteriaSurface {
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("iCloud", value: communityAccess.iCloudState.label)
                            Button("Check iCloud again") {
                                Task { await communityAccess.refreshICloudStatus() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(14)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Date of birth")
                            .font(.subheadline.weight(.semibold))
                        DatePicker(
                            "Date of birth",
                            selection: $birthDate,
                            in: ...minimumAllowedDate,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        Button("Confirm age") {
                            communityAccess.updateBirthDate(birthDate)
                            PrivateJourneyRepository(modelContext: modelContext).updateProfile(
                                birthDate: birthDate,
                                appleUserID: communityAccess.appleUserID
                            )
                        }
                        .buttonStyle(.bordered)
                    }

                    if communityAccess.isSignedInWithApple {
                        KarteriaSurface {
                            Label("Sign in with Apple is connected", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.karteriaSignal)
                                .padding(14)
                        }
                    } else {
                        SignInWithAppleButton(.signIn) { request in
                            request.requestedScopes = []
                        } onCompletion: { result in
                            communityAccess.completeAppleSignIn(result)
                            PrivateJourneyRepository(modelContext: modelContext).updateProfile(
                                birthDate: communityAccess.birthDate,
                                appleUserID: communityAccess.appleUserID
                            )
                            if let appleUserID = communityAccess.appleUserID {
                                Task { await entitlements.identify(appleUserID) }
                            }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 48)
                    }

                    if let requirement = communityAccess.accessRequirement {
                        Text(requirement)
                            .font(.caption)
                            .foregroundStyle(Color.karteriaCoral)
                    } else {
                        Label("Anonymous exchange is ready", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.karteriaSignal)
                    }
                }
                .padding(20)
            }
            .karteriaPage()
            .navigationTitle("Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var entitlements: EntitlementStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    KarteriaSectionHeading(
                        "Karteria Pro",
                        title: "More active goals. Never more votes.",
                        detail: "Pro adds planning and portfolio tools without letting anyone buy a review, a credit, or a verified level."
                    )

                    KarteriaSurface {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Unlimited active goals", systemImage: "flag")
                            Label("Cross-goal patterns and advanced reflection", systemImage: "chart.xyaxis.line")
                            Label("Private 60-second evidence and portfolio export", systemImage: "doc.richtext")
                        }
                        .font(.subheadline)
                        .padding(16)
                    }

                    if entitlements.isConfigured, !entitlements.packages.isEmpty {
                        ForEach(entitlements.packages, id: \.identifier) { package in
                            Button {
                                Task { await entitlements.purchase(package) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(package.storeProduct.localizedTitle)
                                            .font(.headline)
                                        Text(package.storeProduct.localizedPriceString)
                                            .font(.subheadline)
                                        if package.packageType == .annual {
                                            Text("7-day free trial, then annual billing")
                                                .font(.caption.weight(.semibold))
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Restore purchases") {
                            Task { await entitlements.restore() }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        KarteriaSurface {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Store products are not configured in this build.")
                                    .font(.subheadline.weight(.semibold))
                                Text("The release configuration will supply RevenueCat's public SDK key and the monthly and annual offerings.")
                                    .font(.caption)
                                    .foregroundStyle(Color.karteriaMuted)
                            }
                            .padding(14)
                        }
                    }

                    Text("Community Pro Pass: nine settled, quality reviews earn seven days of Pro, up to fourteen days in each rolling thirty-day period.")
                        .font(.caption)
                        .foregroundStyle(Color.karteriaMuted)

                    Text("Subscriptions renew automatically unless canceled at least 24 hours before the current period ends. Payment is charged to your Apple Account. Manage or cancel in Apple Account settings.")
                        .font(.caption)
                        .foregroundStyle(Color.karteriaMuted)

                    HStack(spacing: 16) {
                        Link("Privacy Policy", destination: URL(string: "https://tel0955850213.github.io/Karteria/privacy-policy.html")!)
                        Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(20)
            }
            .karteriaPage()
            .navigationTitle("Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ContentReportSheet: View {
    let submissionID: UUID?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var communityAccess: CommunityAccessStore

    @State private var reason = "Unsafe or sensitive content"
    @State private var detail = ""
    @State private var message: String?

    private let exchangeClient = ReviewExchangeClient()

    var body: some View {
        NavigationStack {
            Form {
                Picker("Reason", selection: $reason) {
                    Text("Unsafe or sensitive content").tag("Unsafe or sensitive content")
                    Text("Private information").tag("Private information")
                    Text("Harassment or abuse").tag("Harassment or abuse")
                    Text("Other policy issue").tag("Other policy issue")
                }
                TextField("What should a moderator know?", text: $detail, axis: .vertical)
                    .lineLimit(3...6)
            }
            .navigationTitle("Report content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Report", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK") { dismiss() }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func send() {
        guard let submissionID else {
            message = "This review is no longer reportable."
            return
        }
        Task {
            do {
                try await exchangeClient.reportContent(
                    submissionID: submissionID,
                    reason: reason,
                    detail: detail,
                    identityToken: communityAccess.identityToken
                )
                message = "Report sent."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
