# CloudKit Setup

This is a release prerequisite, not an action performed by the repository.

1. In the Apple Developer account, verify Team `9A686AFY6S`, bundle ID `com.donaldlin.karteria`, and container `iCloud.com.donaldlin.karteria` before changing any capability.
2. Enable CloudKit and Sign in with Apple only for that bundle ID. Keep the app's private SwiftData store in the private database; do not place private goals, practice reps, or private Journey assets in the public database.
3. In the CloudKit Dashboard Development environment, import and validate [the CloudKit schema](../CloudKit/Karteria.ckdb). [The JSON contract](../CloudKit/public-schema.json) documents field purpose and record naming. Create all listed query indexes before exercising Worker queries.
4. Keep World, Authenticated, and Creator permissions at no access for the six public review record types. Assign the schema's `Moderator` role only to the Apple developer who creates the server-to-server key. The Worker is the only public database reader and writer. Verify that an unauthenticated app cannot fetch `ReviewSubmission` or `PeerReview` records directly.
5. Create a P-256 server-to-server key only when ready to configure a Worker. Keep the private key outside git. Convert a private key to the Worker-required base64 PKCS#8 DER form locally, then enter it only with `wrangler secret put CLOUDKIT_PRIVATE_KEY_PKCS8_B64`. Confirm that the key creator has the `Moderator` role before testing Worker access.
6. Enable sharing for the private custom zone `KarteriaTrustedReviews` in Development. The app creates that zone on first use and stores invite-only `TrustedReviewSubmission` records there; the default private zone cannot host a CloudKit share. Confirm `CKSharingSupported` remains in the app Info.plist and test sharing with a second Apple account using the [CloudKit shared-records model](https://developer.apple.com/documentation/CloudKit/shared-records).
7. The imported schema also defines `TrustedReviewSubmission` without any public database grants. The app uses that type only in the custom private/shared zone for contract metadata, three baseline asset/kind pairs, three checkpoint asset/kind pairs, status, decisions, reviewer note, and review date.
8. Test with two or more separate Apple accounts in Development: owner cannot claim own proof, a fourth reviewer cannot claim a leased seat, expired seats reopen after ten minutes, settlement happens exactly once, a trusted invite reaches only its recipient, and removing its root record revokes the share.
9. Before a release, inspect the exact schema diff and then explicitly promote the reviewed Development schema to Production. This is consequential and must be confirmed at that time.

The Worker stores only a salted SHA-256 hash of Sign in with Apple `sub` in CloudKit. It uses raw `sub` transiently only to grant the matching RevenueCat entitlement.
