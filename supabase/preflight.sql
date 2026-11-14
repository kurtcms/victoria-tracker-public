-- READ ONLY. Run in the intended project's SQL editor before approving the migration.
-- Outputs checks and counts only; no credentials, tokens or personal user rows.
select 'postgres_15_or_later' as check_name,
  current_setting('server_version_num')::integer >= 150000 as ok
union all
select 'supabase_auth_objects', to_regprocedure('auth.uid()') is not null and to_regclass('auth.users') is not null
union all
select 'expected_auth_roles', exists(select 1 from pg_roles where rolname='anon')
  and exists(select 1 from pg_roles where rolname='authenticated')
union all
-- The management API's --read-only path intentionally uses
-- supabase_read_only_user. Inspect the intended migration role, not that reader.
select 'migration_role_can_create_in_public', has_schema_privilege('postgres', 'public', 'CREATE')
union all
select 'extensions_schema_present', to_regnamespace('extensions') is not null
union all
select 'pgcrypto_missing_or_in_extensions', not exists(
  select 1 from pg_extension e join pg_namespace n on n.oid=e.extnamespace
  where e.extname='pgcrypto' and n.nspname <> 'extensions')
union all
select 'app_table_and_view_names_free', not exists(
  select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relname in
    ('families','family_members','children','events','feeding_events','diaper_events','weight_measurements'))
union all
select 'app_type_names_free', to_regtype('public.event_type') is null
  and to_regtype('public.diaper_kind') is null and to_regtype('public.input_source') is null
union all
select 'app_function_names_free', not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in
    ('create_family','create_family_invite','join_family','consume_event_budget','record_event'))
union all
select 'private_namespace_unoccupied', not exists(
  select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private')
  and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private');
