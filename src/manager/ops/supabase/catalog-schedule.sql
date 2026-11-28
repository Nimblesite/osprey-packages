-- Implements [PACKAGE-HOSTED-ROUTES-CATALOG]: refresh the public catalog every ten minutes, well inside
-- the one-hour lifetime catalog.sql attests, so a live catalog never lapses into 503. Idempotent:
-- cron.schedule replaces the named job. Supabase only; run after catalog.sql.
\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
SELECT cron.schedule('registry-public-catalog', '*/10 * * * *', 'SELECT registry.refresh_public_catalog()');
