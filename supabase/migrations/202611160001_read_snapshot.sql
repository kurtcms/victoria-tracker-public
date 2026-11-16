-- Additive read contract. Existing commands/migrations remain unchanged.
begin;
create function public.read_care_snapshot(p_child_id uuid, p_reference_at timestamptz)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare e jsonb; s jsonb; m jsonb;
begin
 if auth.uid() is null or p_reference_at is null or not isfinite(p_reference_at)
   or p_reference_at > now() + interval '5 minutes'
   or not exists(select 1 from public.children where id=p_child_id and archived_at is null)
 then raise exception 'That baby is not available.' using errcode='42501'; end if;
 -- One MVCC snapshot across all domains. RLS applies with the caller's JWT.
 -- Bound payloads explicitly: the Edge Function rejects incomplete snapshots.
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into e from (
  select id,event_type,occurred_at,volume_ml,diaper_kind,weight_kg,measurement_date
  from public.events where child_id=p_child_id and voided_at is null and occurred_at<=p_reference_at
  order by occurred_at desc,id limit 10001
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into s from (
  select id,started_at,ended_at from public.sleep_sessions
  where child_id=p_child_id and voided_at is null and started_at<=p_reference_at
  order by started_at desc,id limit 10001
 ) x;
 select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into m from (
  select id,title,occurred_on,date_precision from public.milestones
  where child_id=p_child_id and voided_at is null
  order by occurred_on desc,id limit 10001
 ) x;
 return jsonb_build_object('complete',jsonb_array_length(e)<=10000 and jsonb_array_length(s)<=10000 and jsonb_array_length(m)<=10000,
   'events',e,'sleep',s,'milestones',m);
end $$;
revoke all on function public.read_care_snapshot(uuid,timestamptz) from public,anon;
grant execute on function public.read_care_snapshot(uuid,timestamptz) to authenticated;
commit;
