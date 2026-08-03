# Karteria: Practice with Proof

`Practice. Prove. Progress.`

Karteria is an English-first iPhone app for deliberate practice. Daily reps remain private; a checkpoint becomes verified only when two of three calibrated anonymous peers independently mark all three observable criteria as met.

## Product boundary

- `Exchange`: anonymous, evidence-first review. No feed, likes, follows, chat, rankings, or AI votes. Reviewers can report content or hide future proof from an opaque anonymous owner.
- `Practice`: private goals, scheduled reps, two-minute fallback, evidence contracts, and submission preflight.
- `Journey`: a private timeline of evidence, verified levels, and before/after progress.
- Members aged 13 to 17 use private practice plus invite-only CloudKit trusted review. It gives advisory feedback only and cannot unlock an anonymous Level, grant credits, or change a 2-of-3 settlement.
- AI is an optional on-device preflight on iOS 27. It can flag missing coverage; it never creates, changes, or substitutes a peer vote.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Karteria/` | Native SwiftUI iOS application, deployment target iOS 18. |
| `KarteriaTests/` | Domain rules for practice, reviews, credits, and Community Pro Pass. |
| `Workers/` | Cloudflare Worker source for the anonymous exchange. |
| `CloudKit/public-schema.json` | Version-controlled declarative public database schema. |
| `docs/` | Setup, privacy, release, and Shipaton submission guidance. |

## Local verification

```bash
# iOS app, using the existing iOS 27 QA Main simulator
xcodebuild -project Karteria.xcodeproj -scheme Karteria \
  -destination 'platform=iOS Simulator,id=6F2A33AA-0CC4-4CB2-8642-23A6F90CD524' test

# Worker source only; this does not log in to or deploy Cloudflare
cd Workers
npm run check
npm test
```

## Configuration state

The repository intentionally contains no Apple, CloudKit, Cloudflare, or RevenueCat secret. An empty `KARTERIA_WORKER_URL` means anonymous submission fails closed while private practice remains fully usable. Evidence owners can remove their public raw proof, trusted-share owners can revoke an invite, and full private-data deletion stops if remaining remote copies cannot be verified and removed. Read [CloudKit setup](docs/CLOUDKIT_SETUP.md), [Worker setup](docs/WORKER_SETUP.md), and [RevenueCat setup](docs/REVENUECAT_SETUP.md) before configuring a release build.

No cloud resource, billing account, payment method, Worker deployment, App Store Connect app, or RevenueCat project is created by this repository.
