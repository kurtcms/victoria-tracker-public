begin;
-- Independent of WHO reference selection. Existing profiles stay unspecified.
alter table public.children add column voice_pronoun text check (voice_pronoun in ('she','he'));
-- A new RPC preserves the deployed save_child contract for older clients.
create function public.save_child_with_pronoun(p_child_id uuid, p_name text, p_birth_date date, p_reference_sex text,
  p_reference_confirmed boolean, p_was_premature boolean, p_expected_version integer default null,
  p_archive boolean default false, p_voice_pronoun text default null) returns public.children
language plpgsql security definer set search_path = '' as $$
declare f uuid; c public.children; old public.children;
begin
  select family_id into f from public.family_members where user_id=auth.uid();
  if f is null then raise exception 'Join your family first' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(f::text,5));
  if p_name is null or length(btrim(p_name)) not between 1 and 80 or p_name ~ '[[:cntrl:]]'
    or p_reference_sex is not null and p_reference_sex not in ('female','male')
    or p_voice_pronoun is not null and p_voice_pronoun not in ('she','he')
    or p_reference_confirmed is null or p_archive is null
    or p_birth_date is not null and (not isfinite(p_birth_date) or p_birth_date > current_date or p_birth_date < date '1900-01-01')
    or p_reference_confirmed and p_reference_sex is null then
    raise exception 'Check the baby profile fields' using errcode='22023';
  end if;
  if p_child_id is null then
    if p_archive then raise exception 'Cannot archive an unsaved profile' using errcode='22023'; end if;
    insert into public.children(family_id,name,date_of_birth,growth_reference_sex,growth_reference_confirmed,was_premature,voice_pronoun)
      values(f,normalize(btrim(p_name)),p_birth_date,p_reference_sex,p_reference_confirmed,p_was_premature,p_voice_pronoun) returning * into c;
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
      growth_reference_confirmed=p_reference_confirmed,was_premature=p_was_premature,voice_pronoun=p_voice_pronoun,
      archived_at=case when p_archive then coalesce(archived_at,now()) else null end,profile_version=profile_version+1
      where id=p_child_id returning * into c;
    insert into public.care_revisions(child_id,target_type,target_id,changed_by,before_value,after_value)
      values(c.id,'profile',c.id,auth.uid(),to_jsonb(old),to_jsonb(c));
  end if;
  return c;
exception when unique_violation then raise exception 'Use a distinct name for each active baby' using errcode='22023';
end $$;

revoke all on function public.save_child_with_pronoun(uuid,text,date,text,boolean,boolean,integer,boolean,text) from public, anon;
grant execute on function public.save_child_with_pronoun(uuid,text,date,text,boolean,boolean,integer,boolean,text) to authenticated;
commit;
