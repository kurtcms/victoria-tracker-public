-- Forward-only expansion. The original migration is immutable.
begin;

alter table public.children
  add column archived_at timestamptz,
  add column profile_version integer not null default 1 check (profile_version > 0),
  add column growth_reference_confirmed boolean not null default false,
  add column was_premature boolean;
create unique index children_active_name on public.children(family_id, lower(normalize(btrim(name)))) where archived_at is null;
alter table public.children add constraint child_birth_date check (date_of_birth is null or date_of_birth between date '1900-01-01' and current_date);

alter table public.events
  add column revision integer not null default 1 check (revision > 0),
  add column voided_at timestamptz,
  add column feeding_basis_ml numeric(7,2),
  add column measurement_date date;
update public.events set feeding_basis_ml = volume_ml where event_type = 'feeding';
-- Keep voided entries out of legacy clients' totals too. Revisions preserve the audit history.
drop policy events_read on public.events;
create policy events_read on public.events for select to authenticated using (
  voided_at is null and exists(select 1 from public.children c where c.id = child_id and private.is_family_member(c.family_id))
);

create table public.sleep_sessions (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id),
  started_at timestamptz not null,
  ended_at timestamptz,
  recorded_by uuid not null references auth.users(id),
  input_source public.input_source not null,
  created_at timestamptz not null default now(),
  revision integer not null default 1 check(revision > 0),
  voided_at timestamptz,
  check(isfinite(started_at) and (ended_at is null or isfinite(ended_at) and ended_at > started_at))
);
create unique index sleep_one_open on public.sleep_sessions(child_id) where ended_at is null and voided_at is null;
create index sleep_child_time on public.sleep_sessions(child_id, started_at desc);
create table public.milestones (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id),
  title text not null check(length(btrim(title)) between 1 and 120),
  note text check(length(note) <= 1000),
  occurred_on date not null,
  date_precision text not null check(date_precision in ('day','month')),
  is_first boolean not null default false,
  recorded_by uuid not null references auth.users(id),
  input_source public.input_source not null,
  created_at timestamptz not null default now(),
  revision integer not null default 1 check(revision > 0),
  voided_at timestamptz,
  check(date_precision <> 'month' or extract(day from occurred_on) = 1)
);
create index milestones_child_date on public.milestones(child_id, occurred_on desc);
create table public.care_receipts (
  recorded_by uuid not null references auth.users(id),
  request_id uuid not null,
  request_hash text not null check(request_hash ~ '^[a-f0-9]{64}$'),
  child_id uuid not null references public.children(id),
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key(recorded_by, request_id)
);
create table public.care_proposals (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id),
  recorded_by uuid not null references auth.users(id),
  target_type text not null check(target_type in ('feeding','event','sleep','milestone')),
  target_id uuid not null,
  expected_revision integer not null,
  changes jsonb not null,
  message text not null,
  expires_at timestamptz not null default now() + interval '10 minutes',
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  response jsonb,
  created_at timestamptz not null default now()
);
create table public.care_revisions (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id),
  target_type text not null,
  target_id uuid not null,
  changed_by uuid not null references auth.users(id),
  before_value jsonb not null,
  after_value jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.sleep_sessions enable row level security;
alter table public.milestones enable row level security;
alter table public.care_receipts enable row level security;
alter table public.care_proposals enable row level security;
alter table public.care_revisions enable row level security;
create policy sleep_read on public.sleep_sessions for select to authenticated using (
  voided_at is null and exists(select 1 from public.children c where c.id = child_id and private.is_family_member(c.family_id)));
create policy milestones_read on public.milestones for select to authenticated using (
  voided_at is null and exists(select 1 from public.children c where c.id = child_id and private.is_family_member(c.family_id)));
create policy receipt_read on public.care_receipts for select to authenticated using (
  recorded_by = auth.uid() and exists(select 1 from public.children c where c.id = child_id and private.is_family_member(c.family_id)));
create policy proposal_read on public.care_proposals for select to authenticated using (
  recorded_by = auth.uid() and exists(select 1 from public.children c where c.id = child_id and private.is_family_member(c.family_id)));
create policy revision_read on public.care_revisions for select to authenticated using (
  exists(select 1 from public.children c where c.id = child_id and private.is_family_member(c.family_id)));
revoke all on public.sleep_sessions, public.milestones, public.care_receipts, public.care_proposals, public.care_revisions from public, anon, authenticated;
grant select on public.sleep_sessions, public.milestones, public.care_receipts, public.care_proposals, public.care_revisions to authenticated;

create function private.care_keys(p jsonb, allowed text[]) returns void language plpgsql set search_path = '' as $$
begin
  if jsonb_typeof(p) is distinct from 'object' or exists(select 1 from jsonb_object_keys(p) k where not k = any(allowed)) then
    raise exception 'Unexpected action fields' using errcode = '22023';
  end if;
end $$;
create function private.care_time(t timestamptz, r timestamptz) returns void language plpgsql set search_path = '' as $$
begin
  if t is null or not isfinite(t) or t > r or t < now() - interval '366 days' then
    raise exception 'Use a completed event within the last year' using errcode = '22023';
  end if;
end $$;
revoke all on function private.care_keys(jsonb,text[]), private.care_time(timestamptz,timestamptz) from public, anon, authenticated;

create function public.create_family_v2(p_name text, p_time_zone text) returns public.children
language plpgsql security definer set search_path = '' as $$
declare f uuid; c public.children;
begin
  if auth.uid() is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80 or p_name ~ '[[:cntrl:]]'
    or not exists(select 1 from pg_timezone_names where name=p_time_zone) then
    raise exception 'Provide a baby name and valid timezone' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
  select family_id into f from public.family_members where user_id=auth.uid();
  if found then
    select * into c from public.children where family_id=f and archived_at is null order by created_at limit 1;
    return c; -- A retry cannot create a second family.
  end if;
  insert into public.families(name) values('Our family') returning id into f;
  insert into public.family_members(family_id,user_id,role) values(f,auth.uid(),'owner');
  insert into public.children(family_id,name,time_zone) values(f,normalize(btrim(p_name)),p_time_zone) returning * into c;
  return c;
end $$;

create function public.save_child(p_child_id uuid, p_name text, p_birth_date date, p_reference_sex text,
  p_reference_confirmed boolean, p_was_premature boolean, p_expected_version integer default null,
  p_archive boolean default false) returns public.children
language plpgsql security definer set search_path = '' as $$
declare f uuid; c public.children; old public.children;
begin
  select family_id into f from public.family_members where user_id=auth.uid();
  if f is null then raise exception 'Join your family first' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(f::text,5));
  if p_name is null or length(btrim(p_name)) not between 1 and 80 or p_name ~ '[[:cntrl:]]'
    or p_reference_sex is not null and p_reference_sex not in ('female','male')
    or p_reference_confirmed is null or p_archive is null
    or p_birth_date is not null and (not isfinite(p_birth_date) or p_birth_date > current_date or p_birth_date < date '1900-01-01')
    or p_reference_confirmed and p_reference_sex is null then
    raise exception 'Check the baby profile fields' using errcode='22023';
  end if;
  if p_child_id is null then
    if p_archive then raise exception 'Cannot archive an unsaved profile' using errcode='22023'; end if;
    insert into public.children(family_id,name,date_of_birth,growth_reference_sex,growth_reference_confirmed,was_premature)
      values(f,normalize(btrim(p_name)),p_birth_date,p_reference_sex,p_reference_confirmed,p_was_premature) returning * into c;
  else
    select * into old from public.children where id=p_child_id and family_id=f for update;
    if not found then raise exception 'Baby not accessible' using errcode='42501'; end if;
    if old.profile_version is distinct from p_expected_version then raise exception 'Profile changed. Refresh and review it again.' using errcode='40001'; end if;
    -- Same child lock as care commands: archiving cannot race a new sleep start.
    perform pg_advisory_xact_lock(hashtextextended(p_child_id::text,4));
    if p_archive and exists(select 1 from public.sleep_sessions where child_id=p_child_id and ended_at is null and voided_at is null) then
      raise exception 'Finish or cancel the active sleep before archiving' using errcode='22023';
    end if;
    update public.children set name=normalize(btrim(p_name)),date_of_birth=p_birth_date,growth_reference_sex=p_reference_sex,
      growth_reference_confirmed=p_reference_confirmed,was_premature=p_was_premature,
      archived_at=case when p_archive then coalesce(archived_at,now()) else null end,profile_version=profile_version+1
      where id=p_child_id returning * into c;
    insert into public.care_revisions(child_id,target_type,target_id,changed_by,before_value,after_value)
      values(c.id,'profile',c.id,auth.uid(),to_jsonb(old),to_jsonb(c));
  end if;
  return c;
exception when unique_violation then raise exception 'Use a distinct name for each active baby' using errcode='22023';
end $$;

create function public.execute_care_command(p_child_id uuid, p_request_id uuid, p_request_hash text,
  p_action text, p_reference_at timestamptz, p_source public.input_source, p_payload jsonb, p_time_zone text, p_utc_offset_seconds integer default 0, p_zone_offsets jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.children; e public.events; s public.sleep_sessions; m public.milestones;
  q public.care_proposals; receipt public.care_receipts; result jsonb; old jsonb; after_row jsonb;
  t timestamptz; ending timestamptz; target uuid; v numeric; basis numeric; kind text; v_title text;
  on_date date; precision text; before_revision integer; amount numeric; msg text; proposed jsonb; target_offset integer;
begin
  if auth.uid() is null or not exists(select 1 from public.children x join public.family_members fm on fm.family_id=x.family_id
    where x.id=p_child_id and fm.user_id=auth.uid()) then
    raise exception 'Baby not accessible' using errcode='42501';
  end if;
  if p_request_id is null or p_request_hash is null or p_request_hash !~ '^[a-f0-9]{64}$' or p_source is null
    or p_reference_at is null or not isfinite(p_reference_at) or p_reference_at > now()+interval '5 minutes'
    or p_reference_at < now()-interval '366 days' or p_action is null
    or not exists(select 1 from pg_timezone_names where name=p_time_zone) or p_utc_offset_seconds is null or abs(p_utc_offset_seconds)>50400
    or jsonb_typeof(p_zone_offsets) is distinct from 'array' or jsonb_array_length(p_zone_offsets)>16 then
    raise exception 'Invalid command metadata' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,6));
  select * into receipt from public.care_receipts where recorded_by=auth.uid() and request_id=p_request_id;
  if found then
    if receipt.request_hash<>p_request_hash or receipt.child_id<>p_child_id then raise exception 'Idempotency conflict' using errcode='23505'; end if;
    return receipt.response || jsonb_build_object('replayed',true) || case when receipt.response->>'status'='recorded' then jsonb_build_object('message','This action was already saved. Nothing was recorded again. Check the app for any later corrections.') else '{}'::jsonb end;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_child_id::text,4));
  select * into c from public.children where id=p_child_id;
  if c.archived_at is not null then raise exception 'This baby is archived. Restore the profile before recording.' using errcode='22023'; end if;
  perform private.care_keys(p_payload,array['occurred_at','ended_at','event_type','volume_ml','weight_kg','diaper_kind',
    'measurement_date','title','note','occurred_on','date_precision','is_first','correction_kind','amount_ml','target_id',
    'target_type','expected_revision','void','proposal_id']);

  if p_action='record' then
    perform private.care_keys(p_payload,array['occurred_at','event_type','volume_ml','weight_kg','diaper_kind','measurement_date']);
    t=(p_payload->>'occurred_at')::timestamptz; perform private.care_time(t,p_reference_at);
    e=public.record_event(p_child_id,p_request_id,p_request_hash,(p_payload->>'event_type')::public.event_type,t,p_source,
      (p_payload->>'volume_ml')::numeric,(p_payload->>'diaper_kind')::public.diaper_kind,(p_payload->>'weight_kg')::numeric);
    if e.event_type='weight' then
      on_date=(p_payload->>'measurement_date')::date;
      if on_date is null or not isfinite(on_date) or on_date > ((p_reference_at+make_interval(secs=>p_utc_offset_seconds)) at time zone 'UTC')::date
        or c.date_of_birth is not null and on_date<c.date_of_birth then raise exception 'Check the measurement date' using errcode='22023'; end if;
      update public.events set measurement_date=on_date where id=e.id;
    end if;
    msg=case e.event_type when 'feeding' then format('Recorded %s millilitres for %s.',trim_scale(e.volume_ml),c.name)
      when 'diaper' then format('Recorded a %s diaper for %s.',case e.diaper_kind when 'mixed' then 'wet and dirty' else e.diaper_kind::text end,c.name)
      else format('Recorded %s kilograms for %s.',trim_scale(e.weight_kg),c.name) end;
    result=jsonb_build_object('status','recorded','message',msg,'event_id',e.id,'child_id',c.id);
  elsif p_action in ('sleep_start','sleep_end','sleep_interval') then
    perform private.care_keys(p_payload,array['occurred_at','ended_at']);
    t=(p_payload->>'occurred_at')::timestamptz; perform private.care_time(t,p_reference_at);
    if p_action='sleep_end' then
      select * into s from public.sleep_sessions where child_id=c.id and ended_at is null and voided_at is null for update;
      if not found then return jsonb_build_object('status','needs_clarification','message',format('No sleep is running for %s. Please give the sleep start and wake times.',c.name)); end if;
      if t<=s.started_at then raise exception 'Wake time must follow the sleep start' using errcode='22023'; end if;
      old=to_jsonb(s);
      update public.sleep_sessions set ended_at=t,revision=revision+1 where id=s.id returning * into s;
      insert into public.care_revisions(child_id,target_type,target_id,changed_by,before_value,after_value) values(c.id,'sleep',s.id,auth.uid(),old,to_jsonb(s));
      msg=format('Recorded %s waking up after %s minutes of sleep.',c.name,round(extract(epoch from(s.ended_at-s.started_at))/60));
    else
      if p_action='sleep_interval' then ending=(p_payload->>'ended_at')::timestamptz; perform private.care_time(ending,p_reference_at);
      else ending=null; end if;
      if ending is not null and ending<=t then raise exception 'Wake time must follow the sleep start' using errcode='22023'; end if;
      if exists(select 1 from public.sleep_sessions x where x.child_id=c.id and x.voided_at is null
        and tstzrange(x.started_at,x.ended_at,'[)') && tstzrange(t,ending,'[)')) then
        return jsonb_build_object('status','needs_clarification','message',format('That overlaps sleep already recorded for %s. Please review or correct the existing sleep in the app.',c.name));
      end if;
      insert into public.sleep_sessions(child_id,started_at,ended_at,recorded_by,input_source) values(c.id,t,ending,auth.uid(),p_source) returning * into s;
      msg=case when ending is null then format('Recorded %s falling asleep.',c.name) else format('Recorded %s minutes of sleep for %s.',round(extract(epoch from(ending-t))/60),c.name) end;
    end if;
    result=jsonb_build_object('status','recorded','message',msg,'event_id',s.id,'child_id',c.id);
  elsif p_action='milestone' then
    perform private.care_keys(p_payload,array['title','note','occurred_on','date_precision','is_first']);
    v_title=btrim(p_payload->>'title'); on_date=(p_payload->>'occurred_on')::date; precision=p_payload->>'date_precision';
    if v_title is null or length(v_title) not between 1 and 120 or on_date is null or not isfinite(on_date)
      or on_date > ((p_reference_at+make_interval(secs=>p_utc_offset_seconds)) at time zone 'UTC')::date or on_date<date '1900-01-01'
      or precision is null or precision not in ('day','month') or length(p_payload->>'note')>1000
      or c.date_of_birth is not null and (case when precision='month' then on_date+interval '1 month'-interval '1 day' else on_date end)<c.date_of_birth then
      raise exception 'Provide a milestone title and past date' using errcode='22023'; end if;
    if precision='month' and extract(day from on_date)<>1 then raise exception 'Month-only milestones use the first day with month precision' using errcode='22023'; end if;
    if exists(select 1 from public.milestones x where x.child_id=c.id and x.voided_at is null and lower(x.title)=lower(v_title)
      and (x.occurred_on=on_date or x.is_first and coalesce((p_payload->>'is_first')::boolean,false))) then
      return jsonb_build_object('status','needs_clarification','message','A matching milestone is already recorded. Review it in Milestones, or describe what makes this a separate observation.'); end if;
    insert into public.milestones(child_id,title,note,occurred_on,date_precision,is_first,recorded_by,input_source)
      values(c.id,v_title,p_payload->>'note',on_date,precision,coalesce((p_payload->>'is_first')::boolean,false),auth.uid(),p_source) returning * into m;
    result=jsonb_build_object('status','recorded','message',format('Recorded %s for %s.',v_title,c.name),'event_id',m.id,'child_id',c.id);
  elsif p_action='propose_feeding' then
    perform private.care_keys(p_payload,array['target_id','correction_kind','amount_ml']);
    target=(p_payload->>'target_id')::uuid;
    if target is null then
      select * into e from public.events where child_id=c.id and event_type='feeding' and voided_at is null
        and occurred_at<=p_reference_at and occurred_at>=p_reference_at-interval '6 hours' order by occurred_at desc,id limit 1 for update;
      if found and (select count(*) from public.events where child_id=c.id and event_type='feeding' and voided_at is null and occurred_at=e.occurred_at)>1 then
        return jsonb_build_object('status','needs_clarification','message','There is more than one feeding at that time. Choose the feeding in the app to correct.'); end if;
    else select * into e from public.events where id=target and child_id=c.id and event_type='feeding' and voided_at is null for update; end if;
    if e.id is null then return jsonb_build_object('status','needs_clarification','message',format('Which feeding should I correct for %s? Choose a feeding in the app if it was more than six hours ago.',c.name)); end if;
    amount=(p_payload->>'amount_ml')::numeric; kind=p_payload->>'correction_kind'; basis=coalesce(e.feeding_basis_ml,e.volume_ml);
    if amount is null or amount<0 or amount>2000 or amount<>round(amount,2) or kind is null or kind not in ('leftover','total') then
      raise exception 'Provide the leftover or corrected total in millilitres' using errcode='22023'; end if;
    v=case when kind='leftover' then basis-amount else amount end;
    if v<0 then raise exception 'Leftover cannot exceed the original bottle amount' using errcode='22023'; end if;
    if v=e.volume_ml then return jsonb_build_object('status','rejected','message',format('That feeding is already %s millilitres. Nothing changed.',trim_scale(v))); end if;
    proposed=jsonb_build_object('volume_ml',v,'basis_ml',basis,'leftover_ml',case when kind='leftover' then amount else null end,'void',v=0);
    select (value->>'seconds')::integer into target_offset from jsonb_array_elements(p_zone_offsets)
      where (value->>'from')::timestamptz<=e.occurred_at order by (value->>'from')::timestamptz desc limit 1;
    if target_offset is not null and abs(target_offset)>50400 then raise exception 'Invalid phone offset' using errcode='22023';end if;
    msg=format('Change %s’s feeding at %s from %s to %s millilitres?',c.name,
      case when target_offset is not null then to_char((e.occurred_at+make_interval(secs=>target_offset)) at time zone 'UTC','Mon DD, HH12:MI AM')
      else to_char(e.occurred_at at time zone p_time_zone,'Mon DD, HH12:MI AM') end,trim_scale(e.volume_ml),trim_scale(v));
    insert into public.care_proposals(child_id,recorded_by,target_type,target_id,expected_revision,changes,message)
      values(c.id,auth.uid(),'feeding',e.id,e.revision,proposed,msg) returning * into q;
    result=jsonb_build_object('status','needs_confirmation','message',q.message,'proposal_id',q.id,'child_id',c.id);
  elsif p_action='propose_edit' then
    perform private.care_keys(p_payload,array['target_id','target_type','expected_revision','occurred_at','ended_at','title','note','occurred_on','date_precision','void','weight_kg','diaper_kind','measurement_date']);
    target=(p_payload->>'target_id')::uuid; kind=p_payload->>'target_type'; before_revision=(p_payload->>'expected_revision')::integer;
    if kind='sleep' then select to_jsonb(x),x.revision into old,before_revision from public.sleep_sessions x where id=target and child_id=c.id and voided_at is null;
    elsif kind='milestone' then select to_jsonb(x),x.revision into old,before_revision from public.milestones x where id=target and child_id=c.id and voided_at is null;
    elsif kind='event' then select to_jsonb(x),x.revision into old,before_revision from public.events x where id=target and child_id=c.id and voided_at is null;
    else raise exception 'Unsupported correction target' using errcode='22023'; end if;
    if old is null then raise exception 'Record not accessible' using errcode='42501'; end if;
    if before_revision is distinct from (p_payload->>'expected_revision')::integer then raise exception 'Record changed. Refresh and review it again.' using errcode='40001'; end if;
    if kind='event' and old->>'event_type'='feeding' and not coalesce((p_payload->>'void')::boolean,false) then raise exception 'Use feeding correction for milk intake' using errcode='22023'; end if;
    msg=format('%s this %s record for %s?',case when coalesce((p_payload->>'void')::boolean,false) then 'Remove' else 'Update' end,kind,c.name);
    insert into public.care_proposals(child_id,recorded_by,target_type,target_id,expected_revision,changes,message)
      values(c.id,auth.uid(),kind,target,before_revision,p_payload,msg) returning * into q;
    result=jsonb_build_object('status','needs_confirmation','message',q.message,'proposal_id',q.id,'child_id',c.id);
  elsif p_action in ('confirm','cancel') then
    perform private.care_keys(p_payload,array['proposal_id']);
    select * into q from public.care_proposals where id=(p_payload->>'proposal_id')::uuid and child_id=c.id and recorded_by=auth.uid() for update;
    if not found then raise exception 'Confirmation not accessible' using errcode='42501'; end if;
    if q.confirmed_at is not null then return q.response || jsonb_build_object('replayed',true,'message','This correction was already saved. Nothing changed again. Check the app for any later corrections.'); end if;
    if p_action='cancel' then
      update public.care_proposals set cancelled_at=coalesce(cancelled_at,now()) where id=q.id;
      result=jsonb_build_object('status','rejected','message','Cancelled. Nothing changed.');
    else
      if q.cancelled_at is not null or q.expires_at<now() then return jsonb_build_object('status','rejected','message','This confirmation has expired or was cancelled. Nothing changed. Please review the correction again.'); end if;
      if q.target_type in ('feeding','event') then select to_jsonb(x),x.revision into old,before_revision from public.events x where id=q.target_id and child_id=c.id for update;
      elsif q.target_type='sleep' then select to_jsonb(x),x.revision into old,before_revision from public.sleep_sessions x where id=q.target_id and child_id=c.id for update;
      else select to_jsonb(x),x.revision into old,before_revision from public.milestones x where id=q.target_id and child_id=c.id for update; end if;
      if old is null or before_revision<>q.expected_revision or old->>'voided_at' is not null then
        return jsonb_build_object('status','rejected','message','This record changed since the confirmation. Nothing changed. Refresh and review it again.'); end if;
      if q.target_type='feeding' then
        v=(q.changes->>'volume_ml')::numeric;
        update public.events set volume_ml=case when v=0 then volume_ml else v end, feeding_basis_ml=(q.changes->>'basis_ml')::numeric,
          voided_at=case when v=0 then now() else null end,revision=revision+1 where id=q.target_id returning to_jsonb(events.*) into after_row;
        msg=format('Changed %s’s feeding from %s to %s millilitres.',c.name,trim_scale((old->>'volume_ml')::numeric),trim_scale(v));
      elsif q.target_type='sleep' then
        if coalesce((q.changes->>'void')::boolean,false) then
          update public.sleep_sessions set voided_at=now(),revision=revision+1 where id=q.target_id returning to_jsonb(sleep_sessions.*) into after_row;
        else
          t=(q.changes->>'occurred_at')::timestamptz; ending=(q.changes->>'ended_at')::timestamptz;
          perform private.care_time(t,p_reference_at); if ending is not null then perform private.care_time(ending,p_reference_at); end if;
          if ending is not null and ending<=t or exists(select 1 from public.sleep_sessions x where x.child_id=c.id and x.id<>q.target_id and x.voided_at is null
            and tstzrange(x.started_at,x.ended_at,'[)') && tstzrange(t,ending,'[)')) then raise exception 'Check sleep times; they overlap or end before the start' using errcode='22023'; end if;
          update public.sleep_sessions set started_at=t,ended_at=ending,revision=revision+1 where id=q.target_id returning to_jsonb(sleep_sessions.*) into after_row;
        end if; msg=format('Updated the sleep record for %s.',c.name);
      elsif q.target_type='milestone' then
        if coalesce((q.changes->>'void')::boolean,false) then
          update public.milestones set voided_at=now(),revision=revision+1 where id=q.target_id returning to_jsonb(milestones.*) into after_row;
        else
          v_title=btrim(q.changes->>'title'); on_date=(q.changes->>'occurred_on')::date; precision=q.changes->>'date_precision';
          if v_title is null or on_date is null or on_date>((p_reference_at+make_interval(secs=>p_utc_offset_seconds)) at time zone 'UTC')::date or on_date<date '1900-01-01' then raise exception 'Check the milestone date and title' using errcode='22023'; end if;
          update public.milestones set title=v_title,note=q.changes->>'note',occurred_on=on_date,date_precision=precision,revision=revision+1
            where id=q.target_id returning to_jsonb(milestones.*) into after_row;
        end if; msg=format('Updated the milestone for %s.',c.name);
      else
        if coalesce((q.changes->>'void')::boolean,false) then
          update public.events set voided_at=now(),revision=revision+1 where id=q.target_id returning to_jsonb(events.*) into after_row;
          msg=format('Removed the record for %s from totals.',c.name);
        else
          t=(q.changes->>'occurred_at')::timestamptz;perform private.care_time(t,p_reference_at);
          if old->>'event_type'='weight' then
            v=(q.changes->>'weight_kg')::numeric;on_date=(q.changes->>'measurement_date')::date;
            if v is null or v<=0 or v>100 or v<>round(v,3) or on_date is null or not isfinite(on_date)
              or on_date>((p_reference_at+make_interval(secs=>p_utc_offset_seconds)) at time zone 'UTC')::date or c.date_of_birth is not null and on_date<c.date_of_birth then
              raise exception 'Check the weight and measurement date' using errcode='22023';end if;
            update public.events set occurred_at=t,weight_kg=v,measurement_date=on_date,revision=revision+1 where id=q.target_id returning to_jsonb(events.*) into after_row;
          elsif old->>'event_type'='diaper' then
            if q.changes->>'diaper_kind' is null or q.changes->>'diaper_kind' not in ('wet','dirty','mixed') then raise exception 'Choose wet, dirty or mixed' using errcode='22023';end if;
            update public.events set occurred_at=t,diaper_kind=(q.changes->>'diaper_kind')::public.diaper_kind,revision=revision+1 where id=q.target_id returning to_jsonb(events.*) into after_row;
          else raise exception 'Use the feeding correction action' using errcode='22023';end if;
          msg=format('Updated the record for %s.',c.name);
        end if;
      end if;
      insert into public.care_revisions(child_id,target_type,target_id,changed_by,before_value,after_value) values(c.id,q.target_type,q.target_id,auth.uid(),old,after_row);
      result=jsonb_build_object('status','recorded','message',msg,'event_id',q.target_id,'child_id',c.id);
      update public.care_proposals set confirmed_at=now(),response=result where id=q.id;
    end if;
  else raise exception 'Unsupported care action' using errcode='22023'; end if;
  insert into public.care_receipts(recorded_by,request_id,request_hash,child_id,response) values(auth.uid(),p_request_id,p_request_hash,c.id,result);
  return result;
end $$;

revoke all on function public.create_family_v2(text,text), public.save_child(uuid,text,date,text,boolean,boolean,integer,boolean),
  public.execute_care_command(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb) from public,anon;
grant execute on function public.create_family_v2(text,text), public.save_child(uuid,text,date,text,boolean,boolean,integer,boolean),
  public.execute_care_command(uuid,uuid,text,text,timestamptz,public.input_source,jsonb,text,integer,jsonb) to authenticated;

-- Prevent false legacy retry confirmations after a feeding is voided.
-- A trigger cannot intercept a function's replay SELECT, so the legacy RPC is replaced
-- with its original contract plus active-child / voided-replay checks.
create or replace function public.record_event(
  p_child_id uuid, p_request_id uuid, p_request_hash text,
  p_event_type public.event_type, p_occurred_at timestamptz, p_input_source public.input_source,
  p_volume_ml numeric default null, p_diaper_kind public.diaper_kind default null, p_weight_kg numeric default null
) returns public.events
language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  if auth.uid() is null or not exists(
    select 1 from public.children c join public.family_members m on m.family_id = c.family_id
    where c.id = p_child_id and c.archived_at is null and m.user_id = auth.uid()
  ) then raise exception 'Child not accessible' using errcode = '42501'; end if;
  if p_request_id is null or p_request_hash is null or p_request_hash !~ '^[a-f0-9]{64}$'
    or p_event_type is null or p_input_source is null then
    raise exception 'Invalid recording metadata' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_child_id::text,4));
  if exists(select 1 from public.children where id=p_child_id and archived_at is not null) then raise exception 'This baby is archived' using errcode='22023';end if;
  -- Serialize retries for this parent/request; conflicting reuse never changes a saved event.
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_request_id::text, 1));
  select * into e from public.events where recorded_by = auth.uid() and request_id = p_request_id;
  if found then
    if e.voided_at is not null then raise exception 'This record was removed. Review it in the updated app.' using errcode = '23505'; end if;
    if e.request_hash <> p_request_hash or e.child_id <> p_child_id then
      raise exception 'Idempotency conflict' using errcode = '23505';
    end if;
    return e;
  end if;
  if p_occurred_at is null or not isfinite(p_occurred_at)
    or p_occurred_at > now() + interval '5 minutes' or p_occurred_at < now() - interval '366 days' then
    raise exception 'Event timestamp out of range' using errcode = '22023';
  end if;
  -- Numeric column coercion rounds values before CHECK constraints see them.
  -- Validate RPC precision first so direct callers cannot silently round data.
  if (p_volume_ml is not null and p_volume_ml <> round(p_volume_ml, 2))
    or (p_weight_kg is not null and p_weight_kg <> round(p_weight_kg, 3)) then
    raise exception 'Too many decimal places' using errcode = '22023';
  end if;
  insert into public.events(child_id, event_type, occurred_at, recorded_by, input_source,
    request_id, request_hash, volume_ml, diaper_kind, weight_kg)
  values(p_child_id, p_event_type, p_occurred_at, auth.uid(), p_input_source,
    p_request_id, p_request_hash, p_volume_ml, p_diaper_kind, p_weight_kg) returning * into e;
  return e;
end;
$$;

commit;
