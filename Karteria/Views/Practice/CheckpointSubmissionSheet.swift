import PhotosUI
import SwiftData
import SwiftUI

struct CheckpointSubmissionSheet: View {
    let goal: GoalRecord
    let level: LevelRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var communityAccess: CommunityAccessStore
    @StateObject private var preflightService = EvidencePreflightService()

    @State private var baselineFormat: EvidenceFormat = .images
    @State private var checkpointFormat: EvidenceFormat = .images
    @State private var baselineImages: [PhotosPickerItem] = []
    @State private var checkpointImages: [PhotosPickerItem] = []
    @State private var baselineVideo: PhotosPickerItem?
    @State private var checkpointVideo: PhotosPickerItem?
    @State private var explanation = ""
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var isPresentingAccess = false
    @State private var preparedBaseline: [PreparedEvidenceMedia] = []
    @State private var preparedCheckpoint: [PreparedEvidenceMedia] = []
    @State private var safetyOutcome: EvidenceSafetyOutcome?
    @State private var preflightResult: EvidencePreflightResult?
    @State private var isPresentingRedaction = false
    @State private var trustedInvitation: TrustedReviewInvitation?

    private let exchangeClient = ReviewExchangeClient()

    private var baselineHasSelection: Bool {
        baselineFormat == .images ? !baselineImages.isEmpty : baselineVideo != nil
    }

    private var checkpointHasSelection: Bool {
        checkpointFormat == .images ? !checkpointImages.isEmpty : checkpointVideo != nil
    }

    private var usesTrustedReview: Bool {
        !communityAccess.canUseAnonymousExchange && communityAccess.canUseTrustedReview
    }

    private var reviewAudienceDetail: String {
        if usesTrustedReview {
            return "This stays in your private iCloud data and is shared only with a person you explicitly invite. It is never added to the anonymous queue."
        }
        return "Your baseline and checkpoint are visible only to the three anonymous reviewers assigned to this contract."
    }

    private var submitTitle: String {
        if isPreparing { return "Preparing evidence" }
        return usesTrustedReview ? "Invite trusted reviewer" : "Submit to exchange"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    KarteriaSectionHeading(
                        "Checkpoint",
                        title: level.contractTitle,
                        detail: reviewAudienceDetail
                    )

                    mediaSection(
                        title: "Baseline proof",
                        format: $baselineFormat,
                        imageItems: $baselineImages,
                        videoItem: $baselineVideo
                    )
                    mediaSection(
                        title: "Checkpoint proof",
                        format: $checkpointFormat,
                        imageItems: $checkpointImages,
                        videoItem: $checkpointVideo
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context for reviewers")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $explanation)
                            .frame(minHeight: 100)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.karteriaLine, lineWidth: 1)
                            }
                        Text("\(explanation.count)/1000")
                            .font(.caption)
                            .foregroundStyle(Color.karteriaMuted)
                    }

                    KarteriaSurface {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "hand.raised")
                                .foregroundStyle(Color.karteriaCoral)
                            Text("Do not submit medical judgments, nudity, dangerous or illegal activity, sexual content, relationship disputes, or someone else's private information to a review.")
                                .font(.caption)
                                .foregroundStyle(Color.karteriaMuted)
                        }
                        .padding(14)
                    }

                    if let safetyOutcome {
                        safetySummary(safetyOutcome)
                    }

                    if let preflightResult {
                        preflightSummary(preflightResult)
                    }

                    if !preparedBaseline.filter({ $0.kind == .image }).isEmpty || !preparedCheckpoint.filter({ $0.kind == .image }).isEmpty {
                        Button {
                            isPresentingRedaction = true
                        } label: {
                            Label("Crop or blur image proof", systemImage: "crop")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isPreparing)
                    }

                    Button {
                        checkEvidence()
                    } label: {
                        Label(isPreparing ? "Checking evidence" : "Check evidence", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isPreparing || !baselineHasSelection || !checkpointHasSelection)

                    KarteriaPrimaryButton(
                        title: submitTitle,
                        systemImage: usesTrustedReview ? "person.crop.circle.badge.plus" : "arrow.up.circle"
                    ) {
                        submit()
                    }
                    .disabled(isPreparing || preflightResult == nil || !baselineHasSelection || !checkpointHasSelection || explanation.count > EvidenceLimits.maximumExplanationCharacters)
                    .opacity(isPreparing || preflightResult == nil || !baselineHasSelection || !checkpointHasSelection || explanation.count > EvidenceLimits.maximumExplanationCharacters ? 0.45 : 1)
                }
                .padding(20)
            }
            .karteriaPage()
            .navigationTitle("Submit proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $isPresentingAccess) {
                CommunityAccessSheet()
            }
            .sheet(isPresented: $isPresentingRedaction) {
                EvidenceRedactionSheet(
                    baseline: $preparedBaseline,
                    checkpoint: $preparedCheckpoint,
                    onChanged: recheckPreparedEvidence
                )
            }
            .sheet(item: $trustedInvitation, onDismiss: { dismiss() }) { invitation in
                TrustedReviewShareSheet(invitation: invitation)
            }
            .alert("Checkpoint", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func mediaSection(
        title: String,
        format: Binding<EvidenceFormat>,
        imageItems: Binding<[PhotosPickerItem]>,
        videoItem: Binding<PhotosPickerItem?>
    ) -> some View {
        KarteriaSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Picker("\(title) format", selection: format) {
                    ForEach(EvidenceFormat.allCases) { option in
                        Text(option == .images ? "Images" : "Video").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: format.wrappedValue) { _, _ in
                    imageItems.wrappedValue = []
                    videoItem.wrappedValue = nil
                    resetAssessment()
                }

                if format.wrappedValue == .images {
                    PhotosPicker(
                        selection: imageItems,
                        maxSelectionCount: EvidenceLimits.maximumImages,
                        matching: .images
                    ) {
                        Label(
                            imageItems.wrappedValue.isEmpty ? "Choose up to 3 images" : "\(imageItems.wrappedValue.count) image(s) selected",
                            systemImage: "photo.on.rectangle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .onChange(of: imageItems.wrappedValue) { _, _ in resetAssessment() }
                } else {
                    PhotosPicker(selection: videoItem, matching: .videos) {
                        Label(videoItem.wrappedValue == nil ? "Choose one video" : "Video selected", systemImage: "video")
                    }
                    .buttonStyle(.bordered)
                    .onChange(of: videoItem.wrappedValue?.itemIdentifier) { _, _ in resetAssessment() }
                }
                Text(format.wrappedValue.label)
                    .font(.caption)
                    .foregroundStyle(Color.karteriaMuted)
            }
            .padding(14)
        }
    }

    private func submit() {
        guard communityAccess.canSubmitCheckpoint else {
            isPresentingAccess = true
            return
        }
        guard !preparedBaseline.isEmpty, !preparedCheckpoint.isEmpty else {
            errorMessage = "Check evidence before submitting this checkpoint."
            return
        }
        if communityAccess.canUseAnonymousExchange && communityAccess.allowsLocalDemo {
            savePrivateCheckpoint(submissionID: UUID(), reviewCredits: nil)
            return
        }
        if usesTrustedReview {
            submitTrustedReview()
            return
        }
        guard exchangeClient.isConfigured else {
            errorMessage = "This build has no configured public exchange publisher. It will not label private evidence as submitted until CloudKit and the Worker are configured."
            return
        }
        guard let manifest = submissionManifest() else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let result = try await exchangeClient.submitCheckpoint(
                    manifest: manifest,
                    baseline: preparedBaseline,
                    checkpoint: preparedCheckpoint,
                    identityToken: communityAccess.identityToken
                )
                savePrivateCheckpoint(submissionID: result.submissionID, reviewCredits: result.reviewCredits)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func checkEvidence() {
        guard communityAccess.canSubmitCheckpoint else {
            isPresentingAccess = true
            return
        }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let baseline = try await prepare(format: baselineFormat, images: baselineImages, video: baselineVideo)
                let checkpoint = try await prepare(format: checkpointFormat, images: checkpointImages, video: checkpointVideo)
                let allMedia = baseline + checkpoint
                let safety = await EvidenceSafetyInspector.inspect(allMedia)
                safetyOutcome = safety
                guard case .clear = safety else {
                    preparedBaseline = []
                    preparedCheckpoint = []
                    preflightResult = nil
                    return
                }
                let contract = EvidenceContract(
                    goalID: goal.id,
                    levelID: level.id,
                    title: level.contractTitle,
                    baselineSummary: level.baselineSummary,
                    criteria: level.criteria
                )
                preparedBaseline = baseline
                preparedCheckpoint = checkpoint
                preflightResult = await preflightService.assess(
                    contract: contract,
                    media: allMedia,
                    explanation: explanation
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetAssessment() {
        preparedBaseline = []
        preparedCheckpoint = []
        safetyOutcome = nil
        preflightResult = nil
    }

    private func recheckPreparedEvidence() {
        guard !preparedBaseline.isEmpty, !preparedCheckpoint.isEmpty else { return }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            let allMedia = preparedBaseline + preparedCheckpoint
            let safety = await EvidenceSafetyInspector.inspect(allMedia)
            safetyOutcome = safety
            guard case .clear = safety else {
                preflightResult = nil
                return
            }
            let contract = EvidenceContract(
                goalID: goal.id,
                levelID: level.id,
                title: level.contractTitle,
                baselineSummary: level.baselineSummary,
                criteria: level.criteria
            )
            preflightResult = await preflightService.assess(
                contract: contract,
                media: allMedia,
                explanation: explanation
            )
        }
    }

    private func submissionManifest() -> ExchangeSubmissionManifest? {
        guard let birthDate = communityAccess.birthDateISO8601 else {
            errorMessage = "Confirm your date of birth before entering anonymous exchange."
            return nil
        }
        let criteria = level.criteria.map(\.title)
        guard criteria.count == 3 else {
            errorMessage = "This checkpoint needs exactly three observable criteria."
            return nil
        }
        return ExchangeSubmissionManifest(
            submissionID: UUID(),
            birthDate: birthDate,
            contract: ExchangeEvidenceContract(
                title: level.contractTitle,
                baselineSummary: level.baselineSummary,
                criteria: criteria
            ),
            explanation: explanation,
            baseline: preparedBaseline.map { ExchangeMediaDescriptor($0, label: "Baseline proof") },
            checkpoint: preparedCheckpoint.map { ExchangeMediaDescriptor($0, label: "Checkpoint proof") }
        )
    }

    private func savePrivateCheckpoint(submissionID: UUID, reviewCredits: Int?) {
        let repository = PrivateJourneyRepository(modelContext: modelContext)
        repository.recordEvidence(preparedBaseline, goal: goal, level: level, isBaseline: true, caption: explanation)
        repository.recordEvidence(preparedCheckpoint, goal: goal, level: level, isBaseline: false, caption: explanation)
        _ = repository.submitCheckpoint(for: level, submissionID: submissionID)
        if let reviewCredits {
            repository.synchronizeReviewCredits(reviewCredits)
        }
        dismiss()
    }

    private func submitTrustedReview() {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let invitation = try await TrustedReviewService.createInvitation(
                    goal: goal,
                    level: level,
                    baseline: preparedBaseline,
                    checkpoint: preparedCheckpoint,
                    explanation: explanation
                )
                let repository = PrivateJourneyRepository(modelContext: modelContext)
                repository.recordEvidence(preparedBaseline, goal: goal, level: level, isBaseline: true, caption: explanation)
                repository.recordEvidence(preparedCheckpoint, goal: goal, level: level, isBaseline: false, caption: explanation)
                repository.recordTrustedReviewInvitation(for: level, recordName: invitation.id)
                trustedInvitation = invitation
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func safetySummary(_ outcome: EvidenceSafetyOutcome) -> some View {
        switch outcome {
        case .blocked(let reason):
            KarteriaSurface {
                Label(reason, systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.karteriaCoral)
                    .padding(14)
            }
        case .clear(let warnings):
            KarteriaSurface {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Safety check complete", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.karteriaSignal)
                    ForEach(warnings) { warning in
                        Text(warning.message)
                            .font(.caption)
                            .foregroundStyle(Color.karteriaMuted)
                    }
                }
                .padding(14)
            }
        }
    }

    private func preflightSummary(_ result: EvidencePreflightResult) -> some View {
        KarteriaSurface {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(
                        result.source == .onDeviceModel ? "On-device preflight" : "Manual checklist",
                        systemImage: result.source == .onDeviceModel ? "cpu" : "checklist"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.karteriaCobalt)
                    Spacer()
                    StatusChip(
                        title: result.allCriteriaAppearCovered ? "Coverage found" : "Check criteria",
                        color: result.allCriteriaAppearCovered ? .karteriaSignal : .karteriaCoral
                    )
                }
                Text(result.summary)
                    .font(.caption)
                    .foregroundStyle(Color.karteriaMuted)
                ForEach(result.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Color.karteriaCoral)
                }
                Text("This preflight never votes or changes the review outcome.")
                    .font(.caption2)
                    .foregroundStyle(Color.karteriaMuted)
            }
            .padding(14)
        }
    }

    private func prepare(
        format: EvidenceFormat,
        images: [PhotosPickerItem],
        video: PhotosPickerItem?
    ) async throws -> [PreparedEvidenceMedia] {
        switch format {
        case .images:
            return try await EvidenceMediaStore.prepareImages(from: images)
        case .video:
            return try await EvidenceMediaStore.prepareVideo(from: video)
        }
    }
}
