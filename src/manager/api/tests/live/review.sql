-- [PACKAGE-SECURITY-SCAN-APPROVAL] Run on the disposable migrated DB as its owner.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path = registry, pg_catalog;
CREATE ROLE registry_session_runtime LOGIN;
GRANT USAGE ON SCHEMA registry TO registry_session_runtime;
GRANT SELECT ON principals, auth_bindings, browser_sessions TO registry_session_runtime;
\ir ../../../ops/supabase/review-grants.sql
-- Deliberately excessive DML grants prove the row boundary independently.
GRANT INSERT, UPDATE, DELETE, SELECT ON review_submissions, review_scans, release_approvals, release_reviewers TO registry_session_runtime;
INSERT INTO principals VALUES (md5('alice')::uuid,'human','active',1,now());
INSERT INTO auth_bindings VALUES (md5('binding')::uuid,md5('alice')::uuid,'issuer','github','123',md5('subject')::uuid,'active',now());
INSERT INTO browser_sessions (id,cookie_digest,binding_id,principal_id,credential_epoch,token_envelope,started_at,last_used_at)
VALUES (md5('session')::uuid,'sha256:'||repeat('c',64),md5('binding')::uuid,md5('alice')::uuid,1,'sealed',now(),now());
INSERT INTO organizations VALUES (md5('org')::uuid,'team','Team','active',1,now());
INSERT INTO memberships VALUES (md5('member')::uuid,md5('org')::uuid,md5('alice')::uuid,'member','human','active',1,now());
INSERT INTO packages VALUES (md5('pkg')::uuid,md5('org')::uuid,'one',md5('member')::uuid,'active','human',1,'active',now());
CREATE FUNCTION pg_temp.approve(version int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO registry.release_approvals VALUES
  (md5(version::text)::uuid,md5('pkg')::uuid,1,version,'sha256:'||repeat(version::text,64),md5('alice')::uuid,statement_timestamp())
$$;
CREATE FUNCTION pg_temp.require_denied(command text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE command;
  RAISE EXCEPTION 'expected RLS denial for %', command;
EXCEPTION WHEN insufficient_privilege THEN NULL;
END $$;
SET LOCAL SESSION AUTHORIZATION registry_publication_collector;
INSERT INTO review_submissions SELECT md5(n::text)::uuid,md5('pkg')::uuid,1,n,'sha256:'||repeat(n::text,64),md5('alice')::uuid FROM generate_series(1,3) n;
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
INSERT INTO review_scans VALUES (md5('1')::uuid,'fixture-v1','accepted',statement_timestamp()),
(md5('2')::uuid,'fixture-v1','["blocked capability"]',statement_timestamp());
SELECT pg_temp.require_denied('INSERT INTO review_scans VALUES (md5(''3'')::uuid,''fixture-v1'',''[]'',statement_timestamp())');
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
SET LOCAL registry.session_issuer = 'issuer';
SELECT set_config('registry.session_subject',md5('subject')::uuid::text,true),
       set_config('registry.session_digest','sha256:'||repeat('c',64),true);
SET LOCAL registry.session_provider = '123';
SELECT pg_temp.require_denied('SELECT pg_temp.approve(1)');
SELECT pg_temp.require_denied('INSERT INTO release_reviewers VALUES (md5(''alice'')::uuid)');
RESET SESSION AUTHORIZATION;
INSERT INTO release_reviewers VALUES (md5('alice')::uuid);
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
SELECT pg_temp.approve(1);
SELECT pg_temp.require_denied('SELECT pg_temp.approve(2)'), pg_temp.require_denied('SELECT pg_temp.approve(3)');
SELECT pg_temp.require_denied('INSERT INTO review_scans VALUES (md5(''3'')::uuid,''fake'',''accepted'',statement_timestamp())');
DELETE FROM release_approvals;
UPDATE review_submissions SET ordinal=99;
RESET SESSION AUTHORIZATION;
DO $$ BEGIN
  IF (SELECT count(*) FROM release_approvals) <> 1 OR EXISTS (SELECT FROM review_submissions WHERE ordinal=99)
  THEN RAISE EXCEPTION 'immutable decision or submission changed'; END IF;
END $$;
ROLLBACK;
