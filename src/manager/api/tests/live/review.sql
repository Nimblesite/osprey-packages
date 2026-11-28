-- [PACKAGE-SECURITY-SCAN-APPROVAL] Run on the disposable migrated DB as its owner.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path = registry, pg_catalog;
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
-- The public identity survives broad DML grants and future governance endpoints.
DO $$ BEGIN
  BEGIN
    UPDATE organizations SET handle='renamed';
    RAISE EXCEPTION 'organization rename succeeded';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'organization identity is immutable' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE packages SET name='renamed';
    RAISE EXCEPTION 'package rename succeeded';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'package identity is immutable' THEN RAISE; END IF;
  END;
END $$;
INSERT INTO release_intents SELECT md5(n::text)::uuid,md5('pkg')::uuid,md5('alice')::uuid,42,repeat('a',40),1,n,now() FROM generate_series(1,3) n;
SET LOCAL SESSION AUTHORIZATION registry_publication_collector;
SELECT pg_temp.require_denied('SELECT registry.submit_frozen_version(md5(''1'')::uuid,md5(''pkg'')::uuid,1,1,''sha256:''||repeat(''1'',64),md5(''alice'')::uuid)');
RESET SESSION AUTHORIZATION;
INSERT INTO package_permissions VALUES (md5('grant')::uuid,md5('org')::uuid,md5('pkg')::uuid,md5('member')::uuid,
'publish-release','active',md5('member')::uuid,1,1,now(),NULL);
SET LOCAL SESSION AUTHORIZATION registry_publication_collector;
SELECT pg_temp.require_denied('SELECT registry.submit_frozen_version(md5(''1'')::uuid,md5(''pkg'')::uuid,2,1,''sha256:''||repeat(''1'',64),md5(''alice'')::uuid)');
SELECT registry.submit_frozen_version(md5(n::text)::uuid,md5('pkg')::uuid,1,n,'sha256:'||repeat(n::text,64),md5('alice')::uuid) FROM generate_series(1,3) n;
-- Retrying the exact frozen job after a lost response must enqueue it once.
SELECT registry.submit_frozen_version(md5('1')::uuid,md5('pkg')::uuid,1,1,'sha256:'||repeat('1',64),md5('alice')::uuid);
DO $$ BEGIN
  BEGIN
    PERFORM registry.submit_frozen_version(md5('1')::uuid,md5('pkg')::uuid,1,1,'sha256:'||repeat('9',64),md5('alice')::uuid);
    RAISE EXCEPTION 'retry silently changed the frozen source';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  BEGIN
    PERFORM registry.submit_frozen_version(md5('4')::uuid,md5('pkg')::uuid,1,1,'sha256:'||repeat('1',64),md5('alice')::uuid);
    RAISE EXCEPTION 'unrequested job acquired an immutable version';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
DO $$ BEGIN
  IF (SELECT count(*) FROM review_submissions) <> 1 OR NOT EXISTS (SELECT FROM review_submissions WHERE id=md5('1')::uuid)
    THEN RAISE EXCEPTION 'collector read outside its current admission scope'; END IF;
END $$;
RESET SESSION AUTHORIZATION;
UPDATE package_permissions SET state='revoked' WHERE id=md5('grant')::uuid;
SET LOCAL SESSION AUTHORIZATION registry_publication_collector;
SELECT pg_temp.require_denied('SELECT registry.submit_frozen_version(md5(''1'')::uuid,md5(''pkg'')::uuid,1,1,''sha256:''||repeat(''1'',64),md5(''alice'')::uuid)');
RESET SESSION AUTHORIZATION;
UPDATE package_permissions SET state='active' WHERE id=md5('grant')::uuid;
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
DO $$ BEGIN
  IF (SELECT count(*) FROM review_submissions j JOIN packages p ON p.id=j.package_id JOIN organizations o ON o.id=p.organization_id) <> 3

  THEN RAISE EXCEPTION 'worker job or identity boundary'; END IF;
END $$;
SELECT pg_temp.require_denied('SELECT principal_id FROM release_reviewers'), pg_temp.require_denied('SELECT principal_id FROM browser_sessions');
-- A previously failed low ordinal cannot monopolize an unkeyed worker.
SAVEPOINT queue_order;
RESET SESSION AUTHORIZATION;
INSERT INTO scan_claims VALUES
  (md5('1')::uuid,gen_random_uuid(),statement_timestamp()-interval '1 minute'),
  (md5('2')::uuid,gen_random_uuid(),statement_timestamp()-interval '2 minutes');
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
DO $$ BEGIN
  BEGIN
    UPDATE scan_claims SET expires_at=statement_timestamp()+interval '5 minutes' WHERE submission_id=md5('1')::uuid;
    RAISE EXCEPTION 'expired scan ticket was renewed without rotating it';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'scan retry must retain submission and rotate ticket' THEN RAISE; END IF;
  END;
  BEGIN
    UPDATE scan_claims SET submission_id=md5('3')::uuid,ticket=gen_random_uuid(),expires_at=statement_timestamp()+interval '5 minutes'
      WHERE submission_id=md5('1')::uuid;
    RAISE EXCEPTION 'scan ticket moved to another submission';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'scan retry must retain submission and rotate ticket' THEN RAISE; END IF;
  END;
  IF registry.claim_pending_scan(NULL)::jsonb->>'id' IS DISTINCT FROM md5('3')::uuid::text THEN
    RAISE EXCEPTION 'an expired lease was retried ahead of an unattempted version';
  END IF;
  IF registry.claim_pending_scan(NULL)::jsonb->>'id' IS DISTINCT FROM md5('2')::uuid::text THEN
    RAISE EXCEPTION 'the oldest expired lease was skipped';
  END IF;
END $$;
ROLLBACK TO queue_order;
RELEASE SAVEPOINT queue_order;
SELECT registry.claim_pending_scan(md5('1')::uuid)::jsonb->>'ticket' AS ticket_one \gset
SELECT registry.claim_pending_scan(md5('2')::uuid)::jsonb->>'ticket' AS ticket_two \gset
DO $$ BEGIN
  IF registry.claim_pending_scan(md5('1')::uuid) IS NOT NULL OR
     registry.record_scan(md5('1')::uuid,gen_random_uuid(),'11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765','accepted') IS NOT NULL
  THEN RAISE EXCEPTION 'duplicate scan claim or stale writer'; END IF;
END $$;
-- Even a valid live lease cannot attest under a revision the operator has not enabled.
SELECT pg_temp.require_denied(format('SELECT registry.record_scan(%L,%L,%L,%L)',md5('1')::uuid,:'ticket_one','unconfigured','accepted'));
SELECT pg_temp.require_denied(format('SELECT registry.record_scan(%L,%L,%L,%L)',md5('1')::uuid,:'ticket_one','11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765','accepted'));
RESET SESSION AUTHORIZATION;
SELECT registry.configure_scan_revision('11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765');
GRANT INSERT,UPDATE,DELETE ON scan_configuration TO registry_scan_worker;
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
SELECT pg_temp.require_denied($cmd$SELECT registry.configure_scan_revision(NULL)$cmd$);
SELECT pg_temp.require_denied('INSERT INTO scan_configuration VALUES (1,''11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765'')');
SELECT pg_temp.require_denied(format('SELECT registry.record_scan(%L,%L,%L,%L)',md5('1')::uuid,:'ticket_one',replace('11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765','11111111-','22222222-'),'accepted'));
SELECT registry.record_scan(md5('1')::uuid,:'ticket_one','11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765','accepted'), registry.record_scan(md5('2')::uuid,:'ticket_two','11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765','["blocked capability"]');
SAVEPOINT recorded_ticket;
RESET SESSION AUTHORIZATION;
DO $$ BEGIN
  BEGIN
    UPDATE registry.scan_claims SET ticket=gen_random_uuid() WHERE submission_id=md5('1')::uuid;
    RAISE EXCEPTION 'recorded scan lost its ticket';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END $$;
ROLLBACK TO recorded_ticket;
RELEASE SAVEPOINT recorded_ticket;
DO $$ BEGIN
  IF registry.frozen_scan_job(md5('1')::uuid)::jsonb ->> 'dir' IS DISTINCT FROM '@team/one/1.1'
    OR registry.completed_scan(md5('1')::uuid) IS DISTINCT FROM md5('1')::uuid
    OR registry.completed_scan(md5('3')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'incorrect durable scan status'; END IF;
END $$;
SELECT registry.claim_pending_scan(NULL)::jsonb->>'ticket' AS ticket_three \gset
SAVEPOINT disable_scan;
RESET SESSION AUTHORIZATION;
SELECT registry.configure_scan_revision(NULL);
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
SELECT pg_temp.require_denied(format('SELECT registry.record_scan(%L,%L,%L,%L)',md5('3')::uuid,:'ticket_three','11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765','accepted'));
ROLLBACK TO disable_scan;
RELEASE SAVEPOINT disable_scan;
SELECT pg_temp.require_denied(format('SELECT registry.record_scan(%L,%L,%L,%L)',md5('3')::uuid,:'ticket_three','11111111-1111-4111-8111-111111111111@sha256:de07230359089e8f569ead2e04c1018ddd55d2f7fafcddf4ae26517e63aa3765',invalid))
FROM unnest(ARRAY['[]','[" "]','[1]','[["nested"]]']) invalid;
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
SET LOCAL registry.session_issuer = 'issuer';
SELECT set_config('registry.session_subject',md5('subject')::uuid::text,true),
       set_config('registry.session_digest','sha256:'||repeat('c',64),true);
SET LOCAL registry.session_provider = '123';
DO $$ BEGIN
  IF registry.publication_receipt(md5('1')::uuid)::jsonb->>'packageId' IS DISTINCT FROM md5('pkg')::uuid::text
    OR registry.publication_receipt(md5('1')::uuid)::jsonb->>'canApprove' IS DISTINCT FROM 'false'
    OR registry.publication_receipt(md5('2')::uuid)::jsonb->'messages' IS DISTINCT FROM '["blocked capability"]'::jsonb
    OR registry.publication_receipt(md5('3')::uuid)::jsonb->>'status' IS DISTINCT FROM 'pending-scan'
    THEN RAISE EXCEPTION 'incorrect publisher receipt'; END IF;
END $$;
SAVEPOINT intent_authority;
SELECT registry.bind_repository(md5('pkg')::uuid,42,'main','');
RESET SESSION AUTHORIZATION;
UPDATE package_permissions SET state='revoked' WHERE id=md5('grant')::uuid;
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
SELECT pg_temp.require_denied('SELECT registry.request_release(md5(''pkg'')::uuid,repeat(''a'',40),1,4)');
RESET SESSION AUTHORIZATION;
UPDATE package_permissions SET state='active', membership_authority_epoch=2 WHERE id=md5('grant')::uuid;
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
SELECT pg_temp.require_denied('SELECT registry.request_release(md5(''pkg'')::uuid,repeat(''a'',40),1,4)');
RESET SESSION AUTHORIZATION;
UPDATE package_permissions SET membership_authority_epoch=1 WHERE id=md5('grant')::uuid;
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
DO $$ BEGIN
  IF registry.request_release(md5('pkg')::uuid,repeat('a',40),1,4) IS NULL THEN
    RAISE EXCEPTION 'valid publisher could not reserve the version after denied attempts';
  END IF;
END $$;
ROLLBACK TO intent_authority;
RELEASE SAVEPOINT intent_authority;
\ir review_isolation.sql
SET LOCAL registry.session_provider = 'revoked-identity';
DO $$ BEGIN
  IF registry.publication_receipt(md5('2')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'unauthorized receipt'; END IF;
END $$;
SET LOCAL registry.session_provider = '123';
DO $$ BEGIN
  BEGIN
    UPDATE browser_sessions SET started_at=started_at-interval '1 second';
    RAISE EXCEPTION 'immutable timestamp changed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'browser session identity and start time are immutable' THEN RAISE; END IF;
  END;
END $$;
SELECT pg_temp.require_denied('SELECT pg_temp.approve(1)');
SELECT pg_temp.require_denied('INSERT INTO release_reviewers VALUES (md5(''alice'')::uuid)');
SELECT pg_temp.require_denied($cmd$SELECT registry.release_reviewer_candidate('issuer','123')$cmd$);
SELECT pg_temp.require_denied($cmd$SELECT registry.appoint_release_reviewer(md5('alice')::uuid,'issuer','123')$cmd$);
RESET SESSION AUTHORIZATION;
DO $$ BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname LIKE 'registry\_%' AND rolname <> current_user AND rolcanlogin AND
      (has_function_privilege(oid, 'registry.release_reviewer_candidate(text,text)', 'execute') OR
       has_function_privilege(oid, 'registry.appoint_release_reviewer(uuid,text,text)', 'execute') OR
       has_function_privilege(oid, 'registry.remove_release_reviewer(uuid)', 'execute')))
    THEN RAISE EXCEPTION 'reviewer administration granted to runtime login'; END IF;
  IF registry.release_reviewer_candidate('issuer','123') IS DISTINCT FROM md5('alice')::uuid
     OR registry.release_reviewer_candidate('foreign','123') IS NOT NULL THEN
    RAISE EXCEPTION 'reviewer lookup returned incorrect binding';
  END IF;
  UPDATE registry.auth_bindings SET state='revoked' WHERE id=md5('binding')::uuid;
  IF registry.release_reviewer_candidate('issuer','123') IS NOT NULL
     OR registry.appoint_release_reviewer(md5('alice')::uuid,'issuer','123') IS NOT NULL
    THEN RAISE EXCEPTION 'revoked binding enrolled as reviewer'; END IF;
  UPDATE registry.auth_bindings SET state='active' WHERE id=md5('binding')::uuid;
  UPDATE registry.principals SET state='suspended' WHERE id=md5('alice')::uuid;
  IF registry.release_reviewer_candidate('issuer','123') IS NOT NULL
    THEN RAISE EXCEPTION 'suspended person offered as reviewer candidate'; END IF;
  IF registry.appoint_release_reviewer(md5('alice')::uuid,'issuer','123') IS NOT NULL
    THEN RAISE EXCEPTION 'suspended person enrolled as reviewer'; END IF;
  UPDATE registry.principals SET state='active' WHERE id=md5('alice')::uuid;
  IF registry.appoint_release_reviewer(md5('alice')::uuid,'issuer','456') IS NOT NULL
    OR registry.appoint_release_reviewer(md5('alice')::uuid,'foreign','123') IS NOT NULL
    OR registry.appoint_release_reviewer(md5('other')::uuid,'issuer','123') IS NOT NULL
    THEN RAISE EXCEPTION 'incorrect reviewer binding accepted'; END IF;
  IF registry.appoint_release_reviewer(md5('alice')::uuid,'issuer','123') IS DISTINCT FROM md5('alice')::uuid
    OR registry.appoint_release_reviewer(md5('alice')::uuid,'issuer','123') IS DISTINCT FROM md5('alice')::uuid
    THEN RAISE EXCEPTION 'reviewer enrollment or retry failed'; END IF;
END $$;
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
-- Permission and browser identity are rechecked at the table on every approval.
CREATE FUNCTION pg_temp.expect_closed_review() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF registry.approve_submission(md5('1')::uuid,'sha256:'||repeat('1',64)) IS NOT NULL
    THEN RAISE EXCEPTION 'approval succeeded after review authority lapsed'; END IF;
  PERFORM pg_temp.require_denied('SELECT pg_temp.approve(1)');
END $$;
SAVEPOINT live_reviewer;
RESET SESSION AUTHORIZATION;
SELECT registry.remove_release_reviewer(md5('alice')::uuid);
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
SELECT pg_temp.expect_closed_review();
ROLLBACK TO live_reviewer;
RESET SESSION AUTHORIZATION;
UPDATE browser_sessions SET revoked_at=statement_timestamp(),token_envelope=NULL WHERE id=md5('session')::uuid;
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
SELECT pg_temp.expect_closed_review();
ROLLBACK TO live_reviewer;
RELEASE SAVEPOINT live_reviewer;
DO $$ BEGIN
  IF registry.approve_submission(md5('1')::uuid,'sha256:'||repeat('9',64)) IS NOT NULL OR
     registry.approve_submission(md5('1')::uuid,'sha256:'||repeat('1',64)) IS DISTINCT FROM md5('1')::uuid OR
     registry.approve_submission(md5('2')::uuid,'sha256:'||repeat('2',64)) IS NOT NULL
  THEN RAISE EXCEPTION 'approval routine accepted the wrong receipt or refused the approved version'; END IF;
END $$;
DO $$ BEGIN
  IF registry.approve_submission(md5('1')::uuid,'sha256:'||repeat('1',64)) IS DISTINCT FROM md5('1')::uuid
    THEN RAISE EXCEPTION 'lost response retry failed'; END IF;
  IF (SELECT count(*) FROM review_submissions) <> 3 THEN RAISE EXCEPTION 'missing review candidates'; END IF;
END $$;
SELECT pg_temp.require_denied('SELECT pg_temp.approve(2)'), pg_temp.require_denied('SELECT pg_temp.approve(3)');
SELECT pg_temp.require_denied('INSERT INTO review_scans VALUES (md5(''3'')::uuid,gen_random_uuid(),''fake'',''accepted'',statement_timestamp())');
DELETE FROM release_approvals;
UPDATE review_submissions SET ordinal=99;
RESET SESSION AUTHORIZATION;
DO $$ BEGIN
  IF (SELECT count(*) FROM release_approvals) <> 1 OR EXISTS (SELECT FROM review_submissions WHERE ordinal=99)
  THEN RAISE EXCEPTION 'immutable decision or submission changed'; END IF;
END $$;
SAVEPOINT final_publish_authority;
UPDATE package_permissions SET state='revoked' WHERE id=md5('grant')::uuid;
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
SELECT pg_temp.require_denied('SELECT registry.publish_approved_release(md5(''1'')::uuid,''MIT'',''Test package'',''[]'',''[]'')');
DO $$ BEGIN
  IF registry.approved_release_job() IS NOT NULL THEN
    RAISE EXCEPTION 'withdrawn publication authority still occupied the publication queue';
  END IF;
END $$;
ROLLBACK TO final_publish_authority;
RELEASE SAVEPOINT final_publish_authority;
CREATE FUNCTION pg_temp.publish(n int, content text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO registry.releases(id,organization_id,package_id,epoch,ordinal,digest,publisher_principal_id,publisher_name,
    license_expression,summary,keywords,warnings,notices,state,published_at)
  VALUES(md5(n::text)::uuid,md5('org')::uuid,md5('pkg')::uuid,1,n,content,md5('alice')::uuid,'Alice',
    'MIT','Test package','[]','[]','[]','eligible',now())
$$;
DO $$ BEGIN
  BEGIN
    PERFORM pg_temp.publish(2,'sha256:'||repeat('2',64));
    RAISE EXCEPTION 'unsigned version entered releases';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  BEGIN
    PERFORM pg_temp.publish(1,'sha256:'||repeat('9',64));
    RAISE EXCEPTION 'substituted digest entered releases';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  PERFORM pg_temp.publish(1,'sha256:'||repeat('1',64));
END $$;
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
DO $$ BEGIN
  IF registry.publish_approved_release(md5('1')::uuid,'MIT','Test package','[]','[]') IS DISTINCT FROM md5('1')::uuid THEN
    RAISE EXCEPTION 'exact publication retry refused'; END IF;
  IF EXISTS (SELECT FROM (VALUES
    ('ISC','Test package','[]','[]'),('MIT','Changed','[]','[]'),
    ('MIT','Test package','["changed"]','[]'),('MIT','Test package','[]','["changed"]')
  ) AS altered(license,about,tags,notices)
    WHERE registry.publish_approved_release(md5('1')::uuid,license,about,tags,notices) IS NOT NULL)
    THEN RAISE EXCEPTION 'different discovery data acknowledged as exact publication retry'; END IF;
END $$;
SET LOCAL SESSION AUTHORIZATION registry_catalog_writer;
SELECT registry.refresh_public_catalog();
SELECT pg_temp.require_denied($denied$UPDATE registry.public_catalog SET body='{"packages":[]}',verified_at=statement_timestamp(),expires_at=statement_timestamp()+interval '1 hour'$denied$);
SET LOCAL SESSION AUTHORIZATION registry_catalog_reader;
DO $$ BEGIN
  IF jsonb_array_length((SELECT body::jsonb FROM registry.public_catalog)->'packages'->0->'releases') IS DISTINCT FROM 1
    THEN RAISE EXCEPTION 'public reader must see only the approved version'; END IF;
END $$;
RESET SESSION AUTHORIZATION;
INSERT INTO browser_sessions(id,cookie_digest,binding_id,principal_id,credential_epoch,token_envelope,started_at,last_used_at)
SELECT gen_random_uuid(),'sha256:'||repeat('d',64),binding_id,principal_id,credential_epoch,'second-envelope',now(),now()
FROM browser_sessions WHERE cookie_digest='sha256:'||repeat('c',64);
SET LOCAL SESSION AUTHORIZATION registry_session_revoker;
SELECT set_config('registry.session_digest','sha256:'||repeat('c',64),true);
DO $$ BEGIN
  IF registry.revoke_browser_session('sha256:'||repeat('d',64)) IS NOT NULL
    OR registry.revoke_browser_session('sha256:'||repeat('c',64)) IS DISTINCT FROM 1
    OR registry.revoke_browser_session('sha256:'||repeat('c',64)) IS NOT NULL
    THEN RAISE EXCEPTION 'logout cookie scope or retry failed'; END IF;
END $$;
SELECT pg_temp.require_denied('SELECT token_envelope FROM browser_sessions');
RESET SESSION AUTHORIZATION;
DO $$ BEGIN
  IF (SELECT count(*) FROM browser_sessions WHERE revoked_at IS NULL AND token_envelope='second-envelope') <> 1
    OR (SELECT count(*) FROM browser_sessions WHERE revoked_at IS NOT NULL AND token_envelope IS NULL) <> 1
    THEN RAISE EXCEPTION 'logout changed a different session'; END IF;
END $$;
GRANT SELECT ON browser_sessions TO registry_session_issuer, registry_session_revoker;
SET LOCAL SESSION AUTHORIZATION registry_session_issuer;
DO $$ BEGIN
  IF EXISTS (SELECT FROM browser_sessions) THEN RAISE EXCEPTION 'issuer RLS exposed a session'; END IF;
END $$;
SET LOCAL SESSION AUTHORIZATION registry_session_revoker;
DO $$ BEGIN
  IF EXISTS (SELECT FROM browser_sessions) THEN RAISE EXCEPTION 'revoker RLS exposed a session'; END IF;
END $$;
ROLLBACK;
