import { sha256Base64, signCloudKitRequest } from "./crypto";

export interface CloudKitEnvironment {
    CLOUDKIT_CONTAINER: string;
    CLOUDKIT_ENVIRONMENT: string;
    CLOUDKIT_KEY_ID?: string;
    CLOUDKIT_PRIVATE_KEY_PKCS8_B64?: string;
}

export interface CloudKitRecord {
    recordName: string;
    recordType: string;
    recordChangeTag?: string;
    fields: Record<string, CloudKitField>;
}

export interface CloudKitField {
    value?: unknown;
    type?: string;
}

export interface CloudKitAssetUploadToken {
    recordName: string;
    fieldName: string;
    url: string;
}

export interface CloudKitQueryFilter {
    fieldName: string;
    comparator: "EQUALS" | "LESS_THAN" | "LESS_THAN_OR_EQUALS" | "GREATER_THAN" | "GREATER_THAN_OR_EQUALS";
    value: unknown;
}

export class CloudKitError extends Error {
    readonly status: number;
    readonly code?: string;

    constructor(message: string, status = 502, code?: string) {
        super(message);
        this.name = "CloudKitError";
        this.status = status;
        this.code = code;
    }
}

export class CloudKitClient {
    private readonly environment: CloudKitEnvironment;

    constructor(environment: CloudKitEnvironment) {
        this.environment = environment;
    }

    get isConfigured(): boolean {
        return Boolean(
            this.environment.CLOUDKIT_CONTAINER
            && this.environment.CLOUDKIT_ENVIRONMENT
            && this.environment.CLOUDKIT_KEY_ID
            && this.environment.CLOUDKIT_PRIVATE_KEY_PKCS8_B64,
        );
    }

    async lookup(recordNames: string[], desiredKeys: string[] = []): Promise<CloudKitRecord[]> {
        const response = await this.post("records/lookup", {
            records: recordNames.map((recordName) => ({ recordName })),
            desiredKeys,
        }, true);
        return recordsFrom(response);
    }

    async query(
        recordType: string,
        filters: CloudKitQueryFilter[] = [],
        options: { desiredKeys?: string[]; resultsLimit?: number; sortField?: string; ascending?: boolean } = {},
    ): Promise<CloudKitRecord[]> {
        const response = await this.post("records/query", {
            query: {
                recordType,
                filterBy: filters.map((filter) => ({
                    fieldName: filter.fieldName,
                    comparator: filter.comparator,
                    fieldValue: field(filter.value),
                })),
                sortBy: options.sortField ? [{ fieldName: options.sortField, ascending: options.ascending ?? true }] : undefined,
            },
            desiredKeys: options.desiredKeys ?? [],
            resultsLimit: Math.min(options.resultsLimit ?? 50, 200),
        });
        return recordsFrom(response);
    }

    async modify(operations: CloudKitOperation[]): Promise<CloudKitRecord[]> {
        const response = await this.post("records/modify", cloudKitModifyPayload(operations));
        return recordsFrom(response);
    }

    async requestAssetUpload(tokens: Array<{ recordName: string; recordType: string; fieldName: string }>): Promise<CloudKitAssetUploadToken[]> {
        const response = await this.post("assets/upload", { tokens });
        const rawTokens = Array.isArray(response.tokens) ? response.tokens : [];
        const parsed = rawTokens.map((token) => {
            if (!isObject(token) || typeof token.recordName !== "string" || typeof token.fieldName !== "string" || typeof token.url !== "string") {
                throw new CloudKitError("CloudKit returned an invalid asset upload token.");
            }
            return { recordName: token.recordName, fieldName: token.fieldName, url: token.url };
        });
        if (parsed.length !== tokens.length) {
            throw new CloudKitError("CloudKit did not create every requested asset upload token.");
        }
        return parsed;
    }

    private async post(
        operation: string,
        payload: Record<string, unknown>,
        allowUnknownItems = false,
    ): Promise<Record<string, unknown>> {
        if (!this.isConfigured) {
            throw new CloudKitError("The public exchange is not configured.", 503, "NOT_CONFIGURED");
        }
        const body = JSON.stringify(payload);
        const path = `/database/1/${this.environment.CLOUDKIT_CONTAINER}/${this.environment.CLOUDKIT_ENVIRONMENT}/public/${operation}`;
        const date = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
        const bodyHash = await sha256Base64(body);
        const signature = await signCloudKitRequest(
            this.environment.CLOUDKIT_PRIVATE_KEY_PKCS8_B64 as string,
            `${date}:${bodyHash}:${path}`,
        );
        const response = await fetch(`https://api.apple-cloudkit.com${path}`, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "X-Apple-CloudKit-Request-KeyID": this.environment.CLOUDKIT_KEY_ID as string,
                "X-Apple-CloudKit-Request-ISO8601Date": date,
                "X-Apple-CloudKit-Request-SignatureV1": signature,
            },
            body,
        });
        const raw = await response.text();
        let decoded: Record<string, unknown> = {};
        try {
            decoded = raw ? JSON.parse(raw) as Record<string, unknown> : {};
        } catch {
            throw new CloudKitError("CloudKit returned unreadable data.", response.status);
        }
        if (!response.ok) {
            throw cloudKitErrorFrom(decoded, response.status);
        }
        const recordFailure = recordFailureFrom(decoded);
        if (recordFailure && !(allowUnknownItems && recordFailure.code === "UNKNOWN_ITEM")) {
            throw recordFailure;
        }
        return decoded;
    }
}

export type CloudKitOperation =
    | { operationType: "create"; record: CloudKitRecord }
    | { operationType: "update"; record: CloudKitRecord }
    | { operationType: "delete"; record: Pick<CloudKitRecord, "recordName" | "recordChangeTag"> };

export function cloudKitModifyPayload(operations: CloudKitOperation[]): Record<string, unknown> {
    // CloudKit's public database only exposes the default zone, which rejects atomic batches.
    return { operations, atomic: false };
}

export function record(
    recordName: string,
    recordType: string,
    fields: Record<string, CloudKitField>,
    recordChangeTag?: string,
): CloudKitRecord {
    return { recordName, recordType, fields, ...(recordChangeTag ? { recordChangeTag } : {}) };
}

export function field(value: unknown, type?: string): CloudKitField {
    return type ? { value, type } : { value };
}

export function valueOf(recordValue: CloudKitRecord, fieldName: string): unknown {
    return recordValue.fields[fieldName]?.value;
}

export function stringValue(recordValue: CloudKitRecord, fieldName: string): string | undefined {
    const value = valueOf(recordValue, fieldName);
    return typeof value === "string" ? value : undefined;
}

export function numberValue(recordValue: CloudKitRecord, fieldName: string): number | undefined {
    const value = valueOf(recordValue, fieldName);
    return typeof value === "number" ? value : undefined;
}

export function booleanValue(recordValue: CloudKitRecord, fieldName: string): boolean | undefined {
    const value = valueOf(recordValue, fieldName);
    return typeof value === "boolean" ? value : undefined;
}

export function assetDownloadURL(recordValue: CloudKitRecord, fieldName: string): string | undefined {
    const value = valueOf(recordValue, fieldName);
    if (!isObject(value) || typeof value.downloadURL !== "string") {
        return undefined;
    }
    return value.downloadURL;
}

export function recordsFrom(payload: Record<string, unknown>): CloudKitRecord[] {
    const rawRecords = Array.isArray(payload.records) ? payload.records : [];
    return rawRecords.filter(isCloudKitRecord);
}

export function isConflict(error: unknown): boolean {
    return error instanceof CloudKitError && ["CONFLICT", "SERVER_REJECTED_REQUEST", "BATCH_REQUEST_FAILED"].includes(error.code ?? "");
}

function isCloudKitRecord(value: unknown): value is CloudKitRecord {
    return isObject(value)
        && typeof value.recordName === "string"
        && typeof value.recordType === "string"
        && isObject(value.fields);
}

function cloudKitErrorFrom(payload: Record<string, unknown>, status: number): CloudKitError {
    const code = typeof payload.serverErrorCode === "string" ? payload.serverErrorCode : undefined;
    const reason = typeof payload.reason === "string" ? payload.reason : "CloudKit rejected the request.";
    return new CloudKitError(reason, status, code);
}

function recordFailureFrom(payload: Record<string, unknown>): CloudKitError | undefined {
    const rawRecords = Array.isArray(payload.records) ? payload.records : [];
    for (const rawRecord of rawRecords) {
        if (!isObject(rawRecord) || typeof rawRecord.serverErrorCode !== "string") {
            continue;
        }
        return new CloudKitError(
            typeof rawRecord.reason === "string" ? rawRecord.reason : "CloudKit rejected a record operation.",
            409,
            rawRecord.serverErrorCode,
        );
    }
    return undefined;
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
