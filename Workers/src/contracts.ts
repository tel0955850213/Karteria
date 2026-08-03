export const evidenceLimits = {
    maximumImages: 3,
    maximumVideoDurationSeconds: 20,
    maximumBundleBytes: 15 * 1_024 * 1_024,
    maximumExplanationCharacters: 1_000,
} as const;

export type ReviewDecision = "met" | "notMet" | "notShown";
export type EvidenceMediaKind = "image" | "video";

export interface MediaDescriptor {
    id: string;
    kind: EvidenceMediaKind;
    mimeType: "image/jpeg" | "video/mp4";
    byteCount: number;
    durationSeconds: number;
    label: string;
}

export interface EvidenceContractPayload {
    title: string;
    baselineSummary: string;
    criteria: [string, string, string];
}

export interface SubmissionManifest {
    submissionID: string;
    birthDate: string;
    contract: EvidenceContractPayload;
    explanation: string;
    baseline: MediaDescriptor[];
    checkpoint: MediaDescriptor[];
}

export interface UploadedAssetValue {
    singleFile: {
        fileChecksum: string;
        size: number;
        receipt: string;
        referenceChecksum?: string;
        wrappingKey?: string;
    };
}

export interface SubmissionDraftPayload {
    submissionID: string;
    subjectHash: string;
    manifestDigest: string;
    expiresAt: number;
}

export class RequestValidationError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "RequestValidationError";
    }
}

export function asObject(value: unknown, message = "Expected an object."): Record<string, unknown> {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
        throw new RequestValidationError(message);
    }
    return value as Record<string, unknown>;
}

export function asString(value: unknown, field: string, maximumLength = 10_000): string {
    if (typeof value !== "string") {
        throw new RequestValidationError(`${field} must be text.`);
    }
    const trimmed = value.trim();
    if (!trimmed || trimmed.length > maximumLength) {
        throw new RequestValidationError(`${field} is missing or too long.`);
    }
    return trimmed;
}

export function asInteger(value: unknown, field: string): number {
    if (typeof value !== "number" || !Number.isInteger(value)) {
        throw new RequestValidationError(`${field} must be an integer.`);
    }
    return value;
}

export function asUUID(value: unknown, field: string): string {
    const uuid = asString(value, field, 36).toLowerCase();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid)) {
        throw new RequestValidationError(`${field} must be a UUID.`);
    }
    return uuid;
}

export function parseSubmissionManifest(value: unknown): SubmissionManifest {
    const object = asObject(value, "submission manifest must be an object.");
    const contractObject = asObject(object.contract, "contract must be an object.");
    const criteriaInput = contractObject.criteria;
    if (!Array.isArray(criteriaInput) || criteriaInput.length !== 3) {
        throw new RequestValidationError("A contract needs exactly three observable criteria.");
    }

    const manifest: SubmissionManifest = {
        submissionID: asUUID(object.submissionID, "submissionID"),
        birthDate: parseBirthDate(object.birthDate),
        contract: {
            title: asString(contractObject.title, "contract title", 160),
            baselineSummary: asString(contractObject.baselineSummary, "baseline summary", 500),
            criteria: criteriaInput.map((criterion, index) => asString(criterion, `criterion ${index + 1}`, 240)) as [string, string, string],
        },
        explanation: asOptionalString(object.explanation, "explanation", evidenceLimits.maximumExplanationCharacters),
        baseline: parseMediaGroup(object.baseline, "baseline"),
        checkpoint: parseMediaGroup(object.checkpoint, "checkpoint"),
    };

    validateMediaGroup(manifest.baseline, "Baseline");
    validateMediaGroup(manifest.checkpoint, "Checkpoint");
    return manifest;
}

export function parseReviewDecisions(value: unknown): [ReviewDecision, ReviewDecision, ReviewDecision] {
    if (!Array.isArray(value) || value.length !== 3) {
        throw new RequestValidationError("A review needs exactly three decisions.");
    }
    const decisions = value.map((decision) => {
        if (decision !== "met" && decision !== "notMet" && decision !== "notShown") {
            throw new RequestValidationError("A review contains an unknown decision.");
        }
        return decision;
    }) as [ReviewDecision, ReviewDecision, ReviewDecision];
    return decisions;
}

export function parseUploadedAssets(value: unknown): Record<string, UploadedAssetValue> {
    const object = asObject(value, "uploadedAssets must be an object.");
    return Object.fromEntries(Object.entries(object).map(([fieldName, rawValue]) => {
        const asset = asObject(rawValue, `asset ${fieldName} must be an object.`);
        const singleFile = asObject(asset.singleFile, `asset ${fieldName} is missing its upload receipt.`);
        const fileChecksum = asString(singleFile.fileChecksum, `asset ${fieldName} checksum`, 1_024);
        const receipt = asString(singleFile.receipt, `asset ${fieldName} receipt`, 8_192);
        const size = asInteger(singleFile.size, `asset ${fieldName} size`);
        if (size <= 0) {
            throw new RequestValidationError(`asset ${fieldName} has an invalid size.`);
        }
        const normalized: UploadedAssetValue = {
            singleFile: {
                fileChecksum,
                receipt,
                size,
            },
        };
        if (typeof singleFile.referenceChecksum === "string") {
            normalized.singleFile.referenceChecksum = singleFile.referenceChecksum;
        }
        if (typeof singleFile.wrappingKey === "string") {
            normalized.singleFile.wrappingKey = singleFile.wrappingKey;
        }
        return [fieldName, normalized];
    }));
}

export function mediaAssetField(group: "baseline" | "checkpoint", index: number): string {
    return `${group}Asset${index + 1}`;
}

export function allMedia(manifest: SubmissionManifest): Array<MediaDescriptor & { fieldName: string }> {
    return [
        ...manifest.baseline.map((media, index) => ({ ...media, fieldName: mediaAssetField("baseline", index) })),
        ...manifest.checkpoint.map((media, index) => ({ ...media, fieldName: mediaAssetField("checkpoint", index) })),
    ];
}

export function isAdultBirthDate(birthDate: string, now = new Date()): boolean {
    const [year, month, day] = birthDate.split("-").map(Number);
    const currentYear = now.getUTCFullYear();
    const currentMonth = now.getUTCMonth() + 1;
    const currentDay = now.getUTCDate();
    return currentYear - year - (currentMonth < month || (currentMonth === month && currentDay < day) ? 1 : 0) >= 18;
}

function asOptionalString(value: unknown, field: string, maximumLength: number): string {
    if (value === undefined || value === null) {
        return "";
    }
    if (typeof value !== "string") {
        throw new RequestValidationError(`${field} must be text.`);
    }
    if (value.length > maximumLength) {
        throw new RequestValidationError(`${field} is too long.`);
    }
    return value.trim();
}

function parseBirthDate(value: unknown): string {
    const text = asString(value, "birthDate", 10);
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
    if (!match) {
        throw new RequestValidationError("birthDate must use YYYY-MM-DD.");
    }
    const year = Number(match[1]);
    const month = Number(match[2]);
    const day = Number(match[3]);
    const currentYear = new Date().getUTCFullYear();
    const candidate = new Date(Date.UTC(year, month - 1, day));
    if (
        year < currentYear - 120
        || year > currentYear
        || candidate.getUTCFullYear() !== year
        || candidate.getUTCMonth() !== month - 1
        || candidate.getUTCDate() !== day
    ) {
        throw new RequestValidationError("birthDate is outside the allowed range.");
    }
    return text;
}

function parseMediaGroup(value: unknown, groupName: string): MediaDescriptor[] {
    if (!Array.isArray(value) || value.length === 0) {
        throw new RequestValidationError(`${groupName} needs evidence.`);
    }
    return value.map((rawMedia, index) => {
        const media = asObject(rawMedia, `${groupName} media ${index + 1} must be an object.`);
        const kind = media.kind;
        if (kind !== "image" && kind !== "video") {
            throw new RequestValidationError(`${groupName} media ${index + 1} has an unknown kind.`);
        }
        const mimeType = media.mimeType;
        if (mimeType !== "image/jpeg" && mimeType !== "video/mp4") {
            throw new RequestValidationError(`${groupName} accepts JPEG images or MP4 videos only.`);
        }
        if ((kind === "image" && mimeType !== "image/jpeg") || (kind === "video" && mimeType !== "video/mp4")) {
            throw new RequestValidationError(`${groupName} media type does not match its format.`);
        }
        const byteCount = asInteger(media.byteCount, `${groupName} media ${index + 1} byteCount`);
        const durationSeconds = typeof media.durationSeconds === "number" ? media.durationSeconds : Number.NaN;
        if (!Number.isFinite(durationSeconds) || durationSeconds < 0) {
            throw new RequestValidationError(`${groupName} media ${index + 1} has an invalid duration.`);
        }
        return {
            id: asUUID(media.id, `${groupName} media ${index + 1} id`),
            kind,
            mimeType,
            byteCount,
            durationSeconds,
            label: asOptionalString(media.label, `${groupName} media ${index + 1} label`, 120),
        };
    });
}

function validateMediaGroup(media: MediaDescriptor[], groupName: string): void {
    const uniqueIDs = new Set(media.map((item) => item.id));
    if (uniqueIDs.size !== media.length) {
        throw new RequestValidationError(`${groupName} contains duplicate media.`);
    }
    const kinds = new Set(media.map((item) => item.kind));
    if (kinds.size !== 1) {
        throw new RequestValidationError(`${groupName} must use either images or one video.`);
    }
    if (media[0]?.kind === "image" && media.length > evidenceLimits.maximumImages) {
        throw new RequestValidationError(`${groupName} accepts at most three images.`);
    }
    if (media[0]?.kind === "video" && media.length !== 1) {
        throw new RequestValidationError(`${groupName} accepts one video.`);
    }
    if (media.some((item) => item.byteCount <= 0) || media.reduce((total, item) => total + item.byteCount, 0) > evidenceLimits.maximumBundleBytes) {
        throw new RequestValidationError(`${groupName} evidence must be 15 MB or smaller after compression.`);
    }
    if (media.some((item) => item.kind === "video" && item.durationSeconds > evidenceLimits.maximumVideoDurationSeconds)) {
        throw new RequestValidationError(`${groupName} video must be 20 seconds or shorter.`);
    }
}
