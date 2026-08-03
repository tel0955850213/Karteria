import SwiftData
import SwiftUI

struct PracticeScheduleSheet: View {
    let goal: GoalRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedWeekdays: Set<Int>
    @State private var preferredHour: Int
    @State private var remindersEnabled: Bool
    @State private var message: String?

    private let weekdayLabels = [
        (1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"),
    ]

    init(goal: GoalRecord) {
        self.goal = goal
        _selectedWeekdays = State(initialValue: goal.schedule.weekdays)
        _preferredHour = State(initialValue: goal.schedule.preferredHour)
        _remindersEnabled = State(initialValue: goal.remindersEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Practice days") {
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
                    Stepper("Preferred time: \(String(format: "%02d:00", preferredHour))", value: $preferredHour, in: 0...23)
                }
                Section("Reminder") {
                    Toggle("Practice reminder", isOn: $remindersEnabled)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.karteriaPaper)
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(selectedWeekdays.isEmpty)
                }
            }
            .alert("Schedule", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func save() {
        let schedule = PracticeSchedule(weekdays: selectedWeekdays, preferredHour: preferredHour)
        PrivateJourneyRepository(modelContext: modelContext).updateSchedule(
            for: goal,
            schedule: schedule,
            remindersEnabled: remindersEnabled
        )
        Task {
            let result = await PracticeReminderService.apply(
                goalID: goal.id,
                schedule: schedule,
                isEnabled: remindersEnabled
            )
            if result == .denied && remindersEnabled {
                message = "Notifications are unavailable. Your private schedule was still saved."
            } else {
                dismiss()
            }
        }
    }

    private func weekdayName(_ day: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day - 1]
    }
}
