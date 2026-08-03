# Privacy and Safety

## Data boundary

| Data | Location | Retention |
| --- | --- | --- |
| Goals, daily reps, schedules, private evidence, Journey | SwiftData and the user's CloudKit private database when iCloud is available | Until the member deletes it. |
| Invite-only trusted review | Owner's shared private CloudKit custom zone | Until the owner revokes the invitation or deletes private data. It never enters the anonymous public database. |
| Anonymous review evidence | Public CloudKit via Worker-only access | Raw proof assets and seats are deleted 30 days after settlement. |
| Review decisions and settlement | Worker-restricted public CloudKit metadata | Retained only for review integrity, reward accounting, and moderation handling. |
| Sign in with Apple identity | Raw subject is transient in Worker; a salted hash is stored in CloudKit | No raw subject is persisted in public records. |

## Submission safeguards

- Each baseline and checkpoint allows up to three JPEG images or one MP4 video of at most 20 seconds; each group is capped at 15 MB after compression.
- Sensitive Content Analysis blocks detected sensitive media from anonymous review when available. OCR warns about visible email addresses, phone numbers, and URLs. The app provides a local redaction utility before public submission.
- Foundation Models preflight is available only when the on-device model is available. It checks observable evidence coverage and never casts, changes, or completes a review vote.
- Medical judgments, nudity, dangerous or illegal activity, sexual content, relationship disputes, and third-party private information remain private-only and must not enter anonymous review.

## Age and community access

- The date-of-birth gate uses the full date, not only a birth year.
- Ages 13 to 17 remain in private practice and invite-only trusted review; they cannot enter the anonymous public queue.
- Age 18+ requires iCloud availability and a current Sign in with Apple token before public exchange is available.

## User controls

- An evidence owner can remove any remaining anonymous raw copy and its open seats. The Worker verifies ownership using the current Sign in with Apple subject hash; settled outcome metadata is not rewritten.
- A reviewer can report content and block future anonymous evidence from the same opaque subject hash. The block changes future matching only and reveals no identity.
- A trusted-review owner can revoke the CloudKit share, which removes its root record and private shared copy.
- `Delete private practice data` first removes every known remote evidence copy. If the same iCloud or Sign in with Apple identity cannot be verified, the app stops before deleting local data rather than falsely claiming complete removal.

Before App Review, set a real public support email in the release configuration and verify its response workflow. Moderators use the Worker-only removal endpoint to remove raw public proof immediately; never use a client-side moderation bypass.
