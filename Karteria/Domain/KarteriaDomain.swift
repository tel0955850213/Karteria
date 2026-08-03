import Foundation

enum GoalStatus: String, Codable, CaseIterable {
    case active
    case complete
    case archived
}

enum LevelStatus: String, Codable, CaseIterable {
    case locked
    case practicing
    case awaitingReview
    case verified
    case needsMorePractice
}

// Trusted reviews are deliberately separate from the anonymous 2-of-3 outcome.
enum TrustedReviewState: String, Codable, CaseIterable {
    case notShared
    case awaitingResponse
    case completed

    var label: String {
        switch self {
        case .notShared: return "Not shared"
        case .awaitingResponse: return "Waiting for trusted feedback"
        case .completed: return "Trusted feedback received"
        }
    }
}

enum ReviewDecision: String, Codable, CaseIterable, Identifiable {
    case met
    case notMet
    case notShown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .met: return "Met"
        case .notMet: return "Not met"
        case .notShown: return "Not shown"
        }
    }

    var requiresNote: Bool { self != .met }
}

enum ReviewSeatState: String, Codable, CaseIterable {
    case open
    case claimed
    case completed
    case expired
}

enum ReviewerCalibrationStatus: String, Codable, CaseIterable {
    case notStarted
    case calibrating
    case qualified
    case recalibrationRequired
}

struct RubricCriterion: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var title: String

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct EvidenceContract: Codable, Equatable, Identifiable {
    let id: UUID
    var goalID: UUID
    var levelID: UUID
    var title: String
    var baselineSummary: String
    var acceptedFormats: [EvidenceFormat]
    var criteria: [RubricCriterion]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        goalID: UUID,
        levelID: UUID,
        title: String,
        baselineSummary: String,
        acceptedFormats: [EvidenceFormat] = [.images, .video],
        criteria: [RubricCriterion],
        createdAt: Date = .now
    ) {
        self.id = id
        self.goalID = goalID
        self.levelID = levelID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baselineSummary = baselineSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.acceptedFormats = acceptedFormats
        self.criteria = Array(criteria.prefix(3))
        self.createdAt = createdAt
    }

    var isValid: Bool {
        !title.isEmpty
            && !baselineSummary.isEmpty
            && criteria.count == 3
            && criteria.allSatisfy { !$0.title.isEmpty }
    }
}

enum EvidenceFormat: String, Codable, CaseIterable, Identifiable {
    case images
    case video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .images: return "Up to 3 images"
        case .video: return "One video, up to 20 sec"
        }
    }
}

struct EvidenceLimits {
    static let maximumImages = 3
    static let maximumVideoDuration: TimeInterval = 20
    static let maximumBundleBytes = 15 * 1_024 * 1_024
    static let maximumExplanationCharacters = 1_000
}

struct ReviewSeat: Codable, Equatable, Identifiable {
    let id: UUID
    var submissionID: UUID
    var reviewerID: String?
    var state: ReviewSeatState
    var claimedAt: Date?
    var expiresAt: Date?

    init(
        id: UUID = UUID(),
        submissionID: UUID,
        reviewerID: String? = nil,
        state: ReviewSeatState = .open,
        claimedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.submissionID = submissionID
        self.reviewerID = reviewerID
        self.state = state
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
    }

    func isClaimable(at now: Date = .now) -> Bool {
        state == .open || (state == .claimed && (expiresAt ?? .distantPast) <= now)
    }
}

struct PeerReviewVote: Codable, Equatable, Identifiable {
    let id: UUID
    var submissionID: UUID
    var seatID: UUID
    var reviewerID: String
    var decisions: [ReviewDecision]
    var note: String
    var submittedAt: Date

    init(
        id: UUID = UUID(),
        submissionID: UUID,
        seatID: UUID,
        reviewerID: String,
        decisions: [ReviewDecision],
        note: String,
        submittedAt: Date = .now
    ) {
        self.id = id
        self.submissionID = submissionID
        self.seatID = seatID
        self.reviewerID = reviewerID
        self.decisions = Array(decisions.prefix(3))
        self.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        self.submittedAt = submittedAt
    }

    var passes: Bool { ReviewEngine.reviewerPasses(decisions) }

    var isValid: Bool {
        decisions.count == 3 && (!decisions.contains(where: \.requiresNote) || note.count >= 20)
    }
}

struct ReviewSettlement: Codable, Equatable, Identifiable {
    let id: String
    var submissionID: UUID
    var reviewedAt: Date
    var outcome: Outcome
    var countedReviewIDs: [UUID]
    var failedCriteriaIndexes: [Int]

    enum Outcome: String, Codable {
        case passed
        case practiceAgain
    }
}

struct CreditBalance: Codable, Equatable {
    static let submissionCost = 3
    static let initialCredits = 3

    var available: Int

    init(available: Int = initialCredits) {
        self.available = max(0, available)
    }

    func canSubmit(queueHasEligibleReview: Bool) -> Bool {
        !queueHasEligibleReview || available >= Self.submissionCost
    }

    @discardableResult
    mutating func consumeForSubmission(queueHasEligibleReview: Bool) -> Int? {
        guard canSubmit(queueHasEligibleReview: queueHasEligibleReview) else { return nil }
        guard queueHasEligibleReview else { return 0 }
        available -= Self.submissionCost
        return Self.submissionCost
    }

    mutating func rewardForValidReview() {
        available += 1
    }
}

struct ReviewerStanding: Codable, Equatable {
    var calibrationCompleted: Int
    var calibrationCorrect: Int
    var status: ReviewerCalibrationStatus
    var validReviewsSinceCalibration: Int
    var disputedReviewsSinceCalibration: Int

    init(
        calibrationCompleted: Int = 0,
        calibrationCorrect: Int = 0,
        status: ReviewerCalibrationStatus = .notStarted,
        validReviewsSinceCalibration: Int = 0,
        disputedReviewsSinceCalibration: Int = 0
    ) {
        self.calibrationCompleted = calibrationCompleted
        self.calibrationCorrect = calibrationCorrect
        self.status = status
        self.validReviewsSinceCalibration = validReviewsSinceCalibration
        self.disputedReviewsSinceCalibration = disputedReviewsSinceCalibration
    }

    var isQualified: Bool { status == .qualified }

    mutating func recordCalibration(answerWasCorrect: Bool) {
        calibrationCompleted += 1
        calibrationCorrect += answerWasCorrect ? 1 : 0
        if calibrationCompleted >= 5 {
            status = calibrationCorrect >= 4 ? .qualified : .recalibrationRequired
        } else {
            status = .calibrating
        }
    }

    mutating func recordReliabilitySignal(isDisputed: Bool) {
        validReviewsSinceCalibration += 1
        disputedReviewsSinceCalibration += isDisputed ? 1 : 0
        guard validReviewsSinceCalibration >= 5 else { return }
        if Double(disputedReviewsSinceCalibration) / Double(validReviewsSinceCalibration) > 0.35 {
            status = .recalibrationRequired
        }
    }
}

struct PracticeSchedule: Codable, Equatable {
    var weekdays: Set<Int>
    var preferredHour: Int
    var minimumMinutes: Int

    init(weekdays: Set<Int> = Set(2...6), preferredHour: Int = 19, minimumMinutes: Int = 2) {
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.preferredHour = min(max(preferredHour, 0), 23)
        self.minimumMinutes = max(2, minimumMinutes)
    }

    func isScheduled(on date: Date, calendar: Calendar = .current) -> Bool {
        weekdays.contains(calendar.component(.weekday, from: date))
    }
}

enum TwoMinuteFallback {
    static func shouldOffer(
        schedule: PracticeSchedule,
        lastPracticeAt: Date?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        guard schedule.isScheduled(on: yesterday, calendar: calendar) else { return false }
        guard let lastPracticeAt else { return true }
        return !calendar.isDate(lastPracticeAt, inSameDayAs: yesterday)
    }
}

struct CommunityProPassAward: Codable, Equatable, Identifiable {
    let id: String
    var awardedAt: Date
    var days: Int
}

enum CommunityProPassPolicy {
    static let qualityReviewsRequired = 9
    static let passLengthDays = 7
    static let rollingWindowDays = 30
    static let maximumDaysInWindow = 14

    static func nextAwardDays(
        settledQualityReviewDates: [Date],
        existingAwards: [CommunityProPassAward],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        let windowStart = calendar.date(byAdding: .day, value: -rollingWindowDays, to: now) ?? .distantPast
        let qualifiedReviewCount = settledQualityReviewDates.filter { $0 >= windowStart && $0 <= now }.count
        let awardedDays = existingAwards
            .filter { $0.awardedAt >= windowStart && $0.awardedAt <= now }
            .reduce(0) { $0 + $1.days }
        guard qualifiedReviewCount / qualityReviewsRequired > awardedDays / passLengthDays else { return 0 }
        return min(passLengthDays, maximumDaysInWindow - awardedDays)
    }
}

enum ReviewEngine {
    static let seatLeaseDuration: TimeInterval = 10 * 60

    static func reviewerPasses(_ decisions: [ReviewDecision]) -> Bool {
        decisions.count == 3 && decisions.allSatisfy { $0 == .met }
    }

    static func failedCriteriaIndexes(reviews: [PeerReviewVote]) -> [Int] {
        guard !reviews.isEmpty else { return [] }
        return (0..<3).filter { index in
            reviews.filter { $0.decisions.indices.contains(index) }
                .filter { $0.decisions[index] != .met }
                .count >= 2
        }
    }

    static func settlement(
        submissionID: UUID,
        reviews: [PeerReviewVote],
        now: Date = .now
    ) -> ReviewSettlement? {
        let uniqueBySeat = Dictionary(grouping: reviews.filter(\.isValid), by: \.seatID)
            .compactMapValues { $0.sorted { $0.submittedAt < $1.submittedAt }.first }
        let counted = uniqueBySeat.values.sorted { $0.submittedAt < $1.submittedAt }.prefix(3)
        guard counted.count == 3 else { return nil }
        let countedReviews = Array(counted)
        let passCount = countedReviews.filter(\.passes).count
        let outcome: ReviewSettlement.Outcome = passCount >= 2 ? .passed : .practiceAgain
        return ReviewSettlement(
            id: "settlement-\(submissionID.uuidString.lowercased())",
            submissionID: submissionID,
            reviewedAt: now,
            outcome: outcome,
            countedReviewIDs: countedReviews.map(\.id),
            failedCriteriaIndexes: outcome == .passed ? [] : failedCriteriaIndexes(reviews: countedReviews)
        )
    }

    static func priorityBoost(submittedAt: Date, now: Date = .now) -> Int {
        let waitingHours = now.timeIntervalSince(submittedAt) / 3_600
        switch waitingHours {
        case 72...: return 100
        case 24...: return 20
        default: return 0
        }
    }

    static func leasedSeat(_ seat: ReviewSeat, reviewerID: String, now: Date = .now) -> ReviewSeat? {
        guard seat.isClaimable(at: now) else { return nil }
        var leased = seat
        leased.reviewerID = reviewerID
        leased.state = .claimed
        leased.claimedAt = now
        leased.expiresAt = now.addingTimeInterval(seatLeaseDuration)
        return leased
    }
}

enum GoalPlanner {
    static func defaultLevels(for goalTitle: String) -> [(title: String, focus: String)] {
        let focus = goalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            ("Level 1: Establish", "Build a repeatable baseline for \(focus)."),
            ("Level 2: Deliberate reps", "Practice the weakest observable part of \(focus)."),
            ("Level 3: Prove transfer", "Show \(focus) in a realistic, independently repeatable situation."),
        ]
    }
}
