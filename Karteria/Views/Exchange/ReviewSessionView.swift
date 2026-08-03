import SwiftUI

struct ReviewResponse {
    var decisions: [ReviewDecision]
    var note: String
}

struct ReviewSessionView: View {
    let item: ReviewWorkItem
    let onSubmit: (ReviewResponse) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var communityAccess: CommunityAccessStore
    @State private var selectedDecisions: [ReviewDecision?] = Array(repeating: nil, count: 3)
    @State private var note = ""
    @State private var isPresentingReport = false
    @State private var isConfirmingBlock = false
    @State private var blockMessage: String?

    private let exchangeClient = ReviewExchangeClient()

    private var requiresNote: Bool {
        selectedDecisions.compactMap { $0 }.contains { $0.requiresNote }
    }

    private var isReady: Bool {
        selectedDecisions.allSatisfy { $0 != nil } && (!requiresNote || note.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        StatusChip(
                            title: reviewKindTitle,
                            color: item.kind == .calibration ? .karteriaCobalt : .karteriaSignal
                        )
                        Spacer()
                        Text("Evidence only")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.karteriaMuted)
                    }

                    KarteriaSectionHeading(
                        "Evidence contract",
                        title: item.contractTitle,
                        detail: item.context
                    )

                    EvidenceComparisonScrubber(baseline: item.baseline, checkpoint: item.checkpoint)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Rubric")
                            .font(.title3.weight(.bold))
                        ForEach(item.criteria.indices, id: \.self) { index in
                            rubricRow(index: index, criterion: item.criteria[index])
                        }
                    }

                    if requiresNote {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What needs another rep?")
                                .font(.subheadline.weight(.semibold))
                            TextEditor(text: $note)
                                .frame(minHeight: 110)
                                .padding(8)
                                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.karteriaLine, lineWidth: 1)
                                }
                            Text("\(note.count)/280. At least 20 characters are needed when a criterion is not met or not shown.")
                                .font(.caption)
                                .foregroundStyle(Color.karteriaMuted)
                        }
                    }

                    KarteriaPrimaryButton(title: "Submit review", systemImage: "checkmark") {
                        let decisions = selectedDecisions.compactMap { $0 }
                        onSubmit(ReviewResponse(decisions: decisions, note: note))
                        dismiss()
                    }
                    .disabled(!isReady)
                    .opacity(isReady ? 1 : 0.45)
                }
                .padding(20)
            }
            .karteriaPage()
            .navigationTitle("Review proof")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if item.kind == .anonymousQueue {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isPresentingReport = true
                        } label: {
                            Image(systemName: "exclamationmark.bubble")
                        }
                        .accessibilityLabel("Report content")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isConfirmingBlock = true
                        } label: {
                            Image(systemName: "hand.raised")
                        }
                        .accessibilityLabel("Block future proof from this member")
                    }
                }
            }
            .sheet(isPresented: $isPresentingReport) {
                ContentReportSheet(submissionID: item.submissionID)
            }
            .confirmationDialog(
                "Block future anonymous proof?",
                isPresented: $isConfirmingBlock,
                titleVisibility: .visible
            ) {
                Button("Block future proof", role: .destructive) { blockFutureProof() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This hides future anonymous submissions from this account. It does not identify the person or change this review.")
            }
            .alert("Anonymous exchange", isPresented: Binding(
                get: { blockMessage != nil },
                set: { if !$0 { blockMessage = nil } }
            )) {
                Button("OK", role: .cancel) { blockMessage = nil }
            } message: {
                Text(blockMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func rubricRow(index: Int, criterion: RubricCriterion) -> some View {
        KarteriaSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.karteriaCobalt, in: Circle())
                    Text(criterion.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.karteriaInk)
                }
                Picker("Criterion \(index + 1)", selection: decisionBinding(for: index)) {
                    Text("Choose").tag(ReviewDecision?.none)
                    ForEach(ReviewDecision.allCases) { decision in
                        Text(decision.title).tag(Optional(decision))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
    }

    private func decisionBinding(for index: Int) -> Binding<ReviewDecision?> {
        Binding(
            get: { selectedDecisions[index] },
            set: { selectedDecisions[index] = $0 }
        )
    }

    private var reviewKindTitle: String {
        switch item.kind {
        case .calibration: return "Calibration"
        case .anonymousQueue: return "Anonymous review"
        case .trustedReview: return "Trusted review"
        }
    }

    private func blockFutureProof() {
        guard let submissionID = item.submissionID else {
            blockMessage = "This anonymous proof is no longer available to block."
            return
        }
        Task {
            do {
                let result = try await exchangeClient.blockSubmissionOwner(
                    submissionID: submissionID,
                    identityToken: communityAccess.identityToken
                )
                blockMessage = result.duplicate
                    ? "Future proof from this anonymous member is already blocked."
                    : "Future anonymous proof from this member is blocked."
            } catch {
                blockMessage = error.localizedDescription
            }
        }
    }
}
