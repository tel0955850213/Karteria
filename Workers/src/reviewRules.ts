import type { ReviewDecision } from "./contracts";

export const reviewRules = {
    seatLeaseMilliseconds: 10 * 60 * 1_000,
    priorityBoostAt24Hours: 20,
    priorityBoostAt72Hours: 100,
    reviewsRequired: 3,
    passesRequired: 2,
    calibrationCasesRequired: 5,
    calibrationCorrectRequired: 4,
    communityPassReviewCount: 9,
    communityPassDays: 7,
    communityPassMaximumDays: 14,
    communityPassWindowMilliseconds: 30 * 24 * 60 * 60 * 1_000,
} as const;

export interface ReviewVote {
    seatID: string;
    decisions: ReviewDecision[];
}

export interface SettlementDecision {
    outcome: "passed" | "practiceAgain";
    failedCriteriaIndexes: number[];
    passingReviewCount: number;
}

export function reviewerPasses(decisions: ReviewDecision[]): boolean {
    return decisions.length === 3 && decisions.every((decision) => decision === "met");
}

export function settlementForVotes(votes: ReviewVote[]): SettlementDecision | undefined {
    const uniqueVotes = [...new Map(votes.map((vote) => [vote.seatID, vote])).values()].slice(0, reviewRules.reviewsRequired);
    if (uniqueVotes.length !== reviewRules.reviewsRequired) {
        return undefined;
    }
    const passingReviewCount = uniqueVotes.filter((vote) => reviewerPasses(vote.decisions)).length;
    if (passingReviewCount >= reviewRules.passesRequired) {
        return { outcome: "passed", failedCriteriaIndexes: [], passingReviewCount };
    }
    return {
        outcome: "practiceAgain",
        failedCriteriaIndexes: [0, 1, 2].filter((criterionIndex) =>
            uniqueVotes.filter((vote) => vote.decisions[criterionIndex] !== "met").length >= reviewRules.passesRequired,
        ),
        passingReviewCount,
    };
}

export function priorityScore(submittedAtMilliseconds: number, nowMilliseconds: number): number {
    const waitingHours = Math.max(0, nowMilliseconds - submittedAtMilliseconds) / (60 * 60 * 1_000);
    if (waitingHours >= 72) {
        return 10_000 + waitingHours;
    }
    if (waitingHours >= 24) {
        return 1_000 + waitingHours;
    }
    return waitingHours;
}

export function canClaimAnonymousOwner(
    reviewerSubjectHash: string,
    ownerSubjectHash: string | undefined,
    blockedOwnerSubjectHashes: readonly string[],
): boolean {
    return ownerSubjectHash !== undefined
        && ownerSubjectHash !== reviewerSubjectHash
        && !blockedOwnerSubjectHashes.includes(ownerSubjectHash);
}

export function nextCommunityPassDays(
    settledQualityReviewCount: number,
    awardedDaysInWindow: number,
): number {
    const earnedPasses = Math.floor(settledQualityReviewCount / reviewRules.communityPassReviewCount);
    const awardedPasses = Math.floor(awardedDaysInWindow / reviewRules.communityPassDays);
    if (earnedPasses <= awardedPasses || awardedDaysInWindow >= reviewRules.communityPassMaximumDays) {
        return 0;
    }
    return Math.min(reviewRules.communityPassDays, reviewRules.communityPassMaximumDays - awardedDaysInWindow);
}
