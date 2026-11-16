-- Synthetic, transactional read contract tests. Never run against family data.
begin;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',label;end if;raise notice 'PASS: %',label;end $$;
create function pg_temp.expect_denied(statement text) returns void language plpgsql as $$
begin begin execute statement;exception when insufficient_privilege then return;end;raise exception 'Expected access denial';end $$;
insert into auth.users(id,email) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','snapshot@example.invalid'),('cccccccc-cccc-4ccc-8ccc-cccccccccccc','outsider@example.invalid');
create temporary table snapshot_context(child uuid,reference_at timestamptz);
grant select,insert on snapshot_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
insert into snapshot_context select (public.create_family_v2('Ava','UTC')).id,now()-interval '1 day';
reset role;
insert into public.events(child_id,event_type,occurred_at,recorded_by,input_source,volume_ml,request_id,request_hash)
 select child,'feeding'::public.event_type,reference_at-interval '1 hour','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source,80,gen_random_uuid(),repeat('a',64) from snapshot_context
 union all select child,'feeding'::public.event_type,reference_at+interval '1 hour','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,'manual'::public.input_source,90,gen_random_uuid(),repeat('a',64) from snapshot_context;
insert into public.sleep_sessions(child_id,started_at,ended_at,recorded_by,input_source)
 select child,reference_at-interval '3 hours',null,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','manual' from snapshot_context;
insert into public.milestones(child_id,title,occurred_on,date_precision,recorded_by,input_source)
 select child,'Waved hello',current_date-2,'day','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','manual' from snapshot_context;
set local role authenticated;
create function pg_temp.snapshot() returns jsonb language sql as $$ select public.read_care_snapshot(child,reference_at) from snapshot_context $$;
select pg_temp.assert_true(pg_temp.snapshot()->>'complete'='true','snapshot completeness is explicit');
select pg_temp.assert_true(jsonb_array_length(pg_temp.snapshot()->'events')=1 and pg_temp.snapshot()->'events'->0->>'volume_ml'='80.00','snapshot excludes future events and preserves recorded consumed amount');
select pg_temp.assert_true(jsonb_array_length(pg_temp.snapshot()->'sleep')=1 and pg_temp.snapshot()->'sleep'->0->>'ended_at' is null,'snapshot preserves an open sleep without inventing wake');
select pg_temp.assert_true(jsonb_array_length(pg_temp.snapshot()->'milestones')=1,'snapshot carries date-only milestone facts');
select pg_temp.assert_true(not (pg_temp.snapshot()->'events'->0 ? 'recorded_by') and not (pg_temp.snapshot()->'events'->0 ? 'created_at'),'snapshot returns only query data');
select set_config('request.jwt.claim.sub','cccccccc-cccc-4ccc-8ccc-cccccccccccc',true);
select pg_temp.expect_denied('select pg_temp.snapshot()');
reset role;
set local role anon;
select pg_temp.expect_denied('select public.read_care_snapshot(null,now())');
reset role;
select pg_temp.assert_true((select not prosecdef from pg_proc where oid='public.read_care_snapshot(uuid,timestamptz)'::regprocedure),'snapshot uses caller privileges');
select pg_temp.assert_true((select count(*) from public.care_receipts)=0 and (select count(*) from public.care_proposals)=0,'snapshot creates no receipt or proposal');
rollback;
