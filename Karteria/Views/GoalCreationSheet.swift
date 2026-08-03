import SwiftData
import SwiftUI

struct GoalCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var entitlements: EntitlementStore
    @Query private var goals: [GoalRecord]

    @State private var identity = ""
    @State private var goalTitle = ""
    @State private var outcome = ""
    @State private var selectedWeekdays: Set<Int> = Set(2...6)
    @State private var preferredHour = 19
    @State private var remindersEnabled = false
    @State private var showPaywall = false

    private let weekdayLabels = [
        (1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"),
    ]

    private var activeGoals: [GoalRecord] { goals.filter { $0.status == .active } }

    private var isValid: Bool {
        !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !goalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedWeekdays.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    KarteriaSectionHeading(
                        "Start with identity",
                        title: "Choose the person you are practicing to become.",
                        detail: "The goal stays private. You only publish deliberate proof at a checkpoint."
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("I am becoming")
                            .font(.subheadline.weight(.semibold))
                        TextField("a calm, clear presenter", text: $identity, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Goal")
                            .font(.subheadline.weight(.semibold))
                        TextField("Present a technical idea with confidence", text: $goalTitle, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proof of progress")
                            .font(.subheadline.weight(.semibold))
                        TextField("Explain one engineering decision in three minutes.", text: $outcome, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Practice days")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            ForEach(weekdayLabels, id: \.0) { weekday, label in
                                Button(label) {
                                    if selectedWeekdays.contains(weekday) {
                                        selectedWeekdays.remove(weekday)
                                    } else {
                                        selectedWeekdays.insert(weekday)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(selectedWeekdays.contains(weekday) ? .karteriaCobalt : .karteriaMuted)
                                .accessibilityLabel("\(weekdayName(weekday)) practice")
                                .accessibilityValue(selectedWeekdays.contains(weekday) ? "Selected" : "Not selected")
                            }
                        }
                        Stepper("Preferred time: \(hourLabel)", value: $preferredHour, in: 0...23)
                        Toggle("Practice reminder", isOn: $remindersEnabled)
                    }

                    if !entitlements.canCreateGoal(activeGoalCount: activeGoals.count) {
                        KarteriaSurface {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(Color.karteriaCoral)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Free includes one active goal")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Complete, archive, or unlock Pro before starting another goal.")
                                        .font(.caption)
                                        .foregroundStyle(Color.karteriaMuted)
                                }
                            }
                            .padding(14)
                        }
                    }

                    KarteriaPrimaryButton(title: "Create private goal", systemImage: "arrow.right") {
                        guard entitlements.canCreateGoal(activeGoalCount: activeGoals.count) else {
                            showPaywall = true
                            return
                        }
                        let goal = PrivateJourneyRepository(modelContext: modelContext).createGoal(
                            identity: identity,
                            title: goalTitle,
                            outcome: outcome,
                            schedule: PracticeSchedule(weekdays: selectedWeekdays, preferredHour: preferredHour),
                            remindersEnabled: remindersEnabled
                        )
                        let schedule = PracticeSchedule(weekdays: selectedWeekdays, preferredHour: preferredHour)
                        Task {
                            _ = await PracticeReminderService.apply(
                                goalID: goal.id,
                                schedule: schedule,
                                isEnabled: remindersEnabled
                            )
                        }
                        dismiss()
                    }
                    .disabled(!isValid)
                    .opacity(isValid ? 1 : 0.45)
                }
                .padding(20)
            }
            .karteriaPage()
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
        }
    }

    private var hourLabel: String {
        String(format: "%02d:00", preferredHour)
    }

    private func weekdayName(_ day: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day - 1]
    }
}
