-- [PACKAGE-SECURITY-SCAN-APPROVAL] Separate workload logins. Provision credentials
-- on activation. Neither worker can mint a human approval or change frozen data.
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT', name)
FROM unnest(ARRAY['registry_publication_collector','registry_scan_worker']) AS name
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = name) \gexec

GRANT USAGE ON SCHEMA registry TO registry_publication_collector, registry_scan_worker;
GRANT INSERT ON registry.review_submissions TO registry_publication_collector;
GRANT SELECT ON registry.review_submissions TO registry_scan_worker;
GRANT INSERT, SELECT ON registry.review_scans TO registry_scan_worker;
GRANT SELECT ON registry.release_reviewers TO registry_session_runtime;
GRANT SELECT(submission_id, verdict) ON registry.review_scans TO registry_session_runtime;
GRANT INSERT ON registry.release_approvals TO registry_session_runtime;
