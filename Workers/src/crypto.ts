const encoder = new TextEncoder();

export function utf8(value: string): Uint8Array {
    return encoder.encode(value);
}

export function toBase64(bytes: ArrayBuffer | Uint8Array): string {
    const source = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    let binary = "";
    const chunkSize = 0x8000;
    for (let index = 0; index < source.length; index += chunkSize) {
        binary += String.fromCharCode(...source.subarray(index, index + chunkSize));
    }
    return btoa(binary);
}

export function fromBase64(value: string): Uint8Array {
    const binary = atob(value);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function toBase64URL(bytes: ArrayBuffer | Uint8Array): string {
    return toBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function fromBase64URL(value: string): Uint8Array {
    const padding = "=".repeat((4 - (value.length % 4)) % 4);
    return fromBase64(value.replaceAll("-", "+").replaceAll("_", "/") + padding);
}

export function asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
    const copy = new Uint8Array(bytes.byteLength);
    copy.set(bytes);
    return copy.buffer;
}

export async function sha256Base64(value: string): Promise<string> {
    return toBase64(await crypto.subtle.digest("SHA-256", asArrayBuffer(utf8(value))));
}

export async function sha256Base64URL(value: string): Promise<string> {
    return toBase64URL(await crypto.subtle.digest("SHA-256", asArrayBuffer(utf8(value))));
}

export async function hmacSHA256Base64URL(secret: string, value: string): Promise<string> {
    const key = await crypto.subtle.importKey(
        "raw",
        asArrayBuffer(utf8(secret)),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
    );
    return toBase64URL(await crypto.subtle.sign("HMAC", key, asArrayBuffer(utf8(value))));
}

export async function signCloudKitRequest(privateKeyBase64: string, message: string): Promise<string> {
    const key = await crypto.subtle.importKey(
        "pkcs8",
        asArrayBuffer(fromBase64(privateKeyBase64)),
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
    );
    const rawSignature = new Uint8Array(await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        asArrayBuffer(utf8(message)),
    ));
    return toBase64(ecdsaRawSignatureToDER(rawSignature));
}

// CloudKit expects an ASN.1 DER ECDSA sequence; Web Crypto returns P-1363 r||s.
export function ecdsaRawSignatureToDER(rawSignature: Uint8Array): Uint8Array {
    if (rawSignature.length !== 64) {
        throw new Error("Expected a P-256 ECDSA signature.");
    }
    const r = derInteger(rawSignature.subarray(0, 32));
    const s = derInteger(rawSignature.subarray(32, 64));
    const sequenceLength = r.length + s.length;
    return Uint8Array.from([0x30, ...derLength(sequenceLength), ...r, ...s]);
}

function derInteger(source: Uint8Array): Uint8Array {
    let firstNonZero = 0;
    while (firstNonZero < source.length - 1 && source[firstNonZero] === 0) {
        firstNonZero += 1;
    }
    const value = source.subarray(firstNonZero);
    const needsLeadingZero = (value[0] ?? 0) >= 0x80;
    const encoded = needsLeadingZero ? Uint8Array.from([0, ...value]) : value;
    return Uint8Array.from([0x02, ...derLength(encoded.length), ...encoded]);
}

function derLength(length: number): number[] {
    if (length < 0x80) {
        return [length];
    }
    const bytes: number[] = [];
    let remaining = length;
    while (remaining > 0) {
        bytes.unshift(remaining & 0xff);
        remaining >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
}
