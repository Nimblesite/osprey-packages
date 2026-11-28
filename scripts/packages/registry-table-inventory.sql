-- [PACKAGE-OWNERSHIP-RLS] Deployment verification reads catalog metadata only.
SELECT json_build_object(
  'name', c.relname,
  'forced', c.relrowsecurity AND c.relforcerowsecurity
)
FROM pg_catalog.pg_class AS c
JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'registry' AND c.relkind IN ('r', 'p')
ORDER BY c.relname;
