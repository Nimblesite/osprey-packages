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
SET LOCAL SESSION AUTHORIZATION registry_publication_collector;
SELECT pg_temp.require_denied('SELECT registry.submit_frozen_version(md5(''1'')::uuid,md5(''pkg'')::uuid,1,1,''sha256:''||repeat(''1'',64),md5(''alice'')::uuid)');
RESET SESSION AUTHORIZATION;
INSERT INTO package_permissions VALUES (md5('grant')::uuid,md5('org')::uuid,md5('pkg')::uuid,md5('member')::uuid,
'publish-release','active',md5('member')::uuid,1,1,now(),NULL);
SET LOCAL SESSION AUTHORIZATION registry_publication_collector;
SELECT registry.submit_frozen_version(md5(n::text)::uuid,md5('pkg')::uuid,1,n,'sha256:'||repeat(n::text,64),md5('alice')::uuid) FROM generate_series(1,3) n;
SET LOCAL SESSION AUTHORIZATION registry_scan_worker;
DO $$ BEGIN
  IF (SELECT count(*) FROM review_submissions j JOIN packages p ON p.id=j.package_id JOIN organizations o ON o.id=p.organization_id) <> 3

  THEN RAISE EXCEPTION 'worker job or identity boundary'; END IF;
END $$;
SELECT pg_temp.require_denied('SELECT principal_id FROM release_reviewers'), pg_temp.require_denied('SELECT principal_id FROM browser_sessions');
SELECT registry.claim_pending_scan(md5('1')::uuid)::jsonb->>'ticket' AS ticket_one \gset
SELECT registry.claim_pending_scan(md5('2')::uuid)::jsonb->>'ticket' AS ticket_two \gset
DO $$ BEGIN
  IF registry.claim_pending_scan(md5('1')::uuid) IS NOT NULL OR
     registry.record_scan(md5('1')::uuid,gen_random_uuid(),'fixture-v1','accepted') IS NOT NULL
  THEN RAISE EXCEPTION 'duplicate scan claim or stale writer'; END IF;
END $$;
SELECT registry.record_scan(md5('1')::uuid,:'ticket_one','fixture-v1','accepted'), registry.record_scan(md5('2')::uuid,:'ticket_two','fixture-v1','["blocked capability"]');
DO $$ BEGIN
  IF registry.frozen_scan_job(md5('1')::uuid)::jsonb ->> 'dir' IS DISTINCT FROM '@team/one/1.1'
    OR registry.completed_scan(md5('1')::uuid) IS DISTINCT FROM md5('1')::uuid
    OR registry.completed_scan(md5('3')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'incorrect durable scan status'; END IF;
END $$;
SELECT registry.claim_pending_scan(NULL)::jsonb->>'ticket' AS ticket_three \gset
SELECT pg_temp.require_denied(format('SELECT registry.record_scan(%L,%L,%L,%L)',md5('3')::uuid,:'ticket_three','fixture-v1',invalid))
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
RESET SESSION AUTHORIZATION;
INSERT INTO release_reviewers VALUES (md5('alice')::uuid);
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
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
SET LOCAL SESSION AUTHORIZATION registry_catalog_writer;
SELECT registry.refresh_public_catalog();
SELECT pg_temp.require_denied($denied$UPDATE registry.public_catalog SET body='{"packages":[]}',verified_at=statement_timestamp(),expires_at=statement_timestamp()+interval '1 hour'$denied$);
SET LOCAL SESSION AUTHORIZATION registry_catalog_reader;
DO $$ BEGIN
  IF jsonb_array_length((SELECT body::jsonb FROM registry.public_catalog)->'packages'->0->'releases') IS DISTINCT FROM 1
    THEN RAISE EXCEPTION 'public reader must see only the approved version'; END IF;
END $$;
ROLLBACK;
