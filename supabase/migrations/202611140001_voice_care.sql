-- Additive build 14 operations. Preserve existing records, RPCs and retry receipts.
begin;
alter table public.milestones add column guide_id text check(guide_id ~ '^(cdc|rbr|cps)-[a-z0-9-]{1,76}$');
create unique index milestone_guide_once on public.milestones(child_id,guide_id) where guide_id is not null and voided_at is null;

create function private.care_label(row_value jsonb,record_kind text) returns text
language sql immutable set search_path='' as $$
 select case record_kind
 when 'feeding' then trim_scale((row_value->>'volume_ml')::numeric)::text || ' mL'
 when 'diaper' then (case row_value->>'diaper_kind' when 'mixed' then 'Wet and dirty' when 'wet' then 'Wet' else 'Dirty' end) || ' diaper'
 when 'weight' then trim_scale((row_value->>'weight_kg')::numeric)::text || ' kg'
 when 'milestone' then coalesce(row_value->>'title','Milestone')
 else 'Sleep' end;
$$;

-- Phone-captured transitions, rather than server timezone rule versions, define wall time.
create function private.care_local(t timestamptz,zone_name text,offsets jsonb) returns timestamp
language sql stable set search_path='' as $$
 select coalesce((t+make_interval(secs=>(select (o->>'seconds')::integer from jsonb_array_elements(offsets) o
   where (o->>'from')::timestamptz<=t order by (o->>'from')::timestamptz desc limit 1))) at time zone 'UTC',t at time zone zone_name);
$$;

create function private.care_present(result jsonb,child uuid,action_name text,action_payload jsonb,zone_name text,offsets jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare c public.children; q public.care_proposals; row_value jsonb; after_value jsonb; kind text; when_text text;
 before_text text; after_text text; msg text; facts jsonb; deleted boolean; event_time timestamptz;
begin
 select * into c from public.children where id=child;
 if result->>'status'='needs_confirmation' then
  select * into q from public.care_proposals where id=(result->>'proposal_id')::uuid and child_id=child and recorded_by=auth.uid();
  if q.id is null then raise exception 'Confirmation not accessible' using errcode='42501';end if;
  if q.target_type in ('event','feeding') then select to_jsonb(x) into row_value from public.events x where id=q.target_id and child_id=child;
  elsif q.target_type='sleep' then select to_jsonb(x) into row_value from public.sleep_sessions x where id=q.target_id and child_id=child;
  else select to_jsonb(x) into row_value from public.milestones x where id=q.target_id and child_id=child;end if;
  kind=case when q.target_type='event' then row_value->>'event_type' else q.target_type end;
  event_time=coalesce((row_value->>'occurred_at')::timestamptz,(row_value->>'started_at')::timestamptz);
  when_text=case when kind='milestone' then case when row_value->>'date_precision'='month' then to_char((row_value->>'occurred_on')::date,'Mon YYYY') else to_char((row_value->>'occurred_on')::date,'Mon DD, YYYY') end
   when kind='weight' and row_value->>'measurement_date' is not null then to_char((row_value->>'measurement_date')::date,'Mon DD, YYYY')
   else to_char(private.care_local(event_time,zone_name,offsets),'Mon DD, HH12:MI AM') end;
  after_value=row_value||q.changes;
  before_text=private.care_label(row_value,kind);after_text=private.care_label(after_value,kind);
  if kind='sleep' then
   before_text=to_char(private.care_local((row_value->>'started_at')::timestamptz,zone_name,offsets),'Mon DD HH24:MI')||' to '||coalesce(to_char(private.care_local((row_value->>'ended_at')::timestamptz,zone_name,offsets),'Mon DD HH24:MI'),'still sleeping');
   after_text=to_char(private.care_local((q.changes->>'occurred_at')::timestamptz,zone_name,offsets),'Mon DD HH24:MI')||' to '||coalesce(to_char(private.care_local((q.changes->>'ended_at')::timestamptz,zone_name,offsets),'Mon DD HH24:MI'),'still sleeping');
  elsif kind='milestone' then
   before_text=before_text||' ('||(row_value->>'occurred_on')||case when row_value->>'note' is not null then '; '||(row_value->>'note') else '' end||')';
   after_text=after_text||' ('||coalesce(q.changes->>'occurred_on',row_value->>'occurred_on')||case when q.changes->>'note' is not null then '; '||(q.changes->>'note') else '' end||')';
  elsif kind='weight' and after_value->>'measurement_date' is distinct from row_value->>'measurement_date' then
   before_text=before_text||' ('||(row_value->>'measurement_date')||')';after_text=after_text||' ('||(after_value->>'measurement_date')||')';
  end if;
  if kind='diaper' and (after_value->>'occurred_at')::timestamptz is distinct from event_time then
   before_text=before_text||' at '||to_char(private.care_local(event_time,zone_name,offsets),'Mon DD, HH12:MI AM');
   after_text=after_text||' at '||to_char(private.care_local((after_value->>'occurred_at')::timestamptz,zone_name,offsets),'Mon DD, HH12:MI AM');
  end if;
  deleted=coalesce((q.changes->>'void')::boolean,false);
  msg=case when deleted then format('Delete %s’s %s from %s?',c.name,lower(private.care_label(row_value,kind)),when_text)
   else format('%s · %s: %s → %s. Save this change?',c.name,when_text,before_text,after_text) end;
  facts=jsonb_build_object('kind','proposal','child_name',c.name,'action',case when deleted then 'delete' else 'change' end,'record_kind',kind,'recorded_at',when_text,'old_label',before_text,'new_label',after_text,'old_value',row_value->'volume_ml','new_value',after_value->'volume_ml','unit',case when kind='feeding' then 'ml' when kind='weight' then 'kg' else null end);
  update public.care_proposals set message=msg where id=q.id;
  return result||jsonb_build_object('message',msg,'details',facts,'is_deletion',deleted);
 elsif result->>'status'='recorded' then
  if action_name in ('confirm','cancel') then
   select * into q from public.care_proposals where id=(action_payload->>'proposal_id')::uuid and child_id=child and recorded_by=auth.uid();
  end if;
  select to_jsonb(x) into row_value from public.events x where id=(result->>'event_id')::uuid and child_id=child;
  if row_value is not null then kind=row_value->>'event_type';
  else
   select to_jsonb(x) into row_value from public.sleep_sessions x where id=(result->>'event_id')::uuid and child_id=child;
   if row_value is not null then kind='sleep';
   else select to_jsonb(x) into row_value from public.milestones x where id=(result->>'event_id')::uuid and child_id=child;kind='milestone';end if;
  end if;
  facts=jsonb_build_object('kind',case when q.id is null then 'recorded' when row_value->>'voided_at' is not null then 'deleted' else 'changed' end,'child_name',c.name,'record_kind',kind,
   'value',case when kind='feeding' then row_value->'volume_ml' when kind='weight' then row_value->'weight_kg' when kind='sleep' and row_value->>'ended_at' is not null then to_jsonb(round(extract(epoch from((row_value->>'ended_at')::timestamptz-(row_value->>'started_at')::timestamptz))/60)) else null end,
   'unit',case when kind='feeding' then 'ml' when kind='weight' then 'kg' when kind='sleep' then 'minutes' else null end,'diaper_kind',row_value->'diaper_kind','title',row_value->'title','sleep_running',kind='sleep' and row_value->>'ended_at' is null);
  return result||jsonb_build_object('details',facts);
 end if;
 if action_name='cancel' and result->>'status'='rejected' then return result||jsonb_build_object('details',jsonb_build_object('kind','cancelled','child_name',c.name));end if;
 return result;
end $$;

create function public.execute_care_conversation(p_child_id uuid,p_request_id uuid,p_request_hash text,
 p_operation text,p_reference_at timestamptz,p_source public.input_source,p_payload jsonb,p_time_zone text,
 p_utc_offset_seconds integer,p_zone_offsets jsonb,p_language text default 'en') returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.children; prior public.care_receipts; item jsonb; result jsonb; inner_result jsonb;
 action_name text; action_payload jsonb; request_part uuid; hash_part text; n integer; items jsonb='[]';ids jsonb='[]';
 failure_response jsonb; selector jsonb; changes jsonb; selected jsonb; target_kind text; target_type text; target uuid;
 tied integer; remove_record boolean; day_value date; day_start timestamptz; day_end timestamptz; query_kind text;
 counts jsonb; facts jsonb; msg text; guide text; found_milestone public.milestones; reference_day date; off jsonb;
 previous_at timestamptz; first_at timestamptz; last_seconds integer; on_date date; precision_value text;
begin
 if auth.uid() is null or not exists(select 1 from public.children x join public.family_members fm on fm.family_id=x.family_id where x.id=p_child_id and fm.user_id=auth.uid()) then raise exception 'Baby not accessible' using errcode='42501';end if;
 if p_request_id is null or p_request_hash is null or p_request_hash !~ '^[a-f0-9]{64}$' or p_source is null
  or p_reference_at is null or not isfinite(p_reference_at) or p_reference_at>now()+interval '5 minutes' or p_reference_at<now()-interval '366 days'
  or p_operation is null or p_operation not in ('action','batch','correct','query') or p_language is null or p_language not in ('en','yue')
  or not exists(select 1 from pg_timezone_names where name=p_time_zone) or p_utc_offset_seconds is null or abs(p_utc_offset_seconds)>50400
  or jsonb_typeof(p_payload) is distinct from 'object' or jsonb_typeof(p_zone_offsets) is distinct from 'array' or jsonb_array_length(p_zone_offsets) not between 1 and 16 then raise exception 'Invalid command metadata' using errcode='22023';end if;
 for off in select value from jsonb_array_elements(p_zone_offsets) loop
  perform private.care_keys(off,array['from','seconds']);
  if (off->>'from')::timestamptz is null or not isfinite((off->>'from')::timestamptz) or (off->>'seconds')::integer is null or abs((off->>'seconds')::integer)>50400
   or (off->>'from')::timestamptz>p_reference_at or (off->>'from')::timestamptz<p_reference_at-interval '367 days'
   or previous_at is not null and (off->>'from')::timestamptz<=previous_at then raise exception 'Invalid phone timezone context' using errcode='22023';end if;
  previous_at=(off->>'from')::timestamptz;first_at=coalesce(first_at,previous_at);last_seconds=(off->>'seconds')::integer;
 end loop;
 if first_at>p_reference_at-interval '366 days'+interval '1 second' or last_seconds<>p_utc_offset_seconds then raise exception 'Incomplete phone timezone context' using errcode='22023';end if;
 select * into c from public.children where id=p_child_id;
 if c.archived_at is not null then raise exception 'This baby is archived. Restore the profile first.' using errcode='22023';end if;
 reference_day=((p_reference_at+make_interval(secs=>p_utc_offset_seconds)) at time zone 'UTC')::date;

 -- Questions do not create receipts, proposals or care rows.
 if p_operation='query' then
  perform private.care_keys(p_payload,array['kind','day']);query_kind=p_payload->>'kind';
  if query_kind is null or query_kind not in ('last_feeding','day_summary','wet_count','dirty_count','has_dirty','sleep_total','last_weight','last_milestone','last_diaper') then raise exception 'Unsupported question. Ask about a saved care record or daily totals.' using errcode='22023';end if;
  day_value=(p_payload->>'day')::date;
  if query_kind in ('day_summary','wet_count','dirty_count','has_dirty','sleep_total') then day_value=coalesce(day_value,reference_day);end if;
  if day_value is not null then
   if not isfinite(day_value) or day_value>reference_day or day_value<reference_day-366 then raise exception 'Ask about a past day within the last year.' using errcode='22023';end if;
   with transitions as(select (x->>'from')::timestamptz as starts,lead((x->>'from')::timestamptz) over(order by ord) as ends,(x->>'seconds')::integer as seconds from jsonb_array_elements(p_zone_offsets) with ordinality a(x,ord)),
   spans as(select greatest((day_value::timestamp at time zone 'UTC')-make_interval(secs=>seconds),starts) as a,least(((day_value+1)::timestamp at time zone 'UTC')-make_interval(secs=>seconds),coalesce(ends,'infinity'::timestamptz)) as b from transitions)
   select min(a),max(b) into day_start,day_end from spans where a<b;
   if day_start is null then raise exception 'That day is outside the phone timezone context.' using errcode='22023';end if;
  end if;
  facts=jsonb_build_object('kind','answer','query_kind',query_kind,'child_name',c.name,'day',day_value,'has_records',false);
  if query_kind in ('day_summary','wet_count','dirty_count','has_dirty','sleep_total') then
   select jsonb_build_object('feeding_ml',coalesce(sum(volume_ml) filter(where event_type='feeding'),0),'feeding_count',count(*) filter(where event_type='feeding'),
    'wet_count',count(*) filter(where event_type='diaper' and diaper_kind in ('wet','mixed')),'dirty_count',count(*) filter(where event_type='diaper' and diaper_kind in ('dirty','mixed')),'has_records',count(*)>0)
    into counts from public.events where child_id=c.id and voided_at is null and occurred_at>=day_start and occurred_at<day_end and occurred_at<=p_reference_at;
   select counts||jsonb_build_object('sleep_minutes',coalesce(round(sum(extract(epoch from(least(coalesce(ended_at,p_reference_at),day_end,p_reference_at)-greatest(started_at,day_start))))/60),0),'sleep_sessions',count(*)) into counts
    from public.sleep_sessions where child_id=c.id and voided_at is null and started_at<least(day_end,p_reference_at) and coalesce(ended_at,p_reference_at)>day_start;
   facts=facts||counts||jsonb_build_object('has_records',true);
   msg=case query_kind when 'wet_count' then format('%s has %s wet diapers recorded on %s.',c.name,counts->>'wet_count',day_value)
    when 'dirty_count' then format('%s has %s dirty diapers recorded on %s.',c.name,counts->>'dirty_count',day_value)
    when 'has_dirty' then case when (counts->>'dirty_count')::integer=0 then format('No dirty diaper is recorded for %s on %s.',c.name,day_value) else format('Yes. %s has %s dirty diapers recorded on %s.',c.name,counts->>'dirty_count',day_value) end
    when 'sleep_total' then format('%s has %s minutes of sleep in %s sessions recorded on %s.',c.name,counts->>'sleep_minutes',counts->>'sleep_sessions',day_value)
    else format('%s on %s: %s millilitres, %s wet diapers, %s dirty diapers, and %s minutes of sleep recorded.',c.name,day_value,counts->>'feeding_ml',counts->>'wet_count',counts->>'dirty_count',counts->>'sleep_minutes') end;
  elsif query_kind='last_milestone' then
   select to_jsonb(x) into selected from public.milestones x where child_id=c.id and voided_at is null and occurred_on<=reference_day and (day_value is null or occurred_on=day_value) order by occurred_on desc,created_at desc,id limit 1;
   facts=facts||jsonb_build_object('has_records',selected is not null,'title',selected->'title','occurred_on',selected->'occurred_on','date_precision',selected->'date_precision');
   msg=case when selected is null then format('No milestone is recorded for %s%s.',c.name,case when day_value is null then '' else ' on '||day_value::text end) else format('%s’s latest recorded milestone is %s, %s.',c.name,selected->>'title',case when selected->>'date_precision'='month' then to_char((selected->>'occurred_on')::date,'Mon YYYY') else selected->>'occurred_on' end) end;
  else
   target_kind=case query_kind when 'last_feeding' then 'feeding' when 'last_weight' then 'weight' else 'diaper' end;
   select to_jsonb(x) into selected from public.events x where child_id=c.id and event_type=target_kind::public.event_type and voided_at is null and occurred_at<=p_reference_at
    and (day_value is null or target_kind='weight' and coalesce(measurement_date,private.care_local(occurred_at,p_time_zone,p_zone_offsets)::date)=day_value
     or target_kind<>'weight' and occurred_at>=day_start and occurred_at<day_end)
    order by case when target_kind='weight' then coalesce(measurement_date,private.care_local(occurred_at,p_time_zone,p_zone_offsets)::date) end desc,occurred_at desc,id limit 1;
   facts=facts||jsonb_build_object('has_records',selected is not null,'value',case when target_kind='feeding' then selected->'volume_ml' when target_kind='weight' then selected->'weight_kg' else null end,'unit',case when target_kind='feeding' then 'ml' when target_kind='weight' then 'kg' else null end,'diaper_kind',selected->'diaper_kind','occurred_at',selected->'occurred_at','measurement_date',selected->'measurement_date','display_time',case when selected is null then null else to_char(private.care_local((selected->>'occurred_at')::timestamptz,p_time_zone,p_zone_offsets),'YYYY-MM-DD HH24:MI') end);
   msg=case when selected is null then format('No %s is recorded for %s%s.',target_kind,c.name,case when day_value is null then '' else ' on '||day_value::text end)
    when target_kind='weight' then format('%s’s latest recorded weight is %s on %s.',c.name,private.care_label(selected,target_kind),coalesce(selected->>'measurement_date',facts->>'display_time'))
    else format('%s’s last recorded %s was %s at %s.',c.name,target_kind,private.care_label(selected,target_kind),facts->>'display_time') end;
  end if;
  return jsonb_build_object('status','answered','message',msg,'child_id',c.id,'details',facts,'language',p_language);
 end if;

 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,6));
 select * into prior from public.care_receipts where recorded_by=auth.uid() and request_id=p_request_id;
 if found then
  if prior.request_hash<>p_request_hash or prior.child_id<>p_child_id then raise exception 'Idempotency conflict' using errcode='23505';end if;
  return prior.response||jsonb_build_object('replayed',true)||case when prior.response->>'status'='recorded' then jsonb_build_object('message','This action was already saved. Nothing was recorded again. Check the app for later corrections.') else '{}'::jsonb end;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_child_id::text,4));
 -- Recheck after the shared child lock, including concurrent archiving.
 if exists(select 1 from public.children where id=c.id and archived_at is not null) then raise exception 'This baby is archived.' using errcode='22023';end if;

 if p_operation='batch' then
  perform private.care_keys(p_payload,array['actions']);
  if jsonb_typeof(p_payload->'actions') is distinct from 'array' or jsonb_array_length(p_payload->'actions') not between 1 and 5 then raise exception 'Describe one to five care events for one baby.' using errcode='22023';end if;
  begin
   n=0;
   for item in select value from jsonb_array_elements(p_payload->'actions') loop
    perform private.care_keys(item,array['action','payload']);action_name=item->>'action';
    if action_name is null or action_name not in ('record','sleep_start','sleep_end','sleep_interval','milestone') or jsonb_typeof(item->'payload') is distinct from 'object' then raise exception 'Only new care events can be combined.' using errcode='22023';end if;
    n=n+1;
    request_part=(substr(md5(p_request_id::text||':'||n::text),1,12)||'4'||substr(md5(p_request_id::text||':'||n::text),14,3)||'8'||substr(md5(p_request_id::text||':'||n::text),18,15))::uuid;
    hash_part=encode(extensions.digest(convert_to(p_request_hash||':'||n::text,'UTF8'),'sha256'),'hex');
    inner_result=public.execute_care_command(c.id,request_part,hash_part,action_name,p_reference_at,p_source,item->'payload',p_time_zone,p_utc_offset_seconds,p_zone_offsets);
    if inner_result->>'status' is distinct from 'recorded' then failure_response=inner_result;raise exception 'Batch needs clarification' using errcode='VT001';end if;
    inner_result=private.care_present(inner_result,c.id,action_name,item->'payload',p_time_zone,p_zone_offsets);
    items=items||jsonb_build_array(inner_result->'details');
    if not ids @> jsonb_build_array(inner_result->'event_id') then ids=ids||jsonb_build_array(inner_result->'event_id');end if;
   end loop;
  exception when sqlstate 'VT001' then
   return failure_response||jsonb_build_object('message','Nothing in that description was saved. '||(failure_response->>'message'),'code',case when action_name='sleep_end' then 'sleep_start_required' when action_name in ('sleep_start','sleep_interval') then 'sleep_overlap' else 'batch_clarification' end,'language',p_language);
  end;
  result=case when n=1 then inner_result else jsonb_build_object('status','recorded','message',format('Recorded %s events for %s.',n,c.name),'event_id',ids->>0,'event_ids',ids,'child_id',c.id,'details',jsonb_build_object('kind','batch','child_name',c.name,'count',n,'items',items)) end;
 elsif p_operation='correct' then
  perform private.care_keys(p_payload,array['selector','changes','remove']);selector=p_payload->'selector';changes=p_payload->'changes';
  if jsonb_typeof(selector) is distinct from 'object' or jsonb_typeof(changes) is distinct from 'object' or jsonb_typeof(p_payload->'remove') is distinct from 'boolean' then raise exception 'Specify a record and correction.' using errcode='22023';end if;
  perform private.care_keys(selector,array['kind','diaper_kind','title','expected_volume_ml']);
  perform private.care_keys(changes,array['correction_kind','amount_ml','diaper_kind','weight_kg','measurement_date','occurred_at','ended_at','title','note','occurred_on','date_precision']);
  target_kind=selector->>'kind';remove_record=(p_payload->>'remove')::boolean;
  if target_kind is null or target_kind not in ('feeding','diaper','weight','sleep','milestone') or remove_record and changes<>'{}'::jsonb then raise exception 'Specify one supported record change.' using errcode='22023';end if;
  if selector->>'diaper_kind' is not null and (target_kind<>'diaper' or selector->>'diaper_kind' not in ('wet','dirty','mixed')) or selector->>'title' is not null and (target_kind<>'milestone' or length(btrim(selector->>'title')) not between 1 and 120) or selector->>'expected_volume_ml' is not null and target_kind<>'feeding' then raise exception 'Invalid record selector.' using errcode='22023';end if;
  if target_kind in ('feeding','diaper','weight') then
   select to_jsonb(x) into selected from public.events x where child_id=c.id and event_type=target_kind::public.event_type and voided_at is null and occurred_at<=p_reference_at and (selector->>'diaper_kind' is null or diaper_kind::text=selector->>'diaper_kind')
    order by case when target_kind='weight' then coalesce(measurement_date,private.care_local(occurred_at,p_time_zone,p_zone_offsets)::date) end desc,occurred_at desc,id limit 1 for update;
   select count(*) into tied from public.events where child_id=c.id and event_type=target_kind::public.event_type and voided_at is null and occurred_at=(selected->>'occurred_at')::timestamptz and (target_kind<>'weight' or measurement_date is not distinct from (selected->>'measurement_date')::date) and (selector->>'diaper_kind' is null or diaper_kind::text=selector->>'diaper_kind');
   target_type='event';
  elsif target_kind='sleep' then
   select to_jsonb(x) into selected from public.sleep_sessions x where child_id=c.id and voided_at is null and started_at<=p_reference_at order by started_at desc,id limit 1 for update;
   select count(*) into tied from public.sleep_sessions where child_id=c.id and voided_at is null and started_at=(selected->>'started_at')::timestamptz;target_type='sleep';
  else
   select to_jsonb(x) into selected from public.milestones x where child_id=c.id and voided_at is null and occurred_on<=reference_day and (selector->>'title' is null or lower(title)=lower(selector->>'title')) order by occurred_on desc,created_at desc,id limit 1 for update;
   select count(*) into tied from public.milestones where child_id=c.id and voided_at is null and occurred_on=(selected->>'occurred_on')::date and created_at=(selected->>'created_at')::timestamptz and (selector->>'title' is null or lower(title)=lower(selector->>'title'));target_type='milestone';
  end if;
  if selected is null or tied<>1 then return jsonb_build_object('status','needs_clarification','code',case when selected is null then 'record_not_found' else 'ambiguous_record' end,'message',case when selected is null then format('No matching %s record was found for %s. Nothing changed.',target_kind,c.name) else 'More than one record matches. Nothing changed. Select the record in the app.' end,'language',p_language);end if;
  if selector->>'expected_volume_ml' is not null and (selector->>'expected_volume_ml')::numeric is distinct from (selected->>'volume_ml')::numeric then return jsonb_build_object('status','needs_clarification','code','previous_amount_mismatch','message',format('The last feeding is %s millilitres, rather than %s. Nothing changed. Please check which feeding to correct.',trim_scale((selected->>'volume_ml')::numeric),selector->>'expected_volume_ml'),'language',p_language);end if;
  target=(selected->>'id')::uuid;
  if target_kind='feeding' and not remove_record then
   perform private.care_keys(changes,array['correction_kind','amount_ml']);action_name='propose_feeding';action_payload=changes||jsonb_build_object('target_id',target);
  else
   if not remove_record and changes='{}'::jsonb then raise exception 'Describe what should change.' using errcode='22023';end if;
   if not remove_record then
    if target_kind='diaper' then perform private.care_keys(changes,array['diaper_kind','occurred_at']);
    elsif target_kind='weight' then perform private.care_keys(changes,array['weight_kg','measurement_date','occurred_at']);
    elsif target_kind='sleep' then perform private.care_keys(changes,array['occurred_at','ended_at']);
    elsif target_kind='milestone' then perform private.care_keys(changes,array['title','note','occurred_on','date_precision']);end if;
   end if;
   action_name='propose_edit';action_payload=jsonb_build_object('target_id',target,'target_type',target_type,'expected_revision',(selected->>'revision')::integer,'void',remove_record);
   if not remove_record then
    action_payload=action_payload||case target_kind
     when 'diaper' then jsonb_build_object('diaper_kind',selected->'diaper_kind','occurred_at',selected->'occurred_at')
     when 'weight' then jsonb_build_object('weight_kg',selected->'weight_kg','measurement_date',coalesce(selected->>'measurement_date',private.care_local((selected->>'occurred_at')::timestamptz,p_time_zone,p_zone_offsets)::date::text),'occurred_at',selected->'occurred_at')
     when 'sleep' then jsonb_build_object('occurred_at',selected->'started_at','ended_at',selected->'ended_at')
     else jsonb_build_object('title',selected->'title','note',selected->'note','occurred_on',selected->'occurred_on','date_precision',selected->'date_precision') end||changes;
   end if;
  end if;
  result=public.execute_care_command(c.id,p_request_id,p_request_hash,action_name,p_reference_at,p_source,action_payload,p_time_zone,p_utc_offset_seconds,p_zone_offsets);
  result=private.care_present(result,c.id,action_name,action_payload,p_time_zone,p_zone_offsets);
 else
  perform private.care_keys(p_payload,array['action','payload']);action_name=p_payload->>'action';action_payload=p_payload->'payload';
  if action_name is null or action_name not in ('record','sleep_start','sleep_end','sleep_interval','milestone','propose_feeding','propose_edit','confirm','cancel') or jsonb_typeof(action_payload) is distinct from 'object' then raise exception 'Unsupported care action.' using errcode='22023';end if;
  guide=action_payload->>'guide_id';
  if guide is not null then
   if action_name<>'milestone' or guide !~ '^(cdc|rbr|cps)-[a-z0-9-]{1,76}$' then raise exception 'Invalid milestone guide reference.' using errcode='22023';end if;
   select * into found_milestone from public.milestones where child_id=c.id and guide_id=guide and voided_at is null;
   if found then
    result=jsonb_build_object('status','recorded','message',format('This milestone is already recorded for %s.',c.name),'event_id',found_milestone.id,'child_id',c.id,'already_recorded',true);
   end if;
  end if;
  if result is null and guide is not null then
   -- An explicit guide observation has its own identity. Do not relabel or infer
   -- achievement from an existing free-text memory, even with an equal title/date.
   perform private.care_keys(action_payload,array['title','note','occurred_on','date_precision','is_first','guide_id']);
   on_date=(action_payload->>'occurred_on')::date;precision_value=action_payload->>'date_precision';
   if jsonb_typeof(action_payload->'title') is distinct from 'string' or length(btrim(action_payload->>'title')) not between 1 and 120
    or on_date is null or not isfinite(on_date) or on_date>reference_day or on_date<date '1900-01-01'
    or precision_value is null or precision_value not in ('day','month') or precision_value='month' and extract(day from on_date)<>1
    or action_payload->>'note' is not null and (jsonb_typeof(action_payload->'note')<>'string' or length(action_payload->>'note')>1000)
    or action_payload->>'is_first' is not null and jsonb_typeof(action_payload->'is_first')<>'boolean'
    or c.date_of_birth is not null and (case when precision_value='month' then on_date+interval '1 month'-interval '1 day' else on_date end)<c.date_of_birth then
     raise exception 'Provide a milestone title and past observation date.' using errcode='22023';
   end if;
   insert into public.milestones(child_id,title,note,occurred_on,date_precision,is_first,recorded_by,input_source,guide_id)
    values(c.id,btrim(action_payload->>'title'),action_payload->>'note',on_date,precision_value,coalesce((action_payload->>'is_first')::boolean,false),auth.uid(),p_source,guide) returning * into found_milestone;
   result=jsonb_build_object('status','recorded','message',format('Recorded %s for %s.',found_milestone.title,c.name),'event_id',found_milestone.id,'child_id',c.id);
  elsif result is null then
   result=public.execute_care_command(c.id,p_request_id,p_request_hash,action_name,p_reference_at,p_source,action_payload,p_time_zone,p_utc_offset_seconds,p_zone_offsets);
  end if;
  result=private.care_present(result,c.id,action_name,action_payload,p_time_zone,p_zone_offsets);
 end if;
 result=result||jsonb_build_object('language',p_language);
 insert into public.care_receipts(recorded_by,request_id,request_hash,child_id,response) values(auth.uid(),p_request_id,p_request_hash,c.id,result)
 on conflict(recorded_by,request_id) do update set response=excluded.response where public.care_receipts.request_hash=excluded.request_hash and public.care_receipts.child_id=excluded.child_id;
 return result;
end $$;
revoke all on function private.care_label(jsonb,text),private.care_local(timestamptz,text,jsonb),private.care_present(jsonb,uuid,text,jsonb,text,jsonb) from public,anon,authenticated;
revoke all on function public.execute_care_conversation(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text) from public,anon;
grant execute on function public.execute_care_conversation(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb,text) to authenticated;
commit;
