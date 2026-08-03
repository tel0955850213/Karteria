import SwiftUI
import SwiftData

struct EvidenceContractSheet: View {
    let level: LevelRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title: String
    @State private var baseline: String
    @State private var criterionOne: String
    @State private var criterionTwo: String
    @State private var criterionThree: String

    init(level: LevelRecord) {
        self.level = level
        _title = State(initialValue: level.contractTitle)
        _baseline = State(initialValue: level.baselineSummary)
        _criterionOne = State(initialValue: level.criterionOne)
        _criterionTwo = State(initialValue: level.criterionTwo)
        _criterionThree = State(initialValue: level.criterionThree)
    }

    private var isValid: Bool {
        [title, baseline, criterionOne, criterionTwo, criterionThree]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    KarteriaSectionHeading(
                        "Evidence contract",
                        title: "Define proof before you practice toward it.",
                        detail: "Each reviewer sees this same contract. It cannot be edited after public submission."
                    )

                    field("Checkpoint title", text: $title, placeholder: "Explain a design tradeoff")
                    field("Baseline", text: $baseline, placeholder: "What can you observe before deliberate practice?")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Three observable criteria")
                            .font(.subheadline.weight(.semibold))
                        criterionField(1, text: $criterionOne)
                        criterionField(2, text: $criterionTwo)
                        criterionField(3, text: $criterionThree)
                    }

                    KarteriaSurface {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "photo.on.rectangle")
                                .foregroundStyle(Color.karteriaCobalt)
                            Text("Baseline and checkpoint each accept up to three HEIC/JPEG images or one H.264/HEVC video up to 20 seconds. The public bundle is capped at 15 MB.")
                                .font(.caption)
                                .foregroundStyle(Color.karteriaMuted)
                        }
                        .padding(14)
                    }

                    KarteriaPrimaryButton(title: "Save contract", systemImage: "checkmark") {
                        PrivateJourneyRepository(modelContext: modelContext).saveEvidenceContract(
                            for: level,
                            title: title,
                            baseline: baseline,
                            criteria: [criterionOne, criterionTwo, criterionThree]
                        )
                        dismiss()
                    }
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.45)
                }
                .padding(20)
            }
            .karteriaPage()
            .navigationTitle("Proof contract")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func criterionField(_ number: Int, text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.karteriaCobalt, in: Circle())
            TextField("Criterion \(number)", text: text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
    }
}
