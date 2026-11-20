begin;
create function pg_temp.assert_true(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',label; end if; raise notice 'PASS: %',label; end $$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if sqlstate=expected then return; end if; raise;
  end;
  raise exception 'Expected SQLSTATE %',expected;
end $$;
insert into auth.users(id,email) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','parent@example.invalid'),('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','outside@example.invalid');
create temporary table profile_context(id uuid);
grant all on profile_context to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',true);
insert into profile_context select (public.create_family_v2('Baby','UTC')).id;
select pg_temp.assert_true((select voice_pronoun is null from public.children),'existing profiles do not infer pronouns from a chart');
select public.save_child_with_pronoun((select id from profile_context),'Baby',null,'male',true,null,1,false,'she');
select pg_temp.assert_true((select voice_pronoun='she' and growth_reference_sex='male' and profile_version=2 from public.children),'pronoun independent of WHO chart and saved in one revision');
select pg_temp.assert_true((select before_value->>'voice_pronoun' is null and after_value->>'voice_pronoun'='she' from public.care_revisions where target_type='profile'),'profile revision includes pronoun change');
select pg_temp.expect_error($q$select public.save_child_with_pronoun((select id from profile_context),'Baby',null,null,false,null,1,false,'he')$q$,'40001');
select pg_temp.expect_error($q$select public.save_child_with_pronoun(null,'Other',null,null,false,null,null,false,'unknown')$q$,'22023');
select public.save_child((select id from profile_context),'Baby',null,'male',true,null,2,false);
select pg_temp.assert_true((select voice_pronoun='she' and profile_version=3 from public.children),'legacy save preserves pronoun');
select public.save_child_with_pronoun((select id from profile_context),'Baby',null,'male',true,null,3,false,null);
select pg_temp.assert_true((select voice_pronoun is null from public.children),'unspecified clears pronoun');
select public.save_child_with_pronoun(null,'Second',null,null,false,null,null,false,'he');
select pg_temp.assert_true((select voice_pronoun='he' from public.children where name='Second'),'new profile pronoun saved');
select pg_temp.expect_error($q$update public.children set voice_pronoun='he'$q$,'42501');
select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true);
select pg_temp.expect_error($q$select public.save_child_with_pronoun((select id from profile_context),'Baby',null,null,false,null,4,false,'he')$q$,'42501');
reset role;
select pg_temp.assert_true(not has_function_privilege('anon','public.save_child_with_pronoun(uuid,text,date,text,boolean,boolean,integer,boolean,text)','EXECUTE'),'anonymous pronoun mutation denied');
rollback;
