-- Assertions run in real PostgreSQL roles. Roll back all fixtures.
begin;
create function pg_temp.assert_true(ok boolean, label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'PASS: %', label;
end;
$$;
insert into auth.users(id, email) values
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a@example.invalid'),
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'b@example.invalid'),
 ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'c@example.invalid');
create temporary table context(key text primary key, value text);
grant select, insert on context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
insert into context values ('child', (public.create_family('America/Vancouver')).id::text);
insert into context values ('invite', public.create_family_invite());
select pg_temp.assert_true((select count(*) from public.children) = 1, 'owner reads own child');
select pg_temp.assert_true((select count(*) from public.family_members) = 1, 'owner reads membership');

select public.record_event((select value::uuid from context where key='child'), 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
 repeat('a',64), 'feeding', now(), 'siri', 160, null, null);
select public.record_event((select value::uuid from context where key='child'), 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
 repeat('a',64), 'feeding', now(), 'siri', 160, null, null);
select pg_temp.assert_true((select count(*) from public.events) = 1, 'retry creates exactly one event');
select pg_temp.assert_true((select recorded_by from public.events limit 1) = auth.uid(), 'recording parent is the authenticated user');
select pg_temp.assert_true((select count(*) from public.feeding_events) = 1, 'typed feeding view works');
select pg_temp.assert_true((select count(*) from public.weight_measurements) = 0, 'typed weight view filters correctly');
select pg_temp.assert_true(not exists(
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','private')
    and p.proname in ('create_family','create_family_invite','join_family','consume_event_budget','record_event','is_family_member')
    and has_function_privilege('anon',p.oid,'EXECUTE')
), 'anonymous has no app RPC execute privileges despite Supabase defaults');
select pg_temp.assert_true(not exists(
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname in ('families','family_members','children','events','feeding_events','diaper_events','weight_measurements')
    and has_table_privilege('authenticated',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
), 'authenticated has no direct mutation grants despite Supabase defaults');

do $$
declare child uuid := (select value::uuid from context where key='child');
begin
  begin
    perform public.record_event(child, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', repeat('b',64), 'feeding', now(), 'siri', 120, null, null);
    raise exception 'FAIL: idempotency conflict accepted';
  exception when unique_violation then raise notice 'PASS: conflicting retry rejected'; end;
  begin
    perform public.record_event(child, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', null, 'feeding', now(), 'siri', 160, null, null);
    raise exception 'FAIL: null hash bypassed retry comparison';
  exception when invalid_parameter_value then raise notice 'PASS: null replay hash rejected'; end;
  begin
    perform public.record_event(child, gen_random_uuid(), repeat('a',64), 'feeding', now(), 'manual', 160.001, null, null);
    raise exception 'FAIL: excess volume precision was silently rounded';
  exception when invalid_parameter_value then raise notice 'PASS: RPC rejects excess volume precision'; end;
  begin
    perform public.record_event(child, gen_random_uuid(), repeat('a',64), 'weight', now(), 'manual', null, null, 7.5555);
    raise exception 'FAIL: excess weight precision was silently rounded';
  exception when invalid_parameter_value then raise notice 'PASS: RPC rejects excess weight precision'; end;
  begin
    perform public.record_event(child, gen_random_uuid(), repeat('a',64), 'feeding', now(), 'manual', -1, null, null);
    raise exception 'FAIL: negative volume accepted';
  exception when check_violation then raise notice 'PASS: negative volume rejected by database'; end;
  begin
    perform public.record_event(child, gen_random_uuid(), repeat('a',64), 'feeding', now(), 'manual', null, null, null);
    raise exception 'FAIL: null volume accepted';
  exception when check_violation then raise notice 'PASS: null required value rejected'; end;
  begin
    perform public.record_event(child, gen_random_uuid(), repeat('a',64), 'weight', now(), 'manual', 120, null, 7.5);
    raise exception 'FAIL: mismatched payload accepted';
  exception when check_violation then raise notice 'PASS: mismatched event fields rejected'; end;
  begin
    perform public.record_event(child, gen_random_uuid(), repeat('a',64), 'weight', now() + interval '1 day', 'manual', null, null, 7.5);
    raise exception 'FAIL: future timestamp accepted';
  exception when invalid_parameter_value then raise notice 'PASS: future timestamp rejected'; end;
  begin
    insert into public.events(child_id, event_type, occurred_at, recorded_by, input_source, request_id, request_hash, volume_ml)
      values(child, 'feeding', now(), auth.uid(), 'manual', gen_random_uuid(), repeat('a',64), 100);
    raise exception 'FAIL: direct insertion allowed';
  exception when insufficient_privilege then raise notice 'PASS: direct insertion denied'; end;
  begin
    update public.family_members set role='owner';
    raise exception 'FAIL: direct membership mutation allowed';
  exception when insufficient_privilege then raise notice 'PASS: direct membership mutation denied'; end;
  begin
    delete from public.events;
    raise exception 'FAIL: direct event deletion allowed';
  exception when insufficient_privilege then raise notice 'PASS: direct event deletion denied'; end;
  begin
    perform count(*) from private.family_invites;
    raise exception 'FAIL: raw invite digests readable';
  exception when insufficient_privilege then raise notice 'PASS: private invite table denied'; end;
  begin
    perform count(*) from private.event_budgets;
    raise exception 'FAIL: raw budget table readable';
  exception when insufficient_privilege then raise notice 'PASS: private budget table denied'; end;
  begin
    execute 'create table private.unauthorized_table(id integer)';
    raise exception 'FAIL: authenticated can create private objects';
  exception when insufficient_privilege then raise notice 'PASS: private schema creation denied'; end;
end;
$$;

select set_config('request.jwt.claim.sub', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', true);
select pg_temp.assert_true((select count(*) from public.events) = 0, 'stranger cannot read events');
select pg_temp.assert_true((select count(*) from public.feeding_events) = 0, 'typed views preserve RLS');
select pg_temp.assert_true((select count(*) from public.children) = 0, 'stranger cannot read child');
select pg_temp.assert_true((select count(*) from public.family_members) = 0, 'stranger cannot read memberships');
select pg_temp.assert_true((select count(*) from public.families) = 0, 'stranger cannot read family');
do $$
begin
  begin
    perform public.record_event((select value::uuid from context where key='child'), gen_random_uuid(), repeat('c',64), 'feeding', now(), 'siri', 160, null, null);
    raise exception 'FAIL: stranger can record for another family';
  exception when insufficient_privilege then raise notice 'PASS: stranger write denied'; end;
  begin
    perform public.create_family_invite();
    raise exception 'FAIL: stranger can invite to another family';
  exception when insufficient_privilege then raise notice 'PASS: stranger invite denied'; end;
end;
$$;

select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', true);
select public.join_family((select value from context where key='invite'));
select pg_temp.assert_true((select count(*) from public.events) = 1, 'invited second parent sees the same event');
select pg_temp.assert_true((select count(*) from public.family_members) = 2, 'both parents share the family');
select public.record_event((select value::uuid from context where key='child'), 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
 repeat('b',64), 'diaper', now(), 'siri', null, 'mixed', null);
select pg_temp.assert_true((select count(*) from public.events) = 2, 'idempotency keys are scoped to the recording parent');
select pg_temp.assert_true((select count(*) from public.diaper_events where diaper_kind='mixed') = 1, 'mixed diaper is exactly one event');

select set_config('request.jwt.claim.sub', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', true);
do $$
begin
  begin
    perform public.join_family((select value from context where key='invite'));
    raise exception 'FAIL: invite was reusable';
  exception when invalid_parameter_value then raise notice 'PASS: consumed invite cannot be reused'; end;
end;
$$;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
do $$
begin
  begin
    perform public.create_family_invite();
    raise exception 'FAIL: third parent invite allowed';
  exception when invalid_parameter_value then raise notice 'PASS: family limited to two parents'; end;
end;
$$;

set local role anon;
select set_config('request.jwt.claim.sub', '', true);
do $$
begin
  begin
    perform count(*) from public.events;
    raise exception 'FAIL: anonymous read allowed';
  exception when insufficient_privilege then raise notice 'PASS: anonymous read denied'; end;
  begin
    perform public.create_family('UTC');
    raise exception 'FAIL: anonymous RPC allowed';
  exception when insufficient_privilege then raise notice 'PASS: anonymous RPC denied'; end;
end;
$$;
rollback;
