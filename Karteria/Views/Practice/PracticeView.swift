import SwiftData
import SwiftUI

struct PracticeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var navigation: KarteriaNavigation
    @Query private var goals: [GoalRecord]
    @Query private var levels: [LevelRecord]
    @Query private var practiceReps: [PracticeRepRecord]

    @State private var practiceNote = ""
    @State private var minutes = 10
    @State private var isPresentingContract = false
    @State private var isPresentingCheckpoint = false
    @State private var isPresentingSettings = false
    @State private var isPresentingSchedule = false

    private var activeGoal: GoalRecord? {
        goals.filter { $0.status == .active }.sorted { $0.createdAt < $1.createdAt }.first
    }

    private var activeLevel: LevelRecord? {
        guard let activeGoal else { return nil }
        return levels.first { $0.goalID == activeGoal.id && $0.number == activeGoal.activeLevelNumber }
    }

    private var latestPractice: PracticeRepRecord? {
        guard let activeLevel else { return nil }
        return practiceReps
            .filter { $0.levelID == activeLevel.id }
            .sorted { $0.completedAt > $1.completedAt }
            .first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    KarteriaHeader(section: "Practice") {
                        isPresentingSettings = true
                    }

                    if let goal = activeGoal, let level = activeLevel {
                        practiceContent(goal: goal, level: level)
                    } else {
                        EmptyPracticeView {
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
            .sheet(isPresented: $isPresentingContract) {
                if let activeLevel {
                    EvidenceContractSheet(level: activeLevel)
                }
            }
            .sheet(isPresented: $isPresentingCheckpoint) {
                if let goal = activeGoal, let activeLevel {
                    CheckpointSubmissionSheet(goal: goal, level: activeLevel)
                }
            }
            .sheet(isPresented: $isPresentingSchedule) {
                if let activeGoal {
                    PracticeScheduleSheet(goal: activeGoal)
                }
            }
        }
    }

    @ViewBuilder
    private func practiceContent(goal: GoalRecord, level: LevelRecord) -> some View {
        KarteriaSectionHeading(
            "Current level",
            title: level.title,
            detail: level.focus
        )

        KarteriaSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(goal.identityStatement)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        isPresentingSchedule = true
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityLabel("Edit practice schedule")
                    StatusChip(title: "Private", color: .karteriaCobalt)
                }
                Text(goal.outcomeStatement)
                    .font(.caption)
                    .foregroundStyle(Color.karteriaMuted)
                Label(scheduleDescription(goal.schedule), systemImage: goal.remindersEnabled ? "bell" : "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.karteriaMuted)
            }
            .padding(16)
        }

        if TwoMinuteFallback.shouldOffer(schedule: goal.schedule, lastPracticeAt: latestPractice?.completedAt) {
            KarteriaSurface {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(Color.karteriaCoral)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Do the two-minute version today")
                            .font(.subheadline.weight(.semibold))
                        Text("A missed practice day is not a reason to miss twice. Make the smallest deliberate rep count.")
                            .font(.caption)
                            .foregroundStyle(Color.karteriaMuted)
                    }
                }
                .padding(14)
            }
        }

        KarteriaSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    KarteriaSectionHeading("Today", title: "Log a private rep")
                    Spacer()
                    Stepper("\(minutes)m", value: $minutes, in: 2...120, step: 1)
                        .fixedSize()
                }
                TextField("What did you deliberately practice?", text: $practiceNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                KarteriaPrimaryButton(title: "Log private rep", systemImage: "checkmark") {
                    PrivateJourneyRepository(modelContext: modelContext).recordPractice(
                        goal: goal,
                        level: level,
                        minutes: minutes,
                        note: practiceNote,
                        usedTwoMinuteFallback: minutes == 2
                    )
                    practiceNote = ""
                }
            }
            .padding(16)
        }

        evidenceContract(for: goal, level: level)
    }

    @ViewBuilder
    private func evidenceContract(for goal: GoalRecord, level: LevelRecord) -> some View {
        if level.criteria.count == 3 && !level.baselineSummary.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                KarteriaSectionHeading("Proof", title: level.contractTitle, detail: level.baselineSummary)
                ForEach(Array(level.criteria.enumerated()), id: \.element.id) { index, criterion in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.karteriaCobalt, in: Circle())
                        Text(criterion.title)
                            .font(.subheadline)
                    }
                }
                if level.status == .awaitingReview {
                    waitingForAnonymousReview
                } else if level.trustedReviewState != .notShared {
                    waitingForTrustedReview(state: level.trustedReviewState)
                } else {
                    HStack(spacing: 10) {
                        Button("Edit contract") { isPresentingContract = true }
                            .buttonStyle(.bordered)
                        Button("Submit checkpoint") { isPresentingCheckpoint = true }
                            .buttonStyle(.borderedProminent)
                            .tint(.karteriaCobalt)
                    }
                }
            }
        } else {
            KarteriaSurface {
                VStack(alignment: .leading, spacing: 12) {
                    KarteriaSectionHeading(
                        "Proof",
                        title: "Create the evidence contract before your checkpoint.",
                        detail: "Define the baseline and three observable criteria before anyone can review it."
                    )
                    KarteriaPrimaryButton(title: "Define proof", systemImage: "list.clipboard") {
                        isPresentingContract = true
                    }
                }
                .padding(16)
            }
        }
    }

    private func scheduleDescription(_ schedule: PracticeSchedule) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let days = schedule.weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ")
        return "\(days) at \(String(format: "%02d:00", schedule.preferredHour))"
    }

    private var waitingForAnonymousReview: some View {
        KarteriaSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("Checkpoint is in anonymous review")
                    .font(.subheadline.weight(.semibold))
                Text("Keep logging private reps while the three seats fill. The contract stays fixed until the 2-of-3 result settles.")
                    .font(.caption)
                    .foregroundStyle(Color.karteriaMuted)
                Button("View exchange") { navigation.selectedTab = .exchange }
                    .buttonStyle(.bordered)
            }
            .padding(14)
        }
    }

    private func waitingForTrustedReview(state: TrustedReviewState) -> some View {
        KarteriaSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text(state == .completed ? "Trusted feedback is ready" : "Trusted invitation is active")
                    .font(.subheadline.weight(.semibold))
                Text(state == .completed
                    ? "Read the private feedback in Exchange. It remains separate from anonymous verification."
                    : "Keep private practice going while the invited reviewer responds. The current proof stays fixed.")
                    .font(.caption)
                    .foregroundStyle(Color.karteriaMuted)
                Button("View exchange") { navigation.selectedTab = .exchange }
                    .buttonStyle(.bordered)
            }
            .padding(14)
        }
    }
}

private struct EmptyPracticeView: View {
    let createGoal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer(minLength: 28)
            KarteriaSectionHeading(
                "Private practice",
                title: "No public proof until you choose a checkpoint.",
                detail: "Create a goal, pick a small daily practice, and build evidence toward a level."
            )
            KarteriaPrimaryButton(title: "Create a goal", systemImage: "plus", action: createGoal)
            Spacer(minLength: 28)
        }
    }
}
