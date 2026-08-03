import SwiftUI

struct GrowthStorySheet: View {
    let goal: GoalRecord?
    let levels: [LevelRecord]

    @Environment(\.dismiss) private var dismiss

    private var story: String {
        guard let goal else { return "" }
        let verifiedTitles = levels.map(\.title).joined(separator: ", ")
        return "\(goal.identityStatement)\n\nVerified progress in Karteria: \(verifiedTitles).\n\nPractice. Prove. Progress."
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                KarteriaSectionHeading(
                    "Growth story",
                    title: goal?.identityStatement ?? "Practice with proof",
                    detail: "A shareable draft based only on verified levels."
                )
                KarteriaSurface {
                    Text(story)
                        .font(.body)
                        .foregroundStyle(Color.karteriaInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                ShareLink(item: story) {
                    Label("Share story", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.karteriaCobalt)
                Spacer()
            }
            .padding(20)
            .karteriaPage()
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
