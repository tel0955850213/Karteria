import { asArrayBuffer, fromBase64URL, sha256Base64URL, utf8 } from "./crypto";

export interface AppleIdentityEnvironment {
    APPLE_BUNDLE_ID: string;
    APPLE_JWKS_URL?: string;
    IDENTITY_HASH_SALT?: string;
}

export interface VerifiedAppleIdentity {
    subject: string;
    subjectHash: string;
}

interface AppleJWTHeader {
    alg: string;
    kid: string;
}

interface AppleJWTPayload {
    iss: string;
    aud: string | string[];
    sub: string;
    exp: number;
    iat?: number;
}

interface AppleJWKSet {
    keys: AppleJWK[];
}

interface AppleJWK extends JsonWebKey {
    kid?: string;
    kty?: string;
}

let cachedKeys: { expiresAt: number; keys: AppleJWK[] } | undefined;

export class AppleIdentityError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "AppleIdentityError";
    }
}

export async function verifyAppleIdentity(
    authorizationHeader: string | null,
    environment: AppleIdentityEnvironment,
): Promise<VerifiedAppleIdentity> {
    const token = bearerToken(authorizationHeader);
    const [encodedHeader, encodedPayload, encodedSignature, ...unexpected] = token.split(".");
    if (!encodedHeader || !encodedPayload || !encodedSignature || unexpected.length > 0) {
        throw new AppleIdentityError("The Sign in with Apple token is malformed.");
    }

    const header = parseJSON<AppleJWTHeader>(encodedHeader, "token header");
    const payload = parseJSON<AppleJWTPayload>(encodedPayload, "token payload");
    if (header.alg !== "RS256" || !header.kid) {
        throw new AppleIdentityError("The Sign in with Apple token uses an unsupported signing key.");
    }
    validateClaims(payload, environment.APPLE_BUNDLE_ID);

    const jwk = (await appleKeys(environment.APPLE_JWKS_URL)).find((candidate) => candidate.kid === header.kid && candidate.kty === "RSA");
    if (!jwk) {
        throw new AppleIdentityError("The Sign in with Apple signing key is not available.");
    }
    const publicKey = await crypto.subtle.importKey(
        "jwk",
        jwk,
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["verify"],
    );
    const verified = await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        publicKey,
        asArrayBuffer(fromBase64URL(encodedSignature)),
        asArrayBuffer(utf8(`${encodedHeader}.${encodedPayload}`)),
    );
    if (!verified) {
        throw new AppleIdentityError("The Sign in with Apple token signature is invalid.");
    }
    if (!environment.IDENTITY_HASH_SALT) {
        throw new AppleIdentityError("The exchange identity service is not configured.");
    }
    return {
        subject: payload.sub,
        subjectHash: await sha256Base64URL(`${environment.IDENTITY_HASH_SALT}:${payload.sub}`),
    };
}

function bearerToken(value: string | null): string {
    if (!value?.startsWith("Bearer ")) {
        throw new AppleIdentityError("Sign in with Apple is required for the exchange.");
    }
    const token = value.slice("Bearer ".length).trim();
    if (!token) {
        throw new AppleIdentityError("Sign in with Apple is required for the exchange.");
    }
    return token;
}

function parseJSON<T>(encoded: string, label: string): T {
    try {
        return JSON.parse(new TextDecoder().decode(fromBase64URL(encoded))) as T;
    } catch {
        throw new AppleIdentityError(`The Sign in with Apple ${label} is unreadable.`);
    }
}

function validateClaims(payload: AppleJWTPayload, bundleID: string): void {
    const now = Math.floor(Date.now() / 1_000);
    const audiences = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (payload.iss !== "https://appleid.apple.com" || !audiences.includes(bundleID)) {
        throw new AppleIdentityError("The Sign in with Apple token is for a different app.");
    }
    if (!payload.sub || typeof payload.sub !== "string" || payload.exp <= now) {
        throw new AppleIdentityError("Sign in with Apple has expired. Sign in again to continue.");
    }
    if (payload.iat && payload.iat > now + 5 * 60) {
        throw new AppleIdentityError("The Sign in with Apple token has an invalid issue time.");
    }
}

async function appleKeys(configuredURL?: string): Promise<AppleJWK[]> {
    const now = Date.now();
    if (cachedKeys && cachedKeys.expiresAt > now) {
        return cachedKeys.keys;
    }
    const response = await fetch(configuredURL ?? "https://appleid.apple.com/auth/keys", {
        headers: { Accept: "application/json" },
    });
    if (!response.ok) {
        throw new AppleIdentityError("Apple's identity keys are temporarily unavailable.");
    }
    const payload = await response.json() as AppleJWKSet;
    if (!Array.isArray(payload.keys)) {
        throw new AppleIdentityError("Apple returned an invalid identity key set.");
    }
    cachedKeys = { keys: payload.keys, expiresAt: now + 60 * 60 * 1_000 };
    return payload.keys;
}
