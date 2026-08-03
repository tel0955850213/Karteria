import assert from "node:assert/strict";
import test from "node:test";

import { canClaimAnonymousOwner, nextCommunityPassDays, priorityScore, settlementForVotes } from "../src/reviewRules";

test("settles a level when two of three reviewers pass every criterion", () => {
    const settlement = settlementForVotes([
        { seatID: "one", decisions: ["met", "met", "met"] },
        { seatID: "two", decisions: ["met", "met", "met"] },
        { seatID: "three", decisions: ["met", "notShown", "met"] },
    ]);
    assert.deepEqual(settlement, {
        outcome: "passed",
        failedCriteriaIndexes: [],
        passingReviewCount: 2,
    });
});

test("returns direct practice focus when fewer than two reviewers pass", () => {
    const settlement = settlementForVotes([
        { seatID: "one", decisions: ["met", "notMet", "met"] },
        { seatID: "two", decisions: ["met", "notShown", "met"] },
        { seatID: "three", decisions: ["met", "met", "met"] },
    ]);
    assert.equal(settlement?.outcome, "practiceAgain");
    assert.deepEqual(settlement?.failedCriteriaIndexes, [1]);
});

test("ranks seventy-two-hour evidence above newer open seats", () => {
    const now = Date.parse("2026-07-31T00:00:00Z");
    assert.ok(priorityScore(now - 73 * 60 * 60 * 1_000, now) > priorityScore(now - 25 * 60 * 60 * 1_000, now));
    assert.ok(priorityScore(now - 25 * 60 * 60 * 1_000, now) > priorityScore(now - 2 * 60 * 60 * 1_000, now));
});

test("never matches self-review or a blocked anonymous owner", () => {
    assert.equal(canClaimAnonymousOwner("reviewer", "reviewer", []), false);
    assert.equal(canClaimAnonymousOwner("reviewer", "blocked-owner", ["blocked-owner"]), false);
    assert.equal(canClaimAnonymousOwner("reviewer", "eligible-owner", ["blocked-owner"]), true);
    assert.equal(canClaimAnonymousOwner("reviewer", undefined, []), false);
});

test("caps Community Pro Pass awards at fourteen days in the rolling window", () => {
    assert.equal(nextCommunityPassDays(9, 0), 7);
    assert.equal(nextCommunityPassDays(18, 7), 7);
    assert.equal(nextCommunityPassDays(27, 14), 0);
});
