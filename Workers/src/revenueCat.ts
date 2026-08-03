export interface RevenueCatEnvironment {
    REVENUECAT_V2_SECRET_KEY?: string;
    REVENUECAT_PROJECT_ID?: string;
    REVENUECAT_PRO_ENTITLEMENT_ID?: string;
}

export class RevenueCatError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "RevenueCatError";
    }
}

export function isRevenueCatConfigured(environment: RevenueCatEnvironment): boolean {
    return Boolean(
        environment.REVENUECAT_V2_SECRET_KEY
        && environment.REVENUECAT_PROJECT_ID
        && environment.REVENUECAT_PRO_ENTITLEMENT_ID,
    );
}

export async function grantCommunityProPass(
    environment: RevenueCatEnvironment,
    appUserID: string,
    expiresAt: Date,
): Promise<void> {
    if (!isRevenueCatConfigured(environment)) {
        throw new RevenueCatError("Community Pro Pass is not configured for this build.");
    }
    const url = `https://api.revenuecat.com/v2/projects/${encodeURIComponent(environment.REVENUECAT_PROJECT_ID as string)}/customers/${encodeURIComponent(appUserID)}/actions/grant_entitlement`;
    const response = await fetch(url, {
        method: "POST",
        headers: {
            Authorization: `Bearer ${environment.REVENUECAT_V2_SECRET_KEY as string}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            entitlement_id: environment.REVENUECAT_PRO_ENTITLEMENT_ID,
            expires_at: expiresAt.getTime(),
        }),
    });
    if (!response.ok) {
        throw new RevenueCatError("RevenueCat could not grant the Community Pro Pass. Try again later.");
    }
}
