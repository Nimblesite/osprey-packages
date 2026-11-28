-- Implements [PACKAGE-OWNERSHIP-RLS]: restricted runtime logins, one per mounted
-- libpq service (src/manager/ops/terraform/secrets.tf). Idempotent; run after the
-- DataProvider migration. Passwords come from the environment through \getenv, never
-- argv. Grants mirror src/manager/api/tests/live, which proves them.
\set ON_ERROR_STOP on
\getenv catalog_password REGISTRY_CATALOG_READER_PASSWORD
\getenv login_password REGISTRY_LOGIN_RUNTIME_PASSWORD
\getenv issuer_password REGISTRY_SESSION_ISSUER_PASSWORD
\getenv runtime_password REGISTRY_SESSION_RUNTIME_PASSWORD
\getenv revoker_password REGISTRY_SESSION_REVOKER_PASSWORD

BEGIN;
SELECT format('CREATE ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT', name)
FROM unnest(ARRAY['registry_catalog_reader', 'registry_login_runtime', 'registry_session_issuer',
                  'registry_session_runtime', 'registry_session_revoker']) AS name
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = name) \gexec

ALTER ROLE registry_catalog_reader PASSWORD :'catalog_password';
ALTER ROLE registry_login_runtime PASSWORD :'login_password';
ALTER ROLE registry_session_issuer PASSWORD :'issuer_password';
ALTER ROLE registry_session_runtime PASSWORD :'runtime_password';
ALTER ROLE registry_session_revoker PASSWORD :'revoker_password';

-- Supabase's API roles never see the private schema [PACKAGE-OWNERSHIP-RLS].
REVOKE ALL ON SCHEMA registry FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA registry FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA registry TO registry_catalog_reader, registry_login_runtime, registry_session_issuer,
  registry_session_runtime, registry_session_revoker;

GRANT SELECT ON registry.public_catalog TO registry_catalog_reader;

GRANT INSERT(state_digest, browser_digest, verifier_envelope, created_at),
      SELECT(state_digest, browser_digest, verifier_envelope, created_at), DELETE
  ON registry.pending_logins TO registry_login_runtime;

GRANT SELECT(id, principal_id, issuer, provider, provider_subject, auth_subject, state)
  ON registry.auth_bindings TO registry_session_issuer, registry_session_runtime;
GRANT SELECT(id, kind, state, credential_epoch)
  ON registry.principals TO registry_session_issuer, registry_session_runtime;
GRANT INSERT(id, cookie_digest, binding_id, principal_id, credential_epoch, token_envelope, started_at, last_used_at), SELECT(id)
  ON registry.browser_sessions TO registry_session_issuer;
GRANT SELECT(id, cookie_digest, binding_id, principal_id, credential_epoch, token_envelope, started_at, last_used_at,
             revoked_at, refresh_id, refresh_started_at),
      UPDATE(last_used_at, token_envelope, refresh_id, refresh_started_at)
  ON registry.browser_sessions TO registry_session_runtime;

GRANT SELECT(id, principal_id) ON registry.auth_bindings TO registry_session_revoker;
GRANT SELECT(id, credential_epoch) ON registry.principals TO registry_session_revoker;
GRANT SELECT(id, cookie_digest, last_used_at, revoked_at), UPDATE(revoked_at, token_envelope)
  ON registry.browser_sessions TO registry_session_revoker;
COMMIT;
