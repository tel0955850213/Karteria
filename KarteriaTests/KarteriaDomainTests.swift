import XCTest
import SwiftData
@testable import Karteria

final class KarteriaDomainTests: XCTestCase {
    func testReviewerPassesOnlyWhenEveryCriterionIsMet() {
        XCTAssertTrue(ReviewEngine.reviewerPasses([.met, .met, .met]))
        XCTAssertFalse(ReviewEngine.reviewerPasses([.met, .notShown, .met]))
        XCTAssertFalse(ReviewEngine.reviewerPasses([.met, .met]))
    }

    func testSettlementRequiresThreeUniqueValidSeatsAndPassesAtTwoVotes() {
        let submissionID = UUID()
        let seats = [UUID(), UUID(), UUID()]
        let reviews = [
            PeerReviewVote(submissionID: submissionID, seatID: seats[0], reviewerID: "a", decisions: [.met, .met, .met], note: "", submittedAt: .distantPast),
            PeerReviewVote(submissionID: submissionID, seatID: seats[1], reviewerID: "b", decisions: [.met, .met, .met], note: "", submittedAt: .distantPast.addingTimeInterval(1)),
            PeerReviewVote(submissionID: submissionID, seatID: seats[2], reviewerID: "c", decisions: [.notMet, .met, .met], note: "The recommendation needs a concrete next step.", submittedAt: .distantPast.addingTimeInterval(2)),
        ]

        let settlement = ReviewEngine.settlement(submissionID: submissionID, reviews: reviews)
        XCTAssertEqual(settlement?.outcome, .passed)
        XCTAssertEqual(settlement?.countedReviewIDs.count, 3)
    }

    func testFailedSettlementReturnsRepeatedWeakCriteria() {
        let submissionID = UUID()
        let reviews = (0..<3).map { index in
            PeerReviewVote(
                submissionID: submissionID,
                seatID: UUID(),
                reviewerID: "reviewer-\(index)",
                decisions: [.met, .notShown, .met],
                note: "The comparison does not show the second criterion clearly.",
                submittedAt: .distantPast.addingTimeInterval(TimeInterval(index))
            )
        }

        let settlement = ReviewEngine.settlement(submissionID: submissionID, reviews: reviews)
        XCTAssertEqual(settlement?.outcome, .practiceAgain)
        XCTAssertEqual(settlement?.failedCriteriaIndexes, [1])
    }

    func testClaimedSeatExpiresAfterTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let seat = ReviewSeat(submissionID: UUID())
        let leased = ReviewEngine.leasedSeat(seat, reviewerID: "reviewer", now: now)
        XCTAssertEqual(leased?.state, .claimed)
        XCTAssertEqual(leased?.expiresAt, now.addingTimeInterval(600))
        XCTAssertFalse(leased?.isClaimable(at: now.addingTimeInterval(599)) ?? true)
        XCTAssertTrue(leased?.isClaimable(at: now.addingTimeInterval(600)) ?? false)
    }

    func testCreditGateIsWaivedWhenNoReviewExists() {
        var credits = CreditBalance(available: 0)
        XCTAssertTrue(credits.canSubmit(queueHasEligibleReview: false))
        XCTAssertEqual(credits.consumeForSubmission(queueHasEligibleReview: false), 0)
        XCTAssertFalse(credits.canSubmit(queueHasEligibleReview: true))
        credits.rewardForValidReview()
        XCTAssertEqual(credits.available, 1)
    }

    func testCalibrationNeedsFourCorrectAnswers() {
        var standing = ReviewerStanding()
        [true, true, true, false, true].forEach { standing.recordCalibration(answerWasCorrect: $0) }
        XCTAssertEqual(standing.status, .qualified)

        var failed = ReviewerStanding()
        [true, false, true, false, true].forEach { failed.recordCalibration(answerWasCorrect: $0) }
        XCTAssertEqual(failed.status, .recalibrationRequired)
    }

    func testTwoMinuteFallbackAppearsAfterMissingScheduledDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 12))! // Thursday
        // The fallback is offered on Thursday because Wednesday's scheduled rep was missed.
        let schedule = PracticeSchedule(weekdays: [4], preferredHour: 19)
        XCTAssertTrue(TwoMinuteFallback.shouldOffer(schedule: schedule, lastPracticeAt: nil, now: now, calendar: calendar))
    }

    func testCommunityPassIsLimitedToFourteenDaysInThirtyDays() {
        let now = Date(timeIntervalSince1970: 10_000)
        let reviews = (0..<18).map { now.addingTimeInterval(-Double($0) * 60) }
        let firstDays = CommunityProPassPolicy.nextAwardDays(
            settledQualityReviewDates: reviews,
            existingAwards: [],
            now: now
        )
        XCTAssertEqual(firstDays, 7)
        let awards = [
            CommunityProPassAward(id: "one", awardedAt: now, days: 7),
            CommunityProPassAward(id: "two", awardedAt: now, days: 7),
        ]
        XCTAssertEqual(
            CommunityProPassPolicy.nextAwardDays(
                settledQualityReviewDates: reviews,
                existingAwards: awards,
                now: now
            ),
            0
        )
    }

    func testGoalPlannerCreatesThreeProgressiveLevels() {
        let levels = GoalPlanner.defaultLevels(for: "Explain a systems design decision")
        XCTAssertEqual(levels.count, 3)
        XCTAssertTrue(levels[0].title.contains("Level 1"))
        XCTAssertTrue(levels[2].focus.contains("Explain a systems design decision"))
    }

    func testPracticeScheduleClampsInputsAndKeepsValidWeekdays() {
        let schedule = PracticeSchedule(weekdays: [0, 2, 4, 8], preferredHour: 27, minimumMinutes: 0)
        XCTAssertEqual(schedule.weekdays, Set([2, 4]))
        XCTAssertEqual(schedule.preferredHour, 23)
        XCTAssertEqual(schedule.minimumMinutes, 2)
    }

    @MainActor
    func testTrustedFeedbackNeverUnlocksAnAnonymousLevel() throws {
        let schema = Schema([ProfileRecord.self, GoalRecord.self, LevelRecord.self, PracticeRepRecord.self, EvidenceRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let repository = PrivateJourneyRepository(modelContext: ModelContext(container))
        let goal = repository.createGoal(
            identity: "I am a clear presenter.",
            title: "Explain a technical decision",
            outcome: "Give a short walkthrough.",
            schedule: PracticeSchedule()
        )
        let level = try XCTUnwrap(repository.levels(for: goal).first)

        repository.recordTrustedReviewInvitation(for: level, recordName: "trusted-\(level.id.uuidString)")
        repository.applyTrustedReviewStatus(
            TrustedReviewOwnerStatus(
                state: .completed,
                decisions: [.met, .met, .met],
                note: "Clear and specific.",
                reviewedAt: .now
            ),
            to: level
        )

        XCTAssertEqual(level.trustedReviewState, .completed)
        XCTAssertEqual(level.status, .practicing)
        XCTAssertEqual(goal.activeLevelNumber, 1)
    }
}
