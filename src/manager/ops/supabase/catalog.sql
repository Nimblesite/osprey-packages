-- Implements [PACKAGE-HOSTED-ROUTES-CATALOG]: the public catalog's one writer. Idempotent; run after
-- the DataProvider migration and roles.sql. registry_catalog_writer is NOLOGIN and holds only
-- SELECT, INSERT and UPDATE on the catalog (an upsert reads the row it replaces);
-- registry.refresh_public_catalog() runs as it (SECURITY DEFINER, pinned search_path), PUBLIC
-- cannot call it, and the catalog_writer_* row policies in schema.yaml admit it to row 1 alone. Each refresh attests a one-hour lifetime; catalog-schedule.sql repeats it every
-- ten minutes. The schema has no release table yet (publication is not built), so the true catalog
-- is the empty list; the publication pipeline replaces that literal with its verified aggregate.
-- src/manager/api/tests/live/src/catalog_writer.osp proves the grants and the decodable row.
\set ON_ERROR_STOP on

BEGIN;
SELECT 'CREATE ROLE registry_catalog_writer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOINHERIT'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'registry_catalog_writer') \gexec

GRANT USAGE ON SCHEMA registry TO registry_catalog_writer;
GRANT SELECT, INSERT, UPDATE ON registry.public_catalog TO registry_catalog_writer;

CREATE OR REPLACE FUNCTION registry.refresh_public_catalog() RETURNS void
  LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
    INSERT INTO registry.public_catalog AS catalog (id, verified_at, expires_at, body)
    VALUES (1, statement_timestamp(), statement_timestamp() + interval '1 hour', '{"packages":[]}')
    ON CONFLICT (id) DO UPDATE
      SET verified_at = excluded.verified_at, expires_at = excluded.expires_at, body = excluded.body
$$;
ALTER FUNCTION registry.refresh_public_catalog() OWNER TO registry_catalog_writer;
REVOKE ALL ON FUNCTION registry.refresh_public_catalog() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registry.refresh_public_catalog() TO CURRENT_USER;

SELECT registry.refresh_public_catalog();
COMMIT;
