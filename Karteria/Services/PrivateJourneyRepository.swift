import Foundation
import SwiftData

@MainActor
final class PrivateJourneyRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func bootstrap(seedDemo: Bool) {
        if fetchProfiles().isEmpty {
            modelContext.insert(ProfileRecord())
        }
        if seedDemo && fetchGoals().isEmpty {
            createDemoGoal()
        }
        save()
    }

    func fetchProfiles() -> [ProfileRecord] {
        (try? modelContext.fetch(FetchDescriptor<ProfileRecord>())) ?? []
    }

    func primaryProfile() -> ProfileRecord {
        if let existing = fetchProfiles().sorted(by: { $0.createdAt < $1.createdAt }).first {
            return existing
        }
        let profile = ProfileRecord()
        modelContext.insert(profile)
        save()
        return profile
    }

    func fetchGoals() -> [GoalRecord] {
        var descriptor = FetchDescriptor<GoalRecord>()
        descriptor.sortBy = [SortDescriptor(\GoalRecord.createdAt)]
        return ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.status == .active }
    }

    func levels(for goal: GoalRecord) -> [LevelRecord] {
        let goalID = goal.id
        var descriptor = FetchDescriptor<LevelRecord>(predicate: #Predicate { $0.goalID == goalID })
        descriptor.sortBy = [SortDescriptor(\LevelRecord.number)]
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func practiceReps(for level: LevelRecord) -> [PracticeRepRecord] {
        let levelID = level.id
        var descriptor = FetchDescriptor<PracticeRepRecord>(predicate: #Predicate { $0.levelID == levelID })
        descriptor.sortBy = [SortDescriptor(\PracticeRepRecord.completedAt, order: .reverse)]
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func createGoal(
        identity: String,
        title: String,
        outcome: String,
        schedule: PracticeSchedule,
        remindersEnabled: Bool = false
    ) -> GoalRecord {
        let normalizedIdentity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = GoalRecord(
            identityStatement: normalizedIdentity,
            title: normalizedTitle,
            outcomeStatement: outcome.trimmingCharacters(in: .whitespacesAndNewlines),
            scheduleWeekdays: schedule.weekdays.sorted().map(String.init).joined(separator: ","),
            scheduleHour: schedule.preferredHour,
            remindersEnabled: remindersEnabled
        )
        modelContext.insert(goal)
        let levels = GoalPlanner.defaultLevels(for: normalizedTitle)
        for (index, level) in levels.enumerated() {
            modelContext.insert(LevelRecord(
                goalID: goal.id,
                number: index + 1,
                title: level.title,
                focus: level.focus,
                statusRaw: index == 0 ? LevelStatus.practicing.rawValue : LevelStatus.locked.rawValue
            ))
        }
        save()
        return goal
    }

    func saveEvidenceContract(
        for level: LevelRecord,
        title: String,
        baseline: String,
        criteria: [String]
    ) {
        let safe = Array(criteria.prefix(3)) + Array(repeating: "", count: max(0, 3 - criteria.count))
        level.contractTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        level.baselineSummary = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        level.criterionOne = safe[0].trimmingCharacters(in: .whitespacesAndNewlines)
        level.criterionTwo = safe[1].trimmingCharacters(in: .whitespacesAndNewlines)
        level.criterionThree = safe[2].trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func recordPractice(
        goal: GoalRecord,
        level: LevelRecord,
        minutes: Int,
        note: String,
        usedTwoMinuteFallback: Bool
    ) {
        modelContext.insert(PracticeRepRecord(
            goalID: goal.id,
            levelID: level.id,
            minutes: minutes,
            note: note,
            usedTwoMinuteFallback: usedTwoMinuteFallback
        ))
        goal.updatedAt = .now
        save()
    }

    func updateProfile(
        birthDate: Date?,
        appleUserID: String?
    ) {
        let profile = primaryProfile()
        profile.birthDate = birthDate
        profile.birthYear = birthDate.map { Calendar.current.component(.year, from: $0) }
        if let appleUserID {
            profile.appleUserID = appleUserID
        }
        save()
    }

    func updateSchedule(
        for goal: GoalRecord,
        schedule: PracticeSchedule,
        remindersEnabled: Bool
    ) {
        goal.scheduleWeekdays = schedule.weekdays.sorted().map(String.init).joined(separator: ",")
        goal.scheduleHour = schedule.preferredHour
        goal.remindersEnabled = remindersEnabled
        goal.updatedAt = .now
        save()
    }

    func recordCalibration(answerWasCorrect: Bool) {
        let profile = primaryProfile()
        var standing = ReviewerStanding(
            calibrationCompleted: profile.calibrationCompleted,
            calibrationCorrect: profile.calibrationCorrect,
            status: ReviewerCalibrationStatus(rawValue: profile.calibrationStatusRaw) ?? .notStarted
        )
        standing.recordCalibration(answerWasCorrect: answerWasCorrect)
        profile.calibrationCompleted = standing.calibrationCompleted
        profile.calibrationCorrect = standing.calibrationCorrect
        profile.calibrationStatusRaw = standing.status.rawValue
        save()
    }

    func rewardReviewCredit() {
        let profile = primaryProfile()
        profile.reviewCredits += 1
        profile.qualityReviewCount += 1
        save()
    }

    func synchronizeReviewCredits(_ credits: Int) {
        let profile = primaryProfile()
        profile.reviewCredits = max(0, credits)
        save()
    }

    func synchronizeReviewerStanding(
        credits: Int,
        calibrationCompleted: Int,
        calibrationCorrect: Int,
        calibrationStatus: String
    ) {
        let profile = primaryProfile()
        profile.reviewCredits = max(0, credits)
        profile.calibrationCompleted = max(0, calibrationCompleted)
        profile.calibrationCorrect = max(0, calibrationCorrect)
        profile.calibrationStatusRaw = calibrationStatus
        save()
    }

    func recordEvidence(_ media: [PreparedEvidenceMedia], goal: GoalRecord, level: LevelRecord, isBaseline: Bool, caption: String) {
        for item in media {
            modelContext.insert(EvidenceRecord(
                goalID: goal.id,
                levelID: level.id,
                kindRaw: item.kind.rawValue,
                localRelativePath: item.relativePath,
                byteCount: item.byteCount,
                durationSeconds: item.duration,
                caption: caption,
                isBaseline: isBaseline
            ))
        }
        save()
    }

    func submitCheckpoint(for level: LevelRecord, submissionID: UUID = UUID()) -> UUID {
        level.statusRaw = LevelStatus.awaitingReview.rawValue
        level.reviewSubmissionID = submissionID
        level.submittedAt = .now
        save()
        return submissionID
    }

    func withdrawCheckpoint(for level: LevelRecord) {
        level.statusRaw = LevelStatus.practicing.rawValue
        level.reviewSubmissionID = nil
        level.submittedAt = nil
        level.settledAt = nil
        level.settlementOutcomeRaw = nil
        save()
    }

    func recordTrustedReviewInvitation(for level: LevelRecord, recordName: String) {
        level.trustedReviewRecordName = recordName
        level.trustedReviewStateRaw = TrustedReviewState.awaitingResponse.rawValue
        level.trustedReviewNote = ""
        level.trustedReviewedAt = nil
        save()
    }

    func applyTrustedReviewStatus(_ status: TrustedReviewOwnerStatus, to level: LevelRecord) {
        level.trustedReviewStateRaw = status.state.rawValue
        level.trustedReviewNote = status.note
        level.trustedReviewedAt = status.reviewedAt
        save()
    }

    func removeTrustedReviewInvitation(from level: LevelRecord) {
        level.trustedReviewRecordName = nil
        level.trustedReviewStateRaw = TrustedReviewState.notShared.rawValue
        level.trustedReviewNote = ""
        level.trustedReviewedAt = nil
        save()
    }

    func apply(settlement: ReviewSettlement, to level: LevelRecord, in goal: GoalRecord) {
        level.settledAt = settlement.reviewedAt
        level.settlementOutcomeRaw = settlement.outcome.rawValue
        level.statusRaw = settlement.outcome == .passed
            ? LevelStatus.verified.rawValue
            : LevelStatus.needsMorePractice.rawValue
        if settlement.outcome == .passed {
            goal.activeLevelNumber += 1
            let nextNumber = level.number + 1
            let goalID = goal.id
            if let next = levels(for: goal).first(where: { $0.goalID == goalID && $0.number == nextNumber }) {
                next.statusRaw = LevelStatus.practicing.rawValue
            } else {
                goal.statusRaw = GoalStatus.complete.rawValue
            }
        }
        goal.updatedAt = .now
        save()
    }

    private func createDemoGoal() {
        let goal = createGoal(
            identity: "I am a calm, clear presenter.",
            title: "Present a technical idea with confidence",
            outcome: "Explain one engineering decision in a three-minute walkthrough.",
            schedule: PracticeSchedule()
        )
        guard let level = levels(for: goal).first else { return }
        saveEvidenceContract(
            for: level,
            title: "Explain a design tradeoff",
            baseline: "My baseline explanation loses the decision criteria after the first minute.",
            criteria: [
                "Name the user problem before proposing a solution.",
                "Compare two concrete options with one tradeoff each.",
                "End with a clear recommendation and next step.",
            ]
        )
        recordPractice(
            goal: goal,
            level: level,
            minutes: 12,
            note: "Explained the caching tradeoff out loud.",
            usedTwoMinuteFallback: false
        )
    }

    private func save() {
        try? modelContext.save()
    }
}
