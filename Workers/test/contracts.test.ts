import assert from "node:assert/strict";
import test from "node:test";

import { isAdultBirthDate, parseSubmissionManifest, RequestValidationError } from "../src/contracts";

const validManifest = {
    submissionID: "96bd2288-335a-4f19-9bee-e8ac03fab0da",
    birthDate: "1999-04-15",
    contract: {
        title: "Explain a technical tradeoff",
        baselineSummary: "The baseline skips decision criteria.",
        criteria: ["Name the user problem.", "Compare two options.", "Give a recommendation."],
    },
    explanation: "A short explanation for reviewers.",
    baseline: [{
        id: "7e28cdb3-835b-46fc-8ce4-e283cfb1cd81",
        kind: "image",
        mimeType: "image/jpeg",
        byteCount: 250_000,
        durationSeconds: 0,
        label: "Baseline",
    }],
    checkpoint: [{
        id: "7499a17e-a7e1-4cf3-8e00-a8d23a2329ad",
        kind: "video",
        mimeType: "video/mp4",
        byteCount: 1_000_000,
        durationSeconds: 20,
        label: "Checkpoint",
    }],
};

test("accepts bounded JPEG and MP4 proof groups", () => {
    const parsed = parseSubmissionManifest(validManifest);
    assert.equal(parsed.baseline.length, 1);
    assert.equal(parsed.checkpoint[0]?.durationSeconds, 20);
});

test("rejects mixed proof formats inside a group", () => {
    assert.throws(
        () => parseSubmissionManifest({
            ...validManifest,
            baseline: [
                validManifest.baseline[0],
                { ...validManifest.checkpoint[0], id: "5494e2df-8918-40ee-a4d5-0c684622c69e" },
            ],
        }),
        RequestValidationError,
    );
});

test("enforces the eighteen-plus anonymous queue gate on the actual birthday", () => {
    assert.equal(isAdultBirthDate("2008-07-31", new Date("2026-07-31T00:00:00Z")), true);
    assert.equal(isAdultBirthDate("2008-08-01", new Date("2026-07-31T00:00:00Z")), false);
});
