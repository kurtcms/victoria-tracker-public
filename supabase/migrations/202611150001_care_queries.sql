-- Add read-only sleep questions and a persisted care report without changing build 14 writes.
begin;
alter function public.execute_care_conversation(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text) set schema private;
alter function private.execute_care_conversation(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text) rename to execute_care_conversation_v14;
revoke all on function private.execute_care_conversation_v14(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text) from public,anon,authenticated;

create function public.execute_care_conversation(p_child_id uuid,p_request_id uuid,p_request_hash text,
 p_operation text,p_reference_at timestamptz,p_source public.input_source,p_payload jsonb,p_time_zone text,
 p_utc_offset_seconds integer,p_zone_offsets jsonb,p_language text default 'en') returns jsonb
language plpgsql security definer set search_path='' as $$
declare query_kind text=p_payload->>'kind'; result jsonb; facts jsonb; selected public.sleep_sessions;
 feeding public.events; day_value date; day_end timestamptz; cutoff timestamptz; event_time timestamptz;
 running boolean; child_name text; msg text;
begin
 if p_operation is distinct from 'query' or query_kind is null or query_kind not in ('last_sleep_start','last_sleep_end','care_report') then
  return private.execute_care_conversation_v14(p_child_id,p_request_id,p_request_hash,p_operation,p_reference_at,p_source,p_payload,p_time_zone,p_utc_offset_seconds,p_zone_offsets,p_language);
 end if;
 -- Reuse the original access, archived-child, UUID, language, payload-key and
 -- complete captured-phone-time validation before reading any new query facts.
 result=private.execute_care_conversation_v14(p_child_id,p_request_id,p_request_hash,p_operation,p_reference_at,p_source,
  p_payload||jsonb_build_object('kind',case when query_kind='care_report' then 'day_summary' else 'last_feeding' end),p_time_zone,p_utc_offset_seconds,p_zone_offsets,p_language);
 facts=result->'details';child_name=facts->>'child_name';day_value=(facts->>'day')::date;
 if query_kind in ('last_sleep_start','last_sleep_end') then
  select * into selected from public.sleep_sessions s where child_id=p_child_id and voided_at is null
   and case when query_kind='last_sleep_start' then started_at<=p_reference_at else ended_at is not null and ended_at<=p_reference_at end
   and (day_value is null or private.care_local(case when query_kind='last_sleep_start' then started_at else ended_at end,p_time_zone,p_zone_offsets)::date=day_value)
   order by case when query_kind='last_sleep_start' then started_at else ended_at end desc,id limit 1;
  event_time=case when query_kind='last_sleep_start' then selected.started_at else selected.ended_at end;
  facts=jsonb_build_object('kind','answer','query_kind',query_kind,'child_name',child_name,'day',day_value,'has_records',selected.id is not null,
   'occurred_at',event_time,'display_time',to_char(private.care_local(event_time,p_time_zone,p_zone_offsets),'YYYY-MM-DD HH24:MI'),
   'started_at',selected.started_at,'ended_at',case when selected.ended_at<=p_reference_at then selected.ended_at else null end,
   'sleep_running',selected.id is not null and (selected.ended_at is null or selected.ended_at>p_reference_at));
  msg=case when selected.id is null then format('No %s is recorded for %s%s.',case when query_kind='last_sleep_start' then 'sleep start' else 'wake-up' end,child_name,case when day_value is null then '' else ' on '||day_value::text end)
   else format('%s last %s at %s.',child_name,case when query_kind='last_sleep_start' then 'fell asleep' else 'woke up' end,facts->>'display_time') end;
 else
  -- Use the same captured transition spans as day_summary, including DST days.
  with transitions as(select (x->>'from')::timestamptz as starts,lead((x->>'from')::timestamptz) over(order by ord) as ends,(x->>'seconds')::integer as seconds from jsonb_array_elements(p_zone_offsets) with ordinality a(x,ord)),
  spans as(select greatest((day_value::timestamp at time zone 'UTC')-make_interval(secs=>seconds),starts) as a,least(((day_value+1)::timestamp at time zone 'UTC')-make_interval(secs=>seconds),coalesce(ends,'infinity'::timestamptz)) as b from transitions)
  select max(b) into day_end from spans where a<b;
  cutoff=least(p_reference_at,day_end-interval '1 microsecond');
  select * into feeding from public.events where child_id=p_child_id and event_type='feeding' and voided_at is null and occurred_at<=cutoff order by occurred_at desc,id limit 1;
  select * into selected from public.sleep_sessions where child_id=p_child_id and voided_at is null and started_at<=cutoff and (ended_at is null or ended_at>cutoff) order by started_at desc,id limit 1;
  running=selected.id is not null;
  facts=facts||jsonb_build_object('query_kind',query_kind,'last_feeding_ml',feeding.volume_ml,'last_feeding_at',feeding.occurred_at,
   'last_feeding_display_time',to_char(private.care_local(feeding.occurred_at,p_time_zone,p_zone_offsets),'YYYY-MM-DD HH24:MI'),
   'sleep_running',running,'sleep_started_at',selected.started_at,'sleep_display_time',to_char(private.care_local(selected.started_at,p_time_zone,p_zone_offsets),'YYYY-MM-DD HH24:MI'),'sleep_status_at',cutoff,'sleep_status_display_time',to_char(private.care_local(cutoff,p_time_zone,p_zone_offsets),'YYYY-MM-DD HH24:MI'));
  msg=format('%s on %s: %s millilitres, %s wet diapers, %s dirty diapers, and %s minutes of sleep recorded. %s %s',child_name,day_value,facts->>'feeding_ml',facts->>'wet_count',facts->>'dirty_count',facts->>'sleep_minutes',
   case when feeding.id is null then 'No feeding is recorded.' else format('Last feeding: %s mL at %s.',trim_scale(feeding.volume_ml),facts->>'last_feeding_display_time') end,
   case when running then format('Sleeping since %s as of %s.',facts->>'sleep_display_time',to_char(private.care_local(cutoff,p_time_zone,p_zone_offsets),'YYYY-MM-DD HH24:MI')) else 'No sleep is recorded as running at that time.' end);
 end if;
 return result||jsonb_build_object('message',msg,'details',facts);
end $$;
revoke all on function public.execute_care_conversation(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text) from public,anon;
grant execute on function public.execute_care_conversation(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text) to authenticated;
commit;
