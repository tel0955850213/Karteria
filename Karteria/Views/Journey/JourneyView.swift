import SwiftData
import SwiftUI

struct JourneyView: View {
    @EnvironmentObject private var navigation: KarteriaNavigation
    @Query private var goals: [GoalRecord]
    @Query private var levels: [LevelRecord]

    @State private var isPresentingSettings = false
    @State private var isPresentingShare = false

    private var activeGoal: GoalRecord? {
        goals.filter { $0.status == .active || $0.status == .complete }.sorted { $0.createdAt < $1.createdAt }.first
    }

    private var journeyLevels: [LevelRecord] {
        guard let activeGoal else { return [] }
        return levels.filter { $0.goalID == activeGoal.id }.sorted { $0.number < $1.number }
    }

    private var verifiedLevels: [LevelRecord] { journeyLevels.filter { $0.status == .verified } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    KarteriaHeader(section: "Journey") {
                        isPresentingSettings = true
                    }
                    if let goal = activeGoal {
                        journeyContent(goal: goal)
                    } else {
                        EmptyJourneyView {
                            navigation.isPresentingGoalCreation = true
                        }
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
            .sheet(isPresented: $isPresentingShare) {
                GrowthStorySheet(goal: activeGoal, levels: verifiedLevels)
            }
        }
    }

    @ViewBuilder
    private func journeyContent(goal: GoalRecord) -> some View {
        KarteriaSectionHeading(
            "Practice with proof",
            title: goal.identityStatement,
            detail: goal.outcomeStatement
        )

        KarteriaSurface {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verified levels")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.karteriaMuted)
                    Text("\(verifiedLevels.count)/\(journeyLevels.count)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.karteriaInk)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.karteriaSignal)
            }
            .padding(16)
        }

        VStack(alignment: .leading, spacing: 14) {
            Text("Level timeline")
                .font(.title3.weight(.bold))
            ForEach(journeyLevels) { level in
                JourneyLevelRow(level: level)
            }
        }

        if verifiedLevels.isEmpty {
            KarteriaSurface {
                Text("Your first verified level will add a before/after record here. Daily reps remain private.")
                    .font(.subheadline)
                    .foregroundStyle(Color.karteriaMuted)
                    .padding(16)
            }
        } else {
            Button("Create growth story") { isPresentingShare = true }
                .buttonStyle(.borderedProminent)
                .tint(.karteriaCobalt)
        }
    }
}

private struct JourneyLevelRow: View {
    let level: LevelRecord

    private var color: Color {
        switch level.status {
        case .verified: return .karteriaSignal
        case .needsMorePractice: return .karteriaCoral
        case .practicing, .awaitingReview: return .karteriaCobalt
        case .locked: return .karteriaLine
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    .overlay {
                        if level.status == .verified {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                Rectangle()
                    .fill(Color.karteriaLine)
                    .frame(width: 2, height: 54)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(level.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    StatusChip(title: level.status.rawValue.replacingOccurrences(of: "_", with: " "), color: color)
                }
                Text(level.focus)
                    .font(.caption)
                    .foregroundStyle(Color.karteriaMuted)
                if level.status == .verified, let settledAt = level.settledAt {
                    Text("Verified \(settledAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.karteriaSignal)
                }
            }
        }
    }
}

private struct EmptyJourneyView: View {
    let createGoal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 28)
            KarteriaSectionHeading(
                "Private journey",
                title: "Verified change will live here.",
                detail: "Start a practice goal to create the first level in your timeline."
            )
            KarteriaPrimaryButton(title: "Create a goal", systemImage: "plus", action: createGoal)
            Spacer(minLength: 28)
        }
    }
}
