# CloudKit Public Schema

`public-schema.json` is the source-controlled schema contract used by `Workers/src/index.ts`. It is a reviewable declaration, not a CloudKit Console import file.

Before development data is created, reproduce the record types and indexes in the CloudKit Dashboard Development environment, then compare the dashboard export to this file. Do not promote the schema to Production until the Apple team, container, bundle ID, role policy, and schema diff have been reviewed at release time.

The public database must not grant normal app users read or write access to these record types. The Worker accesses it with a CloudKit server-to-server key; the native app uses only the Worker API for public exchange data.
