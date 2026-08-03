# RevenueCat Setup

Karteria sells capability-planning tools, not votes. The `pro` entitlement must never unlock review credits, priority placement, a fourth vote, or a way to skip peer verification.

## Products

| Product | Price | Entitlement |
| --- | --- | --- |
| Monthly Pro | US$3.99 per month | `pro` |
| Annual Pro | US$24.99 per year with a 7-day trial | `pro` |
| Community Pro Pass | 7 days, server granted | `pro` |

## Security boundary

- The iOS app may contain only `REVENUECAT_PUBLIC_SDK_KEY` and uses `Purchases.configure` / `logIn` with the Sign in with Apple subject.
- `REVENUECAT_V2_SECRET_KEY` is a Worker secret only. It is never included in Xcode settings, source code, screenshots, CI logs, or the app bundle.
- The Worker calls RevenueCat's v2 grant-entitlement action after it has persisted an idempotent Community Pro Pass award. A failed delivery remains pending and retries with the same expiration instead of minting a second pass.

## Release verification

1. Verify the active RevenueCat project and iOS app before copying its public SDK key into the release-only configuration.
2. Create the `pro` entitlement and attach exactly the monthly and annual App Store products.
3. Confirm sandbox purchase, restore, and expiration behavior on an authorized physical device. Do not use an App Store archive from this beta macOS host.
4. Verify the Worker grants the same `pro` entitlement with a short expiry for a qualifying Community Pro Pass.
