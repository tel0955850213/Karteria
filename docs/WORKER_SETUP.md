# Cloudflare Worker Setup

The Worker code lives in `Workers/`. It is designed for the Cloudflare Workers Free plan only: no billing account, payment method, paid binding, Durable Object, R2, KV, D1, or paid plan is required.

## Before deployment

1. Confirm the Cloudflare account remains on the Free plan with no billing method attached.
2. Configure the route to fail closed. The exchange is security-sensitive; it must not bypass token checks when the free daily request limit is exhausted.
3. Create secrets outside the repository. Do not put any secret in `wrangler.toml`, `.dev.vars.example`, an iOS plist, or a demo video.

Required secrets:

| Secret | Purpose |
| --- | --- |
| `IDENTITY_HASH_SALT` | Hashes Sign in with Apple subjects before CloudKit storage. |
| `SUBMISSION_DRAFT_SECRET` | HMAC-signs the 15-minute direct-upload draft. |
| `CLOUDKIT_KEY_ID` | CloudKit server-to-server key identifier. |
| `CLOUDKIT_PRIVATE_KEY_PKCS8_B64` | Base64 PKCS#8 DER P-256 private key. |
| `REVENUECAT_V2_SECRET_KEY` | Server-only RevenueCat v2 key for Community Pro Pass grants. |
| `REVENUECAT_PROJECT_ID` | RevenueCat project identifier. |
| `REVENUECAT_PRO_ENTITLEMENT_ID` | The single `pro` entitlement identifier. |
| `MODERATOR_API_KEY` | Separate server-only credential for evidence removal. |

## API behavior

- `POST /submissions/initiate`: verifies Apple JWT, validates exact birthday and proof bounds, then creates 15-minute CloudKit asset upload URLs.
- `POST /submissions/finalize`: creates one submission and exactly three deterministic seat records atomically. It debits three credits only when claimable work exists.
- `POST /calibrations/record`: requires five fixed cases with at least four correct answers before anonymous queue access.
- `POST /review-slots/claim`: uses CloudKit change tags to lease one seat for ten minutes. It never returns the submitter's identity and excludes self-review.
- `POST /reviews/settle`: accepts one review per seat, credits the reviewer once, and settles deterministically after three valid reviews.
- `POST /submissions/status`: lets only the owner read review progress and settlement.
- `POST /submissions/remove`: lets only the evidence owner remove raw public proof and open seats; a settled aggregate remains intact for integrity and reward accounting.
- `POST /rewards/redeem`: issues a 7-day `pro` entitlement after nine settled quality reviews, capped at 14 days in any rolling 30-day window.
- `POST /reports`: records one report per reporter and submission.
- `POST /blocks`: stores at most 500 opaque owner subject hashes on the reviewer's standing and excludes those owners from future claim matching. It never alters an existing review.
- `POST /moderation/submissions/remove`: deletes raw public evidence immediately when called with the moderator secret.

The scheduled Worker task purges `ReviewSubmission` assets and seats 30 days after settlement. It keeps only the aggregate settlement metadata needed for the owner's private Journey and reviewer reward accounting.

## Local checks

```bash
cd Workers
npm run check
npm test
npm run bundle:check
```

`bundle:check` creates a local dry-run bundle only. Do not run `wrangler deploy` until the Cloudflare account, free-plan status, route fail mode, configured secrets, and CloudKit Development schema have been verified.
