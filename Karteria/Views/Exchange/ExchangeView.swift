import SwiftData
import SwiftUI

struct ExchangeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var navigation: KarteriaNavigation
    @EnvironmentObject private var communityAccess: CommunityAccessStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @Query private var goals: [GoalRecord]
    @Query private var levels: [LevelRecord]
    @Query private var evidence: [EvidenceRecord]
    @Query private var profiles: [ProfileRecord]

    @State private var isPresentingSettings = false
    @State private var isPresentingAccess = false
    @State private var activeReview: ReviewWorkItem?
    @State private var isClaimingReview = false
    @State private var exchangeMessage: String?
    @State private var queueIsEmpty = false
    @State private var publicSubmissionStatus: SubmissionStatusResponse?
    @State private var trustedReviewItems: [ReviewWorkItem] = []
    @State private var isLoadingTrustedReviews = false
    @State private var isCreatingTrustedInvitation = false
    @State private var trustedOwnerStatus: TrustedReviewOwnerStatus?
    @State private var trustedInvitation: TrustedReviewInvitation?
    @State private var isConfirmingPublicEvidenceRemoval = false
    @State private var isRemovingPublicEvidence = false
    @State private var isConfirmingTrustedReviewRemoval = false
    @State private var isRemovingTrustedReview = false

    private let exchangeClient = ReviewExchangeClient()

    private var activeGoal: GoalRecord? {
        goals.filter { $0.status == .active }.sorted { $0.createdAt < $1.createdAt }.first
    }

    private var activeLevel: LevelRecord? {
        guard let activeGoal else { return nil }
        return levels
            .filter { $0.goalID == activeGoal.id && $0.number == activeGoal.activeLevelNumber }
            .first
    }

    private var profile: ProfileRecord? {
        profiles.sorted { $0.createdAt < $1.createdAt }.first
    }

    private var standing: ReviewerStanding {
        ReviewerStanding(
            calibrationCompleted: profile?.calibrationCompleted ?? 0,
            calibrationCorrect: profile?.calibrationCorrect ?? 0,
            status: ReviewerCalibrationStatus(rawValue: profile?.calibrationStatusRaw ?? "") ?? .notStarted
        )
    }

    private var credits: Int { profile?.reviewCredits ?? CreditBalance.initialCredits }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    KarteriaHeader(section: "Exchange") {
                        isPresentingSettings = true
                    }

                    if let goal = activeGoal, let level = activeLevel {
                        proofStatus(goal: goal, level: level)
                        if communityAccess.canUseAnonymousExchange || communityAccess.allowsLocalDemo {
                            reviewerAction
                        }
                        trustedReviewInbox
                        exchangeRules
                    } else {
                        EmptyExchangeView {
                            navigation.selectedTab = .practice
                            navigation.isPresentingGoalCreation = true
                        }
                        trustedReviewInbox
                    }
                }
                .padding(20)
                .padding(.bottom, 92)
            }
            .karteriaPage()
            .navigationBarHidden(true)
            .sheet(isPresented: $isPresentingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $isPresentingAccess) {
                CommunityAccessSheet()
            }
            .sheet(item: $trustedInvitation) { invitation in
                TrustedReviewShareSheet(invitation: invitation)
            }
            .confirmationDialog(
                "Remove public evidence?",
                isPresented: $isConfirmingPublicEvidenceRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove public evidence", role: .destructive) {
                    withdrawPublicEvidence()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the anonymous evidence copy and its open review seats. It does not alter any settled verification outcome.")
            }
            .confirmationDialog(
                "Remove trusted invitation?",
                isPresented: $isConfirmingTrustedReviewRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove trusted invitation", role: .destructive) {
                    removeTrustedInvitation()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the iCloud shared copy and revokes the invite. It never changes anonymous verification.")
            }
            .fullScreenCover(item: $activeReview) { workItem in
                ReviewSessionView(item: workItem) { response in
                    handle(response: response, for: workItem)
                }
            }
            .alert("Exchange", isPresented: Binding(
                get: { exchangeMessage != nil },
                set: { if !$0 { exchangeMessage = nil } }
            )) {
                Button("OK", role: .cancel) { exchangeMessage = nil }
            } message: {
                Text(exchangeMessage ?? "")
            }
            .task(id: activeLevel?.reviewSubmissionID) {
                await refreshPublicSettlementIfNeeded()
            }
            .task(id: activeLevel?.trustedReviewRecordName) {
                await refreshTrustedOwnerStatusIfNeeded()
            }
            .task(id: communityAccess.canUseTrustedReview) {
                await refreshTrustedReviewInbox()
            }
        }
    }

    @ViewBuilder
    private func proofStatus(goal: GoalRecord, level: LevelRecord) -> some View {
        KarteriaSectionHeading(
            "Your checkpoint",
            title: level.contractTitle.isEmpty ? level.title : level.contractTitle,
            detail: goal.title
        )

        KarteriaSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusChip(title: proofStatusLabel(level.status), color: proofStatusColor(level.status))
                    Spacer()
                    Text("Level \(level.number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.karteriaMuted)
                }
                ReviewSeatDiagram(levelStatus: level.status)
                Text(proofStatusDetail(level.status))
                    .font(.subheadline)
                    .foregroundStyle(Color.karteriaMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if level.status == .awaitingReview, let publicSubmissionStatus {
                    Text("\(publicSubmissionStatus.reviewCount) of 3 reviews received")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.karteriaCobalt)
                    if publicSubmissionStatus.canInviteTrustedReview {
                        Text("Anonymous seats remain open. You can also request private feedback from one trusted person; that feedback never changes the 2-of-3 outcome.")
                            .font(.caption)
                            .foregroundStyle(Color.karteriaMuted)
                        if level.trustedReviewRecordName == nil {
                            Button {
                                inviteTrustedReviewer(for: goal, level: level)
                            } label: {
                                Label(
                                    isCreatingTrustedInvitation ? "Preparing invite" : "Invite trusted reviewer",
                                    systemImage: "person.crop.circle.badge.plus"
                                )
                            }
                            .buttonStyle(.bordered)
                            .disabled(isCreatingTrustedInvitation || !communityAccess.canUseTrustedReview)
                        }
                    }
                }
                if level.status == .awaitingReview {
                    Button(role: .destructive) {
                        isConfirmingPublicEvidenceRemoval = true
                    } label: {
                        Label(
                            isRemovingPublicEvidence ? "Removing public evidence" : "Remove public evidence",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRemovingPublicEvidence)
                }
            }
            .padding(16)
        }

        if let trustedOwnerStatus, level.trustedReviewRecordName != nil {
            KarteriaSurface {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Trusted feedback", systemImage: "person.2")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        StatusChip(
                            title: trustedOwnerStatus.state.label,
                            color: trustedOwnerStatus.state == .completed ? .karteriaSignal : .karteriaCobalt
                        )
                    }
                    if trustedOwnerStatus.state == .completed {
                        Text(trustedFeedbackSummary(trustedOwnerStatus))
                            .font(.caption)
                            .foregroundStyle(Color.karteriaMuted)
                        if !trustedOwnerStatus.note.isEmpty {
                            Text(trustedOwnerStatus.note)
                                .font(.caption)
                                .foregroundStyle(Color.karteriaInk)
                        }
                        Text("Trusted feedback is private and never unlocks an anonymous verification badge or a new Level.")
                            .font(.caption2)
                            .foregroundStyle(Color.karteriaMuted)
                    } else {
                        Text("The invitation is private. The first invited reviewer can respond against the same three criteria.")
                            .font(.caption)
                            .foregroundStyle(Color.karteriaMuted)
                    }
                    Button(role: .destructive) {
                        isConfirmingTrustedReviewRemoval = true
                    } label: {
                        Label(
                            isRemovingTrustedReview ? "Removing trusted invitation" : "Remove trusted invitation",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRemovingTrustedReview)
                }
                .padding(14)
            }
        }

        if level.status == .practicing || level.status == .needsMorePractice {
            KarteriaPrimaryButton(title: "Prepare checkpoint", systemImage: "camera") {
                navigation.selectedTab = .practice
            }
        }
    }

    private var reviewerAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            KarteriaSectionHeading(
                "Review exchange",
                title: standing.isQualified ? "A proof is waiting for a careful reviewer." : "Qualify with calibration first.",
                detail: standing.isQualified
                    ? "Review the evidence against its contract. No identity, popularity, or AI vote is involved."
                    : "\(standing.calibrationCompleted) of 5 calibration cases complete. Four correct answers unlock the anonymous queue."
            )

            KarteriaPrimaryButton(
                title: isClaimingReview ? "Finding a review" : "Review Next",
                systemImage: "arrow.right"
            ) {
                requestNextReview()
            }
            .disabled(isClaimingReview)

            HStack {
                Label("\(credits) review credits", systemImage: "ticket")
                Spacer()
                if queueIsEmpty {
                    StatusChip(title: "Gate waived", color: .karteriaSignal)
                } else if standing.isQualified {
                    StatusChip(title: "Qualified", color: .karteriaSignal)
                } else {
                    StatusChip(title: "Calibration", color: .karteriaCobalt)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.karteriaInk)
        }
    }

    private var exchangeRules: some View {
        KarteriaSurface {
            VStack(alignment: .leading, spacing: 10) {
                Label("Exchange is anonymous by design", systemImage: "eye.slash")
                    .font(.subheadline.weight(.semibold))
                Text("A valid review earns one credit. Three reviewers assess the same contract, and two complete passes verify the level.")
                    .font(.caption)
                    .foregroundStyle(Color.karteriaMuted)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var trustedReviewInbox: some View {
        if communityAccess.canUseTrustedReview {
            KarteriaSurface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Trusted review inbox")
                                .font(.subheadline.weight(.semibold))
                            Text("Invite-only iCloud feedback. It does not earn credits or become an anonymous vote.")
                                .font(.caption)
                                .foregroundStyle(Color.karteriaMuted)
                        }
                        Spacer()
                        Button {
                            Task { await refreshTrustedReviewInbox() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh trusted review inbox")
                        .disabled(isLoadingTrustedReviews)
                    }

                    if isLoadingTrustedReviews {
                        ProgressView()
                            .tint(.karteriaCobalt)
                    } else if trustedReviewItems.isEmpty {
                        Text("No trusted invitations are waiting.")
                            .font(.caption)
                            .foregroundStyle(Color.karteriaMuted)
                    } else {
                        ForEach(trustedReviewItems) { item in
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.contractTitle)
                                        .font(.subheadline.weight(.semibold))
                                    Text("Three criteria, one private response")
                                        .font(.caption)
                                        .foregroundStyle(Color.karteriaMuted)
                                }
                                Spacer()
                                Button("Review") { activeReview = item }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func requestNextReview() {
        queueIsEmpty = false
        if !standing.isQualified {
            activeReview = CalibrationFixtures.next(after: standing.calibrationCompleted)
            return
        }
        guard communityAccess.canUseAnonymousExchange else {
            isPresentingAccess = true
            return
        }
        guard let birthDate = communityAccess.birthDateISO8601 else {
            isPresentingAccess = true
            return
        }
        isClaimingReview = true
        Task {
            defer { isClaimingReview = false }
            do {
                let response = try await exchangeClient.claimNext(
                birthDate: birthDate,
                identityToken: communityAccess.identityToken
                )
                queueIsEmpty = response.queueEmpty
                if let workItem = response.workItem {
                    activeReview = workItem
                } else {
                    exchangeMessage = "No eligible proof is available right now. Your checkpoint can submit without the review-credit gate until the exchange has work to match."
                }
            } catch {
                exchangeMessage = error.localizedDescription
            }
        }
    }

    private func handle(response: ReviewResponse, for workItem: ReviewWorkItem) {
        let repository = PrivateJourneyRepository(modelContext: modelContext)
        switch workItem.kind {
        case .calibration:
            let correct = response.decisions == workItem.calibrationAnswer
            if communityAccess.allowsLocalDemo {
                repository.recordCalibration(answerWasCorrect: correct)
                exchangeMessage = correct
                    ? "Calibration recorded."
                    : "Calibration recorded. Compare each answer with only the evidence shown in the next case."
            } else if exchangeClient.isConfigured,
                      let fixtureID = workItem.fixtureID,
                      communityAccess.canUseAnonymousExchange {
                Task {
                    do {
                        let standing = try await exchangeClient.recordCalibration(
                            caseID: fixtureID,
                            decisions: response.decisions,
                            identityToken: communityAccess.identityToken
                        )
                        repository.synchronizeReviewerStanding(
                            credits: standing.reviewCredits,
                            calibrationCompleted: standing.calibrationCompleted,
                            calibrationCorrect: standing.calibrationCorrect,
                            calibrationStatus: standing.calibrationStatus
                        )
                        exchangeMessage = correct
                            ? "Calibration recorded."
                            : "Calibration recorded. Compare each answer with only the evidence shown in the next case."
                    } catch {
                        exchangeMessage = error.localizedDescription
                    }
                }
            } else {
                exchangeMessage = "Sign in with Apple and configure the anonymous exchange before calibration can qualify a public review."
            }
        case .anonymousQueue:
            guard let submissionID = workItem.submissionID, let seatID = workItem.seatID else {
                exchangeMessage = "This review no longer has a valid seat."
                return
            }
            Task {
                do {
                    let result = try await exchangeClient.submitReview(
                        SubmitReviewRequest(
                            submissionID: submissionID,
                            seatID: seatID,
                            decisions: response.decisions,
                            note: response.note
                        ),
                        identityToken: communityAccess.identityToken
                    )
                    if result.accepted && result.earnedCredit {
                        if let credits = result.reviewCredits {
                            repository.synchronizeReviewCredits(credits)
                        } else {
                            repository.rewardReviewCredit()
                        }
                        exchangeMessage = "Review accepted. One review credit was added."
                    } else {
                        exchangeMessage = "Review was received."
                    }
                } catch {
                    exchangeMessage = error.localizedDescription
                }
            }
        case .trustedReview:
            guard let locator = workItem.trustedReviewLocator else {
                exchangeMessage = "This trusted invitation no longer has a valid record."
                return
            }
            Task {
                do {
                    try await TrustedReviewService.submit(
                        decisions: response.decisions,
                        note: response.note,
                        locator: locator
                    )
                    exchangeMessage = "Trusted feedback sent. It does not earn a credit or change anonymous verification."
                    await refreshTrustedReviewInbox()
                } catch {
                    exchangeMessage = error.localizedDescription
                }
            }
        }
    }

    private func proofStatusLabel(_ status: LevelStatus) -> String {
        switch status {
        case .locked: return "Locked"
        case .practicing: return "Practicing"
        case .awaitingReview: return "Awaiting 3 reviewers"
        case .verified: return "Verified"
        case .needsMorePractice: return "Practice focus"
        }
    }

    private func proofStatusColor(_ status: LevelStatus) -> Color {
        switch status {
        case .verified: return .karteriaSignal
        case .needsMorePractice: return .karteriaCoral
        case .awaitingReview: return .karteriaCobalt
        case .locked: return .karteriaMuted
        case .practicing: return .karteriaCobalt
        }
    }

    private func proofStatusDetail(_ status: LevelStatus) -> String {
        switch status {
        case .awaitingReview: return "Three anonymous seats are open. Your next level stays locked until the evidence settles."
        case .verified: return "Two or more reviewers verified this level."
        case .needsMorePractice: return "The next private rep should target the criterion that was not shown."
        case .practicing: return "Build a baseline, define the proof, then submit when the checkpoint is ready."
        case .locked: return "Complete the current level before opening this contract."
        }
    }

    @MainActor
    private func refreshPublicSettlementIfNeeded() async {
        guard !communityAccess.allowsLocalDemo,
              exchangeClient.isConfigured,
              communityAccess.canUseAnonymousExchange,
              let goal = activeGoal,
              let level = activeLevel,
              level.status == .awaitingReview,
              let submissionID = level.reviewSubmissionID
        else { return }
        do {
            let status = try await exchangeClient.status(
                submissionID: submissionID,
                identityToken: communityAccess.identityToken
            )
            publicSubmissionStatus = status
            guard let publicSettlement = status.settlement else { return }
            let settlement = ReviewSettlement(
                id: "settlement-\(submissionID.uuidString.lowercased())",
                submissionID: submissionID,
                reviewedAt: publicSettlement.reviewedAt,
                outcome: publicSettlement.outcome,
                countedReviewIDs: [],
                failedCriteriaIndexes: publicSettlement.failedCriteriaIndexes
            )
            PrivateJourneyRepository(modelContext: modelContext).apply(
                settlement: settlement,
                to: level,
                in: goal
            )
        } catch {
            // Background status refresh must not interrupt private practice when offline.
        }
    }

    @MainActor
    private func refreshTrustedReviewInbox() async {
        guard communityAccess.canUseTrustedReview, !isLoadingTrustedReviews else { return }
        isLoadingTrustedReviews = true
        defer { isLoadingTrustedReviews = false }
        do {
            trustedReviewItems = try await TrustedReviewService.pendingSharedWorkItems()
        } catch {
            // A missing iCloud account or a just-accepted share must not block private practice.
            trustedReviewItems = []
        }
    }

    @MainActor
    private func refreshTrustedOwnerStatusIfNeeded() async {
        guard let level = activeLevel,
              let recordName = level.trustedReviewRecordName,
              communityAccess.canUseTrustedReview
        else {
            trustedOwnerStatus = nil
            return
        }
        do {
            let status = try await TrustedReviewService.ownerStatus(recordName: recordName)
            trustedOwnerStatus = status
            PrivateJourneyRepository(modelContext: modelContext).applyTrustedReviewStatus(status, to: level)
        } catch {
            trustedOwnerStatus = nil
        }
    }

    private func inviteTrustedReviewer(for goal: GoalRecord, level: LevelRecord) {
        guard communityAccess.canUseTrustedReview else {
            isPresentingAccess = true
            return
        }
        let levelEvidence = evidence.filter { $0.levelID == level.id }
        let baseline = preparedEvidence(from: levelEvidence.filter(\.isBaseline))
        let checkpoint = preparedEvidence(from: levelEvidence.filter { !$0.isBaseline })
        let explanation = levelEvidence.sorted { $0.createdAt > $1.createdAt }.first?.caption ?? ""
        guard !baseline.isEmpty, !checkpoint.isEmpty else {
            exchangeMessage = "Karteria could not find both private evidence groups for a trusted invitation."
            return
        }
        isCreatingTrustedInvitation = true
        Task {
            defer { isCreatingTrustedInvitation = false }
            do {
                let invitation = try await TrustedReviewService.createInvitation(
                    goal: goal,
                    level: level,
                    baseline: baseline,
                    checkpoint: checkpoint,
                    explanation: explanation
                )
                PrivateJourneyRepository(modelContext: modelContext).recordTrustedReviewInvitation(
                    for: level,
                    recordName: invitation.id
                )
                trustedInvitation = invitation
            } catch {
                exchangeMessage = error.localizedDescription
            }
        }
    }

    private func withdrawPublicEvidence() {
        guard let level = activeLevel,
              let submissionID = level.reviewSubmissionID
        else {
            exchangeMessage = "This public evidence is no longer waiting for review."
            return
        }
        let repository = PrivateJourneyRepository(modelContext: modelContext)
        if communityAccess.allowsLocalDemo {
            repository.withdrawCheckpoint(for: level)
            publicSubmissionStatus = nil
            exchangeMessage = "The demo checkpoint returned to private practice."
            return
        }
        isRemovingPublicEvidence = true
        Task {
            defer { isRemovingPublicEvidence = false }
            do {
                try await exchangeClient.removeOwnSubmission(
                    submissionID: submissionID,
                    identityToken: communityAccess.identityToken
                )
                repository.withdrawCheckpoint(for: level)
                publicSubmissionStatus = nil
                exchangeMessage = "The public evidence copy and open review seats were removed. Your private practice remains available."
            } catch {
                exchangeMessage = error.localizedDescription
            }
        }
    }

    private func removeTrustedInvitation() {
        guard let level = activeLevel,
              let recordName = level.trustedReviewRecordName
        else {
            exchangeMessage = "This trusted invitation has already been removed."
            return
        }
        isRemovingTrustedReview = true
        Task {
            defer { isRemovingTrustedReview = false }
            do {
                try await TrustedReviewService.removeOwnedInvitation(recordName: recordName)
                PrivateJourneyRepository(modelContext: modelContext).removeTrustedReviewInvitation(from: level)
                trustedOwnerStatus = nil
                exchangeMessage = "The trusted iCloud copy was removed and the invitation was revoked."
            } catch {
                exchangeMessage = error.localizedDescription
            }
        }
    }

    private func preparedEvidence(from records: [EvidenceRecord]) -> [PreparedEvidenceMedia] {
        records
            .sorted { $0.createdAt < $1.createdAt }
            .map {
                PreparedEvidenceMedia(
                    id: $0.id,
                    kind: EvidenceMediaKind(rawValue: $0.kindRaw) ?? .image,
                    relativePath: $0.localRelativePath,
                    byteCount: $0.byteCount,
                    duration: $0.durationSeconds
                )
            }
    }

    private func trustedFeedbackSummary(_ status: TrustedReviewOwnerStatus) -> String {
        let labels = status.decisions.map(\.title).joined(separator: ", ")
        return labels.isEmpty ? "Trusted feedback was received." : "Criteria: \(labels)."
    }
}

private struct EmptyExchangeView: View {
    let createGoal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 28)
            KarteriaSectionHeading(
                "Proof needs a practice target",
                title: "Start with the identity you want to earn.",
                detail: "Daily reps stay private. A checkpoint only leaves your journey when you choose to ask for proof."
            )
            KarteriaPrimaryButton(title: "Create a goal", systemImage: "plus", action: createGoal)
            Spacer(minLength: 28)
        }
    }
}
