# Registry security findings

## Collector admitted a different version than the publisher requested

**High · [PACKAGE-HOSTED-PUBLISH-FLOW] · Feature branch.** On disposable PostgreSQL, a collector with a current publish grant successfully inserted an epoch-2 submission for an epoch-1 intent. The row policy checked the grant alone. This admitted the wrong version to the review queue. Public availability still requires subsequent gates.

The corrected insert policy matches intent ID, publisher, package, epoch and ordinal and rechecks the current grant. The queue now checks for a previously frozen job using the exact-job read policy, restoring the caller’s scope afterward. The database regression in `src/manager/api/tests/live/review.sql` checks a mismatched epoch, a missing intent, grant revocation and exact retries. Deployment verification remains open.

## Release intent admission and publisher authorization

**Open · [PACKAGE-HOSTED-PUBLISH-FLOW].** The reviewed intent insert policy verifies the session principal and visible repository binding. Its definition lacks an explicit current publish-grant check at reservation time. The collector checks that grant later, after the package/version uniqueness constraint has already reserved the coordinate. The request path also needs independent evidence of the publisher’s signature over this intent. Verify both boundaries in the database-backed publication journey before enabling public writes.

## Production observations

A TLS-verified anonymous GET returned 200 for the plural hostname’s homepage and catalog API, 401 for the session endpoint, and 404 for the website’s release page. The singular hostname failed DNS resolution from the test host. These observations establish availability and guest-session behavior only. No production publication or private package access was exercised.
