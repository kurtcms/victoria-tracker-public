-- READ ONLY: current post-migration catalog/privilege checks; no care rows inserted.
-- Run after all migrations, including on an existing populated installation.
with expected_tables(schema_name, relation_name) as (
  values ('public','families'),('public','family_members'),('public','children'),
    ('public','events'),('public','sleep_sessions'),('public','milestones'),
    ('public','care_proposals'),('public','care_revisions'),('public','care_receipts'),
    ('private','family_invites'),('private','event_budgets')
), app_tables as (
  select e.*,c.oid,c.relrowsecurity from expected_tables e
  join pg_namespace n on n.nspname=e.schema_name
  join pg_class c on c.relnamespace=n.oid and c.relname=e.relation_name and c.relkind in ('r','p')
), app_views as (
  select c.* from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='v'
    and c.relname in ('feeding_events','diaper_events','weight_measurements')
), app_rpcs as (
  select p.* from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='public' and p.proname in
    ('create_family','create_family_v2','create_family_invite','join_family',
     'consume_event_budget','record_event','save_child','save_child_with_pronoun','execute_care_command','execute_care_conversation'))
    or (n.nspname='private' and p.proname='is_family_member')
)
select 'all_tables_present_with_rls' as check_name,count(*)=11 and bool_and(relrowsecurity) as ok from app_tables
union all
select 'views_use_invoker_security',count(*)=3 and bool_and(reloptions @> array['security_invoker=true']) from app_views
union all
select 'authenticated_public_select_granted',count(*)=12 and bool_and(has_table_privilege('authenticated',oid,'SELECT'))
from (select oid from app_tables where schema_name='public' union all select oid from app_views) r
union all
select 'direct_client_mutation_denied',not exists(
  select 1 from (select oid from app_tables union all select oid from app_views) r
  where has_table_privilege('authenticated',oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
    or has_table_privilege('anon',oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))
union all
select 'anonymous_table_read_denied',not exists(
  select 1 from (select oid from app_tables union all select oid from app_views) r where has_table_privilege('anon',oid,'SELECT'))
union all
select 'private_table_read_denied',not exists(
  select 1 from app_tables where schema_name='private' and has_table_privilege('authenticated',oid,'SELECT'))
union all
select 'security_definers_have_empty_search_path',count(*)=11 and bool_and(prosecdef and proconfig @> array['search_path=""']) from app_rpcs
union all
select 'anonymous_rpc_execute_denied',not exists(select 1 from app_rpcs where has_function_privilege('anon',oid,'EXECUTE'))
union all
select 'authenticated_rpc_execute_granted',count(*)=11 and bool_and(has_function_privilege('authenticated',oid,'EXECUTE')) from app_rpcs
union all
select 'private_validators_not_client_callable',count(*)=5 and bool_and(
  not has_function_privilege('authenticated',p.oid,'EXECUTE') and not has_function_privilege('anon',p.oid,'EXECUTE'))
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='private' and p.proname in ('care_keys','care_time','care_label','care_local','care_present')
union all
select 'five_migrations_recorded',count(*)=5 from supabase_migrations.schema_migrations
where version in ('202611120001','202611130001','202611130002','202611140001','202611150001')
union all
select 'private_v14_rpc_secured',count(*)=1 and bool_and(p.prosecdef and p.proconfig @> array['search_path=""']
  and not has_function_privilege('authenticated',p.oid,'EXECUTE')
  and not has_function_privilege('anon',p.oid,'EXECUTE'))
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='private' and p.proname='execute_care_conversation_v14'
union all
select 'read_snapshot_invoker_secured',count(*)=1 and bool_and(not p.prosecdef and p.proconfig @> array['search_path=""']
  and has_function_privilege('authenticated',p.oid,'EXECUTE')
  and not has_function_privilege('anon',p.oid,'EXECUTE'))
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='read_care_snapshot'
union all
select 'voice_pronoun_schema_recorded',
  exists(select 1 from information_schema.columns where table_schema='public' and table_name='children'
    and column_name='voice_pronoun' and data_type='text' and is_nullable='YES')
  and exists(select 1 from supabase_migrations.schema_migrations where version='202611190001');
