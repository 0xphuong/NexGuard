-- L7-A Phase 1 schema verification
-- Usage:
--   docker compose exec -T db psql -U postgres -d nexguard_dev \
--     < apps/fz_http/priv/repo/verify_l7a_schema.sql
--
-- Expected: every SELECT prints a single result row labeled with what
-- it asserts; every assertion ends with `PASS` or `FAIL`. The smoke
-- test (section 9) runs inside a transaction and is rolled back, so
-- it never leaves test data behind.

\echo
\echo '=== 1. Schema migrations applied (expect 6) ==='
SELECT
  CASE WHEN count(*) = 6 THEN 'PASS' ELSE 'FAIL' END AS result,
  count(*)                                          AS migrations_found
FROM schema_migrations
WHERE version BETWEEN 20260620000001 AND 20260620000006;

\echo
\echo '=== 2. New tables exist (expect 5) ==='
SELECT
  CASE WHEN count(*) = 5 THEN 'PASS' ELSE 'FAIL' END AS result,
  count(*) AS tables_found,
  string_agg(table_name, ', ' ORDER BY table_name) AS tables
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'access_groups',
    'user_group_memberships',
    'applications',
    'application_allowed_groups',
    'org_settings'
  );

\echo
\echo '=== 3. access_groups columns ==='
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'access_groups'
ORDER BY ordinal_position;

\echo
\echo '=== 4. user_group_memberships: composite PK ==='
SELECT
  CASE WHEN array_length(conkey, 1) = 2 THEN 'PASS' ELSE 'FAIL' END AS result,
  pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'user_group_memberships'::regclass
  AND contype = 'p';

\echo
\echo '=== 5. applications columns (expect 14) ==='
SELECT
  CASE WHEN count(*) = 14 THEN 'PASS' ELSE 'FAIL' END AS result,
  count(*) AS column_count
FROM information_schema.columns
WHERE table_name = 'applications';

\echo
\echo '=== 6. applications critical types: virtual_ip=inet, l7_rules=jsonb, key_pem=bytea ==='
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'applications'
  AND column_name IN ('virtual_ip', 'l7_rules', 'key_pem')
ORDER BY column_name;

\echo
\echo '=== 7. applications unique constraints ==='
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'applications'
ORDER BY indexname;

\echo
\echo '=== 8. users.access_scope added ==='
SELECT
  CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS result,
  column_default
FROM information_schema.columns
WHERE table_name = 'users' AND column_name = 'access_scope'
GROUP BY column_default;

\echo
\echo '=== 9. org_settings seed row + CHECK ==='
SELECT
  CASE WHEN count(*) = 1 AND bool_or(NOT l7_enabled) THEN 'PASS' ELSE 'FAIL' END AS result,
  count(*)               AS row_count,
  bool_or(l7_enabled)    AS any_enabled
FROM org_settings;

\echo
\echo '--- CHECK constraint: inserting id=2 must FAIL ---'
DO $$
BEGIN
  BEGIN
    INSERT INTO org_settings (id, l7_enabled, inserted_at, updated_at)
    VALUES (2, true, now(), now());
    RAISE NOTICE 'FAIL: insert id=2 succeeded';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS: CHECK constraint rejected id=2';
  END;
END $$;

\echo
\echo '=== 10. Smoke test: full M:N + cascade (in transaction, rolled back) ==='
BEGIN;

INSERT INTO access_groups (name, source) VALUES ('verify_engineering', 'manual');

INSERT INTO user_group_memberships (user_id, group_id, source)
SELECT u.id, ag.id, 'manual'
FROM users u, access_groups ag
WHERE ag.name = 'verify_engineering'
LIMIT 1;

INSERT INTO applications (name, hostname, virtual_ip, backend, cert_source, enabled)
VALUES ('Verify Wiki', 'verify-wiki.test.local', '10.99.255.5'::inet,
        'https://10.0.50.6:443', 'upload', false);

INSERT INTO application_allowed_groups (application_id, group_id)
SELECT a.id, ag.id
FROM applications a, access_groups ag
WHERE a.hostname = 'verify-wiki.test.local'
  AND ag.name = 'verify_engineering';

\echo '--- before group delete ---'
SELECT 'memberships' AS what, count(*) FROM user_group_memberships
WHERE group_id = (SELECT id FROM access_groups WHERE name = 'verify_engineering')
UNION ALL
SELECT 'allowed_groups', count(*) FROM application_allowed_groups
WHERE group_id = (SELECT id FROM access_groups WHERE name = 'verify_engineering');

DELETE FROM access_groups WHERE name = 'verify_engineering';

\echo '--- after group delete (expect both 0 via cascade) ---'
SELECT 'memberships post-cascade' AS what,
       count(*) AS remaining,
       CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM user_group_memberships
WHERE source = 'manual'
  AND group_id NOT IN (SELECT id FROM access_groups);

ROLLBACK;

\echo
\echo '=== 11. Uniqueness: duplicate hostname rejected ==='
BEGIN;
INSERT INTO applications (name, hostname, virtual_ip, backend, cert_source)
VALUES ('A', 'verify-same.example.com', '10.99.254.1'::inet, 'https://x', 'upload');

DO $$
BEGIN
  BEGIN
    INSERT INTO applications (name, hostname, virtual_ip, backend, cert_source)
    VALUES ('B', 'verify-same.example.com', '10.99.254.2'::inet, 'https://y', 'upload');
    RAISE NOTICE 'FAIL: duplicate hostname allowed';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS: duplicate hostname rejected';
  END;
END $$;
ROLLBACK;

\echo
\echo '=== 12. Uniqueness: duplicate virtual_ip rejected ==='
BEGIN;
INSERT INTO applications (name, hostname, virtual_ip, backend, cert_source)
VALUES ('C', 'verify-c.example.com', '10.99.253.1'::inet, 'https://x', 'upload');

DO $$
BEGIN
  BEGIN
    INSERT INTO applications (name, hostname, virtual_ip, backend, cert_source)
    VALUES ('D', 'verify-d.example.com', '10.99.253.1'::inet, 'https://y', 'upload');
    RAISE NOTICE 'FAIL: duplicate virtual_ip allowed';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS: duplicate virtual_ip rejected';
  END;
END $$;
ROLLBACK;

\echo
\echo '=== Verification complete ==='
