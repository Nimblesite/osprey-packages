-- [PACKAGE-SECURITY-SCAN-APPROVAL] Two active organizations own a package named "one".
-- Run from review.sql with Alice's session active and the three reviewed fixtures present.
SAVEPOINT two_publishers;
RESET SESSION AUTHORIZATION;
INSERT INTO principals VALUES (md5('bob')::uuid,'human','active',1,now());
INSERT INTO auth_bindings VALUES (md5('bob-binding')::uuid,md5('bob')::uuid,'issuer','github','456',md5('bob-subject')::uuid,'active',now());
INSERT INTO browser_sessions (id,cookie_digest,binding_id,principal_id,credential_epoch,token_envelope,started_at,last_used_at)
VALUES (md5('bob-session')::uuid,'sha256:'||repeat('b',64),md5('bob-binding')::uuid,md5('bob')::uuid,1,'sealed',now(),now());
INSERT INTO organizations VALUES (md5('other')::uuid,'other','Other','active',1,now());
INSERT INTO memberships VALUES (md5('other-member')::uuid,md5('other')::uuid,md5('bob')::uuid,'member','human','active',1,now());
INSERT INTO packages VALUES (md5('other-pkg')::uuid,md5('other')::uuid,'one',md5('other-member')::uuid,'active','human',1,'active',now());
INSERT INTO package_permissions VALUES (md5('other-grant')::uuid,md5('other')::uuid,md5('other-pkg')::uuid,md5('other-member')::uuid,
  'publish-release','active',md5('other-member')::uuid,1,1,now(),NULL);

INSERT INTO release_intents VALUES (md5('other-job')::uuid,md5('other-pkg')::uuid,md5('bob')::uuid,43,repeat('b',40),1,1,now());
SET LOCAL SESSION AUTHORIZATION registry_publication_collector;
SELECT registry.submit_frozen_version(md5('other-job')::uuid,md5('other-pkg')::uuid,1,1,'sha256:'||repeat('1',64),md5('bob')::uuid);
SET LOCAL SESSION AUTHORIZATION registry_session_runtime;
DO $$ BEGIN
  IF registry.publication_receipt(md5('other-job')::uuid) IS NOT NULL THEN
    RAISE EXCEPTION 'Alice can see a foreign pending version with identical release coordinates and digest';
  END IF;
END $$;
SET LOCAL registry.session_provider = '456';
SELECT set_config('registry.session_subject',md5('bob-subject')::uuid::text,true),
       set_config('registry.session_digest','sha256:'||repeat('b',64),true);
DO $$ BEGIN
  IF registry.publication_receipt(md5('other-job')::uuid)::jsonb->>'status' IS DISTINCT FROM 'pending-scan'
     OR registry.review_session_principal() IS DISTINCT FROM md5('bob')::uuid THEN
    RAISE EXCEPTION 'second publisher must have a live session and see his pending version';
  END IF;
  IF (SELECT count(*) FROM review_submissions) <> 1 OR EXISTS (SELECT FROM review_scans)
     OR EXISTS (SELECT FROM generate_series(1,3) n WHERE registry.publication_receipt(md5(n::text)::uuid) IS NOT NULL)
     OR registry.approve_submission(md5('1')::uuid,'sha256:'||repeat('1',64)) IS NOT NULL THEN
    RAISE EXCEPTION 'foreign publisher can see or approve another organization''s version';
  END IF;
END $$;
ROLLBACK TO two_publishers;
RELEASE SAVEPOINT two_publishers;
