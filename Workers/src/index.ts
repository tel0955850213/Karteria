import {
    allMedia,
    asInteger,
    asObject,
    asString,
    asUUID,
    evidenceLimits,
    isAdultBirthDate,
    mediaAssetField,
    parseReviewDecisions,
    parseSubmissionManifest,
    parseUploadedAssets,
    RequestValidationError,
    type MediaDescriptor,
    type ReviewDecision,
    type SubmissionDraftPayload,
    type SubmissionManifest,
    type UploadedAssetValue,
} from "./contracts";
import { AppleIdentityError, verifyAppleIdentity, type AppleIdentityEnvironment, type VerifiedAppleIdentity } from "./appleIdentity";
import {
    assetDownloadURL,
    booleanValue,
    CloudKitClient,
    CloudKitError,
    type CloudKitField,
    field,
    numberValue,
    record,
    stringValue,
    type CloudKitEnvironment,
    type CloudKitOperation,
    type CloudKitRecord,
} from "./cloudKit";
import { fromBase64URL, hmacSHA256Base64URL, sha256Base64URL } from "./crypto";
import { grantCommunityProPass, isRevenueCatConfigured, RevenueCatError, type RevenueCatEnvironment } from "./revenueCat";
import { canClaimAnonymousOwner, nextCommunityPassDays, priorityScore, reviewerPasses, reviewRules, settlementForVotes } from "./reviewRules";

interface Env extends AppleIdentityEnvironment, CloudKitEnvironment, RevenueCatEnvironment {
    SUBMISSION_DRAFT_SECRET?: string;
    MODERATOR_API_KEY?: string;
}

interface ReviewerStandingState {
    record: CloudKitRecord;
    reviewCredits: number;
    calibrationCompleted: number;
    calibrationCorrect: number;
    calibrationStatus: CalibrationStatus;
    communityPassAwards: CommunityPassAward[];
    blockedOwnerSubjectHashes: string[];
}

type CalibrationStatus = "notStarted" | "calibrating" | "qualified" | "recalibrationRequired";

interface CommunityPassAward {
    id: string;
    awardedAt: number;
    expiresAt: number;
    days: number;
    deliveryState: "pending" | "granted";
}

interface StoredMedia extends MediaDescriptor {
    fieldName: string;
}

interface StoredSubmission {
    record: CloudKitRecord;
    submissionID: string;
    ownerSubjectHash: string;
    state: string;
    submittedAt: number;
    contractTitle: string;
    baselineSummary: string;
    criteria: [string, string, string];
    explanation: string;
    baseline: StoredMedia[];
    checkpoint: StoredMedia[];
    reportCount: number;
}

interface StoredSettlement {
    ownerSubjectHash: string;
    outcome: "passed" | "practiceAgain";
    failedCriteriaIndexes: number[];
    reviewedAt: number;
    cleanupAt: number;
    cleanupState: string;
}

const calibrationCases: Array<{ id: string; answer: [ReviewDecision, ReviewDecision, ReviewDecision] }> = [
    { id: "acknowledge-customer-concern", answer: ["met", "met", "notShown"] },
    { id: "explain-technical-tradeoff", answer: ["met", "met", "met"] },
    { id: "practice-opening-statement", answer: ["met", "notShown", "met"] },
    { id: "show-design-before-after", answer: ["met", "met", "met"] },
    { id: "focused-study-session", answer: ["met", "met", "met"] },
];

const jsonHeaders = {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
} as const;

let lastMaintenanceAttemptAt = 0;
const maintenanceIntervalMilliseconds = 6 * 60 * 60 * 1_000;

export default {
    async fetch(request: Request, environment: Env, context: ExecutionContext): Promise<Response> {
        try {
            scheduleMaintenance(environment, context);
            if (request.method === "OPTIONS") {
                return new Response(null, { status: 204, headers: { Allow: "POST, OPTIONS", "Cache-Control": "no-store" } });
            }
            if (request.method !== "POST") {
                return response({ message: "Only POST requests are supported." }, 405);
            }

            const path = new URL(request.url).pathname.replace(/\/+$/, "") || "/";
            switch (path) {
            case "/submissions/initiate":
                return response(await initiateSubmission(request, environment));
            case "/submissions/finalize":
                return response(await finalizeSubmission(request, environment));
            case "/calibrations/record":
                return response(await recordCalibration(request, environment));
            case "/review-slots/claim":
                return response(await claimReviewSlot(request, environment));
            case "/reviews/settle":
                return response(await submitPeerReview(request, environment));
            case "/submissions/status":
                return response(await submissionStatus(request, environment));
            case "/submissions/remove":
                return response(await removeOwnSubmission(request, environment));
            case "/rewards/redeem":
                return response(await redeemCommunityPass(request, environment));
            case "/reports":
                return response(await reportContent(request, environment));
            case "/blocks":
                return response(await blockSubmissionOwner(request, environment));
            case "/moderation/health":
                return response(await moderationHealth(request, environment));
            case "/moderation/submissions/remove":
                return response(await removeSubmissionForModeration(request, environment));
            default:
                return response({ message: "Unknown exchange endpoint." }, 404);
            }
        } catch (error) {
            return errorResponse(error);
        }
    },

    async scheduled(_event: ScheduledEvent, environment: Env): Promise<void> {
        const client = configuredClient(environment);
        await purgeExpiredEvidence(client);
    },
};

function scheduleMaintenance(environment: Env, context: ExecutionContext): void {
    const now = Date.now();
    if (now - lastMaintenanceAttemptAt < maintenanceIntervalMilliseconds) {
        return;
    }
    const client = new CloudKitClient(environment);
    if (!client.isConfigured) {
        return;
    }
    lastMaintenanceAttemptAt = now;
    context.waitUntil(purgeExpiredEvidence(client).catch(() => {
        lastMaintenanceAttemptAt = 0;
    }));
}

async function initiateSubmission(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const manifest = parseSubmissionManifest(body.manifest);
    assertAnonymousExchangeAge(manifest.birthDate);
    const client = configuredClient(environment);

    const existing = await loadSubmission(client, manifest.submissionID);
    if (existing) {
        assertSubmissionOwner(existing, identity);
        return {
            submissionID: existing.submissionID,
            alreadyFinalized: true,
            creditGateWaived: false,
            reviewCredits: (await getOrCreateStanding(client, identity.subjectHash)).reviewCredits,
            uploads: [],
        };
    }

    const standing = await getOrCreateStanding(client, identity.subjectHash);
    const queueHasClaimableWork = await hasClaimableWork(client);
    if (queueHasClaimableWork && standing.reviewCredits < 3) {
        throw new HTTPError("Complete reviews to earn the three credits needed for this submission.", 403);
    }

    const mediaForUpload = allMedia(manifest);
    const uploadTokens = await client.requestAssetUpload(mediaForUpload.map((media) => ({
        recordName: submissionRecordName(manifest.submissionID),
        recordType: "ReviewSubmission",
        fieldName: media.fieldName,
    })));
    const manifestDigest = await sha256Base64URL(canonicalManifest(manifest));
    return {
        submissionID: manifest.submissionID,
        alreadyFinalized: false,
        draftToken: await signDraft(
            {
                submissionID: manifest.submissionID,
                subjectHash: identity.subjectHash,
                manifestDigest,
                expiresAt: Date.now() + 15 * 60 * 1_000,
            },
            environment,
        ),
        creditGateWaived: !queueHasClaimableWork,
        reviewCredits: standing.reviewCredits,
        uploads: uploadTokens.map((token) => {
            const media = mediaForUpload.find((candidate) => candidate.fieldName === token.fieldName);
            if (!media) {
                throw new CloudKitError("CloudKit returned an upload token for unknown evidence.");
            }
            return { mediaID: media.id, fieldName: token.fieldName, url: token.url };
        }),
    };
}

async function finalizeSubmission(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const manifest = parseSubmissionManifest(body.manifest);
    assertAnonymousExchangeAge(manifest.birthDate);
    const draft = await verifyDraft(asString(body.draftToken, "draftToken", 5_000), environment);
    const manifestDigest = await sha256Base64URL(canonicalManifest(manifest));
    if (
        draft.submissionID !== manifest.submissionID
        || draft.subjectHash !== identity.subjectHash
        || draft.manifestDigest !== manifestDigest
    ) {
        throw new HTTPError("The evidence upload draft does not match this account.", 403);
    }

    const client = configuredClient(environment);
    const existing = await loadSubmission(client, manifest.submissionID);
    if (existing) {
        assertSubmissionOwner(existing, identity);
        return {
            submissionID: existing.submissionID,
            status: existing.state,
            alreadyFinalized: true,
            creditsConsumed: 0,
            creditGateWaived: false,
        };
    }

    const uploadedAssets = parseUploadedAssets(body.uploadedAssets);
    validateUploadedAssets(manifest, uploadedAssets);
    const standing = await getOrCreateStanding(client, identity.subjectHash);
    const queueHasClaimableWork = await hasClaimableWork(client);
    const creditsConsumed = queueHasClaimableWork ? 3 : 0;
    if (standing.reviewCredits < creditsConsumed) {
        throw new HTTPError("Complete reviews to earn the three credits needed for this submission.", 403);
    }

    const now = Date.now();
    const operations: CloudKitOperation[] = [
        {
            operationType: "create",
            record: record(
                submissionRecordName(manifest.submissionID),
                "ReviewSubmission",
                submissionFields(manifest, identity.subjectHash, uploadedAssets, now),
            ),
        },
        ...[1, 2, 3].map((ordinal) => ({
            operationType: "create" as const,
            record: record(
                seatRecordName(manifest.submissionID, ordinal),
                "ReviewSeat",
                {
                    seatID: field(seatID(manifest.submissionID, ordinal)),
                    submissionID: field(manifest.submissionID),
                    ownerSubjectHash: field(identity.subjectHash),
                    state: field("open"),
                    ordinal: field(ordinal),
                    submittedAt: field(now),
                    claimUntil: field(0),
                    reviewerSubjectHash: field(""),
                },
            ),
        })),
    ];
    if (creditsConsumed > 0) {
        operations.push({
            operationType: "update",
            record: record(
                standing.record.recordName,
                "ReviewerStanding",
                standingFields({ ...standing, reviewCredits: standing.reviewCredits - creditsConsumed }),
                requiredChangeTag(standing.record),
            ),
        });
    }

    try {
        await client.modify(operations);
    } catch (error) {
        const createdDuringRetry = await loadSubmission(client, manifest.submissionID);
        if (createdDuringRetry && createdDuringRetry.ownerSubjectHash === identity.subjectHash) {
            return {
                submissionID: createdDuringRetry.submissionID,
                status: createdDuringRetry.state,
                alreadyFinalized: true,
                creditsConsumed: 0,
                creditGateWaived: false,
            };
        }
        throw error;
    }

    return {
        submissionID: manifest.submissionID,
        status: "awaitingReview",
        alreadyFinalized: false,
        creditsConsumed,
        creditGateWaived: creditsConsumed === 0,
        reviewCredits: standing.reviewCredits - creditsConsumed,
    };
}

async function recordCalibration(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const caseID = asString(body.caseID, "caseID", 120);
    const decisions = parseReviewDecisions(body.decisions);
    const client = configuredClient(environment);
    const standing = await getOrCreateStanding(client, identity.subjectHash);
    const reset = standing.calibrationStatus === "recalibrationRequired"
        ? { ...standing, calibrationCompleted: 0, calibrationCorrect: 0, calibrationStatus: "notStarted" as const }
        : standing;
    if (reset.calibrationStatus === "qualified") {
        return standingResponse(reset);
    }
    const expected = calibrationCases[reset.calibrationCompleted];
    if (!expected || expected.id !== caseID) {
        throw new HTTPError("Complete the next calibration case in order.", 409);
    }
    const completed = reset.calibrationCompleted + 1;
    const correct = reset.calibrationCorrect + (sameDecisions(decisions, expected.answer) ? 1 : 0);
    const status: CalibrationStatus = completed >= reviewRules.calibrationCasesRequired
        ? (correct >= reviewRules.calibrationCorrectRequired ? "qualified" : "recalibrationRequired")
        : "calibrating";
    const updated = { ...reset, calibrationCompleted: completed, calibrationCorrect: correct, calibrationStatus: status };
    await client.modify([{
        operationType: "update",
        record: record(
            updated.record.recordName,
            "ReviewerStanding",
            standingFields(updated),
            requiredChangeTag(updated.record),
        ),
    }]);
    return standingResponse(updated);
}

async function claimReviewSlot(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    assertAnonymousExchangeAge(asString(body.birthDate, "birthDate", 10));
    const client = configuredClient(environment);
    const standing = await getOrCreateStanding(client, identity.subjectHash);
    if (standing.calibrationStatus !== "qualified") {
        throw new HTTPError("Finish five calibration cases with at least four correct answers before entering the anonymous queue.", 403);
    }

    const now = Date.now();
    await reopenExpiredSeats(client, now);
    const alreadyClaimed = await client.query(
        "ReviewSeat",
        [
            { fieldName: "state", comparator: "EQUALS", value: "claimed" },
            { fieldName: "reviewerSubjectHash", comparator: "EQUALS", value: identity.subjectHash },
            { fieldName: "claimUntil", comparator: "GREATER_THAN", value: now },
        ],
        { desiredKeys: seatDesiredKeys(), resultsLimit: 1 },
    );
    if (letFirst(alreadyClaimed)) {
        return { workItem: await workItemForSeat(client, letFirst(alreadyClaimed) as CloudKitRecord), queueEmpty: false };
    }

    for (let attempt = 0; attempt < 4; attempt += 1) {
        const candidates = await client.query(
            "ReviewSeat",
            [{ fieldName: "state", comparator: "EQUALS", value: "open" }],
            { desiredKeys: seatDesiredKeys(), resultsLimit: 50 },
        );
        const ranked = candidates
            .filter((candidate) => canClaimAnonymousOwner(
                identity.subjectHash,
                stringValue(candidate, "ownerSubjectHash"),
                standing.blockedOwnerSubjectHashes,
            ))
            .sort((left, right) => {
                const leftSubmittedAt = numberValue(left, "submittedAt") ?? 0;
                const rightSubmittedAt = numberValue(right, "submittedAt") ?? 0;
                return priorityScore(rightSubmittedAt, now) - priorityScore(leftSubmittedAt, now);
            });
        const candidate = ranked[0];
        if (!candidate) {
            return { workItem: null, queueEmpty: true };
        }
        const submissionID = stringValue(candidate, "submissionID");
        if (!submissionID) {
            continue;
        }
        const submission = await loadSubmission(client, submissionID);
        if (!submission || submission.state !== "awaitingReview") {
            continue;
        }
        const claimedRecord = record(
            candidate.recordName,
            "ReviewSeat",
            {
                state: field("claimed"),
                reviewerSubjectHash: field(identity.subjectHash),
                claimedAt: field(now),
                claimUntil: field(now + reviewRules.seatLeaseMilliseconds),
            },
            requiredChangeTag(candidate),
        );
        try {
            await client.modify([{ operationType: "update", record: claimedRecord }]);
            return { workItem: reviewWorkItem(submission, seatIDFromRecord(candidate)), queueEmpty: false };
        } catch (error) {
            if (!(error instanceof CloudKitError)) {
                throw error;
            }
        }
    }
    return { workItem: null, queueEmpty: false };
}

async function submitPeerReview(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const submissionID = asUUID(body.submissionID, "submissionID");
    const requestedSeatID = asUUID(body.seatID, "seatID");
    const decisions = parseReviewDecisions(body.decisions);
    const note = optionalText(body.note, "note", 280);
    if (decisions.some((decision) => decision !== "met") && note.length < 20) {
        throw new RequestValidationError("Explain what needs another rep when a criterion is not met or not shown.");
    }

    const client = configuredClient(environment);
    const seat = await loadSeat(client, submissionID, requestedSeatID);
    if (!seat) {
        throw new HTTPError("This review seat no longer exists.", 404);
    }
    if (stringValue(seat, "reviewerSubjectHash") !== identity.subjectHash) {
        throw new HTTPError("This review seat belongs to another reviewer.", 403);
    }
    if (stringValue(seat, "state") !== "claimed" || (numberValue(seat, "claimUntil") ?? 0) <= Date.now()) {
        throw new HTTPError("This review seat expired. Claim another proof before submitting.", 409);
    }

    const reviewName = reviewRecordName(requestedSeatID);
    const existingReview = await getRecord(client, reviewName);
    const standing = await getOrCreateStanding(client, identity.subjectHash);
    if (existingReview) {
        return {
            accepted: true,
            earnedCredit: false,
            reviewCredits: standing.reviewCredits,
            settlement: await settleSubmissionIfReady(client, submissionID),
        };
    }

    const now = Date.now();
    const updatedStanding = { ...standing, reviewCredits: standing.reviewCredits + 1 };
    try {
        await client.modify([
            {
                operationType: "update",
                record: record(
                    seat.recordName,
                    "ReviewSeat",
                    { state: field("completed"), completedAt: field(now), claimUntil: field(0) },
                    requiredChangeTag(seat),
                ),
            },
            {
                operationType: "create",
                record: record(reviewName, "PeerReview", {
                    reviewID: field(requestedSeatID),
                    submissionID: field(submissionID),
                    seatID: field(requestedSeatID),
                    reviewerSubjectHash: field(identity.subjectHash),
                    decisionsJSON: field(JSON.stringify(decisions)),
                    note: field(note),
                    passes: field(reviewerPasses(decisions)),
                    submittedAt: field(now),
                    qualityEligible: field(false),
                    settledAt: field(0),
                }),
            },
            {
                operationType: "update",
                record: record(
                    standing.record.recordName,
                    "ReviewerStanding",
                    standingFields(updatedStanding),
                    requiredChangeTag(standing.record),
                ),
            },
        ]);
    } catch (error) {
        if (await getRecord(client, reviewName)) {
            return {
                accepted: true,
                earnedCredit: false,
                reviewCredits: standing.reviewCredits + 1,
                settlement: await settleSubmissionIfReady(client, submissionID),
            };
        }
        throw error;
    }

    return {
        accepted: true,
        earnedCredit: true,
        reviewCredits: updatedStanding.reviewCredits,
        settlement: await settleSubmissionIfReady(client, submissionID),
    };
}

async function submissionStatus(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const submissionID = asUUID(body.submissionID, "submissionID");
    const client = configuredClient(environment);
    const submission = await loadSubmission(client, submissionID);
    const settlement = await loadSettlement(client, submissionID);
    if (!submission && !settlement) {
        throw new HTTPError("This checkpoint is no longer available in the public exchange.", 404);
    }
    const ownerHash = submission?.ownerSubjectHash ?? settlement?.ownerSubjectHash;
    if (ownerHash !== identity.subjectHash) {
        throw new HTTPError("This checkpoint belongs to another member.", 403);
    }
    const reviewCount = submission
        ? (await client.query("PeerReview", [{ fieldName: "submissionID", comparator: "EQUALS", value: submissionID }], { resultsLimit: 3 })).length
        : reviewRules.reviewsRequired;
    const submittedAt = submission?.submittedAt ?? settlement?.reviewedAt ?? Date.now();
    return {
        submissionID,
        state: settlement?.outcome ?? submission?.state ?? "evidencePurged",
        reviewCount,
        submittedAt: new Date(submittedAt).toISOString(),
        canInviteTrustedReview: !settlement && Date.now() - submittedAt >= 24 * 60 * 60 * 1_000,
        highestPriority: !settlement && Date.now() - submittedAt >= 72 * 60 * 60 * 1_000,
        settlement: settlement ? settlementResponse(settlement) : null,
    };
}

async function removeOwnSubmission(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const submissionID = asUUID(body.submissionID, "submissionID");
    const client = configuredClient(environment);
    const submission = await loadSubmission(client, submissionID);
    const settlement = await loadSettlement(client, submissionID);
    if (!submission && !settlement) {
        return { removed: true, alreadyRemoved: true };
    }
    const ownerSubjectHash = submission?.ownerSubjectHash ?? settlement?.ownerSubjectHash;
    if (ownerSubjectHash !== identity.subjectHash) {
        throw new HTTPError("Only the evidence owner can remove this public copy.", 403);
    }
    await purgeSubmissionEvidence(client, submissionID, "removed");
    return { removed: true, alreadyRemoved: false };
}

async function redeemCommunityPass(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const client = configuredClient(environment);
    if (!isRevenueCatConfigured(environment)) {
        throw new HTTPError("Community Pro Pass is not configured for this build.", 503);
    }
    let standing = await getOrCreateStanding(client, identity.subjectHash);
    const now = Date.now();
    const windowStart = now - reviewRules.communityPassWindowMilliseconds;
    const settledReviews = await client.query(
        "PeerReview",
        [
            { fieldName: "reviewerSubjectHash", comparator: "EQUALS", value: identity.subjectHash },
            { fieldName: "qualityEligible", comparator: "EQUALS", value: true },
            { fieldName: "settledAt", comparator: "GREATER_THAN_OR_EQUALS", value: windowStart },
        ],
        { desiredKeys: ["settledAt"], resultsLimit: 200, sortField: "settledAt", ascending: true },
    );
    const activeAwards = standing.communityPassAwards.filter((award) => award.awardedAt >= windowStart);
    const pendingAward = activeAwards.find((award) => award.deliveryState === "pending");
    if (pendingAward) {
        await grantCommunityProPass(environment, identity.subject, new Date(pendingAward.expiresAt));
        standing = await markAwardGranted(client, standing, pendingAward.id);
        return { grantedDays: pendingAward.days, entitlementExpiresAt: new Date(pendingAward.expiresAt).toISOString() };
    }

    const awardedDays = activeAwards.reduce((total, award) => total + award.days, 0);
    const days = nextCommunityPassDays(settledReviews.length, awardedDays);
    if (days === 0) {
        return { grantedDays: 0, entitlementExpiresAt: null };
    }
    const currentGroup = Math.floor(awardedDays / reviewRules.communityPassDays);
    const groupRecords = settledReviews
        .slice(currentGroup * reviewRules.communityPassReviewCount, (currentGroup + 1) * reviewRules.communityPassReviewCount)
        .map((review) => review.recordName)
        .sort()
        .join("|");
    const award: CommunityPassAward = {
        id: `community-pro-${await sha256Base64URL(`${identity.subjectHash}:${groupRecords}`)}`,
        awardedAt: now,
        expiresAt: now + days * 24 * 60 * 60 * 1_000,
        days,
        deliveryState: "pending",
    };
    standing = await appendAward(client, standing, award);
    await grantCommunityProPass(environment, identity.subject, new Date(award.expiresAt));
    await markAwardGranted(client, standing, award.id);
    return { grantedDays: award.days, entitlementExpiresAt: new Date(award.expiresAt).toISOString() };
}

async function reportContent(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const submissionID = asUUID(body.submissionID, "submissionID");
    const reason = asString(body.reason, "reason", 120);
    const detail = asString(body.detail, "detail", 500);
    const client = configuredClient(environment);
    const submission = await loadSubmission(client, submissionID);
    if (!submission) {
        throw new HTTPError("This evidence is no longer reportable.", 404);
    }
    const reportName = `report-${submissionID}-${identity.subjectHash}`;
    if (await getRecord(client, reportName)) {
        return { accepted: true, duplicate: true };
    }
    await client.modify([
        {
            operationType: "create",
            record: record(reportName, "ContentReport", {
                submissionID: field(submissionID),
                reporterSubjectHash: field(identity.subjectHash),
                reason: field(reason),
                detail: field(detail),
                state: field("pending"),
                createdAt: field(Date.now()),
            }),
        },
        {
            operationType: "update",
            record: record(
                submission.record.recordName,
                "ReviewSubmission",
                { reportCount: field(submission.reportCount + 1) },
                requiredChangeTag(submission.record),
            ),
        },
    ]);
    return { accepted: true, duplicate: false };
}

async function blockSubmissionOwner(request: Request, environment: Env): Promise<Record<string, unknown>> {
    const identity = await authenticatedIdentity(request, environment);
    const body = asObject(await requestJSON(request));
    const submissionID = asUUID(body.submissionID, "submissionID");
    const client = configuredClient(environment);
    const submission = await loadSubmission(client, submissionID);
    if (!submission) {
        throw new HTTPError("This evidence is no longer available to block.", 404);
    }
    if (submission.ownerSubjectHash === identity.subjectHash) {
        throw new HTTPError("You cannot block your own evidence.", 400);
    }

    let standing = await getOrCreateStanding(client, identity.subjectHash);
    for (let attempt = 0; attempt < 3; attempt += 1) {
        if (standing.blockedOwnerSubjectHashes.includes(submission.ownerSubjectHash)) {
            return { blocked: true, duplicate: true };
        }
        const updated = {
            ...standing,
            blockedOwnerSubjectHashes: [...standing.blockedOwnerSubjectHashes.slice(-499), submission.ownerSubjectHash],
        };
        try {
            await client.modify([{
                operationType: "update",
                record: record(
                    standing.record.recordName,
                    "ReviewerStanding",
                    standingFields(updated),
                    requiredChangeTag(standing.record),
                ),
            }]);
            return { blocked: true, duplicate: false };
        } catch (error) {
            if (!(error instanceof CloudKitError) || attempt === 2) {
                throw error;
            }
            standing = await getOrCreateStanding(client, identity.subjectHash);
        }
    }
    throw new HTTPError("Karteria could not save this block. Try again.", 409);
}

async function removeSubmissionForModeration(request: Request, environment: Env): Promise<Record<string, unknown>> {
    assertModerator(request, environment);
    const body = asObject(await requestJSON(request));
    const submissionID = asUUID(body.submissionID, "submissionID");
    const client = configuredClient(environment);
    await purgeSubmissionEvidence(client, submissionID, "removed");
    return { removed: true };
}

async function moderationHealth(request: Request, environment: Env): Promise<Record<string, unknown>> {
    assertModerator(request, environment);
    const client = configuredClient(environment);
    await client.query(
        "ReviewSeat",
        [{ fieldName: "state", comparator: "EQUALS", value: "__health_probe__" }],
        { desiredKeys: ["seatID"], resultsLimit: 1 },
    );
    return {
        status: "ok",
        cloudKitEnvironment: environment.CLOUDKIT_ENVIRONMENT,
        revenueCatConfigured: isRevenueCatConfigured(environment),
    };
}

function assertModerator(request: Request, environment: Env): void {
    const expected = environment.MODERATOR_API_KEY;
    if (!expected || request.headers.get("X-Karteria-Moderator-Key") !== expected) {
        throw new HTTPError("Moderator authorization is required.", 401);
    }
}

async function settleSubmissionIfReady(client: CloudKitClient, submissionID: string): Promise<Record<string, unknown> | null> {
    const existing = await loadSettlement(client, submissionID);
    if (existing) {
        return settlementResponse(existing);
    }
    const submission = await loadSubmission(client, submissionID);
    if (!submission || submission.state !== "awaitingReview") {
        return null;
    }
    const reviews = await client.query(
        "PeerReview",
        [{ fieldName: "submissionID", comparator: "EQUALS", value: submissionID }],
        { desiredKeys: ["seatID", "decisionsJSON", "reviewerSubjectHash", "submittedAt"], resultsLimit: 3 },
    );
    const votes = reviews.flatMap((review) => {
        const seatID = stringValue(review, "seatID");
        const rawDecisions = stringValue(review, "decisionsJSON");
        if (!seatID || !rawDecisions) {
            return [];
        }
        try {
            return [{ seatID, decisions: JSON.parse(rawDecisions) as ReviewDecision[] }];
        } catch {
            return [];
        }
    });
    const decision = settlementForVotes(votes);
    if (!decision) {
        return null;
    }
    const now = Date.now();
    const qualityEligible = submission.reportCount === 0;
    const settlementFields = {
        settlementID: field(submissionID),
        submissionID: field(submissionID),
        ownerSubjectHash: field(submission.ownerSubjectHash),
        outcome: field(decision.outcome),
        failedCriteriaIndexesJSON: field(JSON.stringify(decision.failedCriteriaIndexes)),
        reviewedAt: field(now),
        cleanupAt: field(now + 30 * 24 * 60 * 60 * 1_000),
        cleanupState: field("pending"),
    };
    const operations: CloudKitOperation[] = [
        {
            operationType: "create",
            record: record(settlementRecordName(submissionID), "ReviewSettlement", settlementFields),
        },
        {
            operationType: "update",
            record: record(
                submission.record.recordName,
                "ReviewSubmission",
                {
                    state: field(decision.outcome),
                    settledAt: field(now),
                    failedCriteriaIndexesJSON: field(JSON.stringify(decision.failedCriteriaIndexes)),
                    cleanupAt: field(now + 30 * 24 * 60 * 60 * 1_000),
                },
                requiredChangeTag(submission.record),
            ),
        },
        ...reviews.map((review) => ({
            operationType: "update" as const,
            record: record(
                review.recordName,
                "PeerReview",
                {
                    qualityEligible: field(qualityEligible),
                    settledAt: field(now),
                    settlementID: field(submissionID),
                },
                requiredChangeTag(review),
            ),
        })),
    ];
    try {
        await client.modify(operations);
        return settlementResponse({
            ownerSubjectHash: submission.ownerSubjectHash,
            outcome: decision.outcome,
            failedCriteriaIndexes: decision.failedCriteriaIndexes,
            reviewedAt: now,
            cleanupAt: now + 30 * 24 * 60 * 60 * 1_000,
            cleanupState: "pending",
        });
    } catch (error) {
        const concurrentSettlement = await loadSettlement(client, submissionID);
        if (concurrentSettlement) {
            return settlementResponse(concurrentSettlement);
        }
        throw error;
    }
}

async function workItemForSeat(client: CloudKitClient, seat: CloudKitRecord): Promise<Record<string, unknown>> {
    const submissionID = stringValue(seat, "submissionID");
    if (!submissionID) {
        throw new HTTPError("This review seat has no submission.", 409);
    }
    const submission = await loadSubmission(client, submissionID);
    if (!submission) {
        throw new HTTPError("This review evidence has expired.", 410);
    }
    return reviewWorkItem(submission, seatIDFromRecord(seat));
}

function reviewWorkItem(submission: StoredSubmission, assignedSeatID: string): Record<string, unknown> {
    return {
        id: crypto.randomUUID(),
        kind: "anonymousQueue",
        submissionID: submission.submissionID,
        seatID: assignedSeatID,
        contractTitle: submission.contractTitle,
        context: submission.explanation || "Judge only what the evidence visibly demonstrates against this contract.",
        criteria: submission.criteria.map((title) => ({ id: crypto.randomUUID(), title })),
        baseline: evidencePreview(submission.record, submission.baseline, "Baseline"),
        checkpoint: evidencePreview(submission.record, submission.checkpoint, "Checkpoint"),
    };
}

function evidencePreview(recordValue: CloudKitRecord, media: StoredMedia[], label: string): Record<string, unknown> {
    const urls = media
        .map((item) => assetDownloadURL(recordValue, item.fieldName))
        .filter((url): url is string => Boolean(url));
    const kind = media[0]?.kind ?? "image";
    return {
        id: crypto.randomUUID(),
        label,
        summary: media.length === 1
            ? (kind === "video" ? "One short video proof." : "One image proof.")
            : `${media.length} image proofs.`,
        remoteURLs: urls,
        mediaKind: kind,
    };
}

async function reopenExpiredSeats(client: CloudKitClient, now: number): Promise<void> {
    const expired = await client.query(
        "ReviewSeat",
        [
            { fieldName: "state", comparator: "EQUALS", value: "claimed" },
            { fieldName: "claimUntil", comparator: "LESS_THAN", value: now },
        ],
        { desiredKeys: seatDesiredKeys(), resultsLimit: 50 },
    );
    for (const seat of expired) {
        try {
            await client.modify([{
                operationType: "update",
                record: record(
                    seat.recordName,
                    "ReviewSeat",
                    {
                        state: field("open"),
                        reviewerSubjectHash: field(""),
                        claimUntil: field(0),
                    },
                    requiredChangeTag(seat),
                ),
            }]);
        } catch {
            // A competing claim owns this seat now. The next claim loop selects another one.
        }
    }
}

async function hasClaimableWork(client: CloudKitClient): Promise<boolean> {
    const seats = await client.query(
        "ReviewSeat",
        [{ fieldName: "state", comparator: "EQUALS", value: "open" }],
        { desiredKeys: ["seatID"], resultsLimit: 1 },
    );
    return seats.length > 0;
}

async function purgeExpiredEvidence(client: CloudKitClient): Promise<void> {
    const now = Date.now();
    const settlements = await client.query(
        "ReviewSettlement",
        [
            { fieldName: "cleanupState", comparator: "EQUALS", value: "pending" },
            { fieldName: "cleanupAt", comparator: "LESS_THAN_OR_EQUALS", value: now },
        ],
        { desiredKeys: ["submissionID"], resultsLimit: 50 },
    );
    for (const settlement of settlements) {
        const submissionID = stringValue(settlement, "submissionID");
        if (!submissionID) {
            continue;
        }
        await purgeSubmissionEvidence(client, submissionID, "purged");
    }
}

async function purgeSubmissionEvidence(client: CloudKitClient, submissionID: string, cleanupState: "purged" | "removed"): Promise<void> {
    const submission = await loadSubmission(client, submissionID);
    const settlementRecord = await getRecord(client, settlementRecordName(submissionID));
    const seats = await client.query(
        "ReviewSeat",
        [{ fieldName: "submissionID", comparator: "EQUALS", value: submissionID }],
        { resultsLimit: 3 },
    );
    const operations: CloudKitOperation[] = [
        ...(submission ? [{
            operationType: "delete" as const,
            record: { recordName: submission.record.recordName, recordChangeTag: requiredChangeTag(submission.record) },
        }] : []),
        ...seats.map((seat) => ({
            operationType: "delete" as const,
            record: { recordName: seat.recordName, recordChangeTag: requiredChangeTag(seat) },
        })),
        ...(settlementRecord ? [{
            operationType: "update" as const,
            record: record(
                settlementRecord.recordName,
                "ReviewSettlement",
                { cleanupState: field(cleanupState), evidencePurgedAt: field(Date.now()) },
                requiredChangeTag(settlementRecord),
            ),
        }] : []),
    ];
    if (operations.length > 0) {
        await client.modify(operations);
    }
}

async function loadSubmission(client: CloudKitClient, submissionID: string): Promise<StoredSubmission | undefined> {
    const recordValue = await getRecord(client, submissionRecordName(submissionID));
    return recordValue ? storedSubmission(recordValue) : undefined;
}

async function loadSeat(client: CloudKitClient, submissionID: string, requestedSeatID: string): Promise<CloudKitRecord | undefined> {
    const seats = await client.query(
        "ReviewSeat",
        [
            { fieldName: "submissionID", comparator: "EQUALS", value: submissionID },
            { fieldName: "seatID", comparator: "EQUALS", value: requestedSeatID },
        ],
        { desiredKeys: seatDesiredKeys(), resultsLimit: 1 },
    );
    return seats[0];
}

async function loadSettlement(client: CloudKitClient, submissionID: string): Promise<StoredSettlement | undefined> {
    const recordValue = await getRecord(client, settlementRecordName(submissionID));
    return recordValue ? storedSettlement(recordValue) : undefined;
}

async function getRecord(client: CloudKitClient, recordName: string, desiredKeys: string[] = []): Promise<CloudKitRecord | undefined> {
    const records = await client.lookup([recordName], desiredKeys);
    return records[0];
}

async function getOrCreateStanding(client: CloudKitClient, subjectHash: string): Promise<ReviewerStandingState> {
    const recordName = standingRecordName(subjectHash);
    const existing = await getRecord(client, recordName);
    if (existing) {
        return standingFromRecord(existing);
    }
    const freshRecord = record(recordName, "ReviewerStanding", {
        subjectHash: field(subjectHash),
        reviewCredits: field(3),
        calibrationCompleted: field(0),
        calibrationCorrect: field(0),
        calibrationStatus: field("notStarted"),
        communityPassAwardsJSON: field("[]"),
        blockedOwnerSubjectHashesJSON: field("[]"),
    });
    try {
        const created = await client.modify([{ operationType: "create", record: freshRecord }]);
        return standingFromRecord(created[0] ?? freshRecord);
    } catch (error) {
        const raced = await getRecord(client, recordName);
        if (raced) {
            return standingFromRecord(raced);
        }
        throw error;
    }
}

async function appendAward(
    client: CloudKitClient,
    standing: ReviewerStandingState,
    award: CommunityPassAward,
): Promise<ReviewerStandingState> {
    const existing = standing.communityPassAwards.find((candidate) => candidate.id === award.id);
    if (existing) {
        return standing;
    }
    const updated = {
        ...standing,
        communityPassAwards: [...standing.communityPassAwards.slice(-99), award],
    };
    const records = await client.modify([{
        operationType: "update",
        record: record(
            standing.record.recordName,
            "ReviewerStanding",
            standingFields(updated),
            requiredChangeTag(standing.record),
        ),
    }]);
    return standingFromRecord(records[0] ?? updated.record);
}

async function markAwardGranted(
    client: CloudKitClient,
    standing: ReviewerStandingState,
    awardID: string,
): Promise<ReviewerStandingState> {
    const awards = standing.communityPassAwards.map((award) => award.id === awardID
        ? { ...award, deliveryState: "granted" as const }
        : award);
    const updated = { ...standing, communityPassAwards: awards };
    const records = await client.modify([{
        operationType: "update",
        record: record(
            standing.record.recordName,
            "ReviewerStanding",
            standingFields(updated),
            requiredChangeTag(standing.record),
        ),
    }]);
    return standingFromRecord(records[0] ?? updated.record);
}

function standingFromRecord(recordValue: CloudKitRecord): ReviewerStandingState {
    const status = stringValue(recordValue, "calibrationStatus");
    const calibrationStatus: CalibrationStatus = status === "calibrating" || status === "qualified" || status === "recalibrationRequired"
        ? status
        : "notStarted";
    return {
        record: recordValue,
        reviewCredits: Math.max(0, numberValue(recordValue, "reviewCredits") ?? 3),
        calibrationCompleted: Math.max(0, numberValue(recordValue, "calibrationCompleted") ?? 0),
        calibrationCorrect: Math.max(0, numberValue(recordValue, "calibrationCorrect") ?? 0),
        calibrationStatus,
        communityPassAwards: parseAwards(stringValue(recordValue, "communityPassAwardsJSON")),
        blockedOwnerSubjectHashes: parseBlockedOwnerHashes(stringValue(recordValue, "blockedOwnerSubjectHashesJSON")),
    };
}

function standingFields(standing: ReviewerStandingState): Record<string, CloudKitField> {
    return {
        reviewCredits: field(standing.reviewCredits),
        calibrationCompleted: field(standing.calibrationCompleted),
        calibrationCorrect: field(standing.calibrationCorrect),
        calibrationStatus: field(standing.calibrationStatus),
        communityPassAwardsJSON: field(JSON.stringify(standing.communityPassAwards)),
        blockedOwnerSubjectHashesJSON: field(JSON.stringify(standing.blockedOwnerSubjectHashes)),
    };
}

function storedSubmission(recordValue: CloudKitRecord): StoredSubmission {
    const submissionID = requiredString(recordValue, "submissionID");
    const ownerSubjectHash = requiredString(recordValue, "ownerSubjectHash");
    const criteria = parseStringArray(requiredString(recordValue, "criteriaJSON"), 3) as [string, string, string];
    return {
        record: recordValue,
        submissionID,
        ownerSubjectHash,
        state: requiredString(recordValue, "state"),
        submittedAt: numberValue(recordValue, "submittedAt") ?? 0,
        contractTitle: requiredString(recordValue, "contractTitle"),
        baselineSummary: requiredString(recordValue, "baselineSummary"),
        criteria,
        explanation: stringValue(recordValue, "explanation") ?? "",
        baseline: parseStoredMedia(requiredString(recordValue, "baselineManifestJSON")),
        checkpoint: parseStoredMedia(requiredString(recordValue, "checkpointManifestJSON")),
        reportCount: numberValue(recordValue, "reportCount") ?? 0,
    };
}

function storedSettlement(recordValue: CloudKitRecord): StoredSettlement {
    const outcome = requiredString(recordValue, "outcome");
    if (outcome !== "passed" && outcome !== "practiceAgain") {
        throw new CloudKitError("A settlement has an invalid outcome.");
    }
    return {
        ownerSubjectHash: requiredString(recordValue, "ownerSubjectHash"),
        outcome,
        failedCriteriaIndexes: parseNumberArray(stringValue(recordValue, "failedCriteriaIndexesJSON") ?? "[]"),
        reviewedAt: numberValue(recordValue, "reviewedAt") ?? 0,
        cleanupAt: numberValue(recordValue, "cleanupAt") ?? 0,
        cleanupState: stringValue(recordValue, "cleanupState") ?? "pending",
    };
}

function submissionFields(
    manifest: SubmissionManifest,
    subjectHash: string,
    uploadedAssets: Record<string, UploadedAssetValue>,
    now: number,
): Record<string, CloudKitField> {
    const baseline = manifest.baseline.map((media, index) => ({ ...media, fieldName: mediaAssetField("baseline", index) }));
    const checkpoint = manifest.checkpoint.map((media, index) => ({ ...media, fieldName: mediaAssetField("checkpoint", index) }));
    const fields: Record<string, CloudKitField> = {
        submissionID: field(manifest.submissionID),
        ownerSubjectHash: field(subjectHash),
        state: field("awaitingReview"),
        submittedAt: field(now),
        settledAt: field(0),
        contractTitle: field(manifest.contract.title),
        baselineSummary: field(manifest.contract.baselineSummary),
        criteriaJSON: field(JSON.stringify(manifest.contract.criteria)),
        explanation: field(manifest.explanation),
        baselineManifestJSON: field(JSON.stringify(baseline)),
        checkpointManifestJSON: field(JSON.stringify(checkpoint)),
        reportCount: field(0),
        cleanupAt: field(0),
    };
    for (const media of [...baseline, ...checkpoint]) {
        fields[media.fieldName] = field(uploadedAssets[media.fieldName]);
    }
    return fields;
}

function validateUploadedAssets(manifest: SubmissionManifest, uploadedAssets: Record<string, UploadedAssetValue>): void {
    const expectedMedia = allMedia(manifest);
    const expectedFields = new Set(expectedMedia.map((media) => media.fieldName));
    if (Object.keys(uploadedAssets).length !== expectedFields.size || Object.keys(uploadedAssets).some((fieldName) => !expectedFields.has(fieldName))) {
        throw new RequestValidationError("The uploaded evidence does not match the approved upload draft.");
    }
    for (const media of expectedMedia) {
        const uploaded = uploadedAssets[media.fieldName];
        if (!uploaded || uploaded.singleFile.size !== media.byteCount) {
            throw new RequestValidationError("An uploaded evidence file has an unexpected size.");
        }
    }
}

function canonicalManifest(manifest: SubmissionManifest): string {
    return JSON.stringify({
        submissionID: manifest.submissionID,
        birthDate: manifest.birthDate,
        contract: manifest.contract,
        explanation: manifest.explanation,
        baseline: manifest.baseline,
        checkpoint: manifest.checkpoint,
    });
}

async function signDraft(payload: SubmissionDraftPayload, environment: Env): Promise<string> {
    if (!environment.SUBMISSION_DRAFT_SECRET) {
        throw new HTTPError("The evidence upload service is not configured.", 503);
    }
    const encodedPayload = encodeJSON(payload);
    const signature = await hmacSHA256Base64URL(environment.SUBMISSION_DRAFT_SECRET, encodedPayload);
    return `${encodedPayload}.${signature}`;
}

async function verifyDraft(token: string, environment: Env): Promise<SubmissionDraftPayload> {
    if (!environment.SUBMISSION_DRAFT_SECRET) {
        throw new HTTPError("The evidence upload service is not configured.", 503);
    }
    const [encodedPayload, signature, ...unexpected] = token.split(".");
    if (!encodedPayload || !signature || unexpected.length > 0) {
        throw new HTTPError("The evidence upload draft is invalid.", 403);
    }
    const expectedSignature = await hmacSHA256Base64URL(environment.SUBMISSION_DRAFT_SECRET, encodedPayload);
    if (signature !== expectedSignature) {
        throw new HTTPError("The evidence upload draft signature is invalid.", 403);
    }
    try {
        const payload = JSON.parse(new TextDecoder().decode(fromBase64URL(encodedPayload))) as SubmissionDraftPayload;
        if (typeof payload.expiresAt !== "number" || payload.expiresAt <= Date.now()) {
            throw new HTTPError("The evidence upload draft expired. Request a fresh upload draft.", 403);
        }
        return payload;
    } catch (error) {
        if (error instanceof HTTPError) {
            throw error;
        }
        throw new HTTPError("The evidence upload draft is unreadable.", 403);
    }
}

function encodeJSON(value: unknown): string {
    const bytes = new TextEncoder().encode(JSON.stringify(value));
    let binary = "";
    for (const byte of bytes) {
        binary += String.fromCharCode(byte);
    }
    return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function settlementResponse(settlement: StoredSettlement): Record<string, unknown> {
    return {
        outcome: settlement.outcome,
        failedCriteriaIndexes: settlement.failedCriteriaIndexes,
        reviewedAt: new Date(settlement.reviewedAt).toISOString(),
        cleanupAt: new Date(settlement.cleanupAt).toISOString(),
    };
}

function standingResponse(standing: Pick<ReviewerStandingState, "reviewCredits" | "calibrationCompleted" | "calibrationCorrect" | "calibrationStatus">): Record<string, unknown> {
    return {
        reviewCredits: standing.reviewCredits,
        calibrationCompleted: standing.calibrationCompleted,
        calibrationCorrect: standing.calibrationCorrect,
        calibrationStatus: standing.calibrationStatus,
    };
}

function parseStoredMedia(rawValue: string): StoredMedia[] {
    try {
        const media = JSON.parse(rawValue) as unknown;
        if (!Array.isArray(media)) {
            throw new Error();
        }
        return media.map((raw) => {
            const item = asObject(raw);
            const kind = item.kind;
            if (kind !== "image" && kind !== "video") {
                throw new Error();
            }
            return {
                id: asString(item.id, "stored evidence id", 36),
                kind,
                mimeType: item.mimeType === "video/mp4" ? "video/mp4" : "image/jpeg",
                byteCount: asInteger(item.byteCount, "stored evidence byteCount"),
                durationSeconds: typeof item.durationSeconds === "number" ? item.durationSeconds : 0,
                label: typeof item.label === "string" ? item.label : "",
                fieldName: asString(item.fieldName, "stored evidence fieldName", 50),
            };
        });
    } catch {
        throw new CloudKitError("A public evidence manifest is unreadable.");
    }
}

function parseStringArray(value: string, expectedLength?: number): string[] {
    try {
        const parsed = JSON.parse(value) as unknown;
        if (!Array.isArray(parsed) || (expectedLength !== undefined && parsed.length !== expectedLength) || !parsed.every((item) => typeof item === "string")) {
            throw new Error();
        }
        return parsed;
    } catch {
        throw new CloudKitError("A stored list is unreadable.");
    }
}

function parseNumberArray(value: string): number[] {
    try {
        const parsed = JSON.parse(value) as unknown;
        return Array.isArray(parsed) ? parsed.filter((item): item is number => typeof item === "number" && Number.isInteger(item)) : [];
    } catch {
        return [];
    }
}

function parseAwards(value: string | undefined): CommunityPassAward[] {
    if (!value) {
        return [];
    }
    try {
        const parsed = JSON.parse(value) as unknown;
        if (!Array.isArray(parsed)) {
            return [];
        }
        return parsed.flatMap((raw) => {
            if (typeof raw !== "object" || raw === null) {
                return [];
            }
            const item = raw as Partial<CommunityPassAward>;
            if (
                typeof item.id !== "string"
                || typeof item.awardedAt !== "number"
                || typeof item.expiresAt !== "number"
                || typeof item.days !== "number"
                || (item.deliveryState !== "pending" && item.deliveryState !== "granted")
            ) {
                return [];
            }
            return [{
                id: item.id,
                awardedAt: item.awardedAt,
                expiresAt: item.expiresAt,
                days: item.days,
                deliveryState: item.deliveryState,
            }];
        });
    } catch {
        return [];
    }
}

function parseBlockedOwnerHashes(value: string | undefined): string[] {
    if (!value) {
        return [];
    }
    try {
        const parsed = JSON.parse(value) as unknown;
        if (!Array.isArray(parsed)) {
            return [];
        }
        return Array.from(new Set(parsed.filter((item): item is string => typeof item === "string" && item.length >= 20))).slice(-500);
    } catch {
        return [];
    }
}

function assertSubmissionOwner(submission: StoredSubmission, identity: VerifiedAppleIdentity): void {
    if (submission.ownerSubjectHash !== identity.subjectHash) {
        throw new HTTPError("This checkpoint belongs to another member.", 403);
    }
}

function assertAnonymousExchangeAge(birthDate: string): void {
    if (!isAdultBirthDate(birthDate)) {
        throw new HTTPError("Anonymous exchange is available only to members 18 and older.", 403);
    }
}

function configuredClient(environment: Env): CloudKitClient {
    const client = new CloudKitClient(environment);
    if (!client.isConfigured) {
        throw new HTTPError("The anonymous exchange is not configured for this build.", 503);
    }
    return client;
}

async function authenticatedIdentity(request: Request, environment: Env): Promise<VerifiedAppleIdentity> {
    return verifyAppleIdentity(request.headers.get("Authorization"), environment);
}

async function requestJSON(request: Request): Promise<unknown> {
    const declaredLength = Number(request.headers.get("Content-Length") ?? 0);
    if (Number.isFinite(declaredLength) && declaredLength > 256 * 1_024) {
        throw new HTTPError("Exchange metadata is too large.", 413);
    }
    try {
        return await request.json();
    } catch {
        throw new RequestValidationError("The request body must be JSON.");
    }
}

function response(value: unknown, status = 200): Response {
    return new Response(JSON.stringify(value), { status, headers: jsonHeaders });
}

function errorResponse(error: unknown): Response {
    if (error instanceof HTTPError) {
        return response({ message: error.message }, error.status);
    }
    if (error instanceof RequestValidationError || error instanceof AppleIdentityError) {
        return response({ message: error.message }, 400);
    }
    if (error instanceof CloudKitError) {
        return response({ message: error.message }, error.status);
    }
    if (error instanceof RevenueCatError) {
        return response({ message: error.message }, 503);
    }
    return response({ message: "The exchange could not complete that request." }, 500);
}

class HTTPError extends Error {
    constructor(message: string, readonly status: number) {
        super(message);
        this.name = "HTTPError";
    }
}

function requiredString(recordValue: CloudKitRecord, fieldName: string): string {
    const value = stringValue(recordValue, fieldName);
    if (!value) {
        throw new CloudKitError(`CloudKit record is missing ${fieldName}.`);
    }
    return value;
}

function requiredChangeTag(recordValue: CloudKitRecord): string {
    if (!recordValue.recordChangeTag) {
        throw new CloudKitError("CloudKit did not return a change tag for a mutable record.");
    }
    return recordValue.recordChangeTag;
}

function seatDesiredKeys(): string[] {
    return ["seatID", "submissionID", "ownerSubjectHash", "state", "reviewerSubjectHash", "claimUntil", "submittedAt"];
}

function seatID(submissionID: string, ordinal: number): string {
    // Deterministic v5-like IDs are unnecessary here because record names are the idempotency key.
    return deterministicSeatUUID(submissionID, ordinal);
}

function deterministicSeatUUID(submissionID: string, ordinal: number): string {
    const hex = submissionID.replaceAll("-", "");
    const suffix = ordinal.toString(16).padStart(2, "0");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-5${hex.slice(13, 16)}-8${hex.slice(17, 19)}${suffix.slice(0, 1)}-${hex.slice(20, 32)}`;
}

function seatIDFromRecord(recordValue: CloudKitRecord): string {
    return requiredString(recordValue, "seatID");
}

function submissionRecordName(submissionID: string): string {
    return `submission-${submissionID}`;
}

function seatRecordName(submissionID: string, ordinal: number): string {
    return `seat-${submissionID}-${ordinal}`;
}

function reviewRecordName(seatID: string): string {
    return `review-${seatID}`;
}

function settlementRecordName(submissionID: string): string {
    return `settlement-${submissionID}`;
}

function standingRecordName(subjectHash: string): string {
    return `standing-${subjectHash}`;
}

function optionalText(value: unknown, fieldName: string, maximumLength: number): string {
    if (value === null || value === undefined) {
        return "";
    }
    if (typeof value !== "string" || value.length > maximumLength) {
        throw new RequestValidationError(`${fieldName} must be text within the allowed limit.`);
    }
    return value.trim();
}

function sameDecisions(left: ReviewDecision[], right: ReviewDecision[]): boolean {
    return left.length === right.length && left.every((decision, index) => decision === right[index]);
}

function letFirst<T>(values: T[]): T | undefined {
    return values[0];
}
