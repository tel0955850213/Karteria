import Foundation
import SwiftData

@Model
final class ProfileRecord {
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var reviewCredits: Int = CreditBalance.initialCredits
    var calibrationCompleted: Int = 0
    var calibrationCorrect: Int = 0
    var calibrationStatusRaw: String = ReviewerCalibrationStatus.notStarted.rawValue
    var birthDate: Date?
    var birthYear: Int?
    var appleUserID: String?
    var hasCompletedOnboarding: Bool = false
    var qualityReviewCount: Int = 0

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        reviewCredits: Int = CreditBalance.initialCredits,
        calibrationCompleted: Int = 0,
        calibrationCorrect: Int = 0,
        calibrationStatusRaw: String = ReviewerCalibrationStatus.notStarted.rawValue,
        birthDate: Date? = nil,
        birthYear: Int? = nil,
        appleUserID: String? = nil,
        hasCompletedOnboarding: Bool = false,
        qualityReviewCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.reviewCredits = reviewCredits
        self.calibrationCompleted = calibrationCompleted
        self.calibrationCorrect = calibrationCorrect
        self.calibrationStatusRaw = calibrationStatusRaw
        self.birthDate = birthDate
        self.birthYear = birthYear
        self.appleUserID = appleUserID
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.qualityReviewCount = qualityReviewCount
    }
}

@Model
final class GoalRecord {
    var id: UUID = UUID()
    var identityStatement: String = ""
    var title: String = ""
    var outcomeStatement: String = ""
    var statusRaw: String = GoalStatus.active.rawValue
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var scheduleWeekdays: String = "2,3,4,5,6"
    var scheduleHour: Int = 19
    var remindersEnabled: Bool = false
    var activeLevelNumber: Int = 1

    init(
        id: UUID = UUID(),
        identityStatement: String,
        title: String,
        outcomeStatement: String,
        statusRaw: String = GoalStatus.active.rawValue,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        scheduleWeekdays: String = "2,3,4,5,6",
        scheduleHour: Int = 19,
        remindersEnabled: Bool = false,
        activeLevelNumber: Int = 1
    ) {
        self.id = id
        self.identityStatement = identityStatement
        self.title = title
        self.outcomeStatement = outcomeStatement
        self.statusRaw = statusRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scheduleWeekdays = scheduleWeekdays
        self.scheduleHour = scheduleHour
        self.remindersEnabled = remindersEnabled
        self.activeLevelNumber = activeLevelNumber
    }

    var status: GoalStatus { GoalStatus(rawValue: statusRaw) ?? .active }
    var schedule: PracticeSchedule {
        let weekdays = Set(scheduleWeekdays.split(separator: ",").compactMap { Int($0) })
        return PracticeSchedule(weekdays: weekdays, preferredHour: scheduleHour)
    }
}

@Model
final class LevelRecord {
    var id: UUID = UUID()
    var goalID: UUID = UUID()
    var number: Int = 1
    var title: String = ""
    var focus: String = ""
    var statusRaw: String = LevelStatus.locked.rawValue
    var contractTitle: String = ""
    var baselineSummary: String = ""
    var criterionOne: String = ""
    var criterionTwo: String = ""
    var criterionThree: String = ""
    var submittedAt: Date?
    var settledAt: Date?
    var settlementOutcomeRaw: String?
    var reviewSubmissionID: UUID?
    var trustedReviewRecordName: String?
    var trustedReviewStateRaw: String = TrustedReviewState.notShared.rawValue
    var trustedReviewNote: String = ""
    var trustedReviewedAt: Date?

    init(
        id: UUID = UUID(),
        goalID: UUID,
        number: Int,
        title: String,
        focus: String,
        statusRaw: String = LevelStatus.locked.rawValue,
        contractTitle: String = "",
        baselineSummary: String = "",
        criterionOne: String = "",
        criterionTwo: String = "",
        criterionThree: String = "",
        submittedAt: Date? = nil,
        settledAt: Date? = nil,
        settlementOutcomeRaw: String? = nil,
        reviewSubmissionID: UUID? = nil,
        trustedReviewRecordName: String? = nil,
        trustedReviewStateRaw: String = TrustedReviewState.notShared.rawValue,
        trustedReviewNote: String = "",
        trustedReviewedAt: Date? = nil
    ) {
        self.id = id
        self.goalID = goalID
        self.number = number
        self.title = title
        self.focus = focus
        self.statusRaw = statusRaw
        self.contractTitle = contractTitle
        self.baselineSummary = baselineSummary
        self.criterionOne = criterionOne
        self.criterionTwo = criterionTwo
        self.criterionThree = criterionThree
        self.submittedAt = submittedAt
        self.settledAt = settledAt
        self.settlementOutcomeRaw = settlementOutcomeRaw
        self.reviewSubmissionID = reviewSubmissionID
        self.trustedReviewRecordName = trustedReviewRecordName
        self.trustedReviewStateRaw = trustedReviewStateRaw
        self.trustedReviewNote = trustedReviewNote
        self.trustedReviewedAt = trustedReviewedAt
    }

    var status: LevelStatus { LevelStatus(rawValue: statusRaw) ?? .locked }
    var trustedReviewState: TrustedReviewState {
        TrustedReviewState(rawValue: trustedReviewStateRaw) ?? .notShared
    }
    var criteria: [RubricCriterion] {
        [criterionOne, criterionTwo, criterionThree]
            .map { RubricCriterion(title: $0) }
            .filter { !$0.title.isEmpty }
    }
}

@Model
final class PracticeRepRecord {
    var id: UUID = UUID()
    var goalID: UUID = UUID()
    var levelID: UUID = UUID()
    var completedAt: Date = Date.now
    var minutes: Int = 2
    var note: String = ""
    var usedTwoMinuteFallback: Bool = false

    init(
        id: UUID = UUID(),
        goalID: UUID,
        levelID: UUID,
        completedAt: Date = .now,
        minutes: Int,
        note: String,
        usedTwoMinuteFallback: Bool
    ) {
        self.id = id
        self.goalID = goalID
        self.levelID = levelID
        self.completedAt = completedAt
        self.minutes = max(1, minutes)
        self.note = String(note.prefix(1_000))
        self.usedTwoMinuteFallback = usedTwoMinuteFallback
    }
}

@Model
final class EvidenceRecord {
    var id: UUID = UUID()
    var goalID: UUID = UUID()
    var levelID: UUID = UUID()
    var kindRaw: String = EvidenceMediaKind.image.rawValue
    var localRelativePath: String = ""
    var byteCount: Int = 0
    var durationSeconds: Double = 0
    var caption: String = ""
    var isBaseline: Bool = false
    var createdAt: Date = Date.now

    init(
        id: UUID = UUID(),
        goalID: UUID,
        levelID: UUID,
        kindRaw: String,
        localRelativePath: String,
        byteCount: Int,
        durationSeconds: Double = 0,
        caption: String = "",
        isBaseline: Bool,
        createdAt: Date = .now
    ) {
        self.id = id
        self.goalID = goalID
        self.levelID = levelID
        self.kindRaw = kindRaw
        self.localRelativePath = localRelativePath
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.caption = String(caption.prefix(EvidenceLimits.maximumExplanationCharacters))
        self.isBaseline = isBaseline
        self.createdAt = createdAt
    }
}
