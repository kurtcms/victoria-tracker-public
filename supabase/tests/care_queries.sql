-- Isolated fixtures: captured phone clock is yesterday at 12:00 UTC, with +02:00 offset.
begin;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',label;end if;raise notice 'PASS: %',label;end $$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin begin execute statement;exception when others then if sqlstate=expected then return;end if;raise;end;raise exception 'Expected SQLSTATE %',expected;end $$;
insert into auth.users(id,email) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','queries@example.invalid'),('cccccccc-cccc-4ccc-8ccc-cccccccccccc','outsider@example.invalid');
create temporary table query_context(child uuid,reference_at timestamptz);
grant select,insert on query_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
insert into query_context select (public.create_family_v2('Ava','UTC')).id,date_trunc('day',now())-interval '1 day'+interval '12 hours';
create function pg_temp.ask(kind text,day_value date default null) returns jsonb language sql as $$
 select public.execute_care_conversation(child,gen_random_uuid(),repeat('a',64),'query',reference_at,'siri',jsonb_build_object('kind',kind,'day',day_value),'UTC',7200,
 jsonb_build_array(jsonb_build_object('from',reference_at-interval '366 days','seconds',7200)),'en')->'details' from query_context;
$$;
select pg_temp.assert_true(pg_temp.ask('last_sleep_start')->>'has_records'='false','no sleep start is an absent record');
select pg_temp.assert_true(pg_temp.ask('last_sleep_end')->>'has_records'='false','no wake is an absent record');
reset role;
-- Last night starts before local midnight and wakes after it. A later sleep is still running at reference.
insert into public.sleep_sessions(child_id,started_at,ended_at,recorded_by,input_source)
 select child,reference_at-interval '15 hours',reference_at-interval '10 hours','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source from query_context
 union all select child,reference_at-interval '1 hour',null,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source from query_context
 union all select child,reference_at+interval '1 hour',reference_at+interval '2 hours','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source from query_context;
insert into public.sleep_sessions(child_id,started_at,ended_at,recorded_by,input_source,voided_at)
 select child,reference_at-interval '5 minutes',reference_at-interval '1 minute','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source,now() from query_context;
insert into public.events(child_id,event_type,occurred_at,recorded_by,input_source,volume_ml,diaper_kind,request_id,request_hash)
 select child,'feeding'::public.event_type,reference_at-interval '2 hours','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source,120,null::public.diaper_kind,gen_random_uuid(),repeat('a',64) from query_context
 union all select child,'feeding'::public.event_type,reference_at+interval '1 hour','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source,999,null,gen_random_uuid(),repeat('a',64) from query_context
 union all select child,'feeding'::public.event_type,reference_at-interval '16 hours','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source,80,null,gen_random_uuid(),repeat('a',64) from query_context
 union all select child,'diaper'::public.event_type,reference_at-interval '3 hours','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source,null,'mixed'::public.diaper_kind,gen_random_uuid(),repeat('a',64) from query_context;
set local role authenticated;
select pg_temp.assert_true((pg_temp.ask('last_sleep_start')->>'occurred_at')::timestamptz=(select reference_at-interval '1 hour' from query_context),'latest start excludes future and voided sessions');
select pg_temp.assert_true((pg_temp.ask('last_sleep_end')->>'occurred_at')::timestamptz=(select reference_at-interval '10 hours' from query_context),'latest wake excludes running future and voided sessions');
select pg_temp.assert_true(pg_temp.ask('last_sleep_start',(select reference_at::date-1 from query_context))->>'display_time'=to_char((select reference_at-interval '13 hours' from query_context),'YYYY-MM-DD HH24:MI'),'explicit start day follows captured phone offset');
select pg_temp.assert_true(pg_temp.ask('last_sleep_end',(select reference_at::date-1 from query_context))->>'has_records'='false','wake day filters wake time rather than start time');
select pg_temp.assert_true(pg_temp.ask('has_dirty')->>'dirty_count'='1','mixed diapers answer dirty today');
select pg_temp.assert_true(pg_temp.ask('day_summary')->>'feeding_ml'='120.00','milk today excludes local yesterday and future intake');
select pg_temp.assert_true(pg_temp.ask('care_report')->>'feeding_ml'='120.00' and pg_temp.ask('care_report')->>'last_feeding_ml'='120.00' and pg_temp.ask('care_report')->>'sleep_running'='true','report combines bounded totals latest feeding and active sleep');
select pg_temp.assert_true(pg_temp.ask('care_report',(select reference_at::date-1 from query_context))->>'last_feeding_ml'='80.00' and pg_temp.ask('care_report',(select reference_at::date-1 from query_context))->>'sleep_running'='true','historical report uses selected day cutoff rather than current state');
-- A captured fallback (+02:00 to +01:00) makes the historical day 25 hours.
-- The previous-night sleep contributes 21:00-23:00 UTC, exactly 120 minutes.
select pg_temp.assert_true((select public.execute_care_conversation(child,gen_random_uuid(),repeat('a',64),'query',reference_at,'siri',jsonb_build_object('kind','care_report','day',reference_at::date-1),'UTC',3600,
 jsonb_build_array(jsonb_build_object('from',reference_at-interval '366 days','seconds',7200),jsonb_build_object('from',date_trunc('day',reference_at)-interval '23 hours','seconds',3600)),'en')->'details'->>'sleep_minutes'='120' from query_context),'report sleep totals honor captured fallback day rather than server UTC rules');
select pg_temp.assert_true((select (public.execute_care_conversation(child,gen_random_uuid(),repeat('a',64),'query',reference_at,'siri',jsonb_build_object('kind','care_report','day',reference_at::date-1),'UTC',3600,
 jsonb_build_array(jsonb_build_object('from',reference_at-interval '366 days','seconds',7200),jsonb_build_object('from',date_trunc('day',reference_at)-interval '23 hours','seconds',3600)),'en')->'details'->>'sleep_status_at')::timestamptz=reference_at-interval '13 hours 1 microsecond' from query_context),'historical sleep status cutoff honors captured fallback boundary');
select pg_temp.expect_error($q$select pg_temp.ask('care_report',current_date+1)$q$,'22023');
-- All new branches retain the original metadata and payload validation boundary.
select pg_temp.expect_error($q$select public.execute_care_conversation(child,null,repeat('a',64),'query',reference_at,'siri','{"kind":"last_sleep_start","day":null}','UTC',7200,jsonb_build_array(jsonb_build_object('from',reference_at-interval '366 days','seconds',7200)),'en') from query_context$q$,'22023');
select pg_temp.expect_error($q$select public.execute_care_conversation(child,gen_random_uuid(),repeat('a',64),'query',reference_at,'siri','{"kind":"care_report","day":null,"injected":true}','UTC',7200,jsonb_build_array(jsonb_build_object('from',reference_at-interval '366 days','seconds',7200)),'en') from query_context$q$,'22023');
select pg_temp.expect_error($q$select public.execute_care_conversation(child,gen_random_uuid(),repeat('a',64),'query',reference_at,'siri','{"kind":"last_sleep_end","day":null}','UTC',7200,jsonb_build_array(jsonb_build_object('from',reference_at-interval '365 days','seconds',7200)),'en') from query_context$q$,'22023');
reset role;
update public.sleep_sessions set ended_at=(select reference_at+interval '30 minutes' from query_context) where ended_at is null;
set local role authenticated;
select pg_temp.assert_true(pg_temp.ask('last_sleep_start')->>'sleep_running'='true' and pg_temp.ask('last_sleep_start')->>'ended_at' is null,'later persisted wake is not exposed at an earlier captured reference');
select pg_temp.assert_true(pg_temp.ask('care_report')->>'sleep_running'='true','report regards a later persisted wake as sleeping at reference');

select set_config('request.jwt.claim.sub','cccccccc-cccc-4ccc-8ccc-cccccccccccc',true);
select pg_temp.expect_error($q$select pg_temp.ask('last_sleep_start')$q$,'42501');
select pg_temp.expect_error($q$select pg_temp.ask('last_sleep_end')$q$,'42501');
select pg_temp.expect_error($q$select pg_temp.ask('care_report')$q$,'42501');
reset role;
select pg_temp.assert_true(not has_function_privilege('authenticated','private.execute_care_conversation_v14(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text)','EXECUTE') and not has_function_privilege('anon','private.execute_care_conversation_v14(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text)','EXECUTE'),'original implementation is inaccessible directly');
select pg_temp.assert_true(not has_function_privilege('anon','public.execute_care_conversation(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text)','EXECUTE'),'anonymous cannot call new wrapper');
select pg_temp.assert_true((select count(*) from public.care_receipts)=0 and (select count(*) from public.care_proposals)=0,'queries create neither receipts nor proposals');
rollback;
