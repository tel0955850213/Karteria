import Foundation

enum ReviewWorkKind: String, Codable {
    case calibration
    case anonymousQueue
    case trustedReview
}

struct TrustedReviewLocator: Codable, Equatable, Hashable {
    var recordName: String
    var zoneName: String
    var ownerName: String
}

struct ReviewEvidencePreview: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var summary: String
    var localRelativePath: String?
    var localFileURLs: [URL]
    var remoteURLs: [URL]
    var mediaKind: EvidenceMediaKind?

    init(
        id: UUID = UUID(),
        label: String,
        summary: String,
        localRelativePath: String? = nil,
        localFileURLs: [URL] = [],
        remoteURLs: [URL] = [],
        mediaKind: EvidenceMediaKind? = nil
    ) {
        self.id = id
        self.label = label
        self.summary = summary
        self.localRelativePath = localRelativePath
        self.localFileURLs = localFileURLs
        self.remoteURLs = remoteURLs
        self.mediaKind = mediaKind
    }
}

struct ReviewWorkItem: Codable, Identifiable {
    let id: UUID
    var kind: ReviewWorkKind
    var submissionID: UUID?
    var seatID: UUID?
    var fixtureID: String?
    var contractTitle: String
    var context: String
    var criteria: [RubricCriterion]
    var baseline: ReviewEvidencePreview
    var checkpoint: ReviewEvidencePreview
    var calibrationAnswer: [ReviewDecision]?
    var trustedReviewLocator: TrustedReviewLocator?

    init(
        id: UUID = UUID(),
        kind: ReviewWorkKind,
        submissionID: UUID? = nil,
        seatID: UUID? = nil,
        fixtureID: String? = nil,
        contractTitle: String,
        context: String,
        criteria: [RubricCriterion],
        baseline: ReviewEvidencePreview,
        checkpoint: ReviewEvidencePreview,
        calibrationAnswer: [ReviewDecision]? = nil,
        trustedReviewLocator: TrustedReviewLocator? = nil
    ) {
        self.id = id
        self.kind = kind
        self.submissionID = submissionID
        self.seatID = seatID
        self.fixtureID = fixtureID
        self.contractTitle = contractTitle
        self.context = context
        self.criteria = Array(criteria.prefix(3))
        self.baseline = baseline
        self.checkpoint = checkpoint
        self.calibrationAnswer = calibrationAnswer
        self.trustedReviewLocator = trustedReviewLocator
    }
}

enum CalibrationFixtures {
    static let cases: [ReviewWorkItem] = [
        ReviewWorkItem(
            kind: .calibration,
            fixtureID: "acknowledge-customer-concern",
            contractTitle: "Acknowledge a customer concern",
            context: "A synthetic practice case. Judge only the evidence shown.",
            criteria: [
                RubricCriterion(title: "State the concern in the customer's words."),
                RubricCriterion(title: "Offer one specific next step."),
                RubricCriterion(title: "Set a realistic follow-up time."),
            ],
            baseline: ReviewEvidencePreview(label: "Baseline", summary: "A reply that dismisses the concern and offers no next action."),
            checkpoint: ReviewEvidencePreview(label: "Checkpoint", summary: "A reply names the concern and proposes a next step, but does not set a time."),
            calibrationAnswer: [.met, .met, .notShown]
        ),
        ReviewWorkItem(
            kind: .calibration,
            fixtureID: "explain-technical-tradeoff",
            contractTitle: "Explain a technical tradeoff",
            context: "A synthetic practice case. Judge only the evidence shown.",
            criteria: [
                RubricCriterion(title: "Name the user problem first."),
                RubricCriterion(title: "Compare two concrete options."),
                RubricCriterion(title: "Give a recommendation with a reason."),
            ],
            baseline: ReviewEvidencePreview(label: "Baseline", summary: "The explanation lists a preferred implementation without user context."),
            checkpoint: ReviewEvidencePreview(label: "Checkpoint", summary: "The explanation names the problem, compares cache and query approaches, then recommends a cache because latency is the constraint."),
            calibrationAnswer: [.met, .met, .met]
        ),
        ReviewWorkItem(
            kind: .calibration,
            fixtureID: "practice-opening-statement",
            contractTitle: "Practice an opening statement",
            context: "A synthetic practice case. Judge only the evidence shown.",
            criteria: [
                RubricCriterion(title: "Open with the audience's outcome."),
                RubricCriterion(title: "Use one concrete example."),
                RubricCriterion(title: "Keep the opening under 30 seconds."),
            ],
            baseline: ReviewEvidencePreview(label: "Baseline", summary: "The opening starts with the speaker's biography and lasts 48 seconds."),
            checkpoint: ReviewEvidencePreview(label: "Checkpoint", summary: "The opening starts with the audience outcome, has no concrete example, and lasts 27 seconds."),
            calibrationAnswer: [.met, .notShown, .met]
        ),
        ReviewWorkItem(
            kind: .calibration,
            fixtureID: "show-design-before-after",
            contractTitle: "Show a design before and after",
            context: "A synthetic practice case. Judge only the evidence shown.",
            criteria: [
                RubricCriterion(title: "Show the original user flow."),
                RubricCriterion(title: "Show the revised flow."),
                RubricCriterion(title: "State what changed for the user."),
            ],
            baseline: ReviewEvidencePreview(label: "Baseline", summary: "A screenshot of a long sign-up sequence with two optional fields."),
            checkpoint: ReviewEvidencePreview(label: "Checkpoint", summary: "Before and after screens are shown; the revised flow removes optional fields and the caption says completion takes fewer decisions."),
            calibrationAnswer: [.met, .met, .met]
        ),
        ReviewWorkItem(
            kind: .calibration,
            fixtureID: "focused-study-session",
            contractTitle: "Prepare a focused study session",
            context: "A synthetic practice case. Judge only the evidence shown.",
            criteria: [
                RubricCriterion(title: "Name one specific concept to practice."),
                RubricCriterion(title: "Choose an active recall method."),
                RubricCriterion(title: "Define a two-minute fallback."),
            ],
            baseline: ReviewEvidencePreview(label: "Baseline", summary: "A calendar block named Study."),
            checkpoint: ReviewEvidencePreview(label: "Checkpoint", summary: "The session names Fourier transforms, uses a closed-book recall prompt, and defines a two-minute formula recall fallback."),
            calibrationAnswer: [.met, .met, .met]
        ),
    ]

    static func next(after completed: Int) -> ReviewWorkItem? {
        guard completed < cases.count else { return nil }
        return cases[completed]
    }
}
