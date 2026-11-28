# Registry security findings

## Collector admitted a different version than the publisher requested

**High · [PACKAGE-HOSTED-PUBLISH-FLOW] · Feature branch.** On disposable PostgreSQL, a collector with a current publish grant successfully inserted an epoch-2 submission for an epoch-1 intent. The row policy checked the grant alone. This admitted the wrong version to the review queue. Public availability still requires subsequent gates.

The corrected insert policy matches intent ID, publisher, package, epoch and ordinal and rechecks the current grant. The queue now checks for a previously frozen job using the exact-job read policy, restoring the caller’s scope afterward. The database regression in `src/manager/api/tests/live/review.sql` checks a mismatched epoch, a missing intent, grant revocation and exact retries. Deployment verification remains open.

## Release intent admission and publisher authorization

**High · Fixed on feature branch · [PACKAGE-HOSTED-PUBLISH-FLOW].** A disposable database accepted a new version reservation after the publisher’s grant had been revoked. Release intent insertion now shares the collector’s current-grant check. The database regression exercises revoked and stale-epoch grants and verifies that an authorized publisher can still reserve the same version afterward.

**Open · Publisher signature.** The request path still needs independent evidence of the publisher’s signature over the exact intent. Verify this boundary in the database-backed publication journey before enabling public writes.

## Revocation after approval did not stop publication

**High · [PACKAGE-HOSTED-PUBLISH-FLOW].** In disposable PostgreSQL, the scanner could make an approved version eligible after the publisher lost the package grant. The release table checked the digest, administrator approval, package and organization, but omitted current publisher authority. Both the release insert policy and queue selection now apply the same current-grant predicate as intent admission. Scanner reads of principals, memberships and grants are scoped to publishers of approved submissions.

The regression applies the simulated revocation before the publication statement and checks denial at insertion and omission from the queue. Concurrent revocation/finalization and authority changes between grant removal and reissuance still need separate evidence.

## Private source dispatch used the worker’s mounted configuration alone

**High · [PACKAGE-SECURITY-SCAN-VERDICT].** Receipt insertion checked the database operator’s selected NAP revision, but the worker had already opened the bundle and could send it to a different configuration selected by its mount. On the feature branch the worker now compares the mounted configuration ID and digest with the operator’s selection before it opens quarantine. A missing or mismatched selection stops processing. The worker still verifies the remote configuration and the database still checks the selection when recording a verdict. The regression exercises disabled and mismatched selections against disposable PostgreSQL. Production exposure has not been established.

## Published-source creation on filesystem mounts

**Open · [PACKAGE-HOSTED-PUBLISH-FLOW].** The proposed filesystem writer checks existing contents, then uses an ordinary write after any read failure. Those operations alone do not ensure atomic creation during concurrent writes. The Cloud Storage role restricts object overwrites separately. Verify create-only semantics on each supported backend before claiming that guarantee.

## Production observations

A TLS-verified anonymous GET returned 200 for the plural hostname’s homepage and catalog API, 401 for the session endpoint, and 404 for the website’s release page. The singular hostname failed DNS resolution from the test host. These observations establish availability and guest-session behavior only. No production publication or private package access was exercised.
